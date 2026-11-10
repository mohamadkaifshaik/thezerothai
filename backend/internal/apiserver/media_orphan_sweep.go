// media_orphan_sweep.go is the daily step that deletes READY images nothing ever attached (media/orphan_sweep.go). It
// rides the daily-maintenance cron like the poll vote sweep (no new Cloud Scheduler job, no Terraform job), as the LAST step
// of the chain so it never takes time from the trends refresh: it gets min(mediaOrphanSweepMax, what the chain has left)
// and is skipped below mediaOrphanSweepMin. Inside that budget it runs page after page (at most mediaOrphanSweepMaxPages)
// while a page is full and moved something. Its outcome is for the logs, never the HTTP status; a partial run resumes the
// next day (every phase is idempotent and the due query returns what is left).
//
// MEDIA_ORPHAN_SWEEP (cfg.MediaOrphanSweep, default off) is its kill switch: off logs one line and does nothing, mark
// never claims or deletes, delete runs both phases. The sweeper enforces the same mode; the step's check only saves the
// work and says so in the log. Like the poll vote sweep it is NOT behind FEATURE_MEDIA (it handles documents that outlive
// the flag), and DEGRADED_MODE=readonly skips it (it only writes and deletes).
package apiserver

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// mediaOrphanSweepMax bounds the step inside the maintenance request; mediaOrphanSweepMin is the least time worth starting with.
	mediaOrphanSweepMax = 3 * time.Second
	mediaOrphanSweepMin = time.Second
	// mediaOrphanSweepMaxPages bounds one run's pages (and so its writes: at most 2 per document) whatever the budget.
	mediaOrphanSweepMaxPages = 30
	mediaOrphanSweepOp       = "cron/daily-maintenance/media-orphan-sweep"
)

// orphanSweeper is media.OrphanSweeper's Sweep (a seam for the step's unit test).
type orphanSweeper interface {
	Sweep(ctx context.Context, now time.Time, limit int) (media.OrphanSweepResult, error)
}

// mediaOrphanSweepStep runs the orphan sweep, page after page, inside its budget.
type mediaOrphanSweepStep struct {
	sweeper  orphanSweeper
	mode     config.MediaOrphanSweep
	limit    int
	readOnly bool
	log      *slog.Logger
	now      func() time.Time
}

// Refresh implements trendsStep. It returns nil whatever happens and never panics out: a failure is logged as
// media_orphan_sweep_failed (Error) and reported to Error Reporting under its own op. One log line per run, counts only.
func (s mediaOrphanSweepStep) Refresh(ctx context.Context) error {
	if !s.mode.Runs() {
		s.log.InfoContext(ctx, "media_orphan_sweep", "outcome", "disabled", "mode", string(config.MediaOrphanSweepOff))
		return nil
	}
	if s.readOnly {
		s.log.InfoContext(ctx, "media_orphan_sweep", "outcome", "skipped_readonly")
		return nil
	}
	budget := mediaOrphanSweepMax
	if dl, ok := ctx.Deadline(); ok {
		budget = min(budget, time.Until(dl))
	}
	if budget < mediaOrphanSweepMin {
		s.log.InfoContext(ctx, "media_orphan_sweep", "outcome", "skipped_deadline", "left_ms", budget.Milliseconds())
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), mediaOrphanSweepOp, logger.ScrubErr(panicError{v}))
		}
	}()
	var (
		total media.OrphanSweepResult
		pages int
		err   error
	)
	for pages < mediaOrphanSweepMaxPages && ctx.Err() == nil {
		var res media.OrphanSweepResult
		res, err = s.sweeper.Sweep(ctx, s.now(), s.limit)
		pages++
		total.Add(res)
		if err != nil || !res.More || res.Progressed() == 0 {
			break
		}
	}
	attrs := []any{
		"mode", string(s.mode), "pages", pages, "due", total.Due, "more", total.More, "marked", total.Marked, "deleted", total.Deleted,
		"held", total.Held, "kept", total.Kept, "attached", total.Attached, "restored", total.Restored, "waiting", total.Waiting,
		"deferred", total.Deferred, "young", total.Young, "conflicts", total.Conflicts, "failed", total.Failed,
		"skipped", total.Skipped, "undecodable", total.Undecodable,
	}
	switch {
	case total.Failed > 0 || (err != nil && ctx.Err() == nil):
		// A failure is an Error even when the budget also ran out: the cut-off part is redone tomorrow, but a failed
		// holder read, write or object delete may repeat every day.
		if err == nil {
			err = fmt.Errorf("media orphan sweep: %d failed", total.Failed)
		}
		s.log.ErrorContext(ctx, "media_orphan_sweep_failed", append(attrs, "error", logger.ScrubErr(err).Error())...)
		mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), mediaOrphanSweepOp, logger.ScrubErr(err))
	case err != nil || (ctx.Err() != nil && total.More):
		// The budget ran out mid-run (a page of deletes routinely takes longer than 3 s while a backlog drains): what was cut
		// off is redone by the next run, so this is a partial run, not a failure for Error Reporting.
		s.log.InfoContext(ctx, "media_orphan_sweep", append(attrs, "outcome", "partial")...)
	default:
		s.log.InfoContext(ctx, "media_orphan_sweep", append(attrs, "outcome", "ok")...)
	}
	return nil
}
