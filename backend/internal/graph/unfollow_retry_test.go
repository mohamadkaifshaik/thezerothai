package graph

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// usersCounters is an identity.Counters that appends one users/{uid} update per call, like the real one.
type usersCounters struct{ client *firestore.Client }

func (c usersCounters) upd(b store.Batch, uid string) {
	b.Update(c.client.Collection("users").Doc(uid), []firestore.Update{{Path: "n", Value: firestore.Increment(1)}})
}
func (c usersCounters) AddPostsCount(b store.Batch, uid string, _ int64)     { c.upd(b, uid) }
func (c usersCounters) AddFollowersCount(b store.Batch, uid string, _ int64) { c.upd(b, uid) }
func (c usersCounters) AddFollowingCount(b store.Batch, uid string, _ int64) { c.upd(b, uid) }
func (c usersCounters) AddCounts(b store.Batch, uid string, _, _ int64)      { c.upd(b, uid) }

var errAborted = status.Error(codes.Aborted, "Transaction lock timeout")

// TestUnfollow_RetryLoop drives Unfollow's bounded retry (ADR-0008 D1) with an injected commit and backoff,
// so it needs no emulator. Budget: a successful unfollow is 3 writes + 1 delete counted exactly once no
// matter how many attempts were lost; failed attempts count nothing.
func TestUnfollow_RetryLoop(t *testing.T) {
	t.Parallel()
	aborted := func(n int) []error {
		out := make([]error, n)
		for i := range out {
			out[i] = errAborted
		}
		return out
	}
	tests := []struct {
		name         string
		results      []error // commit results in order
		cancelOnWait int     // cancel ctx during the Nth backoff (1-based); 0 = never
		wantChanged  bool
		wantErr      func(error) bool
		wantCommits  int
		wantWaits    int
		wantAttempts int
		wantWrites   int64
		wantDeletes  int64
		wantCeilings []time.Duration
	}{
		{
			name: "aborted x5 then ok", results: append(aborted(5), nil),
			wantChanged: true, wantCommits: 6, wantWaits: 5, wantAttempts: 6, wantWrites: 3, wantDeletes: 1,
			wantCeilings: []time.Duration{25 * time.Millisecond, 50 * time.Millisecond, 100 * time.Millisecond, 200 * time.Millisecond, 400 * time.Millisecond},
		},
		{
			name: "first try ok", results: []error{nil},
			wantChanged: true, wantCommits: 1, wantAttempts: 1, wantWrites: 3, wantDeletes: 1,
		},
		{
			name: "aborted x6 is contention", results: aborted(6),
			wantErr:     func(err error) bool { return errors.Is(err, ErrContention) },
			wantCommits: 6, wantWaits: 5, wantAttempts: 6,
		},
		{
			name: "precondition failed is a no-op", results: []error{status.Error(codes.NotFound, "no such doc")},
			wantCommits: 1, wantAttempts: 1,
		},
		{
			name: "precondition failed after contention", results: []error{errAborted, status.Error(codes.FailedPrecondition, "exists")},
			wantCommits: 2, wantWaits: 1, wantAttempts: 2,
		},
		{
			name: "other error is not retried", results: []error{status.Error(codes.PermissionDenied, "nope")},
			wantErr: func(err error) bool {
				return status.Code(err) == codes.PermissionDenied && !errors.Is(err, ErrContention)
			},
			wantCommits: 1,
		},
		{
			name: "context cancelled during backoff", results: aborted(6), cancelOnWait: 2,
			wantErr:     func(err error) bool { return errors.Is(err, context.Canceled) },
			wantCommits: 2, wantWaits: 2, wantAttempts: 2,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			client := &firestore.Client{}
			repo := NewFirestoreRepo(client)
			repo.SetCounters(usersCounters{client})

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx, info := logger.WithRequestInfo(ctx)
			ctx, counter := budget.WithCounter(ctx)

			commits, waits := 0, 0
			var ceilings []time.Duration
			repo.commitBatch = func(context.Context, *store.FirestoreBatch) error {
				if commits >= len(tt.results) {
					t.Fatalf("unexpected commit #%d", commits+1)
				}
				err := tt.results[commits]
				commits++
				return err
			}
			repo.backoff = func(ctx context.Context, ceiling time.Duration) error {
				waits++
				ceilings = append(ceilings, ceiling)
				if waits == tt.cancelOnWait {
					cancel()
				}
				return ctx.Err()
			}

			changed, err := repo.Unfollow(ctx, "uid-a", "uid-b", time.Unix(0, 0))

			if changed != tt.wantChanged {
				t.Errorf("changed = %v, want %v", changed, tt.wantChanged)
			}
			if (err != nil) != (tt.wantErr != nil) || (tt.wantErr != nil && !tt.wantErr(err)) {
				t.Errorf("err = %v", err)
			}
			if commits != tt.wantCommits || waits != tt.wantWaits {
				t.Errorf("commits/waits = %d/%d, want %d/%d", commits, waits, tt.wantCommits, tt.wantWaits)
			}
			if tt.wantCeilings != nil {
				if fmt.Sprint(ceilings) != fmt.Sprint(tt.wantCeilings) {
					t.Errorf("backoff ceilings = %v, want %v", ceilings, tt.wantCeilings)
				}
			}
			if tt.wantAttempts > 0 {
				got, _ := info.Get(fieldTxnAttempt)
				if fmt.Sprint(got) != fmt.Sprint(tt.wantAttempts) {
					t.Errorf("txn_attempts = %v, want %d", got, tt.wantAttempts)
				}
			}
			if counter.Writes() != tt.wantWrites || counter.Deletes() != tt.wantDeletes || counter.Reads() != 0 {
				t.Errorf("budget r/w/d = %d/%d/%d, want 0/%d/%d", counter.Reads(), counter.Writes(), counter.Deletes(), tt.wantWrites, tt.wantDeletes)
			}
		})
	}
}

// TestUnfollow_ExhaustedMapsToUnavailable checks the service boundary for the exhausted-retry error.
func TestUnfollow_ExhaustedMapsToUnavailable(t *testing.T) {
	t.Parallel()
	client := &firestore.Client{}
	repo := NewFirestoreRepo(client)
	repo.SetCounters(usersCounters{client})
	repo.commitBatch = func(context.Context, *store.FirestoreBatch) error { return errAborted }
	repo.backoff = func(context.Context, time.Duration) error { return nil }

	_, err := repo.Unfollow(context.Background(), "uid-a", "uid-b", time.Now())
	mapped := (&service{}).internalErr("unfollow", err, "uid-a", "uid-b")
	assertAPIErr(t, mapped, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	var ae *apierr.Error
	if !errors.As(mapped, &ae) || ae.RetryAfter != time.Second {
		t.Errorf("RetryAfter = %v, want 1s", ae)
	}
}

// TestInternalErr_ContextEnds: a client disconnect or deadline is CANCELED / DEADLINE_EXCEEDED, never
// INTERNAL (mw logs only INTERNAL at ERROR).
func TestInternalErr_ContextEnds(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		err  error
		want connect.Code
	}{
		{"context.Canceled", fmt.Errorf("graph: unfollow: %w", context.Canceled), connect.CodeCanceled},
		{"grpc Canceled", status.Error(codes.Canceled, "rpc"), connect.CodeCanceled},
		{"context.DeadlineExceeded", fmt.Errorf("x: %w", context.DeadlineExceeded), connect.CodeDeadlineExceeded},
		{"grpc DeadlineExceeded", fmt.Errorf("x: %w", status.Error(codes.DeadlineExceeded, "rpc")), connect.CodeDeadlineExceeded},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := (&service{}).internalErr("unfollow", tt.err, "uid-a")
			assertAPIErr(t, got, tt.want, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		})
	}
}
