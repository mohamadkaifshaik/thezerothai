// ciphertext_sweep.go is the daily step that blanks the ciphertext and commitment of end-to-end encrypted messages 30 days
// after they were sent (messaging/retention.go; the proto's "Retention"). It rides the daily-maintenance cron like the
// poll vote and media orphan sweeps (no new Cloud Scheduler job), as the LAST step of the chain, after the media orphan
// sweep: it gets min(ciphertextSweepMax, what the chain has left) and is skipped below ciphertextSweepMin, so it never takes
// time from the trends refresh or the other sweeps. Inside that budget it runs pages of messaging.CiphertextSweepPage (300)
// while a page is full and swept something, at most ciphertextSweepMaxPages (20) pages: one run reads and writes at most
// 6 000 documents whatever the budget. A backlog (the first run after 30 days of traffic) drains over several runs: the
// query returns what is left, oldest first.
//
// Its outcome is for the logs (counts only, never an id or a byte), never the HTTP status: a failure, including the
// FAILED_PRECONDITION of a query whose collection-group index is not deployed yet, is logged as ciphertext_sweep_failed
// and reported to Error Reporting, and the step returns nil. It is NOT behind a flag (e2ee_dm gates only starting
// encryption; the retention promise holds for messages that outlive any flag), and DEGRADED_MODE=readonly skips it (it
// only writes).
package apiserver

import (
	"context"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// ciphertextSweepMax bounds the step inside the maintenance request; ciphertextSweepMin is the least time worth starting
	// with (one page of 300 updates, 16 at a time).
	ciphertextSweepMax = 3 * time.Second
	ciphertextSweepMin = time.Second
	// ciphertextSweepMaxPages caps one run (at most 20 x 300 documents read and written) whatever the budget.
	ciphertextSweepMaxPages = 20
	ciphertextSweepOp       = "cron/daily-maintenance/ciphertext-sweep"
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
		s.log.InfoContext(ctx, "ciphertext_sweep", "outcome", "skipped_readonly")
		return nil
	}
	budget := ciphertextSweepMax
	if dl, ok := ctx.Deadline(); ok {
		budget = min(budget, time.Until(dl))
	}
	if budget < ciphertextSweepMin {
		s.log.InfoContext(ctx, "ciphertext_sweep", "outcome", "skipped_deadline", "left_ms", budget.Milliseconds())
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), ciphertextSweepOp, logger.ScrubErr(panicError{v}))
		}
	}()
	total, pages, err := s.run(ctx)
	attrs := []any{"pages", pages, "due", total.Due, "swept", total.Swept, "skipped", total.Skipped, "more", total.More}
	switch {
	case err != nil && ctx.Err() == nil:
		s.log.ErrorContext(ctx, "ciphertext_sweep_failed", append(attrs, "error", logger.ScrubErr(err).Error())...)
		mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), ciphertextSweepOp, logger.ScrubErr(err))
	case err != nil || (ctx.Err() != nil && total.More) || (pages == ciphertextSweepMaxPages && total.More):
		// The budget or the page cap ran out with more due: the next run continues (the query returns what is left).
		s.log.InfoContext(ctx, "ciphertext_sweep", append(attrs, "outcome", "partial")...)
	default:
		s.log.InfoContext(ctx, "ciphertext_sweep", append(attrs, "outcome", "ok")...)
	}
	return nil
}

// run sweeps pages until one is short, sweeps nothing (every hit skipped: they come back first on the next page, so
// another page now would only repeat them), fails, the budget ends or the page cap is reached.
func (s ciphertextSweepStep) run(ctx context.Context) (messaging.CiphertextSweepResult, int, error) {
	var total messaging.CiphertextSweepResult
	pages := 0
	for pages < ciphertextSweepMaxPages && ctx.Err() == nil {
		res, err := s.sweeper.SweepCiphertext(ctx, s.now(), s.limit)
		pages++
		total.Add(res)
		if err != nil {
			return total, pages, err
		}
		if !res.More || res.Swept == 0 {
			break
		}
	}
	return total, pages, nil
}
