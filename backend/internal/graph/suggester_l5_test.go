package graph

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// W3-22 L-5: one account must not steer friends-of-friends suggestions. Each sampled followee contributes at most
// maxCandidatesPerFollowee candidates, and a sampled followee the Directory cache already knows is not ACTIVE is left
// out of the query. Both cost 0 reads.

var l5Followees = []string{"fe-00", "fe-01", "fe-02", "fe-03", "fe-04"} // fe-04 is the newest followee

// inactiveDir is sugDir plus the optional cache-only KnownInactive extension identity's service implements.
type inactiveDir struct {
	*sugDir
	known  map[string]bool
	probes [][]string
}

func (d *inactiveDir) KnownInactive(uids []string) map[string]bool {
	d.probes = append(d.probes, slices.Clone(uids))
	out := map[string]bool{}
	for _, u := range uids {
		if d.known[u] {
			out[u] = true
		}
	}
	return out
}

func sortedCopy(s []string) []string {
	out := slices.Clone(s)
	slices.Sort(out)
	return out
}

// pairsFrom builds {follower, candidate} pairs for every candidate, in order (newest first once edgesOf stamps them).
func pairsFrom(follower string, candidates []string) [][2]string {
	out := make([][2]string, len(candidates))
	for i, c := range candidates {
		out[i] = [2]string{follower, c}
	}
	return out
}

func TestFriendsOfFriends_PerFolloweeCap(t *testing.T) {
	limits := SuggestionLimits{HydrateMax: 20}.normalized()
	suggest := func(t *testing.T, snap Snapshot, edges []Edge) []string {
		t.Helper()
		repo := &sugRepo{fakeRepo: newFakeRepo(), follows: edges}
		f := newFriendsOfFriends(repo, limits, time.Now)
		ctx, _ := budget.WithCounter(context.Background())
		s, err := f.Suggest(ctx, sugViewer, snap)
		if err != nil {
			t.Fatalf("Suggest: %v", err)
		}
		return s.Candidates
	}

	t.Run("a flooder alone yields exactly its newest three", func(t *testing.T) {
		flood := names("fl", 30) // fills the whole 30-edge window
		got := suggest(t, mkSnap(l5Followees...), edgesOf(pairsFrom("fe-04", flood)...))
		if want := []string{"fl-00", "fl-01", "fl-02"}; !slices.Equal(sortedCopy(got), want) {
			t.Errorf("candidates = %v, want its newest three %v", got, want)
		}
	})

	t.Run("the other followees keep their share", func(t *testing.T) {
		pairs := append(pairsFrom("fe-04", names("fl", 12)), [2]string{"fe-03", "cb-00"}, [2]string{"fe-02", "cc-00"})
		got := suggest(t, mkSnap(l5Followees...), edgesOf(pairs...))
		if want := []string{"cb-00", "cc-00", "fl-00", "fl-01", "fl-02"}; !slices.Equal(sortedCopy(got), want) {
			t.Errorf("candidates = %v, want %v (three from the flooder, one each from the others)", got, want)
		}
	})

	t.Run("the cap is per followee, not global", func(t *testing.T) {
		fa, fb := names("fa", 6), names("fb", 6)
		var pairs [][2]string
		for i := 0; i < 6; i++ { // interleaved newest first: fe-04, fe-03, fe-04, fe-03, ...
			pairs = append(pairs, [2]string{"fe-04", fa[i]}, [2]string{"fe-03", fb[i]})
		}
		got := suggest(t, mkSnap(l5Followees...), edgesOf(pairs...))
		if want := []string{"fa-00", "fa-01", "fa-02", "fb-00", "fb-01", "fb-02"}; !slices.Equal(sortedCopy(got), want) {
			t.Errorf("candidates = %v, want %v", got, want)
		}
	})

	t.Run("an edge the exclusion matrix refuses takes no slot", func(t *testing.T) {
		snap := mkSnap(l5Followees...)
		snap.Blocked["ex-0"], snap.Muted["ex-1"], snap.BlockedBy["ex-2"] = true, true, true
		snap.Following["ex-3"] = true // already followed
		pairs := pairsFrom("fe-04", []string{"ex-0", "ex-1", "ex-2", "ex-3", "fl-00", "fl-01", "fl-02", "fl-03", "fl-04"})
		got := suggest(t, snap, edgesOf(pairs...))
		if want := []string{"fl-00", "fl-01", "fl-02"}; !slices.Equal(sortedCopy(got), want) {
			t.Errorf("candidates = %v, want %v (four refused edges first, then the newest three usable)", got, want)
		}
	})

	t.Run("a candidate two followees follow still counts twice", func(t *testing.T) {
		pairs := [][2]string{{"fe-04", "pop"}, {"fe-03", "pop"}, {"fe-04", "solo-a"}, {"fe-03", "solo-b"}}
		got := suggest(t, mkSnap(l5Followees...), edgesOf(pairs...))
		if len(got) != 3 || got[0] != "pop" {
			t.Errorf("candidates = %v, want pop first (two sampled followees follow it)", got)
		}
	})
}

// TestListSuggestedUsers_FlooderLog is the signal W3-23 watches: a window filled by one account ends as source=fof
// with candidates <= 3.
func TestListSuggestedUsers_FlooderLog(t *testing.T) {
	flood := names("fl", 30)
	env := newSugEnv(t, SuggestionLimits{HydrateMax: 10}, mkSnap(l5Followees...), edgesOf(pairsFrom("fe-04", flood)...), flood)
	ctx, info := obsCtx()
	items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 5)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"fl-00", "fl-01", "fl-02"}; !slices.Equal(sortedCopy(rowUIDs(items)), want) {
		t.Errorf("rows = %v, want %v", rowUIDs(items), want)
	}
	if got := field(info, fieldSuggestSource); got != SuggestionSourceFriendsOfFriends {
		t.Errorf("source = %v, want fof", got)
	}
	if got := field(info, fieldSuggestCandidates); got != int64(3) {
		t.Errorf("candidates = %v, want 3", got)
	}
}

func TestListSuggestedUsers_SkipsKnownInactiveFollowees(t *testing.T) {
	flood := names("fl", 10)
	pairs := append(pairsFrom("fe-04", flood), [2]string{"fe-03", "cb-00"}, [2]string{"fe-02", "cc-00"}, [2]string{"fe-01", "cd-00"})
	active := append(slices.Clone(flood), "cb-00", "cc-00", "cd-00")
	build := func(t *testing.T, known ...string) (*sugEnv, *inactiveDir) {
		t.Helper()
		env := newSugEnv(t, SuggestionLimits{HydrateMax: 10, CuratedUIDs: []string{"cu-0", "cu-1", "cu-2"}}, mkSnap(l5Followees...), edgesOf(pairs...), append(slices.Clone(active), "cu-0", "cu-1", "cu-2"))
		dir := &inactiveDir{sugDir: env.dir, known: map[string]bool{}}
		for _, k := range known {
			dir.known[k] = true
		}
		env.svc.SetDirectory(dir)
		return env, dir
	}

	t.Run("a suspended followee leaves the query and its share goes to the others", func(t *testing.T) {
		env, dir := build(t, "fe-04")
		got, counter := env.list(t, sugViewer, 5)
		if want := []string{"cb-00", "cc-00", "cd-00"}; !slices.Equal(sortedCopy(got), want) {
			t.Errorf("rows = %v, want %v (no candidate of the suspended followee)", got, want)
		}
		if len(env.repo.queries) != 1 || !slices.Equal(env.repo.queries[0].followers, []string{"fe-03", "fe-02", "fe-01", "fe-00"}) {
			t.Fatalf("queries = %+v, want one over the four active followees, newest first", env.repo.queries)
		}
		if len(dir.probes) != 1 || !slices.Equal(dir.probes[0], []string{"fe-04", "fe-03", "fe-02", "fe-01", "fe-00"}) {
			t.Errorf("probes = %v, want one probe of the sample", dir.probes)
		}
		// snapshot 1 + the 3 edges the query returns + 3 profiles hydrated: the probe itself is free.
		budgettest.Assert(t, "inactive followee skipped", counter, budgettest.Budget{Reads: 7})
	})

	t.Run("every sampled followee inactive means no edge query", func(t *testing.T) {
		env, _ := build(t, l5Followees...)
		ctx, info := obsCtx()
		ctx, counter := budget.WithCounter(ctx)
		items, err := env.svc.ListSuggestedUsers(ctx, sugViewer, 5)
		if err != nil {
			t.Fatal(err)
		}
		if len(env.repo.queries) != 0 {
			t.Errorf("edge queries = %d, want 0", len(env.repo.queries))
		}
		if want := []string{"cu-0", "cu-1", "cu-2"}; !slices.Equal(rowUIDs(items), want) {
			t.Errorf("rows = %v, want the curated fallback %v", rowUIDs(items), want)
		}
		if got := field(info, fieldSuggestSource); got != SuggestionSourceCurated {
			t.Errorf("source = %v, want curated", got)
		}
		budgettest.Assert(t, "all followees inactive", counter, budgettest.Budget{Reads: 4}) // snapshot 1 + 3 curated profiles
	})

	t.Run("nothing known changes nothing", func(t *testing.T) {
		env, _ := build(t)
		env.list(t, sugViewer, 5)
		if len(env.repo.queries) != 1 || len(env.repo.queries[0].followers) != 5 {
			t.Errorf("queries = %+v, want one over all five followees", env.repo.queries)
		}
	})

	t.Run("a Directory without the extension skips nothing", func(t *testing.T) {
		env := newSugEnv(t, SuggestionLimits{HydrateMax: 10}, mkSnap(l5Followees...), edgesOf(pairs...), active)
		got, _ := env.list(t, sugViewer, 5)
		if len(env.repo.queries) != 1 || len(env.repo.queries[0].followers) != 5 {
			t.Errorf("queries = %+v, want one over all five followees", env.repo.queries)
		}
		if len(got) != 5 {
			t.Errorf("rows = %v, want 5", got)
		}
	})

	t.Run("no Directory at all skips nothing", func(t *testing.T) {
		s := &service{}
		if got := s.knownInactive([]string{"fe-04"}); got != nil {
			t.Errorf("knownInactive without a directory = %v, want nil", got)
		}
	})

	t.Run("the snapshot's own slice is never edited", func(t *testing.T) {
		env, _ := build(t, "fe-04")
		before := slices.Clone(env.repo.snapshots[sugViewer].RecentFollowing)
		env.list(t, sugViewer, 5)
		if after := env.repo.snapshots[sugViewer].RecentFollowing; !slices.Equal(after, before) {
			t.Errorf("RecentFollowing changed: %v -> %v", before, after)
		}
	})
}
