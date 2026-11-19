// ciphertext_sweep.go is the step that blanks the ciphertext and commitment of end-to-end encrypted messages 30 days after
// they were sent (messaging/retention.go; the proto's "Retention"). No Cloud Scheduler job of its own: it rides two
// existing ticks, each time only on the time the tick's own work left over.
//
//   - Daily: the LAST step of the daily-maintenance chain (prod only: dev has no daily-maintenance job), after the media
//     orphan sweep: min(ciphertextSweepMax 3 s, what the chain has left), skipped below ciphertextSweepMin.
//   - Hourly: after the trends refresh on /internal/cron/trends-refresh, the one hourly job in BOTH dev and prod
//     (withCiphertextSweep): the refresh keeps its own 25 s deadline and the route's response is the refresh's alone; the
//     step gets min(ciphertextHourlyMax 2 s, ciphertextHourlyCutoff 28 s - elapsed) (Cloud Run's request timeout is 30 s)
//     and is skipped below ciphertextSweepMin.
//
// Inside its budget it runs pages of messaging.CiphertextSweepPage (300) while a page is full and swept something, at most
// ciphertextSweepMaxPages (20) pages: one run reads and writes at most 6 000 documents. A backlog drains over several runs,
// oldest first.
//
// One `ciphertext_sweep` line per run, counts only (never an id or a byte), with lag_h = now - the oldest due ctExpireAt
// in hours (0 when nothing is due; the promise is broken by that much) and cap_reached. Outcomes and levels: ok (INFO),
// partial (more remain: the budget or the page cap ran out; WARN), stalled (a page swept nothing while hits remain due;
// WARN), skipped_deadline (no time left; WARN), skipped_readonly (DEGRADED_MODE=readonly; INFO), failed (the query or an
// update failed, including the FAILED_PRECONDITION of a collection-group index not yet READY; ERROR and Error Reporting).
// Any outcome is WARN at least when lag_h > 24. It never fails the cron or changes a route's response. It is NOT behind a
// flag: e2ee_dm gates only starting encryption, and the retention promise holds for messages that outlive any flag.
package apiserver

import (
	"context"
	"log/slog"
	"math"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// ciphertextSweepMax bounds the step in the daily chain; ciphertextSweepMin is the least time worth starting with (one
	// page of 300 updates, 16 at a time).
	ciphertextSweepMax = 3 * time.Second
	ciphertextSweepMin = time.Second
	// ciphertextHourlyMax and ciphertextHourlyCutoff bound the step on the hourly trends-refresh tick.
	ciphertextHourlyMax    = 2 * time.Second
	ciphertextHourlyCutoff = 28 * time.Second
	// ciphertextSweepMaxPages caps one run (at most 20 x 300 documents read and written) whatever the budget.
	ciphertextSweepMaxPages = 20
	// ciphertextLagWarnHours: a run that finds something due for longer than this logs WARN whatever its outcome.
	ciphertextLagWarnHours = 24
	ciphertextSweepEvent   = "ciphertext_sweep"
	ciphertextSweepOp      = "cron/daily-maintenance/ciphertext-sweep"
)

// ciphertextSweepStep runs messaging.CiphertextSweeper page after page inside its budget.
type ciphertextSweepStep struct {
	sweeper  messaging.CiphertextSweeper
	limit    int
	readOnly bool
	log      *slog.Logger
	now      func() time.Time
}

// Refresh implements trendsStep. It returns nil whatever happens and never panics out. One log line per run.
func (s ciphertextSweepStep) Refresh(ctx context.Context) error {
	if s.readOnly {
		s.log.InfoContext(ctx, ciphertextSweepEvent, "outcome", "skipped_readonly")
		return nil
	}
	budget := ciphertextSweepMax
	if dl, ok := ctx.Deadline(); ok {
		budget = min(budget, time.Until(dl))
	}
	if budget < ciphertextSweepMin {
		s.log.WarnContext(ctx, ciphertextSweepEvent, "outcome", "skipped_deadline", "left_ms", budget.Milliseconds())
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			s.log.ErrorContext(ctx, ciphertextSweepEvent, "outcome", "failed", "error", "panic")
			mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), ciphertextSweepOp, logger.ScrubErr(panicError{v}))
		}
	}()
	started := s.now()
	total, last, pages, err := s.run(ctx)
	lag := lagHours(started, total.OldestDue)
	capReached := pages == ciphertextSweepMaxPages && total.More
	attrs := []any{
		"pages", pages, "due", total.Due, "swept", total.Swept, "skipped", total.Skipped, "more", total.More,
		"cap_reached", capReached, "lag_h", lag,
	}
	outcome, level := "ok", slog.LevelInfo
	switch {
	case err != nil && ctx.Err() == nil:
		outcome, level = "failed", slog.LevelError
	case last.Due > 0 && last.Swept == 0:
		// Every hit of the last page was skipped (changed between query and update): they stay due and come back first, so
		// the run stopped rather than repeat them.
		outcome, level = "stalled", slog.LevelWarn
	case err != nil || total.More:
		// The budget or the page cap ran out with more due: the next run continues.
		outcome, level = "partial", slog.LevelWarn
	}
	if lag > ciphertextLagWarnHours && level < slog.LevelWarn {
		level = slog.LevelWarn
	}
	attrs = append(attrs, "outcome", outcome)
	if outcome == "failed" {
		attrs = append(attrs, "error", logger.ScrubErr(err).Error())
		mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), ciphertextSweepOp, logger.ScrubErr(err))
	}
	s.log.Log(ctx, level, ciphertextSweepEvent, attrs...)
	return nil
}

// run sweeps pages until one is short, sweeps nothing (every hit skipped: they come back first on the next page, so
// another page now would only repeat them), fails, the budget ends or the page cap is reached. last is the last page.
func (s ciphertextSweepStep) run(ctx context.Context) (total, last messaging.CiphertextSweepResult, pages int, err error) {
	for pages < ciphertextSweepMaxPages && ctx.Err() == nil {
		last, err = s.sweeper.SweepCiphertext(ctx, s.now(), s.limit)
		pages++
		total.Add(last)
		if err != nil || !last.More || last.Swept == 0 {
			break
		}
	}
	return total, last, pages, err
}

// lagHours is now - oldest in hours, one decimal, 0 when nothing was due.
func lagHours(now, oldest time.Time) float64 {
	if oldest.IsZero() || !now.After(oldest) {
		return 0
	}
	return math.Round(now.Sub(oldest).Hours()*10) / 10
}

// withCiphertextSweep runs inner (the hourly trends refresh) through a status-capturing writer, then the step on the time
// left (min(ciphertextHourlyMax, ciphertextHourlyCutoff - elapsed); skipped_deadline at WARN below ciphertextSweepMin),
// then writes inner's captured response unchanged. A non-POST goes to inner alone.
func withCiphertextSweep(inner http.Handler, step ciphertextSweepStep, projectID string, now func() time.Time) http.Handler {
	return withCronStep(inner, cronStepBudget{
		event: ciphertextSweepEvent, cutoff: ciphertextHourlyCutoff, max: ciphertextHourlyMax, min: ciphertextSweepMin, skipLevel: slog.LevelWarn,
	}, step.Refresh, step.log, projectID, now)
}
