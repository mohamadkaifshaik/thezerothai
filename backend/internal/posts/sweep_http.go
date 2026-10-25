// sweep_http.go is the `/internal/cron/publish-scheduled` route (ADR-0021 D1 "The route", Sweep steps 6 and 7): POST
// only, a 25 s context deadline, a budget.Counter of its own (system reads, never charged to a user's ADR-0010 D5
// budget), route-level panic recovery, and the one `scheduled_sweep` line per run. Mount it behind the OIDC verifier
// (apiserver's routeTable.internal does).
//
// Response contract: 204 when the run processed what it fetched, even when some items failed (each is counted in the
// line and the failed ones are in their own docs) and even when a LATER due page failed (SweepResult.LaterPageErr: an
// Error Reporting entry, no retry, which would burn the attempt ladder of the items just processed); 500 only when the
// FIRST due page failed, so nothing was processed and Cloud Scheduler's retry (retry_count 3) is harmless.
// Overlapping runs, such as a retry and the next tick, are safe because the publish transaction requires PENDING.
package posts

import (
	"context"
	"log/slog"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// NewSweepHandler is the cron route of the publish sweep. log receives the run line and the Error Reporting entries.
func NewSweepHandler(sw Sweeper, log *slog.Logger, projectID string) http.Handler {
	return mw.RecoverHTTP(log, projectID, sweepOp, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		started := time.Now()
		ctx, cancel := context.WithTimeout(logger.WithTrace(r.Context(), logger.TraceFromRequest(r, projectID)), sweepRunDeadline)
		defer cancel()
		ctx, counter := budget.WithCounter(ctx)

		res, err := sw.Sweep(ctx)
		// A due-query failure is the run's error: err when page 1 failed (nothing processed, 500, Scheduler's retry is
		// wanted), res.LaterPageErr when a later page failed (the earlier pages were processed: 204, a retry would burn the
		// items' attempt ladder). Both are scrubbed by Sweep; scrubbing again is idempotent and keeps the guarantee here.
		runErr := err
		if runErr == nil {
			runErr = res.LaterPageErr
		}
		if err != nil {
			res.Outcome = SweepError
		}
		attrs := append(res.logAttrs(counter), "latency_ms", time.Since(started).Milliseconds())
		attrs = append(attrs, logger.TraceAttrs(ctx)...)
		// The one scheduled_sweep line is written for EVERY run, failed ones included (outcome=error, with the counts of what
		// was processed). The Error Reporting entry is a separate line that carries only the scrubbed error.
		if runErr != nil {
			log.WarnContext(ctx, "scheduled_sweep", attrs...)
			mw.ReportError(ctx, log.With(logger.TraceAttrs(ctx)...), sweepOp, logger.ScrubErr(runErr))
		} else {
			log.InfoContext(ctx, "scheduled_sweep", attrs...)
		}
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}

// logAttrs are the fields of the scheduled_sweep line: counts, the largest lateness and the run's Firestore usage, never
// an id, a handle or text.
func (r SweepResult) logAttrs(c *budget.Counter) []any {
	reasons := make([]string, 0, len(r.Failed))
	for k := range r.Failed {
		reasons = append(reasons, string(k))
	}
	slices.Sort(reasons)
	failed := make([]any, 0, len(reasons))
	failedTotal := 0
	for _, k := range reasons {
		failed = append(failed, strings.ToLower(k), r.Failed[ScheduledFailure(k)])
		failedTotal += r.Failed[ScheduledFailure(k)]
	}
	return []any{
		"due", r.Due,
		"published", r.Published,
		slog.Group("failed", failed...),
		"failed_total", failedTotal,
		"cancelled", r.Cancelled,
		"expired", r.Expired(),
		"transient", r.Transient,
		"deferred", r.Deferred,
		"noop", r.Noop,
		"write_failed", r.WriteFailed,
		"skipped_bad_path", r.SkippedBadPath,
		"undecodable", r.Undecodable,
		"max_lateness_ms", r.MaxLateness.Milliseconds(),
		"fs_reads", c.Reads(),
		"fs_writes", c.Writes(),
		"fs_deletes", c.Deletes(),
		"outcome", r.Outcome,
	}
}
