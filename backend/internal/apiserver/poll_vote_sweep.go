// poll_vote_sweep.go is the daily step that removes expired userLikes.pollVotes entries from accounts that never come back (ADR-0029
// D8, security L-2, ticket W6-29). It rides the daily-maintenance cron (no new Cloud Scheduler job: the free tier holds 3 per
// billing account) as a step before the trends refresh, under the same status rule: its outcome is for the logs, never the HTTP
// status. The trends step keeps its own window: the chain gets min(10 s, time left) and the sweep takes at most pollVoteSweepMax of
// it; a partial run resumes the next day.
//
// It is deliberately NOT behind FEATURE_POLLS or any flag: like the poll_votes eraser and export section, it handles documents that
// outlive the flag, and the retention promise must hold with the flag off. DEGRADED_MODE=readonly skips it (it only writes).
package apiserver

import (
	"context"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// pollVoteSweepMax bounds the sweep inside the maintenance request, so a slow sweep cannot starve the trends refresh.
	pollVoteSweepMax = 3 * time.Second
	pollVoteSweepOp  = "cron/daily-maintenance/poll-vote-sweep"
)

// pollVoteSweepStep runs engagement.PollVoteSweeper once per call.
type pollVoteSweepStep struct {
	sweeper  engagement.PollVoteSweeper
	ttl      time.Duration
	readOnly bool
	log      *slog.Logger
	now      func() time.Time
}

// Refresh implements trendsStep. It returns nil whatever happens and never panics out (the trends step must still run): a failure
// is logged as poll_vote_sweep_failed and reported to Error Reporting under its own op.
func (s pollVoteSweepStep) Refresh(ctx context.Context) error {
	if s.readOnly {
		s.log.InfoContext(ctx, "poll_vote_sweep", "outcome", "skipped_readonly")
		return nil
	}
	ctx, c := budget.WithCounter(ctx)
	ctx, cancel := context.WithTimeout(ctx, pollVoteSweepMax)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), pollVoteSweepOp, logger.ScrubErr(panicError{v}))
		}
	}()
	res, err := s.sweeper.SweepPollVotes(ctx, s.now(), s.ttl)
	attrs := []any{
		"docs", res.Docs, "pruned", res.Pruned, "entries", res.Entries, "skipped", res.Skipped, "more", res.More,
		"fs_reads", c.Reads(), "fs_writes", c.Writes(),
	}
	if err != nil {
		s.log.ErrorContext(ctx, "poll_vote_sweep_failed", append(attrs, "error", logger.ScrubErr(err).Error())...)
		mw.ReportError(ctx, s.log.With(logger.TraceAttrs(ctx)...), pollVoteSweepOp, logger.ScrubErr(err))
		return nil
	}
	s.log.InfoContext(ctx, "poll_vote_sweep", append(attrs, "outcome", "ok")...)
	return nil
}

// stepChain runs its steps in order and returns the last error (the maintenance wrapper drops it anyway).
type stepChain []trendsStep

// Refresh implements trendsStep.
func (c stepChain) Refresh(ctx context.Context) error {
	var err error
	for _, s := range c {
		err = s.Refresh(ctx)
	}
	return err
}
