// daily_stats.go is the storage of F2 Creator Studio insights that identity owns (FEATURE_CREATOR_INSIGHTS):
//
//	users/{uid}/dailyStats/{yyyymmdd IST} {date, impressions, engagements, followersGained, followersLost, expireAt}
//
// One doc per creator and IST day. Other modules never name the path: they stage increments through StatsWriter, in
// the batch or transaction of the write that causes them (the Counters pattern), so a stat moves exactly when its cause
// commits:
//
//   - impressions: the view rollup (posts, FoldViews) adds each post's view delta (new total - old viewCount) on the
//     author's doc for the fold day, at most one write per author per fold batch;
//   - engagements: a like, repost, reply or quote received from another account adds 1 on the cold path (and an undo
//     subtracts 1 on the day of the undo); on a hot post the counter rollup (FoldCounters) adds the folded delta;
//   - followersGained / followersLost: graph's follow, accept, go-public, unfollow and block paths, on the followee.
//
// Every stage is a Set with MergeAll and Increment transforms: it has no precondition and creates the doc. It is only
// ever staged next to a write that carries an Exists precondition (the post's counter Update, the users doc's counter
// Update), so an erased author (posts and users doc gone) gets no doc: the commit fails before anything is written, and
// every fallback that drops the counter drops the stat too. An author being erased is not a concern for the erase
// step either: it runs after the posts and graph steps, when no counter write can reach the author any more.
//
// Hot doc: a creator's doc for today takes one write per like, repost, reply, quote and follow they receive (plus at
// most one per rollup batch), and Firestore sustains about one write per second on one document. That is the same
// exposure the plain counters already have (posts/{id}.likeCount, users/{uid}.followersCount); hot posts move their
// engagements to the rollup (HOT_COUNTER_THRESHOLD), which then writes the doc once per fold. A creator who receives more
// than about one engagement per second across all posts is the future sharding candidate (shardcount, like viewShards).
//
// Retention: expireAt is the IST day's start + DailyStatsTTL (400 days) on every write, so the TTL policy
// (infra/terraform/modules/firestore, collection group dailyStats) deletes the doc about 400 days later. The account
// erasure deletes the docs outright (PurgeDailyStatsPage) and the export includes them (ExportDailyStats).
//
// While FEATURE_CREATOR_INSIGHTS is globally off nothing is staged (off), so the prod default writes nothing.
package identity

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// DailyStatsSubcollection is users/{uid}/dailyStats (lifecycle tables, the TTL policy's collection group).
	DailyStatsSubcollection = "dailyStats"
	// DailyStatsTTL is expireAt - the IST day's start.
	DailyStatsTTL = 400 * 24 * time.Hour
	// dailyStatsPage is the page of the erase step and of the export (ops paths; a batch holds 500 writes). An account
	// has at most about 400 docs (the TTL), so the export is one or two pages.
	dailyStatsPage = 500
	// dailyStatsExportMax bounds the export (a TTL that has not run yet may leave a few more docs than 400).
	dailyStatsExportMax = 2 * dailyStatsPage
	// MaxInsightsWindowDays is the longest GetCreatorInsights window (and the default): a call reads twice as many docs.
	MaxInsightsWindowDays = 28
)

// ist is the zone of the day key (the daily quotas' and the impressions dedupe's: quota.TodayAt).
var ist = time.FixedZone("IST", 5*3600+30*60)

// StatsDay is the dailyStats day key (yyyymmdd) of t: the IST day, the same key as the impressions dedupe day
// (engagement.ImpressionDay), rolling over at 18:30 UTC.
func StatsDay(t time.Time) string {
	return strings.ReplaceAll(quota.TodayAt(t), "-", "")
}

// statsDayStart is the IST midnight a day key names; false for a malformed key.
func statsDayStart(day string) (time.Time, bool) {
	t, err := time.ParseInLocation("20060102", day, ist)
	if err != nil || len(day) != 8 {
		return time.Time{}, false
	}
	return t, true
}

// DailyDelta is one change of a creator's daily stats. Negative values are undos.
type DailyDelta struct {
	Impressions     int64
	Engagements     int64
	FollowersGained int64
	FollowersLost   int64
}

// IsZero reports a delta that changes nothing.
func (d DailyDelta) IsZero() bool {
	return d.Impressions == 0 && d.Engagements == 0 && d.FollowersGained == 0 && d.FollowersLost == 0
}

// StatsWriter is the staging seam posts, engagement and graph write a creator's daily stats through, inside their own
// batch or transaction (the Counters pattern: they stage, they commit). *DailyStatsRepo implements it.
type StatsWriter interface {
	// StageDaily appends ONE write to b: Increment of every non-zero field of d on users/{uid}/dailyStats/{day}, with
	// date and expireAt set (Set with MergeAll, no precondition: stage it only next to a write that carries Exists on the
	// post or on users/{uid}). Nothing is appended for an empty uid, a zero delta, a malformed day, or while
	// FEATURE_CREATOR_INSIGHTS is globally off.
	StageDaily(b store.Batch, uid, day string, d DailyDelta)
}

// DailyStats is one creator's stats for one IST day as stored (values may be below zero after undos; readers clamp).
type DailyStats struct {
	Date            string
	Impressions     int64
	Engagements     int64
	FollowersGained int64
	FollowersLost   int64
}

// dailyStatsDoc is users/{uid}/dailyStats/{day}.
type dailyStatsDoc struct {
	Date            string    `firestore:"date" json:"date"`
	Impressions     int64     `firestore:"impressions" json:"impressions"`
	Engagements     int64     `firestore:"engagements" json:"engagements"`
	FollowersGained int64     `firestore:"followersGained" json:"followersGained"`
	FollowersLost   int64     `firestore:"followersLost" json:"followersLost"`
	ExpireAt        time.Time `firestore:"expireAt" json:"-"`
}

// DailyStatsRepo is the Firestore side of users/{uid}/dailyStats: the StatsWriter, the insights read, the erase page
// and the export.
type DailyStatsRepo struct {
	client *firestore.Client
	off    func() bool
}

var _ StatsWriter = (*DailyStatsRepo)(nil)

// NewDailyStatsRepo builds the repo. off reports FEATURE_CREATOR_INSIGHTS globally off (nil = never off): StageDaily
// then appends nothing.
func NewDailyStatsRepo(client *firestore.Client, off func() bool) *DailyStatsRepo {
	return &DailyStatsRepo{client: client, off: off}
}

func (r *DailyStatsRepo) col(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(DailyStatsSubcollection)
}

// StageDaily implements StatsWriter.
func (r *DailyStatsRepo) StageDaily(b store.Batch, uid, day string, d DailyDelta) {
	if r == nil || uid == "" || d.IsZero() || (r.off != nil && r.off()) {
		return
	}
	data, ok := dailyStatsIncrement(day, d)
	if !ok {
		return
	}
	b.Set(r.col(uid).Doc(day), data, firestore.MergeAll)
}

// dailyStatsIncrement is the MergeAll data of one stage: date, expireAt and an Increment per non-zero field. Pure.
func dailyStatsIncrement(day string, d DailyDelta) (map[string]any, bool) {
	start, ok := statsDayStart(day)
	if !ok {
		return nil, false
	}
	data := map[string]any{"date": day, "expireAt": start.Add(DailyStatsTTL).UTC()}
	for _, f := range []struct {
		name string
		n    int64
	}{
		{"impressions", d.Impressions}, {"engagements", d.Engagements},
		{"followersGained", d.FollowersGained}, {"followersLost", d.FollowersLost},
	} {
		if f.n != 0 {
			data[f.name] = firestore.Increment(f.n)
		}
	}
	return data, true
}

// ReadDailyStats reads uid's docs for days in ONE GetAll (len(days) reads, at most 2 x MaxInsightsWindowDays), in
// days' order; a missing doc is a zero DailyStats with its Date.
func (r *DailyStatsRepo) ReadDailyStats(ctx context.Context, uid string, days []string) ([]DailyStats, error) {
	if len(days) == 0 {
		return nil, nil
	}
	if len(days) > 2*MaxInsightsWindowDays {
		return nil, fmt.Errorf("identity: read daily stats: %d days is above %d", len(days), 2*MaxInsightsWindowDays)
	}
	refs := make([]*firestore.DocumentRef, len(days))
	for i, d := range days {
		refs[i] = r.col(uid).Doc(d)
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("identity: read daily stats %s: %w", logger.HashUID(uid), err)
	}
	if len(snaps) != len(refs) {
		return nil, fmt.Errorf("identity: read daily stats: got %d documents for %d refs", len(snaps), len(refs))
	}
	out := make([]DailyStats, len(days))
	for i, s := range snaps {
		out[i] = DailyStats{Date: days[i]}
		if s == nil || !s.Exists() {
			continue
		}
		var d dailyStatsDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode daily stats %s: %w", s.Ref.ID, err)
		}
		out[i] = DailyStats{Date: days[i], Impressions: d.Impressions, Engagements: d.Engagements, FollowersGained: d.FollowersGained, FollowersLost: d.FollowersLost}
	}
	return out, nil
}

// PurgeDailyStatsPage deletes up to dailyStatsPage of uid's dailyStats docs in one batch and reports how many. Reads:
// one per document (minimum 1). Deleted documents leave the next page, so repeating the call is self-resuming.
func (r *DailyStatsRepo) PurgeDailyStatsPage(ctx context.Context, uid string) (int, error) {
	docs, err := r.col(uid).Select().Limit(dailyStatsPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, fmt.Errorf("identity: purge daily stats %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, logger.RedactErr(fmt.Errorf("identity: purge daily stats %s: %w", logger.HashUID(uid), err), uid)
	}
	return len(docs), nil
}

// ExportDailyStats writes uid's daily stats as one JSON array, oldest first (at most dailyStatsExportMax docs, paged by
// document id, which is the day key). The values are as stored; expireAt is not exported.
func (r *DailyStatsRepo) ExportDailyStats(ctx context.Context, uid string, w io.Writer) error {
	out := make([]dailyStatsDoc, 0, 64)
	last := ""
	for len(out) < dailyStatsExportMax {
		q := r.col(uid).OrderBy(firestore.DocumentID, firestore.Asc)
		if last != "" {
			q = q.StartAfter(last)
		}
		docs, err := q.Limit(dailyStatsPage).Documents(ctx).GetAll()
		if err != nil {
			return fmt.Errorf("identity: export daily stats %s: %w", logger.HashUID(uid), err)
		}
		for _, s := range docs {
			var d dailyStatsDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("identity: decode daily stats %s: %w", s.Ref.ID, err)
			}
			d.Date = s.Ref.ID
			out = append(out, d)
		}
		if len(docs) < dailyStatsPage {
			break
		}
		last = docs[len(docs)-1].Ref.ID
	}
	if err := json.NewEncoder(w).Encode(out); err != nil {
		return fmt.Errorf("identity: write daily stats section: %w", err)
	}
	return nil
}

// DailyStatsCheckpoint resumes DailyStatsEraser.PurgeUser; it only carries the running count (the purge is
// self-resuming). It is the step's own type: the step name is persisted in deletionJob.step.
type DailyStatsCheckpoint struct {
	Deleted int
}

// DailyStatsPurger deletes one page of a user's dailyStats docs (*DailyStatsRepo; tests use a fake).
type DailyStatsPurger interface {
	PurgeDailyStatsPage(ctx context.Context, uid string) (deleted int, err error)
}

// DailyStatsEraser is the `daily_stats` account-deletion step.
type DailyStatsEraser struct {
	repo DailyStatsPurger
}

// NewDailyStatsEraser builds the step.
func NewDailyStatsEraser(repo DailyStatsPurger) *DailyStatsEraser {
	return &DailyStatsEraser{repo: repo}
}

// PurgeUser deletes one page; done is true on a short page (including the empty page of an account with none).
func (e *DailyStatsEraser) PurgeUser(ctx context.Context, uid string, cp DailyStatsCheckpoint) (DailyStatsCheckpoint, bool, error) {
	n, err := e.repo.PurgeDailyStatsPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := DailyStatsCheckpoint{Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "identity_purge_daily_stats", "uid_hash", logger.HashUID(uid), "docs", n, "deleted_total", next.Deleted)
	}
	return next, n < dailyStatsPage, nil
}
