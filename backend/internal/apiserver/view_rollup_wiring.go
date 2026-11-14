// view_rollup_wiring.go composes the view rollup (F1 post views, posts.ViewRollup): its cron step and routes.
//
// The rollup has no Cloud Scheduler job of its own by default (the free tier holds 3 jobs per billing account and prod
// keeps the third as headroom; dev keeps none). Like the outbox sweep it rides the publish-scheduled cron (every 5 min in
// prod) as a step after the publish sweep, the outbox sweep and the billing recovery, under the daily-maintenance status
// rule: the route's status is the publish sweep's alone, and the rollup's outcome is for the logs. Its own 15-minute
// gate (viewRollup/state) makes every third tick the one that works. /internal/cron/view-rollup runs it alone, for dev,
// operators and an optional dedicated 15-minute Scheduler job (an owner decision); behind that route the gate is 1 minute,
// only collapsing Scheduler retries, so a job firing every 15 minutes never misses a slot to clock jitter.
package apiserver

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// Time budget of the rollup step inside the publish-scheduled request (Cloud Run's request timeout is 30 s): the step
// gets min(viewRollupStepMax, viewRollupCutoff - elapsed) and is skipped below viewRollupStepMin. The standalone route
// runs it under viewRollupRouteDeadline.
const (
	viewRollupCutoff        = 28 * time.Second
	viewRollupStepMax       = 8 * time.Second
	viewRollupStepMin       = 2 * time.Second
	viewRollupRouteDeadline = 25 * time.Second
	viewRollupRouteInterval = time.Minute
	viewRollupOp            = "cron/view-rollup"
)

// viewRollupRunner is the one method of posts.ViewRollup the step needs.
type viewRollupRunner interface {
	Run(ctx context.Context) (posts.ViewRollupResult, error)
}

// viewRollupStep runs one rollup and writes its one `view_rollup` line (counts only, never a post id), plus an Error
// Reporting entry for a failure or a panic.
type viewRollupStep struct {
	rollup viewRollupRunner
	log    *slog.Logger
}

func (s viewRollupStep) run(ctx context.Context) (err error) {
	reporter := s.log.With(logger.TraceAttrs(ctx)...)
	defer func() {
		if v := recover(); v != nil {
			err = panicError{v}
			mw.ReportError(ctx, reporter, viewRollupOp, err)
		}
	}()
	started := time.Now()
	res, err := s.rollup.Run(ctx)
	attrs := append(res.LogAttrs(), "latency_ms", time.Since(started).Milliseconds())
	if err != nil {
		s.log.WarnContext(ctx, "view_rollup", append(append(attrs, "error", true), logger.TraceAttrs(ctx)...)...)
		mw.ReportError(ctx, reporter, viewRollupOp, logger.ScrubErr(err))
		return err
	}
	s.log.InfoContext(ctx, "view_rollup", append(attrs, logger.TraceAttrs(ctx)...)...)
	return nil
}

// withViewRollup runs inner through a status-capturing writer, then the rollup step with min(viewRollupStepMax,
// viewRollupCutoff - elapsed), then writes inner's captured response. A non-POST goes to inner alone.
func withViewRollup(inner http.Handler, step viewRollupStep, projectID string, now func() time.Time) http.Handler {
	return withCronStep(inner, cronStepBudget{event: "view_rollup", cutoff: viewRollupCutoff, max: viewRollupStepMax, min: viewRollupStepMin}, step.run, step.log, projectID, now)
}

// viewRollupHandler is /internal/cron/view-rollup: POST only, a 25 s deadline, 204, or 500 when the run failed (every
// step is idempotent, so a retry is harmless).
func viewRollupHandler(step viewRollupStep, log *slog.Logger, projectID string) http.Handler {
	return cronStepHandler(step.run, viewRollupOp, viewRollupRouteDeadline, log, projectID)
}

// newViewRollups builds the two runners over one repo: the tick's (15-minute gate, the default) and the route's. forget
// evicts a folded post from this instance's posts cache (nil = none).
func newViewRollups(repo posts.ViewRollupRepo, off func() bool, readOnly bool, forget func(string)) (tick, route *posts.ViewRollup) {
	tick = &posts.ViewRollup{Repo: repo, Off: off, ReadOnly: readOnly, Forget: forget}
	route = &posts.ViewRollup{Repo: repo, Off: off, ReadOnly: readOnly, MinInterval: viewRollupRouteInterval, Forget: forget}
	return tick, route
}
