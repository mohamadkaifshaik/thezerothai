package search

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// refreshPage is the CreatedAfter page size (the reader's maximum, ADR-0028 D6).
	refreshPage = posts.MaxCreatedAfterLimit
	// firstWindow is how far back the first run, and a run after a stuck watermark, looks (ADR-0028 D6).
	firstWindow = 24 * time.Hour
	// staleWatermark is the age past which the watermark is dropped: a stuck sweep must never show a week-old list as
	// "today" (ADR-0028 D6 step 3).
	staleWatermark = 48 * time.Hour
	// emptySettle holds the watermark of an empty run this far behind now, so a post whose createdAt is a moment ago
	// but whose commit lands after our read is still read by the next run.
	emptySettle = time.Minute
	// writeReserve is how much of the context's deadline is kept for the 1-write Put: a page never runs into it, and a run
	// that has read pages stops paging (as a backlog) once less than this is left, so a slow night still saves its progress
	// instead of failing the write on an expired context and never moving the watermark.
	writeReserve = 2 * time.Second
	// refreshOp is the Error Reporting operation name of the sweep.
	refreshOp = "cron/trends-refresh"
)

// Skip reasons of a run that wrote nothing (the trends_skipped log line, ADR-0028 D10).
const (
	SkipFlagOff  = "flag_off"
	SkipReadonly = "readonly"
	SkipFresh    = "fresh"
	SkipDeadline = "deadline"
)

// PostScanner is the part of posts.Reader the sweep uses (posts.Reader satisfies it). The posts it returns are PROJECTED
// (id, author, hashtags, moderation, createdAt, kind) and must never be stored in any cache.
type PostScanner interface {
	CreatedAfter(ctx context.Context, after posts.Position, limit int) ([]*posts.Post, error)
}

// RefresherConfig is the sweep's configuration (config.SearchConfig plus the switches).
type RefresherConfig struct {
	// MinAuthors is TRENDS_MIN_AUTHORS, MaxPosts TRENDS_MAX_POSTS_PER_RUN, MinInterval TRENDS_MIN_INTERVAL.
	MinAuthors  int
	MaxPosts    int
	MinInterval time.Duration
	// Denylist is TRENDS_DENYLIST (tag bodies; normalised here like a query).
	Denylist []string
	// ReadOnly is DEGRADED_MODE=readonly.
	ReadOnly bool
	// Now is the clock (nil: time.Now); Log receives the run line and the Error Reporting entries (nil: discarded).
	Now func() time.Time
	Log *slog.Logger
}

// Refresher is TrendsRefresher (ADR-0028 D6).
type Refresher struct {
	store     TrendsStore
	scan      PostScanner
	protected identity.ProtectedAuthors
	flags     FlagChecker
	cfg       RefresherConfig
	deny      map[string]struct{} // TrendKey set of TRENDS_DENYLIST
}

var _ TrendsRefresher = (*Refresher)(nil)

// NewRefresher builds the sweep. A nil protected loader fails every run that has posts to count: an unknown protected
// set is never read as "nobody is protected" (ADR-0025). A nil FlagChecker is off for everyone.
func NewRefresher(store TrendsStore, scan PostScanner, protected identity.ProtectedAuthors, fc FlagChecker, cfg RefresherConfig) *Refresher {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.DiscardHandler)
	}
	if cfg.MinAuthors < 1 {
		cfg.MinAuthors = 3
	}
	if cfg.MaxPosts < 1 {
		cfg.MaxPosts = 2000
	}
	if cfg.MinInterval <= 0 {
		cfg.MinInterval = 12 * time.Hour
	}
	return &Refresher{store: store, scan: scan, protected: protected, flags: fc, cfg: cfg, deny: trendKeySet(cfg.Denylist)}
}

// RunResult is what one run did, for the log line and the tests.
type RunResult struct {
	// Skipped is one of the Skip* reasons, "" when the run computed and wrote a list.
	Skipped      string
	PostsScanned int
	TagsCounted  int
	TagsKept     int
	Backlog      bool
	// WatermarkReset is true when a stale watermark (older than 48 h) was dropped (trends_backlog_skipped).
	WatermarkReset bool
	// FsReads and FsWrites are the run's own Firestore counts (the same numbers as the log line).
	FsReads, FsWrites int64
	// LaterPageErr is a failure after the first page: the run wrote what it had, as a backlog, and succeeded.
	LaterPageErr error
}

// Refresh recomputes trends/current from the posts created since the last run (ADR-0028 D6).
//
// Firestore, worst case: flag globally off or DEGRADED_MODE=readonly 0 reads, 0 writes; a run inside TRENDS_MIN_INTERVAL
// of the last list 1 read (the document), 0 writes; otherwise 2 + new posts (the document, the hide list, then one read per
// projected post, an empty page bills 1: <= 2 + TRENDS_MAX_POSTS_PER_RUN = 2,002) and 1 write. The protected set comes
// through the identity loader on its detached counter and is never charged here. Refresh owns its budget counter and writes the one trends_refresh (or
// trends_skipped) line. The error is non-nil only when nothing was written because the document read, the hide list, the first page or
// the protected set failed; a later-page failure writes the partial list as a backlog and is reported, not returned.
func (r *Refresher) Refresh(ctx context.Context) error {
	_, err := r.Run(ctx)
	return err
}

// Run is Refresh with the result.
func (r *Refresher) Run(ctx context.Context) (RunResult, error) {
	started := r.cfg.Now()
	ctx, counter := budget.WithCounter(ctx)
	res, err := r.run(ctx, started)
	res.FsReads, res.FsWrites = counter.Reads(), counter.Writes()
	attrs := []any{
		"fs_reads", counter.Reads(), "fs_writes", counter.Writes(),
		"duration_ms", r.cfg.Now().Sub(started).Milliseconds(),
	}
	attrs = append(attrs, logger.TraceAttrs(ctx)...)
	switch {
	case err != nil:
		attrs = append(attrs, "outcome", "error", "trends_posts_scanned", res.PostsScanned)
		mw.ReportError(ctx, r.cfg.Log.With(attrs...), refreshOp, logger.ScrubErr(err))
	case res.Skipped != "":
		r.cfg.Log.InfoContext(ctx, "trends_skipped", append(attrs, "reason", res.Skipped)...)
	default:
		attrs = append(attrs, "trends_posts_scanned", res.PostsScanned, "trends_tags", res.TagsCounted,
			"tags_kept", res.TagsKept, "backlog", res.Backlog, "outcome", "ok")
		r.cfg.Log.InfoContext(ctx, "trends_refresh", attrs...)
		if res.Backlog {
			r.cfg.Log.WarnContext(ctx, "trends_backlog", "trends_posts_scanned", res.PostsScanned)
		}
		if res.WatermarkReset {
			r.cfg.Log.WarnContext(ctx, "trends_backlog_skipped", "reason", "watermark_older_than_48h")
		}
		if res.LaterPageErr != nil {
			mw.ReportError(ctx, r.cfg.Log.With(logger.TraceAttrs(ctx)...), refreshOp, logger.ScrubErr(res.LaterPageErr))
		}
	}
	return res, err
}

func (r *Refresher) run(ctx context.Context, now time.Time) (RunResult, error) {
	if r.flags == nil || r.flags.GloballyOff(FlagTrends) {
		return RunResult{Skipped: SkipFlagOff}, nil // only mode off is a job kill switch (flag-rollout skill)
	}
	if r.cfg.ReadOnly {
		return RunResult{Skipped: SkipReadonly}, nil
	}
	prev, err := r.store.Get(ctx)
	if err != nil {
		return RunResult{}, err
	}
	if prev != nil && !prev.Backlog && now.Sub(prev.ComputedAt) < r.cfg.MinInterval {
		// A Scheduler retry of the backstop minutes after a good run must not replace the day's list with an almost empty
		// window (ADR-0028 D6 step 2).
		return RunResult{Skipped: SkipFresh}, nil
	}
	// The hide list (ADR-0028 note 2026-10-31 part 1) is read once the run is going to write, before any post is read: a
	// failed read fails the run with nothing written, as an unavailable protected set does, and is never read as empty.
	hidden, err := r.store.Hidden(ctx)
	if err != nil {
		return RunResult{}, fmt.Errorf("search: trends hide list: %w", err)
	}
	hide := trendKeySet(hidden)

	var res RunResult
	wm := Watermark{At: now.Add(-firstWindow)}
	if prev != nil {
		wm = prev.Watermark
		if wm.At.IsZero() || now.Sub(wm.At) > staleWatermark {
			res.WatermarkReset = !wm.At.IsZero()
			wm = Watermark{At: now.Add(-firstWindow)}
		}
	}
	windowStart := wm.At

	var (
		tags      = map[string]*tagCount{}
		protected identity.ProtectedSet
		read      bool
		more      bool
	)
	for res.PostsScanned < r.cfg.MaxPosts {
		want := min(refreshPage, r.cfg.MaxPosts-res.PostsScanned)
		pageCtx, cancel := ctx, context.CancelFunc(func() {})
		if dl, ok := ctx.Deadline(); ok {
			limit := dl.Add(-writeReserve)
			if res.PostsScanned > 0 && time.Until(limit) <= 0 {
				more = true // out of time: save what was read, the next run resumes after the last read post
				break
			}
			pageCtx, cancel = context.WithDeadline(ctx, limit)
		}
		page, err := r.scan.CreatedAfter(pageCtx, wm.position(), want)
		cancel()
		if err != nil {
			if res.PostsScanned == 0 {
				return res, fmt.Errorf("search: trends first page: %w", err)
			}
			res.LaterPageErr = fmt.Errorf("search: trends later page: %w", err)
			more = true // posts remain: the next run resumes after the last read post
			break
		}
		if len(page) > 0 && protected == nil {
			if r.protected == nil {
				return res, errors.New("search: trends: protected-authors loader not wired")
			}
			if protected, err = r.protected.Current(ctx); err != nil {
				return res, fmt.Errorf("search: trends protected set: %w", err)
			}
		}
		for _, p := range page {
			res.PostsScanned++
			read = true
			wm = Watermark{At: p.CreatedAt, ID: p.ID}
			if !p.Visible() || p.Kind == posts.KindRepost || protected.Has(p.AuthorID) {
				continue
			}
			for _, t := range p.Hashtags {
				c := tags[t]
				if c == nil {
					c = &tagCount{authors: map[string]struct{}{}}
					tags[t] = c
				}
				c.posts++
				c.authors[p.AuthorID] = struct{}{}
			}
		}
		if len(page) < want {
			more = false // the end of the new posts
			break
		}
		more = res.PostsScanned >= r.cfg.MaxPosts
	}
	res.Backlog = more

	if !read {
		// Nothing new: hold the watermark a moment behind now, never before the old one.
		wm = Watermark{At: laterOf(wm.At, now.Add(-emptySettle))}
	}
	items := r.rank(tags, hide)
	res.TagsCounted = len(tags)
	res.TagsKept = len(items)
	doc := &TrendsDoc{
		Items: items, WindowStart: windowStart, Watermark: wm, ComputedAt: now,
		PostsScanned: res.PostsScanned, Backlog: res.Backlog,
	}
	if err := r.store.Put(ctx, doc); err != nil {
		return res, err
	}
	return res, nil
}

func laterOf(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

type tagCount struct {
	posts   int64
	authors map[string]struct{}
}

// matchesKey is true when the tag's TrendKey is in one of the sets (the denylist, the hide list).
func matchesKey(tag string, sets ...map[string]struct{}) bool {
	k := TrendKey(tag)
	for _, s := range sets {
		if _, ok := s[k]; ok && k != "" {
			return true
		}
	}
	return false
}

// rank applies the denylist, the hide list and the distinct-author minimum, orders by authors, then posts, then tag, and keeps the top
// maxTrendItems (ADR-0028 D6 step 6).
func (r *Refresher) rank(tags map[string]*tagCount, hide map[string]struct{}) []TrendItem {
	items := make([]TrendItem, 0, len(tags))
	for tag, c := range tags {
		if len(c.authors) < r.cfg.MinAuthors || matchesKey(tag, r.deny, hide) {
			continue
		}
		items = append(items, TrendItem{Tag: tag, Posts: c.posts, Authors: int64(len(c.authors))})
	}
	slices.SortFunc(items, func(a, b TrendItem) int {
		switch {
		case a.Authors != b.Authors:
			return int(b.Authors - a.Authors)
		case a.Posts != b.Posts:
			return int(b.Posts - a.Posts)
		default:
			return strings.Compare(a.Tag, b.Tag)
		}
	})
	if len(items) > maxTrendItems {
		items = items[:maxTrendItems]
	}
	return items
}
