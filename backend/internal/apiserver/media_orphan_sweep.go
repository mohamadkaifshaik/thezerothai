// media_orphan_sweep.go is the daily step that deletes READY images nothing ever attached (media/orphan_sweep.go). It
// rides the daily-maintenance cron like the poll vote sweep (no new Cloud Scheduler job, no Terraform), as the LAST step of
// the chain so it never takes time from the trends refresh: it gets min(mediaOrphanSweepMax, what the chain has left) and
// is skipped below mediaOrphanSweepMin. Its outcome is for the logs, never the HTTP status; a partial run resumes the next
// day (every phase is idempotent and the due query returns what is left).
//
// Like the poll vote sweep it is NOT behind FEATURE_MEDIA (it handles documents that outlive the flag), and
// DEGRADED_MODE=readonly skips it (it only writes and deletes).
package apiserver

import (
	"context"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// mediaOrphanSweepMax bounds the step inside the maintenance request; mediaOrphanSweepMin is the least time worth starting with.
	mediaOrphanSweepMax = 3 * time.Second
	mediaOrphanSweepMin = time.Second
	mediaOrphanSweepOp  = "cron/daily-maintenance/media-orphan-sweep"
)

// orphanSweeper is media.OrphanSweeper's Sweep (a seam for the step's unit test).
type orphanSweeper interface {
	Sweep(ctx context.Context, now time.Time, limit int) (media.OrphanSweepResult, error)
}

// mediaOrphanSweepStep runs one page of the orphan sweep per call.
type mediaOrphanSweepStep struct {
	sweeper  orphanSweeper
	limit    int
	readOnly bool
	log      *slog.Logger
	now      func() time.Time
}

// Refresh implements trendsStep. It returns nil whatever happens and never panics out: a failure is logged as
// media_orphan_sweep_failed and reported to Error Reporting under its own op. The log line carries counts only.
func (s mediaOrphanSweepStep) Refresh(ctx context.Context) error {
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
	res, err := s.sweeper.Sweep(ctx, s.now(), s.limit)
	attrs := []any{
		"due", res.Due, "more", res.More, "marked", res.Marked, "deleted", res.Deleted, "held", res.Held, "kept", res.Kept,
		"attached", res.Attached, "restored", res.Restored, "waiting", res.Waiting, "conflicts", res.Conflicts,
		"failed", res.Failed, "skipped", res.Skipped,
	}
	if err != nil && ctx.Err() != nil {
		// The budget ran out mid-page (a page of deletes routinely takes longer than 3 s while a backlog drains): what was
		// cut off is redone by the next run, so this is a partial run, not a failure for Error Reporting.
		s.log.InfoContext(ctx, "media_orphan_sweep", append(attrs, "outcome", "partial")...)
		return nil
	}
	if err != nil {
		s.log.ErrorContext(ctx, "media_orphan_sweep_failed", append(attrs, "error", logger.ScrubErr(err).Error())...)
		mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), mediaOrphanSweepOp, logger.ScrubErr(err))
		return nil
	}
	s.log.InfoContext(ctx, "media_orphan_sweep", append(attrs, "outcome", "ok")...)
	return nil
}
