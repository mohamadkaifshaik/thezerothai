//go:build integration

// lists_t27_integration_test.go (T27, ADR-0008 D10 refinement): ListMutedUsers/ListBlockedUsers remove uids
// whose users/{uid} doc is gone from the caller's OWN array, never touch SUSPENDED/DELETING entries, are
// idempotent, and stay inside the documented budget (reads 1 + page_size, writes <= 1).
package graph_test

import (
	"context"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// hookDirectory decorates identity.Directory: after the real LookupProfiles returns, afterLookup runs before
// the result goes back to graph, i.e. between graph's GetLists and its RemoveOwnArrayEntries.
type hookDirectory struct {
	identity.Directory
	afterLookup func(ctx context.Context)
}

func (h hookDirectory) LookupProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, []string, error) {
	found, missing, err := h.Directory.LookupProfiles(ctx, uids)
	if err == nil && h.afterLookup != nil {
		h.afterLookup(ctx)
	}
	return found, missing, err
}

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

// Two "instances" (separate identity+graph pairs, so separate caches) share one Firestore. A barrier in each
// instance's Directory holds the hydrated result until BOTH have looked up, so both really issue the
// ArrayRemove concurrently, and neither can be short-circuited by a negative cache. ArrayRemove is idempotent:
// both succeed and the array ends up clean.
func TestListBlockedUsers_Integration_LazyCleanup_DanglingEntryAndRace(t *testing.T) {
	w1 := newWired(t)
	w2 := newInstance(w1.client)
	ctx := context.Background()
	mustCreateProfile(t, w1.identity, "uid-a", "usera")
	mustCreateProfile(t, w1.identity, "uid-live", "userl")
	// Dangling entry with no users/ or graph/ doc (D2 overflow / L5 purge race) next to a live block.
	seedGraphArrays(t, w1.client, "uid-a", map[string]interface{}{"blocked": []string{"uid-ghost", "uid-live"}})
	seedGraphArrays(t, w1.client, "uid-live", map[string]interface{}{"blockedBy": []string{"uid-a"}})

	var arrived sync.WaitGroup
	arrived.Add(2)
	barrier := func(context.Context) {
		arrived.Done()
		done := make(chan struct{})
		go func() { arrived.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("barrier: the other instance never reached the clean-up")
		}
	}
	for _, w := range []wired{w1, w2} {
		w.graph.setDirectory(hookDirectory{Directory: w.identity.(identity.Directory), afterLookup: barrier})
	}

	errs := runConcurrently(2, func(i int) error {
		w := []wired{w1, w2}[i]
		c, counter := budget.WithCounter(ctx)
		_, err := w.graph.ListBlockedUsers(c, "uid-a", 50, "")
		if counter.Writes() != 1 {
			t.Errorf("instance %d writes = %d, want 1 (both must attempt the ArrayRemove)", i, counter.Writes())
		}
		return err
	})
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := graphArrays(t, w1.client, "uid-a")["blocked"]; !reflect.DeepEqual(got, []string{"uid-live"}) {
		t.Errorf("blocked[] = %v, want [uid-live]", got)
	}
	// Only the caller's own doc was written: the live target's blockedBy is untouched.
	if got := graphArrays(t, w1.client, "uid-live")["blockedBy"]; !reflect.DeepEqual(got, []string{"uid-a"}) {
		t.Errorf("uid-live blockedBy = %v", got)
	}
}

// A Mute of a NEW uid that lands between the list's GetLists and its clean-up write must survive: the
// decorator's LookupProfiles runs graph.Mute mid-call, and ArrayRemove only touches the named stale uid.
func TestListMutedUsers_Integration_CleanupKeepsConcurrentAdds(t *testing.T) {
	w := newWired(t)
	ctx := context.Background()
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-new", "usern")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"muted": []string{"uid-ghost"}})

	muted := false
	w.graph.setDirectory(hookDirectory{Directory: w.identity.(identity.Directory), afterLookup: func(c context.Context) {
		if muted {
			return
		}
		muted = true
		if _, err := w.graph.Mute(c, "uid-a", key1, "uid-new"); err != nil {
			t.Errorf("mid-call Mute: %v", err)
		}
	}})

	if _, err := w.graph.ListMutedUsers(ctx, "uid-a", 50, ""); err != nil {
		t.Fatal(err)
	}
	if !muted {
		t.Fatal("hook never ran: the race was not exercised")
	}
	if got := graphArrays(t, w.client, "uid-a")["muted"]; !reflect.DeepEqual(got, []string{"uid-new"}) {
		t.Errorf("muted[] = %v, want [uid-new] (stale uid-ghost gone, concurrent add kept)", got)
	}
}

// RemoveOwnArrayEntries only accepts "blocked" and "muted": any other kind (here "following") is an error
// and leaves that array untouched.
func TestRemoveOwnArrayEntries_Integration_RejectsFollowing(t *testing.T) {
	w := newWired(t)
	ctx := context.Background()
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"following": []string{"uid-x", "uid-y"}})

	if err := w.graph.repo.RemoveOwnArrayEntries(ctx, "uid-a", "following", []string{"uid-x"}, time.Now()); err == nil {
		t.Fatal("expected an error for kind \"following\"")
	}
	if got := graphArrays(t, w.client, "uid-a")["following"]; !reflect.DeepEqual(got, []string{"uid-x", "uid-y"}) {
		t.Errorf("following[] = %v, want unchanged", got)
	}
	w.SkipInvariantSweep("following[] seeded without edge docs/counters")
}
