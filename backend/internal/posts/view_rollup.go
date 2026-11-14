// view_rollup.go is the counter rollup of posts, in two halves with their own markers, semantics and cadence:
//
//   - views (F1 post views): it folds the view shards of every post that had views into posts/{id}.viewCount (the
//     ABSOLUTE shard sum). It runs only when the last views run is at least MinInterval old (one state-doc transaction),
//     so a 5-minute tick rolls views up every 15 minutes and a Scheduler retry right after a run is a cheap no-op. It is
//     skipped while post_views is globally off (Off).
//   - engagement counters of hot posts (hot counters design 2026-11-14): it folds the likeCount, repostCount and
//     shareCount shards of every post with a counter marker into the plain post fields (a DELTA fold, one
//     transaction per non-zero shard). It runs on every tick, whatever post_views says and without the views gate,
//     so a hot post's counts lag by at most its window, one grace window and one tick (about 15 minutes).
//
// Both find their posts through rollup markers instead of scanning posts, fold only windows closed for at least one
// more full window (foldBefore: a late commit cannot strand a value), delete a marker only after its own fold for its post is done, and are idempotent on redelivery
// and when two runs overlap. The run is on a cron tick (/internal/cron/view-rollup, and the publish-scheduled tick it
// rides in prod).
//
// Bounded work per run: per half, at most MaxPages pages of ViewRollupPage markers (so at most MaxPages x 50 posts; a
// view fold is 10 shard reads and 1 write per post, a counter fold 11 reads per post plus 1 read and 2 writes per
// non-zero shard), stopping early at the context deadline. Markers not reached stay for the next run.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// Defaults of ViewRollup.
const (
	DefaultViewRollupInterval = 15 * time.Minute
	DefaultViewRollupPages    = 20
)

// Outcomes of ViewRollupResult.Outcome (the views half; the counter half always runs unless ReadOnly).
const (
	ViewRollupRan      = "ok"
	ViewRollupFresh    = "fresh"
	ViewRollupOff      = "skipped_flag_off"
	ViewRollupReadOnly = "skipped_readonly"
)

// ViewRollupResult is what one run did, for its log line (counts only).
type ViewRollupResult struct {
	// Outcome is the views half's.
	Outcome string
	Pages   int
	Markers int
	Folded  int
	Gone    int
	// More is true when the views half stopped with markers left (page bound or deadline).
	More bool
	// The counter half: pages and markers read, posts folded and posts found gone; CountersMore as More.
	CounterPages   int
	CounterMarkers int
	CountersFolded int
	CountersGone   int
	CountersMore   bool
}

// LogAttrs are the slog attributes of the result.
func (r ViewRollupResult) LogAttrs() []any {
	return []any{
		"outcome", r.Outcome, "pages", r.Pages, "markers", r.Markers, "folded", r.Folded, "gone", r.Gone, "more", r.More,
		"counter_pages", r.CounterPages, "counter_markers", r.CounterMarkers, "counters_folded", r.CountersFolded,
		"counters_gone", r.CountersGone, "counters_more", r.CountersMore,
	}
}

// ViewRollup runs the rollup over a ViewRollupRepo.
type ViewRollup struct {
	Repo ViewRollupRepo
	// MinInterval between views runs (DefaultViewRollupInterval when 0); MaxPages bounds each half of one run
	// (DefaultViewRollupPages when 0).
	MinInterval time.Duration
	MaxPages    int
	// Off reports FEATURE_POST_VIEWS globally off: the views half then does no Firestore work at all (no gate, no query).
	// The counter half runs regardless. Nil = never off.
	Off func() bool
	// ReadOnly is DEGRADED_MODE=readonly: the rollup writes, so both halves are skipped.
	ReadOnly bool
	// Now is the clock (nil = time.Now).
	Now func() time.Time
	// Forget evicts a post from this instance's posts cache once one of its counters was folded (nil = no cache). Other
	// instances converge within CACHE_TTL, as for replyCount.
	Forget func(postID string)
}

// Run does one rollup: the views half (gated), then the counter half (every run). An error of one half does not stop
// the other; both are returned.
func (v *ViewRollup) Run(ctx context.Context) (ViewRollupResult, error) {
	if v.ReadOnly {
		return ViewRollupResult{Outcome: ViewRollupReadOnly}, nil
	}
	if v.Repo == nil {
		if v.Off != nil && v.Off() {
			return ViewRollupResult{Outcome: ViewRollupOff}, nil // the views contract, unchanged: no repo needed when off
		}
		return ViewRollupResult{}, errors.New("posts: view rollup has no repo")
	}
	now := time.Now
	if v.Now != nil {
		now = v.Now
	}
	pages := v.MaxPages
	if pages <= 0 {
		pages = DefaultViewRollupPages
	}
	started := now()
	window := foldBefore(started)
	var res ViewRollupResult
	viewsErr := v.runViews(ctx, started, window, pages, &res)
	// The counter half runs even with post_views globally off (Off): one marker query per tick costs about 288 reads a
	// day when there is nothing to fold, an accepted cost (the hot engagement counters must not depend on the views flag).
	counters, countersErr := v.drain(ctx, window, pages, markerPass{
		query: v.Repo.DirtyCounterMarkers,
		fold:  v.Repo.FoldCounters,
		what:  "counter",
	})
	res.CounterPages, res.CounterMarkers, res.CountersFolded, res.CountersGone, res.CountersMore =
		counters.pages, counters.markers, counters.folded, counters.gone, counters.more
	return res, errors.Join(viewsErr, countersErr)
}

// foldBefore is the first window a run must NOT fold: both halves fold the markers of windows before it. It is the
// current window minus one, a grace of one full window (5 minutes) after a window closes. A write is staged with its
// window taken at staging time, and the memo may leave its marker out (this instance already committed it); if that
// commit lands after the window closed, a fold that already read the shard would delete the marker and strand the
// value with no marker until the post's next write. One full window is far beyond any commit's delay (transactions
// are bounded by seconds, a request by Cloud Run's 30 s timeout) plus clock skew, and since the prod tick fires on
// window boundaries a shorter grace (say a minute) would give the same cutoff anyway. It costs one window of lag.
func foldBefore(now time.Time) int64 { return viewWindow(now) - 1 }

// runViews is the views half: the flag, the min-interval gate, then the absolute fold of the view markers.
func (v *ViewRollup) runViews(ctx context.Context, started time.Time, window int64, pages int, res *ViewRollupResult) error {
	if v.Off != nil && v.Off() {
		res.Outcome = ViewRollupOff
		return nil
	}
	interval := v.MinInterval
	if interval <= 0 {
		interval = DefaultViewRollupInterval
	}
	ok, err := v.Repo.AcquireViewRollup(ctx, started, interval)
	if err != nil {
		return err
	}
	if !ok {
		res.Outcome = ViewRollupFresh
		return nil
	}
	res.Outcome = ViewRollupRan
	pr, err := v.drain(ctx, window, pages, markerPass{
		query: v.Repo.DirtyViewMarkers,
		fold: func(ctx context.Context, ids []string) ([]string, int, int, error) {
			folded, gone, err := v.Repo.FoldViews(ctx, ids)
			if err != nil {
				return nil, folded, gone, err
			}
			return ids, folded, gone, nil
		},
		what: "view",
	})
	res.Pages, res.Markers, res.Folded, res.Gone, res.More = pr.pages, pr.markers, pr.folded, pr.gone, pr.more
	return err
}

// markerPass is one half of the rollup: its marker query and its fold (done = the posts whose fold finished).
type markerPass struct {
	query func(ctx context.Context, window int64, limit int) ([]ViewMarker, error)
	fold  func(ctx context.Context, ids []string) (done []string, folded, gone int, err error)
	what  string
}

// passResult is what one markerPass did.
type passResult struct {
	pages, markers, folded, gone int
	more                         bool
}

// drain pages through a pass's markers: fold the page's posts not yet attempted in this run, evict them from the
// cache, delete the markers of the posts whose fold is done, and go on until a short page, the page bound, the deadline,
// or a page that brings no post not yet attempted (markers kept by an unfinished fold, or rewritten since they were
// read, stay at the head of the query, and the query has no cursor: re-reading them would only repeat the same work).
func (v *ViewRollup) drain(ctx context.Context, window int64, pages int, p markerPass) (passResult, error) {
	var res passResult
	attempted := map[string]struct{}{}
	for res.pages < pages {
		if ctx.Err() != nil {
			res.more = true
			return res, nil
		}
		markers, err := p.query(ctx, window, ViewRollupPage)
		if err != nil {
			return res, err
		}
		if len(markers) == 0 {
			return res, nil
		}
		res.pages++
		res.markers += len(markers)
		var ids []string
		for _, id := range distinctMarkerPosts(markers) {
			if _, ok := attempted[id]; !ok {
				attempted[id] = struct{}{}
				ids = append(ids, id)
			}
		}
		if len(ids) == 0 {
			break // nothing new on this page: the rest waits for the next run
		}
		done, folded, gone, foldErr := p.fold(ctx, ids)
		if v.Forget != nil {
			for _, id := range ids {
				v.Forget(id)
			}
		}
		res.folded += folded
		res.gone += gone
		if del := markersOf(markers, done); len(del) > 0 {
			if err := v.Repo.DeleteViewMarkers(ctx, del); err != nil {
				return res, errors.Join(foldErr, fmt.Errorf("posts: rollup %s markers: %w", p.what, err))
			}
		}
		if foldErr != nil {
			return res, fmt.Errorf("posts: rollup %s fold: %w", p.what, foldErr)
		}
		if len(markers) < ViewRollupPage {
			return res, nil
		}
	}
	res.more = true
	return res, nil
}

// markersOf keeps the markers whose post is in done.
func markersOf(markers []ViewMarker, done []string) []ViewMarker {
	if len(done) == 0 {
		return nil
	}
	ok := make(map[string]struct{}, len(done))
	for _, id := range done {
		ok[id] = struct{}{}
	}
	out := make([]ViewMarker, 0, len(markers))
	for _, m := range markers {
		if _, in := ok[m.PostID]; in {
			out = append(out, m)
		}
	}
	return out
}

// distinctMarkerPosts are the post ids of a page, each once, in marker order.
func distinctMarkerPosts(markers []ViewMarker) []string {
	seen := make(map[string]struct{}, len(markers))
	out := make([]string, 0, len(markers))
	for _, m := range markers {
		if _, ok := seen[m.PostID]; ok {
			continue
		}
		seen[m.PostID] = struct{}{}
		out = append(out, m.PostID)
	}
	return out
}
