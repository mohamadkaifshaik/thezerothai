// poll_vote_sweep.go is the daily step that removes expired userLikes.pollVotes entries from accounts that never come back (ADR-0029
// D8, security L-2, ticket W6-29). It rides the daily-maintenance cron (no new Cloud Scheduler job: the free tier holds 3 per
// billing account) as a step before the trends refresh, under the same status rule: its outcome is for the logs, never the HTTP
// status.
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
)

// pollVoteSweepMax bounds the sweep inside the maintenance request (the step chain as a whole gets 10 s).
const pollVoteSweepMax = 5 * time.Second

// pollVoteSweepStep runs engagement.PollVoteSweeper once per call.
type pollVoteSweepStep struct {
	sweeper  engagement.PollVoteSweeper
	ttl      time.Duration
	readOnly bool
	log      *slog.Logger
	now      func() time.Time
}

// Refresh implements trendsStep. It returns nil whatever happens: a failure is logged as poll_vote_sweep_failed.
func (s pollVoteSweepStep) Refresh(ctx context.Context) error {
	if s.readOnly {
		s.log.InfoContext(ctx, "poll_vote_sweep", "outcome", "skipped_readonly")
		return nil
	}
	ctx, c := budget.WithCounter(ctx)
	ctx, cancel := context.WithTimeout(ctx, pollVoteSweepMax)
	defer cancel()
	res, err := s.sweeper.SweepPollVotes(ctx, s.now(), s.ttl)
	attrs := []any{
		"docs", res.Docs, "pruned", res.Pruned, "entries", res.Entries, "skipped", res.Skipped, "more", res.More,
		"fs_reads", c.Reads(), "fs_writes", c.Writes(),
	}
	if err != nil {
		s.log.ErrorContext(ctx, "poll_vote_sweep_failed", append(attrs, "error", logger.ScrubErr(err).Error())...)
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
