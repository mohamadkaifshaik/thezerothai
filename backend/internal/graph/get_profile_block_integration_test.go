//go:build integration

package graph_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
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

// TestT17_GetProfile_BlockEnforcement: IdentityService.GetProfile with the block check wired answers on a cold
// instance and from its warm caches, and is NOT_FOUND for a viewer the target blocked (identity's own tests run
// without a BlockChecker).
func TestT17_GetProfile_BlockEnforcement(t *testing.T) {
	w := newWired(t)
	viewer, target := "uid-t17v", "uid-t17t"
	mustCreateProfile(t, w.identity, viewer, "t17viewer")
	mustCreateProfile(t, w.identity, target, "t17target")

	ctx := context.Background()
	cold := coldIdentity(t, w)
	if _, err := cold.GetProfile(ctx, viewer, identity.ProfileTarget{UserID: target}); err != nil {
		t.Fatalf("GetProfile (cold instance): %v", err)
	}
	// Warm: everything from the 60 s instance caches.
	if _, err := cold.GetProfile(ctx, viewer, identity.ProfileTarget{UserID: target}); err != nil {
		t.Fatalf("GetProfile (warm): %v", err)
	}

	// Blocked: block seeded before the cold instance's first read. The block is on the viewer's own graph
	// (blockedBy), so the check needs no target-graph read.
	blockedViewer, blocker := "uid-t17bv", "uid-t17bb"
	mustCreateProfile(t, w.identity, blockedViewer, "t17blockedv")
	mustCreateProfile(t, w.identity, blocker, "t17blocker")
	seedBlock(t, w.client, blocker, blockedViewer)
	cold2 := coldIdentity(t, w)
	if _, err := cold2.GetProfile(ctx, blockedViewer, identity.ProfileTarget{UserID: blocker}); err == nil {
		t.Fatal("GetProfile succeeded for a viewer blocked by the target")
	}
}
