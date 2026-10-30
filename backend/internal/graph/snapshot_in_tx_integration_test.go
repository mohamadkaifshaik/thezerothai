//go:build integration

// snapshot_in_tx_integration_test.go: graph.TxReader.SnapshotInTx (ADR-0027 note W7-33): 1 read through the transaction,
// the 60 s cache neither read nor filled, a missing document is an empty Snapshot.
package graph_test

import (
	"context"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func snapshotInTx(t *testing.T, client *firestore.Client, tr graph.TxReader, uid string) (graph.Snapshot, *budget.Counter) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	var snap graph.Snapshot
	err := client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		var terr error
		snap, terr = tr.SnapshotInTx(ctx, tx, uid)
		return terr
	})
	if err != nil {
		t.Fatalf("SnapshotInTx: %v", err)
	}
	return snap, counter
}

func TestSnapshotInTx_Integration_FreshOneReadCacheUntouched(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	// Warm this instance's 60 s cache with B's graph as it is now (empty).
	ctx0, c0 := budget.WithCounter(context.Background())
	cached, err := w.graph.repo.GetSnapshot(ctx0, "uid-b")
	if err != nil || len(cached.Blocked) != 0 {
		t.Fatalf("GetSnapshot = %+v, %v", cached, err)
	}
	_ = c0

	// B blocks and mutes A (on "another instance": the cache here still holds the old document).
	if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	snap, counter := snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	if !snap.Blocked["uid-a"] {
		t.Errorf("SnapshotInTx = %+v, want B's Blocked[uid-a] (fresh)", snap)
	}
	budgettest.Assert(t, "graph.SnapshotInTx", counter, budgettest.Budget{Reads: 1})
}

func TestSnapshotInTx_Integration_CacheNeitherReadNorFilled(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	reader := w.graph.Service.(graph.Reader)

	// A transaction read must not fill the cache: the next cached Snapshot still costs its own read.
	_, _ = snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	ctx, counter := budget.WithCounter(context.Background())
	if _, err := reader.Snapshot(ctx, "uid-b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "Reader.Snapshot after SnapshotInTx (cache was not filled)", counter, budgettest.Budget{Reads: 1})

	// With the cache warm (filled just above), a Block by B on ANOTHER instance sharing the database is invisible to this
	// instance's cached read but visible to SnapshotInTx.
	other := newInstance(w.client)
	if _, err := other.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}
	stale, err := reader.Snapshot(context.Background(), "uid-b")
	if err != nil {
		t.Fatal(err)
	}
	fresh, _ := snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	if stale.Blocked["uid-a"] || !fresh.Blocked["uid-a"] {
		t.Errorf("cached Blocked[a]=%v (want the 60 s old false), in-transaction Blocked[a]=%v (want true)", stale.Blocked["uid-a"], fresh.Blocked["uid-a"])
	}
}

func TestSnapshotInTx_Integration_MissingDocIsEmpty(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)
	snap, counter := snapshotInTx(t, client, repo, "ghost-uid")
	if len(snap.Following)+len(snap.Blocked)+len(snap.Muted) != 0 {
		t.Errorf("snapshot of a missing doc = %+v, want empty", snap)
	}
	budgettest.Assert(t, "graph.SnapshotInTx (missing)", counter, budgettest.Budget{Reads: 1})
}
