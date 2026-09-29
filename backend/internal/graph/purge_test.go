package graph

import (
	"context"
	"errors"
	"testing"
)

func TestService_PurgeUser_DelegatesAndInvalidatesCache(t *testing.T) {
	repo := newFakeRepo()
	repo.purgeNext, repo.purgeDone = Checkpoint{Step: 3, Offset: 500}, false
	svc := newTestServiceWithRepo(repo, true)
	ctx := context.Background()
	_, _ = svc.Snapshot(ctx, "uid-1")

	next, done, err := svc.PurgeUser(ctx, "uid-1", Checkpoint{Step: 2})
	if err != nil || done || next != (Checkpoint{Step: 3, Offset: 500}) {
		t.Fatalf("PurgeUser = %+v, %v, %v", next, done, err)
	}
	if repo.lastPurgeCP != (Checkpoint{Step: 2}) {
		t.Errorf("checkpoint not forwarded: %+v", repo.lastPurgeCP)
	}
	_, _ = svc.Snapshot(ctx, "uid-1")
	if repo.calls != 2 {
		t.Errorf("snapshot reads = %d, want 2 (cache invalidated by the purge)", repo.calls)
	}

	repo.purgeErr = errors.New("boom")
	if _, _, err := svc.PurgeUser(ctx, "uid-1", Checkpoint{}); err == nil {
		t.Error("expected the repo error")
	}
}
