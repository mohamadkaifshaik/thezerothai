//go:build integration

package graph_test

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func newTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	projectID := fmt.Sprintf("demo-test-%d", rand.Int63())
	client, err := firestore.NewClient(context.Background(), projectID)
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

// TestInitGraph_Integration_EmptyDocDecodesToEmptySnapshot (acceptance): a doc created by InitGraph
// decodes to five empty sets with no error.
func TestInitGraph_Integration_EmptyDocDecodesToEmptySnapshot(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)

	b := store.NewFirestoreBatch(client)
	repo.InitGraph(b, "uid-1", time.Now().UTC())
	if err := b.Commit(context.Background()); err != nil {
		t.Fatalf("commit: %v", err)
	}

	ctx2 := context.Background()
	snap, err := repo.GetSnapshot(ctx2, "uid-1")
	if err != nil {
		t.Fatalf("GetSnapshot() error = %v", err)
	}
	if len(snap.Following) != 0 || len(snap.Blocked) != 0 || len(snap.Muted) != 0 || len(snap.Requested) != 0 || len(snap.BlockedBy) != 0 {
		t.Errorf("expected all sets empty, got %+v", snap)
	}
	if snap.BlockedByOverflow {
		t.Error("expected BlockedByOverflow = false")
	}
}

// TestGetSnapshot_Integration_MissingDocIsEmptyNotError: a graph doc that was never created (defensive:
// should not happen for a real ACTIVE profile) must not crash a request.
func TestGetSnapshot_Integration_MissingDocIsEmptyNotError(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)

	snap, err := repo.GetSnapshot(context.Background(), "ghost-uid")
	if err != nil {
		t.Fatalf("GetSnapshot() error = %v", err)
	}
	if len(snap.Following) != 0 {
		t.Errorf("expected an empty snapshot for a missing doc, got %+v", snap)
	}
}

// TestSnapshot_Integration_ServiceCachesWithin60s: a second Reader.Snapshot call within the cache TTL is served from
// the cache, so it does not see a change written to the document after the first call.
func TestSnapshot_Integration_ServiceCachesWithin60s(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)

	ctx0 := context.Background()
	b := store.NewFirestoreBatch(client)
	repo.InitGraph(b, "uid-1", time.Now().UTC())
	if err := b.Commit(ctx0); err != nil {
		t.Fatalf("commit: %v", err)
	}

	svc := graph.New(graph.Deps{Repo: repo, Cache: graph.NewCache(time.Minute)})

	ctx := context.Background()
	first, err := svc.Snapshot(ctx, "uid-1")
	if err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	if first.Blocked["uid-2"] {
		t.Fatalf("first Snapshot = %+v, want nothing blocked yet", first)
	}
	if _, err := client.Collection("graph").Doc("uid-1").Update(ctx, []firestore.Update{{Path: "blocked", Value: firestore.ArrayUnion("uid-2")}}); err != nil {
		t.Fatalf("write blocked: %v", err)
	}
	second, err := svc.Snapshot(ctx, "uid-1")
	if err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	if second.Blocked["uid-2"] {
		t.Errorf("second Snapshot = %+v saw a write made after the first call: it was not served from the cache", second)
	}
}
