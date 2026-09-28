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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
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

// TestInitGraph_Integration_EmptyDocDecodesToEmptySnapshot (T5 acceptance): a doc created by InitGraph
// decodes to five empty sets with no error, and GetSnapshot's cache-miss path costs exactly 1 read.
func TestInitGraph_Integration_EmptyDocDecodesToEmptySnapshot(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)

	ctx, counter := budget.WithCounter(context.Background())
	b := store.NewFirestoreBatch(client, counter)
	repo.InitGraph(b, "uid-1", time.Now().UTC())
	if err := b.Commit(ctx); err != nil {
		t.Fatalf("commit: %v", err)
	}

	ctx2, counter2 := budget.WithCounter(context.Background())
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
	budgettest.Assert(t, "graph.GetSnapshot (cold)", counter2, budgettest.Budget{Reads: 1})
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

// TestSnapshot_Integration_ServiceCachesWithin60s (ADR-0008 D8/T5): two Reader.Snapshot calls within the
// cache TTL cost exactly 1 Firestore read.
func TestSnapshot_Integration_ServiceCachesWithin60s(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)

	ctx0, _ := budget.WithCounter(context.Background())
	b := store.NewFirestoreBatch(client, nil)
	repo.InitGraph(b, "uid-1", time.Now().UTC())
	if err := b.Commit(ctx0); err != nil {
		t.Fatalf("commit: %v", err)
	}

	svc := graph.New(graph.Deps{Repo: repo, Cache: graph.NewCache(time.Minute)})

	ctx, counter := budget.WithCounter(context.Background())
	if _, err := svc.Snapshot(ctx, "uid-1"); err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	if _, err := svc.Snapshot(ctx, "uid-1"); err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	budgettest.Assert(t, "graph.Snapshot (two calls, warm cache)", counter, budgettest.Budget{Reads: 1})
}
