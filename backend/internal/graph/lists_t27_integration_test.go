//go:build integration

// lists_t27_integration_test.go (T27, ADR-0008 D10 refinement): ListMutedUsers/ListBlockedUsers remove uids
// whose users/{uid} doc is gone from the caller's OWN array, never touch SUSPENDED/DELETING entries, are
// idempotent, and stay inside the documented budget (reads 1 + page_size, writes <= 1).
package graph_test

import (
	"context"
	"reflect"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestListMutedUsers_Integration_LazyCleanup(t *testing.T) {
	w := newWired(t)
	ctx := context.Background()
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	for i, u := range []string{"uid-gone", "uid-susp", "uid-live"} {
		mustCreateProfile(t, w.identity, u, "user"+string(rune('b'+i)))
		if _, err := w.graph.Mute(ctx, "uid-a", key1, u); err != nil {
			t.Fatal(err)
		}
	}
	// uid-gone is purged (graph doc first, as PurgeUser leaves the muter's array alone), then its profile
	// is deleted; uid-susp is only suspended.
	if _, err := w.client.Doc("users/uid-gone").Delete(ctx); err != nil {
		t.Fatal(err)
	}
	seedUserField(t, w, "uid-susp", "status", "SUSPENDED")
	w.identity.(identity.Directory).Forget("uid-gone", "uid-susp", "uid-live")
	// Purge removed the target's own graph doc; the muter's muted[] keeps the entry (arrays aren't indexed).
	if _, err := w.client.Doc("graph/uid-gone").Delete(ctx); err != nil {
		t.Fatal(err)
	}
	w.SkipInvariantSweep("uid-gone's users/ and graph/ docs deleted to simulate a purge")

	var uids []string
	measured(t, "GraphService.ListMutedUsers (T27 clean-up)", budgettest.Budget{Reads: 1 + 3, Writes: 1}, func(c context.Context) {
		p, err := w.graph.ListMutedUsers(c, "uid-a", 50, "")
		if err != nil {
			t.Fatal(err)
		}
		for _, it := range p.Items {
			uids = append(uids, it.User.UserID)
		}
	})
	if !reflect.DeepEqual(uids, []string{"uid-live"}) {
		t.Errorf("page = %v, want only uid-live", uids)
	}
	if got := graphArrays(t, w.client, "uid-a")["muted"]; !reflect.DeepEqual(got, []string{"uid-susp", "uid-live"}) {
		t.Errorf("muted[] = %v, want uid-gone removed and uid-susp kept", got)
	}

	// Idempotent: the second call finds nothing missing and writes nothing.
	c2, counter := budget.WithCounter(ctx)
	if _, err := w.graph.ListMutedUsers(c2, "uid-a", 50, ""); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.ListMutedUsers (second call)", counter, budgettest.Budget{Reads: 1 + 3})
	if counter.Writes() != 0 {
		t.Errorf("second call writes = %d, want 0", counter.Writes())
	}
}

func TestListBlockedUsers_Integration_LazyCleanup_DanglingEntryAndRace(t *testing.T) {
	w := newWired(t)
	ctx := context.Background()
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-live", "userl")
	// Dangling entry with no users/ or graph/ doc (D2 overflow / L5 purge race) next to a live block.
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"blocked": []string{"uid-ghost", "uid-live"}})
	seedGraphArrays(t, w.client, "uid-live", map[string]interface{}{"blockedBy": []string{"uid-a"}})

	// Race: the same clean-up runs twice concurrently (two instances); ArrayRemove is idempotent.
	errs := runConcurrently(2, func(int) error {
		_, err := w.graph.ListBlockedUsers(ctx, "uid-a", 50, "")
		return err
	})
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := graphArrays(t, w.client, "uid-a")["blocked"]; !reflect.DeepEqual(got, []string{"uid-live"}) {
		t.Errorf("blocked[] = %v, want [uid-live]", got)
	}
	// Only the caller's own doc was written: the live target's blockedBy is untouched.
	if got := graphArrays(t, w.client, "uid-live")["blockedBy"]; !reflect.DeepEqual(got, []string{"uid-a"}) {
		t.Errorf("uid-live blockedBy = %v", got)
	}
}

// A concurrent Mute of a NEW uid between the list's read and its clean-up write must survive: ArrayRemove
// only touches the named uids.
func TestListMutedUsers_Integration_CleanupKeepsConcurrentAdds(t *testing.T) {
	w := newWired(t)
	ctx := context.Background()
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-new", "usern")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"muted": []string{"uid-ghost"}})
	if _, err := w.graph.ListMutedUsers(ctx, "uid-a", 50, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := w.client.Doc("graph/uid-a").Update(ctx, []firestore.Update{{Path: "muted", Value: firestore.ArrayUnion("uid-new")}}); err != nil {
		t.Fatal(err)
	}
	if got := graphArrays(t, w.client, "uid-a")["muted"]; !reflect.DeepEqual(got, []string{"uid-new"}) {
		t.Errorf("muted[] = %v, want [uid-new]", got)
	}
}
