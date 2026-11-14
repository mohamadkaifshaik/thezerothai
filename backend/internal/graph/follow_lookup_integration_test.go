//go:build integration

package graph_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// TestFollowersAmong_Integration_OneBatchOfEdgeDocs: FollowEdgesExist reads follows/{candidate}_{viewer} in one batch
// (a missing doc is false, the opposite edge does not count, duplicates are read once), and FollowersAmong over the
// real repo answers the same, then from its cache.
func TestFollowersAmong_Integration_OneBatchOfEdgeDocs(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	for _, id := range []string{"fl-org-a_fl-viewer", "fl-viewer_fl-org-b"} {
		if _, err := client.Collection("follows").Doc(id).Set(ctx, map[string]any{"createdAt": time.Now().UTC()}); err != nil {
			t.Fatal(err)
		}
	}
	repo := graph.NewFirestoreRepo(client)
	got, err := repo.FollowEdgesExist(ctx, "fl-viewer", []string{"fl-org-a", "fl-org-b", "fl-org-c", "fl-org-a"})
	if err != nil {
		t.Fatalf("FollowEdgesExist: %v", err)
	}
	if len(got) != 3 || !got["fl-org-a"] || got["fl-org-b"] || got["fl-org-c"] {
		t.Fatalf("edges = %v, want only fl-org-a", got)
	}
	if _, err := repo.FollowEdgesExist(ctx, "fl-viewer", []string{"bad_uid"}); err == nil {
		t.Error("a uid with '_' must be refused (ambiguous edge id)")
	}

	svc := graph.New(graph.Deps{Repo: repo, Cache: graph.NewCache(time.Minute)})
	followers, err := svc.FollowersAmong(ctx, "fl-viewer", []string{"fl-org-a", "fl-org-b", "fl-org-c"})
	if err != nil {
		t.Fatalf("FollowersAmong: %v", err)
	}
	if len(followers) != 1 || !followers["fl-org-a"] {
		t.Fatalf("followers = %v, want only fl-org-a", followers)
	}
}
