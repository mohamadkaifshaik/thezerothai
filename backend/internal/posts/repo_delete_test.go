package posts

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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type countersStub struct{ client *firestore.Client }

func (c countersStub) AddPostsCount(b store.Batch, uid string, _ int64) {
	b.Update(c.client.Doc("users/"+uid), []firestore.Update{{Path: "postsCount", Value: 1}})
}
func (countersStub) AddFollowingCount(store.Batch, string, int64) {}
func (countersStub) AddFollowersCount(store.Batch, string, int64) {}
func (countersStub) AddCounts(store.Batch, string, int64, int64)  {}

// TestDeleteOwn_RetryLoop drives DeleteOwn's contention retry (jittered via store.CommitWithRetry) with injected
// commit/backoff: success counts 1 write + 1 delete once, a failed precondition 0, exhaustion is an error.
func TestDeleteOwn_RetryLoop(t *testing.T) {
	t.Parallel()
	aborted := status.Error(codes.Aborted, "lock")
	tests := []struct {
		name         string
		results      []error
		want         bool
		wantErr      bool
		wantWaits    int
		wantAttempts int
		wantWrites   int64
	}{
		{name: "clean", results: []error{nil}, want: true, wantAttempts: 1, wantWrites: 1},
		{name: "wins after contention", results: []error{aborted, nil}, want: true, wantWaits: 1, wantAttempts: 2, wantWrites: 1},
		{name: "gone after contention", results: []error{aborted, status.Error(codes.NotFound, "x")}, wantWaits: 1, wantAttempts: 2},
		{name: "exhausted", results: []error{aborted, aborted, aborted, aborted}, wantErr: true, wantWaits: 3, wantAttempts: 4},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			client := &firestore.Client{}
			repo := NewFirestoreRepo(client)
			repo.SetWriters(WriteDeps{Counters: countersStub{client}})
			commits, waits := 0, 0
			repo.commitBatch = func(context.Context, *store.FirestoreBatch) error {
				commits++
				return tt.results[commits-1]
			}
			repo.backoff = func(context.Context, time.Duration) error { waits++; return nil }
			ctx, info := logger.WithRequestInfo(context.Background())
			ctx, counter := budget.WithCounter(ctx)

			got, err := repo.DeleteOwn(ctx, "1", "uid-a")
			if got != tt.want || (err != nil) != tt.wantErr || waits != tt.wantWaits {
				t.Errorf("got/err/waits = %v/%v/%d", got, err, waits)
			}
			if v, _ := info.Get("txn_attempts"); fmt.Sprint(v) != fmt.Sprint(tt.wantAttempts) {
				t.Errorf("txn_attempts = %v, want %d", v, tt.wantAttempts)
			}
			if counter.Writes() != tt.wantWrites {
				t.Errorf("writes = %d, want %d", counter.Writes(), tt.wantWrites)
			}
			if tt.wantErr && !errors.Is(err, store.ErrContended) {
				t.Errorf("err = %v, want ErrContended", err)
			}
		})
	}
}
