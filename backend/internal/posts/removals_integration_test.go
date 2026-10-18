//go:build integration

package posts

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// seedSharedInstantRemovals commits n log entries in ONE batch, so they all carry the same server createdAt (the
// shape of a suspension page, ADR-0016 D10).
func seedSharedInstantRemovals(t *testing.T, repo *FirestoreRepo, n int) {
	t.Helper()
	seedSharedInstantRemovalsBy(t, repo, "spammer", n)
}

func seedSharedInstantRemovalsBy(t *testing.T, repo *FirestoreRepo, author string, n int) {
	t.Helper()
	b := repo.client.Batch()
	for i := range n {
		b.Set(repo.removalRef(fmt.Sprintf("%019d", i+1)), removalDoc{State: string(RemovalRemoved), AuthorID: author, ExpireAt: time.Now().Add(RemovalRetention)})
	}
	if _, err := b.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
}

// TestRemovalSource_AfterPagesThroughSharedTimestamp checks, against the emulator, that (createdAt, __name__)
// StartAfter paging neither skips nor repeats entries that share one commit timestamp, and that it needs no
// composite index.
func TestRemovalSource_AfterPagesThroughSharedTimestamp(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedSharedInstantRemovals(t, repo, 120)

	floor := time.Now().Add(-time.Hour)
	var all []RemovalEntry
	at, id := floor, ""
	for range 10 {
		ctx, c := budget.WithCounter(context.Background())
		page, err := repo.After(ctx, at, id, RemovalMaxIDs)
		if err != nil {
			t.Fatal(err)
		}
		if want := int64(max(len(page), 1)); c.Reads() != want {
			t.Fatalf("page of %d charged %d reads, want %d", len(page), c.Reads(), want)
		}
		all = append(all, page...)
		if len(page) < RemovalMaxIDs {
			break
		}
		at, id = page[len(page)-1].At, page[len(page)-1].PostID
	}
	if len(all) != 120 {
		t.Fatalf("paged %d entries, want 120", len(all))
	}
	for i, e := range all {
		if want := fmt.Sprintf("%019d", i+1); e.PostID != want {
			t.Fatalf("entry %d = %s, want %s (ascending, no skip, no repeat)", i, e.PostID, want)
		}
		if !e.At.Equal(all[0].At) {
			t.Fatalf("entry %d has a different createdAt: seeding did not share one commit timestamp", i)
		}
	}
	last := all[len(all)-1]
	ctx, c := budget.WithCounter(context.Background())
	tail, err := repo.After(ctx, last.At, last.PostID, RemovalMaxIDs)
	if err != nil || len(tail) != 0 {
		t.Fatalf("after the last entry: %d entries err=%v, want none", len(tail), err)
	}
	budgettest.Assert(t, "After at the tail", c, budgettest.Budget{Reads: 1})

	// Newest is the same order reversed.
	newest, err := repo.Newest(context.Background(), floor, 3)
	if err != nil || len(newest) != 3 || newest[0].PostID != fmt.Sprintf("%019d", 120) || newest[2].PostID != fmt.Sprintf("%019d", 118) {
		t.Fatalf("Newest = %+v err=%v, want ids 120,119,118", newest, err)
	}
}
