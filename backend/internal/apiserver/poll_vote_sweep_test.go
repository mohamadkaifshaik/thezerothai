package apiserver

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
)

type fakeSweeper struct {
	calls int
	ttl   time.Duration
	res   engagement.PollSweepResult
	err   error
}

func (f *fakeSweeper) SweepPollVotes(_ context.Context, _ time.Time, ttl time.Duration) (engagement.PollSweepResult, error) {
	f.calls++
	f.ttl = ttl
	return f.res, f.err
}

// The sweep step logs its outcome and never fails the maintenance request; readonly skips it; the chain runs every step.
func TestPollVoteSweepStep(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		readOnly  bool
		err       error
		wantCalls int
		wantLog   string
	}{
		{"ok", false, nil, 1, `"msg":"poll_vote_sweep"`},
		{"failure is logged, not returned", false, errors.New("firestore down"), 1, `poll_vote_sweep_failed`},
		{"readonly skips", true, nil, 0, "skipped_readonly"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeSweeper{res: engagement.PollSweepResult{Docs: 2, Pruned: 2, Entries: 3}, err: tt.err}
			step := pollVoteSweepStep{sweeper: sw, ttl: 720 * time.Hour, readOnly: tt.readOnly, log: slog.New(slog.NewJSONHandler(&buf, nil)), now: time.Now}
			if err := step.Refresh(context.Background()); err != nil {
				t.Fatalf("Refresh = %v, want nil: the sweep never fails the request", err)
			}
			if sw.calls != tt.wantCalls || !strings.Contains(buf.String(), tt.wantLog) {
				t.Errorf("calls %d, log %s", sw.calls, buf.String())
			}
			if tt.wantCalls == 1 && sw.ttl != 720*time.Hour {
				t.Errorf("ttl = %v", sw.ttl)
			}
		})
	}
}

type countStep struct{ n *int }

func (c countStep) Refresh(context.Context) error { *c.n++; return nil }

func TestStepChainRunsEveryStep(t *testing.T) {
	t.Parallel()
	n := 0
	if err := (stepChain{countStep{&n}, countStep{&n}}).Refresh(context.Background()); err != nil || n != 2 {
		t.Fatalf("ran %d steps, err %v", n, err)
	}
}
