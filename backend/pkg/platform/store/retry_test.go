package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func TestCommitWithRetry(t *testing.T) {
	t.Parallel()
	aborted := status.Error(codes.Aborted, "lock")
	notFound := status.Error(codes.NotFound, "no doc")
	boom := errors.New("boom")
	tests := []struct {
		name          string
		results       []error
		cancelOnSleep int
		wantCommitted bool
		wantErr       func(error) bool
		wantCommits   int
		wantAttempts  int
		wantCeilings  []time.Duration
		wantWrites    int64
	}{
		{name: "first try", results: []error{nil}, wantCommitted: true, wantCommits: 1, wantAttempts: 1, wantWrites: 1},
		{name: "wins after contention", results: []error{aborted, aborted, nil}, wantCommitted: true, wantCommits: 3, wantAttempts: 3,
			wantCeilings: []time.Duration{10, 20}, wantWrites: 1},
		{name: "precondition failed is a 0-write no-op", results: []error{aborted, notFound}, wantCommits: 2, wantAttempts: 2, wantCeilings: []time.Duration{10}},
		{name: "exhausted", results: []error{aborted, aborted, aborted, aborted}, wantCommits: 4, wantAttempts: 4,
			wantCeilings: []time.Duration{10, 20, 40}, wantErr: func(e error) bool { return errors.Is(e, ErrContended) }},
		{name: "other error not retried", results: []error{boom}, wantCommits: 1, wantAttempts: 1,
			wantErr: func(e error) bool { return errors.Is(e, boom) }},
		{name: "context ends during backoff", results: []error{aborted, aborted}, cancelOnSleep: 1, wantCommits: 1, wantAttempts: 1,
			wantCeilings: []time.Duration{10}, wantErr: func(e error) bool { return errors.Is(e, context.Canceled) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx, counter := budget.WithCounter(ctx)
			commits := 0
			var ceilings []time.Duration
			res, err := CommitWithRetry(ctx,
				func(c *budget.Counter) *FirestoreBatch { return NewFirestoreBatch(&firestore.Client{}, c) },
				RetryConfig{
					MaxAttempts: 4, Backoff: 10,
					Commit: func(context.Context, *FirestoreBatch) error {
						commits++
						return tt.results[commits-1]
					},
					Sleep: func(ctx context.Context, c time.Duration) error {
						ceilings = append(ceilings, c)
						if len(ceilings) == tt.cancelOnSleep {
							cancel()
						}
						return ctx.Err()
					},
				},
				func(b Batch) { b.Delete((&firestore.Client{}).Doc("c/d")) })
			if res.Committed != tt.wantCommitted || res.Attempts != tt.wantAttempts || commits != tt.wantCommits {
				t.Errorf("committed/attempts/commits = %v/%d/%d", res.Committed, res.Attempts, commits)
			}
			if (err != nil) != (tt.wantErr != nil) || (tt.wantErr != nil && !tt.wantErr(err)) {
				t.Errorf("err = %v", err)
			}
			if tt.wantCeilings != nil && fmt.Sprint(ceilings) != fmt.Sprint(tt.wantCeilings) {
				t.Errorf("ceilings = %v, want %v", ceilings, tt.wantCeilings)
			}
			if counter.Deletes() != tt.wantWrites {
				t.Errorf("deletes = %d, want %d", counter.Deletes(), tt.wantWrites)
			}
		})
	}
}

func TestWait_JitterBoundedAndCancellable(t *testing.T) {
	t.Parallel()
	if err := Wait(context.Background(), 2*time.Millisecond); err != nil {
		t.Fatalf("Wait = %v", err)
	}
	if err := Wait(context.Background(), 0); err != nil {
		t.Fatalf("Wait(0) = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Wait(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatalf("Wait cancelled = %v", err)
	}
}

func TestNoteTxnAttempts(t *testing.T) {
	t.Parallel()
	ctx, info := logger.WithRequestInfo(context.Background())
	NoteTxnAttempts(ctx, "x_txn_contention", 2)
	if got, _ := info.Get("txn_attempts"); fmt.Sprint(got) != "2" {
		t.Errorf("txn_attempts = %v", got)
	}
}
