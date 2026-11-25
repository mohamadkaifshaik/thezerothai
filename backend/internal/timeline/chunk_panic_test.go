package timeline

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"golang.org/x/sync/semaphore"
)

// An instance at its query limit must honor a queued request's deadline.
func TestChunkReadBudgetCancellation(t *testing.T) {
	r := newRig(t)
	r.srv.chunkReads = semaphore.NewWeighted(1)
	if !r.srv.chunkReads.TryAcquire(1) {
		t.Fatal("empty semaphore refused slot")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := r.srv.homeSources(ctx, []string{"a"}, request{}, 20, r.clock.Now())
	if !errors.Is(err, context.DeadlineExceeded) || len(r.posts.queries) != 0 {
		t.Fatalf("queued query: err=%v, queries=%v", err, r.posts.queries)
	}
	r.srv.chunkReads.Release(1)
	_, err = r.srv.homeSources(context.Background(), []string{"a"}, request{}, 20, r.clock.Now())
	if err != nil || len(r.posts.queries) != 1 || !r.srv.chunkReads.TryAcquire(1) {
		t.Fatalf("next query: err=%v, queries=%v", err, r.posts.queries)
	}
}

// The per-chunk author queries run on errgroup goroutines, which the request's recover interceptor does not cover.
func TestListTimeline_PanicInChunkQueryFailsTheCallOnly(t *testing.T) {
	r, _ := listRig(t, names("m", 3)...)
	r.posts.hook = func() { panic("boom") }
	_, err := r.list("me", testListID, "", "", 20)
	if err == nil || !strings.Contains(err.Error(), "panic of type string") {
		t.Fatalf("err = %v, want the panic as this call's error", err)
	}
}
