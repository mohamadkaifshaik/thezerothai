//go:build integration

package lists

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// W5-9: DeleteList unpins and UpdateList retitles through the real identity adapter (lists.Pins) on the emulator. Reads and writes
// are the service's own on top of the interceptor's one profile read: a pinned list adds 1 read and 1 write, an unpinned one adds
// 1 read and no write.

func pinsEnv(t *testing.T) (*listsEnv, *identity.HomeTabsAdapter) {
	t.Helper()
	e := newListsEnv(t, time.Now().Add(-72*time.Hour))
	ctx := context.Background()
	if _, err := e.client.Collection("users").Doc("owner").Set(ctx, map[string]any{
		"handle": "owner", "handleLower": "owner", "status": "ACTIVE", "createdAt": time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	repo := identity.NewFirestoreRepo(e.client, graph.NewFirestoreRepo(e.client))
	adapter := identity.NewHomeTabs(repo, idempotency.New(e.client), identity.NewCache(time.Minute))
	e.svc.d.Pins = adapter
	return e, adapter
}

func pinTo(t *testing.T, a *identity.HomeTabsAdapter, key string, tabs ...identity.HomeTab) {
	t.Helper()
	if _, err := a.Replace(context.Background(), "owner", key, "h-"+key, func([]identity.HomeTab) ([]identity.HomeTab, error) { return tabs, nil }); err != nil {
		t.Fatal(err)
	}
}

func pinnedIDs(t *testing.T, e *listsEnv) []string {
	t.Helper()
	snap, err := e.client.Collection("users").Doc("owner").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d struct {
		HomeTabs []identity.HomeTab `firestore:"homeTabs"`
	}
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, tb := range d.HomeTabs {
		out = append(out, tb.ID+":"+tb.Title)
	}
	return out
}

func TestPins_Integration_DeleteListUnpins(t *testing.T) {
	e, a := pinsEnv(t)
	ids := e.seedLists(t, "owner", 2, []string{"m1"})
	pinTo(t, a, "pin-key-00000001", identity.HomeTab{Kind: identity.HomeTabKindList, ID: ids[0], Title: "seed 0"}, identity.HomeTab{Kind: identity.HomeTabKindList, ID: ids[1], Title: "seed 1"})

	// Pinned: 2 reads + 1 (Unpin) = 3; writes 1 (idempotency) + 1 (homeTabs) = 2; 1 delete.
	c := measured(t, "DeleteList, pinned", budgettest.Budget{Reads: 3, Writes: 2, Deletes: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(1), ids[0]); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 3 || c.Writes() != 2 || c.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 3/2/1", c.Reads(), c.Writes(), c.Deletes())
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{ids[1] + ":seed 1"}) {
		t.Fatalf("pins = %v, want only the other list", got)
	}
	// A replay never reaches the adapter again (Deleted is false): 1 read, 0 writes.
	c = measured(t, "DeleteList, replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(1), ids[0]); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 0 {
		t.Errorf("replay writes = %d, want 0", c.Writes())
	}
	// Deleted, not pinned: Unpin reads once and writes nothing.
	pinTo(t, a, "pin-key-00000002")
	ids2 := e.seedLists(t, "owner", 1, nil)
	c = measured(t, "DeleteList, unpinned", budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1}, func(ctx context.Context) {
		if err := e.svc.DeleteList(ctx, "owner", key(2), ids2[0]); err != nil {
			t.Fatal(err)
		}
	})
	if c.Writes() != 1 {
		t.Errorf("unpinned writes = %d, want 1 (the idempotency record only)", c.Writes())
	}
}

func TestPins_Integration_UpdateListRetitles(t *testing.T) {
	e, a := pinsEnv(t)
	id := e.seedLists(t, "owner", 1, []string{"m1"})[0]
	pinTo(t, a, "pin-key-00000001", identity.HomeTab{Kind: identity.HomeTabKindList, ID: id, Title: "seed 0"})

	// Pinned rename: 2 reads + 1 (Retitle); writes 2 (list, idempotency) + 1 (homeTabs).
	var v View
	c := measured(t, "UpdateList rename, pinned", budgettest.Budget{Reads: 3, Writes: 3}, func(ctx context.Context) {
		var err error
		v, err = e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(1), ListID: id, Name: ptr("Renamed")})
		if err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 3 || c.Writes() != 3 {
		t.Errorf("reads/writes = %d/%d, want 3/3", c.Reads(), c.Writes())
	}
	if !v.PinnedByViewer {
		t.Error("the owner's UpdateList response must say pinned_by_viewer")
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{id + ":Renamed"}) {
		t.Fatalf("pins = %v, want the tab retitled", got)
	}
	// Not a rename: no Retitle at all.
	c = measured(t, "UpdateList description only", budgettest.Budget{Reads: 2, Writes: 2}, func(ctx context.Context) {
		if _, err := e.svc.UpdateList(ctx, "owner", UpdateInput{Key: key(2), ListID: id, Description: ptr("d")}); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 2 {
		t.Errorf("description-only reads = %d, want 2 (no pin lookup)", c.Reads())
	}
}
