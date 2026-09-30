//go:build integration

package graph_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// coldIdentity wires a second identity+graph pair over the SAME Firestore project with empty caches: what
// a freshly started Cloud Run instance sees (the wired fixture's caches are warmed by CreateProfile).
func coldIdentity(t *testing.T, w wired) identity.Service {
	t.Helper()
	gr := graph.NewFirestoreRepo(w.client)
	ir := identity.NewFirestoreRepo(w.client, gr)
	gr.SetCounters(ir)
	gr.SetProfiles(ir)
	gs := graph.New(graph.Deps{Repo: gr, Cache: graph.NewCache(time.Minute), Flags: alwaysOnFlags{}, CursorKey: []byte("test-cursor-key")})
	is := identity.New(ir, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithBlockChecker(gs))
	gs.SetDirectory(is.(identity.Directory))
	return is
}

// TestT17_GetProfile_BlockEnforcement_Budget closes the T16 gap found during the T17 test sweep: the plan
// budget for IdentityService.GetProfile with the block check wired ("3 reads worst / 0-1 typical", ADR-0008
// D9) had no measured assertion (identity's own budget tests run without a BlockChecker). Measures a cold
// instance, the warm path, and the blocked (NOT_FOUND) path.
func TestT17_GetProfile_BlockEnforcement_Budget(t *testing.T) {
	w := newWired(t)
	viewer, target := "uid-t17v", "uid-t17t"
	mustCreateProfile(t, w.identity, viewer, "t17viewer")
	mustCreateProfile(t, w.identity, target, "t17target")

	cold := coldIdentity(t, w)
	// Cold instance: viewer graph + viewer users doc (status) + target users doc.
	measured(t, "GetProfile+blockcheck (cold instance)", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
		if _, err := cold.GetProfile(ctx, viewer, identity.ProfileTarget{UserID: target}); err != nil {
			t.Fatalf("GetProfile: %v", err)
		}
	})
	// Warm: everything from the 60 s instance caches.
	measured(t, "GetProfile+blockcheck (warm)", budgettest.Budget{Reads: 0}, func(ctx context.Context) {
		if _, err := cold.GetProfile(ctx, viewer, identity.ProfileTarget{UserID: target}); err != nil {
			t.Fatalf("GetProfile (warm): %v", err)
		}
	})

	// Blocked: block seeded before the cold instance's first read. The block is on the viewer's own graph
	// (blockedBy), so the check needs no target-graph read.
	blockedViewer, blocker := "uid-t17bv", "uid-t17bb"
	mustCreateProfile(t, w.identity, blockedViewer, "t17blockedv")
	mustCreateProfile(t, w.identity, blocker, "t17blocker")
	seedBlock(t, w.client, blocker, blockedViewer)
	cold2 := coldIdentity(t, w)
	measured(t, "GetProfile+blockcheck (blocked, NOT_FOUND, cold instance)", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
		if _, err := cold2.GetProfile(ctx, blockedViewer, identity.ProfileTarget{UserID: blocker}); err == nil {
			t.Fatal("GetProfile succeeded for a viewer blocked by the target")
		}
	})
}
