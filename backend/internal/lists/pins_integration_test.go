//go:build integration

package lists

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// DeleteList unpins and UpdateList retitles through the real identity adapter (lists.Pins) on the emulator. That the adapter is not
// called on a replay, an unpinned delete or a description-only update is proved with a fake in service_test.go.

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

	// Pinned: the list goes and its tab goes with it.
	if err := e.svc.DeleteList(context.Background(), "owner", key(1), ids[0]); err != nil {
		t.Fatal(err)
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{ids[1] + ":seed 1"}) {
		t.Fatalf("pins = %v, want only the other list", got)
	}
	// A replay never reaches the adapter again (Deleted is false): the other tab is untouched.
	if err := e.svc.DeleteList(context.Background(), "owner", key(1), ids[0]); err != nil {
		t.Fatal(err)
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{ids[1] + ":seed 1"}) {
		t.Fatalf("pins after the replay = %v, want only the other list", got)
	}
	// Deleted, not pinned: the tabs stay as they were.
	pinTo(t, a, "pin-key-00000002")
	ids2 := e.seedLists(t, "owner", 1, nil)
	if err := e.svc.DeleteList(context.Background(), "owner", key(2), ids2[0]); err != nil {
		t.Fatal(err)
	}
	if got := pinnedIDs(t, e); len(got) != 0 {
		t.Fatalf("pins = %v, want none: deleting an unpinned list must not add a tab", got)
	}
}

func TestPins_Integration_UpdateListRetitles(t *testing.T) {
	e, a := pinsEnv(t)
	id := e.seedLists(t, "owner", 1, []string{"m1"})[0]
	pinTo(t, a, "pin-key-00000001", identity.HomeTab{Kind: identity.HomeTabKindList, ID: id, Title: "seed 0"})

	// Pinned rename: the tab takes the new name.
	v, err := e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(1), ListID: id, Name: ptr("Renamed")})
	if err != nil {
		t.Fatal(err)
	}
	if !v.PinnedByViewer {
		t.Error("the owner's UpdateList response must say pinned_by_viewer")
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{id + ":Renamed"}) {
		t.Fatalf("pins = %v, want the tab retitled", got)
	}
	// Not a rename: no Retitle at all.
	if _, err := e.svc.UpdateList(context.Background(), "owner", UpdateInput{Key: key(2), ListID: id, Description: ptr("d")}); err != nil {
		t.Fatal(err)
	}
	if got := pinnedIDs(t, e); !slices.Equal(got, []string{id + ":Renamed"}) {
		t.Fatalf("pins after a description-only update = %v, want the tab as it was", got)
	}
}
