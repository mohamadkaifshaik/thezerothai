package graph

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// FollowEdgesExist answers from f.followEdges (followee fixed) and records each batch: one call is one batched read.
func (f *fakeRepo) FollowEdgesExist(_ context.Context, followeeUID string, followerUIDs []string) (map[string]bool, error) {
	f.edgeBatches = append(f.edgeBatches, append([]string(nil), followerUIDs...))
	if f.edgeBatchErr != nil {
		return nil, f.edgeBatchErr
	}
	out := map[string]bool{}
	for _, u := range followerUIDs {
		out[u] = f.followEdges[edgeKey{u, followeeUID}]
	}
	return out, nil
}

// TestFollowersAmong: distinct candidates only (no empty id, never the viewer), the edge direction is candidate ->
// viewer, one batched read cold and none warm (true and false both cached), chunks of 25, the cap refused before any
// read, and an error fails the call.
func TestFollowersAmong(t *testing.T) {
	ctx := context.Background()
	t.Run("dedupe, direction and cache", func(t *testing.T) {
		repo := newFakeRepo()
		repo.followEdges = map[edgeKey]bool{
			{"org-a", "me"}: true,
			{"me", "org-b"}: true, // the viewer follows org-b: the wrong direction
		}
		svc := newTestServiceWithRepo(repo, true)
		got, err := svc.FollowersAmong(ctx, "me", []string{"org-a", "org-b", "", "me", "org-a", "org-c"})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || !got["org-a"] {
			t.Fatalf("followers = %v, want only org-a", got)
		}
		if len(repo.edgeBatches) != 1 || len(repo.edgeBatches[0]) != 3 {
			t.Fatalf("batches = %v, want one batch of the 3 distinct candidates", repo.edgeBatches)
		}
		again, err := svc.FollowersAmong(ctx, "me", []string{"org-c", "org-a", "org-b"})
		if err != nil || len(again) != 1 || !again["org-a"] {
			t.Fatalf("warm = %v, %v", again, err)
		}
		if len(repo.edgeBatches) != 1 {
			t.Fatalf("warm call read again: %v", repo.edgeBatches)
		}
		// The followed_by cache is the same one: GetProfileRelationship's pair answer needs no read now.
		if exists, ok := svc.cache.Edge("org-a", "me"); !ok || !exists {
			t.Fatalf("edge cache = %v, %v", exists, ok)
		}
	})
	t.Run("empty and self only read nothing", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestServiceWithRepo(repo, true)
		got, err := svc.FollowersAmong(ctx, "me", []string{"", "me"})
		if err != nil || len(got) != 0 || len(repo.edgeBatches) != 0 {
			t.Fatalf("got %v, %v, batches %v", got, err, repo.edgeBatches)
		}
	})
	t.Run("chunks of 25", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestServiceWithRepo(repo, true)
		var cands []string
		for i := range 60 {
			cands = append(cands, fmt.Sprintf("u-%02d", i))
		}
		if _, err := svc.FollowersAmong(ctx, "me", cands); err != nil {
			t.Fatal(err)
		}
		if len(repo.edgeBatches) != 3 || len(repo.edgeBatches[0]) != 25 || len(repo.edgeBatches[2]) != 10 {
			t.Fatalf("batches = %d, want 25+25+10", len(repo.edgeBatches))
		}
	})
	t.Run("cap", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestServiceWithRepo(repo, true)
		var cands []string
		for i := range MaxFollowLookup + 1 {
			cands = append(cands, fmt.Sprintf("u-%03d", i))
		}
		if _, err := svc.FollowersAmong(ctx, "me", cands); err == nil || len(repo.edgeBatches) != 0 {
			t.Fatalf("err = %v, batches %d, want a refusal before any read", err, len(repo.edgeBatches))
		}
	})
	t.Run("read error", func(t *testing.T) {
		repo := newFakeRepo()
		repo.edgeBatchErr = errors.New("boom")
		svc := newTestServiceWithRepo(repo, true)
		if _, err := svc.FollowersAmong(ctx, "me", []string{"org-a"}); !errors.Is(err, repo.edgeBatchErr) {
			t.Fatalf("err = %v, want the read error wrapped", err)
		}
		if _, ok := svc.cache.Edge("org-a", "me"); ok {
			t.Fatal("a failed read was cached")
		}
	})
}
