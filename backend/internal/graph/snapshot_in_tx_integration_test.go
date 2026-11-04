//go:build integration

// snapshot_in_tx_integration_test.go: graph.TxReader.SnapshotInTx reads through the transaction,
// the 60 s cache neither read nor filled, a missing document is an empty Snapshot.
package graph_test

import (
	"context"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

func snapshotInTx(t *testing.T, client *firestore.Client, tr graph.TxReader, uid string) graph.Snapshot {
	t.Helper()
	ctx := context.Background()
	var snap graph.Snapshot
	err := client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		var terr error
		snap, terr = tr.SnapshotInTx(ctx, tx, uid)
		return terr
	})
	if err != nil {
		t.Fatalf("SnapshotInTx: %v", err)
	}
	return snap
}

func TestSnapshotInTx_Integration_FreshCacheUntouched(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	// Warm this instance's 60 s cache with B's graph as it is now (empty).
	ctx0 := context.Background()
	cached, err := w.graph.repo.GetSnapshot(ctx0, "uid-b")
	if err != nil || len(cached.Blocked) != 0 {
		t.Fatalf("GetSnapshot = %+v, %v", cached, err)
	}

	// B blocks and mutes A (on "another instance": the cache here still holds the old document).
	if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	snap := snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	if !snap.Blocked["uid-a"] {
		t.Errorf("SnapshotInTx = %+v, want B's Blocked[uid-a] (fresh)", snap)
	}
}

func TestSnapshotInTx_Integration_CacheNeitherReadNorFilled(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	reader := w.graph.Service.(graph.Reader)

	// A transaction read must not fill the cache: a Block on ANOTHER instance sharing the database, made after the
	// transaction read, is visible to the next cached Snapshot because that call still has to load the document.
	snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	other := newInstance(w.client)
	if _, err := other.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}
	first, err := reader.Snapshot(context.Background(), "uid-b")
	if err != nil {
		t.Fatal(err)
	}
	if !first.Blocked["uid-a"] {
		t.Fatalf("Snapshot after SnapshotInTx = %+v, want Blocked[uid-a]: the transaction read must not have filled the cache", first)
	}

	// With the cache warm (filled just above), a second Block by B on the other instance is invisible to this
	// instance's cached read but visible to SnapshotInTx.
	if _, err := other.graph.Block(context.Background(), "uid-b", key2, "uid-c"); err != nil {
		t.Fatal(err)
	}
	stale, err := reader.Snapshot(context.Background(), "uid-b")
	if err != nil {
		t.Fatal(err)
	}
	fresh := snapshotInTx(t, w.client, w.graph.repo, "uid-b")
	if stale.Blocked["uid-c"] || !fresh.Blocked["uid-c"] {
		t.Errorf("cached Blocked[c]=%v (want the 60 s old false), in-transaction Blocked[c]=%v (want true)", stale.Blocked["uid-c"], fresh.Blocked["uid-c"])
	}
}

func TestSnapshotInTx_Integration_MissingDocIsEmpty(t *testing.T) {
	client := newTestClient(t)
	repo := graph.NewFirestoreRepo(client)
	snap := snapshotInTx(t, client, repo, "ghost-uid")
	if len(snap.Following)+len(snap.Blocked)+len(snap.Muted) != 0 {
		t.Errorf("snapshot of a missing doc = %+v, want empty", snap)
	}
}
