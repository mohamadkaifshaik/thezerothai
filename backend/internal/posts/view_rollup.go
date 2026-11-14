// view_rollup.go is the view rollup (F1 post views): it folds the view shards of every post that had views into
// posts/{id}.viewCount, finding them through the rollup markers instead of scanning posts. It runs on a cron tick
// (/internal/cron/view-rollup, and the publish-scheduled tick it rides in prod) and is idempotent on redelivery.
//
// Bounded work per run: at most MaxPages pages of ViewRollupPage markers (so at most MaxPages x 50 posts, each 10 shard
// reads and 1 write, plus the marker query and deletes), stopping early at the context deadline. Markers not reached stay
// for the next run. A run starts only when the last one is at least MinInterval old (one state-doc transaction), so a
// 5-minute tick rolls up every 15 minutes and a Scheduler retry right after a run is a cheap no-op.
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

// Outcomes of ViewRollupResult.Outcome.
const (
	ViewRollupRan      = "ok"
	ViewRollupFresh    = "fresh"
	ViewRollupOff      = "skipped_flag_off"
	ViewRollupReadOnly = "skipped_readonly"
)

// ViewRollupResult is what one run did, for its log line (counts only).
type ViewRollupResult struct {
	Outcome string
	Pages   int
	Markers int
	Folded  int
	Gone    int
	// More is true when the run stopped with markers left (page bound or deadline).
	More bool
}

// LogAttrs are the slog attributes of the result.
func (r ViewRollupResult) LogAttrs() []any {
	return []any{"outcome", r.Outcome, "pages", r.Pages, "markers", r.Markers, "folded", r.Folded, "gone", r.Gone, "more", r.More}
}

// ViewRollup runs the rollup over a ViewRollupRepo.
type ViewRollup struct {
	Repo ViewRollupRepo
	// MinInterval between runs (DefaultViewRollupInterval when 0); MaxPages bounds one run (DefaultViewRollupPages when 0).
	MinInterval time.Duration
	MaxPages    int
	// Off reports FEATURE_POST_VIEWS globally off: the rollup then does no Firestore work at all. Nil = never off.
	Off func() bool
	// ReadOnly is DEGRADED_MODE=readonly: the rollup writes, so it is skipped.
	ReadOnly bool
	// Now is the clock (nil = time.Now).
	Now func() time.Time
}

// Run does one rollup.
func (v *ViewRollup) Run(ctx context.Context) (ViewRollupResult, error) {
	if v.ReadOnly {
		return ViewRollupResult{Outcome: ViewRollupReadOnly}, nil
	}
	if v.Off != nil && v.Off() {
		return ViewRollupResult{Outcome: ViewRollupOff}, nil
	}
	if v.Repo == nil {
		return ViewRollupResult{}, errors.New("posts: view rollup has no repo")
	}
	now := time.Now
	if v.Now != nil {
		now = v.Now
	}
	interval, pages := v.MinInterval, v.MaxPages
	if interval <= 0 {
		interval = DefaultViewRollupInterval
	}
	if pages <= 0 {
		pages = DefaultViewRollupPages
	}
	started := now()
	ok, err := v.Repo.AcquireViewRollup(ctx, started, interval)
	if err != nil {
		return ViewRollupResult{}, err
	}
	if !ok {
		return ViewRollupResult{Outcome: ViewRollupFresh}, nil
	}
	res := ViewRollupResult{Outcome: ViewRollupRan}
	window := viewWindow(started) // only closed windows: no instance still writes their markers
	for res.Pages < pages {
		if ctx.Err() != nil {
			res.More = true
			return res, nil
		}
		markers, err := v.Repo.DirtyViewMarkers(ctx, window, ViewRollupPage)
		if err != nil {
			return res, err
		}
		if len(markers) == 0 {
			return res, nil
		}
		res.Pages++
		res.Markers += len(markers)
		folded, gone, err := v.Repo.FoldViews(ctx, distinctMarkerPosts(markers))
		res.Folded += folded
		res.Gone += gone
		if err != nil {
			return res, fmt.Errorf("posts: view rollup fold: %w", err)
		}
		if err := v.Repo.DeleteViewMarkers(ctx, markers); err != nil {
			return res, fmt.Errorf("posts: view rollup markers: %w", err)
		}
		if len(markers) < ViewRollupPage {
			return res, nil
		}
	}
	res.More = true
	return res, nil
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
