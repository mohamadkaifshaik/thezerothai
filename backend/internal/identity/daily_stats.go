// daily_stats.go is the storage of F2 Creator Studio insights that identity owns (FEATURE_CREATOR_INSIGHTS):
//
//	users/{uid}/dailyStats/{yyyymmdd IST}_{s} {date, shard, impressions, engagements, followersGained, followersLost, expireAt}
//
// One creator day is DailyStatsShards docs (s in 0..DailyStatsShards-1); a day's stats are the sum of its shards. Other
// modules never name the path: they stage increments through StatsWriter, in the batch or transaction of the write that
// causes them (the Counters pattern), so a stat moves exactly when its cause commits:
//
//   - impressions: the view rollup (posts, FoldViews) adds each post's view delta (new total - old viewCount) on the
//     author's day, at most one write per author and shard per fold batch;
//   - engagements: a like, repost, reply or quote received from another account adds 1 on the cold path (and an undo
//     subtracts 1 on the day of the undo); on a hot post the counter rollup (FoldCounters) adds the folded delta;
//   - followersGained / followersLost: graph's follow, accept, go-public, unfollow and block paths, on the followee.
//
// The shard is picked deterministically from a shard key (StatsShard, FNV-1a): the actor's uid for a like, repost,
// reply, quote or follow, the post id for the view rollup and the hot fold (which have no actor). So one actor's write
// and its undo land on the same shard, and a retried transaction writes the same doc.
//
// Every stage is a Set with MergeAll and Increment transforms: it has no precondition and creates the doc. It is only
// ever staged next to a write that carries an Exists precondition (the post's counter Update, the users doc's counter
// Update), so an erased author (posts and users doc gone) gets no doc: the commit fails before anything is written, and
// every fallback that drops the counter drops the stat too. An author being erased is not a concern for the erase
// step either: it runs after the posts and graph steps, when no counter write can reach the author any more.
//
// Hot doc: a creator's day takes one write per like, repost, reply, quote and follow they receive (plus at most one per
// rollup batch and shard), gathered from ALL their posts and follows, more than any single plain counter takes. Firestore
// sustains about one write per second on one document, and past it the cause's own commit (the like, the follow)
// contends and is retried or fails, not just the stat. The DailyStatsShards (4) shards spread a day over 4 docs: about 4
// writes per second sustained per creator, if the actors spread over the shards. DailyStatsShards is the constant to
// raise (more shards cost more reads per insights call; existing docs keep their ids, so raising it is safe, lowering it
// strands the high shards). Hot posts also move their engagements to the rollup (HOT_COUNTER_THRESHOLD), which writes
// the day once per fold.
//
// Retention: expireAt is the IST day's start + DailyStatsTTL (400 days) on every write of every shard, so the TTL policy
// (infra/terraform/modules/firestore, collection group dailyStats) deletes each shard about 400 days later. The account
// erasure deletes the docs outright (PurgeDailyStatsPage) and the export includes them, one row per shard doc
// (ExportDailyStats).
//
// While FEATURE_CREATOR_INSIGHTS is globally off nothing is staged (Off), so the prod default writes nothing, and the
// writers skip the reads they would only do for a stat.
package identity

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"log/slog"
	"strconv"
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
	// DailyStatsShards is the number of docs one creator day is spread over (about one sustained write per second each).
	// Raise it here when a creator outgrows it (see the file comment).
	DailyStatsShards = 4
	// DailyStatsTTL is expireAt - the IST day's start.
	DailyStatsTTL = 400 * 24 * time.Hour
	// dailyStatsPage is the page of the erase step and of the export (ops paths; a batch holds 500 writes). An account
	// has at most about 400 x DailyStatsShards docs (the TTL).
	dailyStatsPage = 500
	// dailyStatsExportMax bounds the export (a TTL that has not run yet may leave a few more docs than 400 days' worth).
	dailyStatsExportMax = 4 * dailyStatsPage
	// MaxInsightsWindowDays is the longest GetCreatorInsights window (and the default): a call reads twice as many days.
	MaxInsightsWindowDays = 28
)

// ist is the zone of the day key (the daily quotas' and the impressions dedupe's: quota.TodayAt).
var ist = time.FixedZone("IST", 5*3600+30*60)

// StatsDay is the dailyStats day key (yyyymmdd) of t: the IST day, the same key as the impressions dedupe day
// (engagement.ImpressionDay), rolling over at 18:30 UTC.
func StatsDay(t time.Time) string {
	return strings.ReplaceAll(quota.TodayAt(t), "-", "")
}

// StatsShard is the shard of a day a write with shardKey goes to: FNV-1a of the key mod DailyStatsShards.
func StatsShard(shardKey string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(shardKey)) // hash.Hash never returns an error
	return int(h.Sum32() % DailyStatsShards)
}

// dailyStatsID is the doc id {day}_{shard}.
func dailyStatsID(day string, shard int) string { return day + "_" + strconv.Itoa(shard) }

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
	// StageDaily appends ONE write to b: Increment of every non-zero field of d on
	// users/{uid}/dailyStats/{day}_{StatsShard(shardKey)}, with date, shard and expireAt set (Set with MergeAll, no
	// precondition: stage it only next to a write that carries Exists on the post or on users/{uid}). shardKey is the
	// actor's uid, or the post id when there is no actor. Nothing is appended for an empty uid, a zero delta, a
	// malformed day, or while Off.
	StageDaily(b store.Batch, uid, day, shardKey string, d DailyDelta)
	// Off reports FEATURE_CREATOR_INSIGHTS globally off: StageDaily stages nothing, so a writer skips any read it would
	// only do for a stat.
	Off() bool
}

// DailyStats is one creator's stats for one IST day, its shards summed (values may be below zero after undos; readers
// clamp).
type DailyStats struct {
	Date            string
	Impressions     int64
	Engagements     int64
	FollowersGained int64
	FollowersLost   int64
}

// dailyStatsDoc is one shard, users/{uid}/dailyStats/{day}_{shard}.
type dailyStatsDoc struct {
	Date            string    `firestore:"date" json:"date"`
	Shard           int64     `firestore:"shard" json:"shard"`
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

// Off implements StatsWriter. A nil repo is off.
func (r *DailyStatsRepo) Off() bool { return r == nil || (r.off != nil && r.off()) }

// StageDaily implements StatsWriter.
func (r *DailyStatsRepo) StageDaily(b store.Batch, uid, day, shardKey string, d DailyDelta) {
	if r.Off() || uid == "" || d.IsZero() {
		return
	}
	shard := StatsShard(shardKey)
	data, ok := dailyStatsIncrement(day, shard, d)
	if !ok {
		return
	}
	b.Set(r.col(uid).Doc(dailyStatsID(day, shard)), data, firestore.MergeAll)
}

// dailyStatsIncrement is the MergeAll data of one stage: date, shard, expireAt and an Increment per non-zero field. Pure.
func dailyStatsIncrement(day string, shard int, d DailyDelta) (map[string]any, bool) {
	start, ok := statsDayStart(day)
	if !ok {
		return nil, false
	}
	data := map[string]any{"date": day, "shard": int64(shard), "expireAt": start.Add(DailyStatsTTL).UTC()}
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

// ReadDailyStats reads uid's stats for days (yyyymmdd keys, oldest first, at most 2 x MaxInsightsWindowDays) with ONE
// range query on the doc id, {days[0]}_ to {days[last]}_~, Limit len(days) x DailyStatsShards: a read per shard doc that
// exists (minimum 1), cheaper than a GetAll of every possible shard. The answer is in days' order with the shards summed;
// a day without docs is a zero DailyStats with its Date.
func (r *DailyStatsRepo) ReadDailyStats(ctx context.Context, uid string, days []string) ([]DailyStats, error) {
	if len(days) == 0 {
		return nil, nil
	}
	if len(days) > 2*MaxInsightsWindowDays {
		return nil, fmt.Errorf("identity: read daily stats: %d days is above %d", len(days), 2*MaxInsightsWindowDays)
	}
	col := r.col(uid)
	docs, err := col.Where(firestore.DocumentID, ">=", col.Doc(days[0]+"_")).
		Where(firestore.DocumentID, "<=", col.Doc(days[len(days)-1]+"_~")).
		OrderBy(firestore.DocumentID, firestore.Asc).Limit(len(days) * DailyStatsShards).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("identity: read daily stats %s: %w", logger.HashUID(uid), err)
	}
	return sumDailyStats(days, docs)
}

// sumDailyStats sums shard docs per day into days' order; docs of other days are ignored.
func sumDailyStats(days []string, docs []*firestore.DocumentSnapshot) ([]DailyStats, error) {
	out := make([]DailyStats, len(days))
	at := make(map[string]int, len(days))
	for i, d := range days {
		out[i] = DailyStats{Date: d}
		at[d] = i
	}
	for _, s := range docs {
		var d dailyStatsDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode daily stats %s: %w", s.Ref.ID, err)
		}
		day := d.Date
		if day == "" {
			day, _, _ = strings.Cut(s.Ref.ID, "_")
		}
		i, ok := at[day]
		if !ok {
			continue
		}
		out[i].Impressions += d.Impressions
		out[i].Engagements += d.Engagements
		out[i].FollowersGained += d.FollowersGained
		out[i].FollowersLost += d.FollowersLost
	}
	return out, nil
}

// PurgeDailyStatsPage deletes up to dailyStatsPage of uid's dailyStats docs (shards) in one batch and reports how many.
// Reads: one per document (minimum 1). Deleted documents leave the next page, so repeating the call is self-resuming.
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

// ExportDailyStats writes uid's daily stats as one JSON array of shard docs {date, shard, impressions, engagements,
// followersGained, followersLost}, oldest first (at most dailyStatsExportMax docs, paged by document id, which starts
// with the day key). The values are as stored; expireAt is not exported. A day's stats are the sum of its rows.
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
			if d.Date == "" {
				d.Date, _, _ = strings.Cut(s.Ref.ID, "_")
			}
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
