//go:build integration

package graph_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// TestBlockersAmong_Integration_OverflowReadsTheCandidatesInOneBatch: the viewer's blockedBy overflowed and omits the
// blocker; the batched read of the candidates' own docs finds it, a missing doc is "not blocked", and duplicates are
// read once.
func TestBlockersAmong_Integration_OverflowReadsTheCandidatesInOneBatch(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	seed := func(uid string, blocked []string, overflow bool) {
		t.Helper()
		_, err := client.Collection("graph").Doc(uid).Set(ctx, map[string]any{
			"following": []string{}, "blocked": blocked, "muted": []string{}, "requested": []string{},
			"blockedBy": []string{}, "blockedByOverflow": overflow, "updatedAt": time.Now().UTC(),
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	seed("viewer", []string{}, true)
	seed("blocker", []string{"viewer"}, false)
	seed("stranger", []string{"someone-else"}, false)

	repo := graph.NewFirestoreRepo(client)
	snaps, err := repo.GetSnapshots(ctx, []string{"blocker", "stranger", "missing", "blocker"})
	if err != nil {
		t.Fatalf("GetSnapshots: %v", err)
	}
	if len(snaps) != 3 || !snaps["blocker"].Blocked["viewer"] || snaps["stranger"].Blocked["viewer"] || len(snaps["missing"].Blocked) != 0 {
		t.Fatalf("snapshots = %+v", snaps)
	}

	svc := graph.New(graph.Deps{Repo: repo, Cache: graph.NewCache(time.Minute)})
	got, err := svc.BlockersAmong(ctx, "viewer", []string{"blocker", "stranger", "missing"})
	if err != nil {
		t.Fatalf("BlockersAmong: %v", err)
	}
	if len(got) != 1 || !got["blocker"] {
		t.Errorf("blockers = %v, want only blocker", got)
	}
}
