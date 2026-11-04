//go:build integration

// suggestions_integration_test.go: ListSuggestedUsers against the Firestore emulator:
// the friends-of-friends `in` + order-by query, the exclusion matrix on real documents, the curated fallback, the
// cold call at the default and a pinned EdgeLimit, the warm call and the Follow eviction (the edge and hydration
// caps themselves are checked against the recorded query and hydration calls in suggester_test.go). The emulator does not enforce composite indexes: the index the query needs is the existing follows
// (followerId ASC, createdAt DESC), reasoned from firebase/firestore.indexes.json in the repo_suggestions.go comment.
package graph_test

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func withSuggestions(l graph.SuggestionLimits) wiredOption {
	return func(d *graph.Deps) { d.Suggestions = l }
}

func rowUIDs(items []graph.ListItem) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.User.UserID
	}
	return out
}

// listSuggested runs ListSuggestedUsers and returns the rows.
func listSuggested(t *testing.T, w wired, viewer string, maxResults int32) []graph.ListItem {
	t.Helper()
	items, err := w.graph.ListSuggestedUsers(context.Background(), viewer, maxResults)
	if err != nil {
		t.Fatalf("ListSuggestedUsers: %v", err)
	}
	return items
}

// TestListEdgesByFollowers_OrderedAcrossFollowers: the `in` query returns the newest edges of ALL named followers
// globally newest first (interleaved, not grouped per follower), ties by document id descending, honours the limit,
// and refuses malformed input.
func TestListEdgesByFollowers_OrderedAcrossFollowers(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("edge-only seeding")
	ctx := context.Background()
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	at := func(min int) time.Time { return base.Add(time.Duration(min) * time.Minute) }

	// Interleaved across f1, f2, f3; fx is not in the follower list; two edges share a createdAt.
	seedEdge(t, w, "f1", "t1", at(1))
	seedEdge(t, w, "f2", "t2", at(2))
	seedEdge(t, w, "f3", "t3", at(3))
	seedEdge(t, w, "f1", "t4", at(4))
	seedEdge(t, w, "f2", "t5", at(5))
	seedEdge(t, w, "f3", "t6", at(6))
	seedEdge(t, w, "fx", "tx", at(7))
	seedEdge(t, w, "f1", "t7", at(0))
	seedEdge(t, w, "f1", "ta", at(8))
	seedEdge(t, w, "f2", "ta", at(8)) // same createdAt as f1_ta: __name__ DESC puts f2_ta first

	read := func(followers []string, limit int) []graph.Edge {
		t.Helper()
		edges, err := w.graph.repo.ListEdgesByFollowers(ctx, followers, limit)
		if err != nil {
			t.Fatalf("ListEdgesByFollowers: %v", err)
		}
		return edges
	}
	followeesOf := func(edges []graph.Edge) []string {
		out := make([]string, len(edges))
		for i, e := range edges {
			out[i] = e.FolloweeID
		}
		return out
	}

	edges := read([]string{"f1", "f2", "f3"}, 50)
	if want := []string{"ta", "ta", "t6", "t5", "t4", "t3", "t2", "t1", "t7"}; !slices.Equal(followeesOf(edges), want) {
		t.Errorf("followees = %v, want %v (globally newest first)", followeesOf(edges), want)
	}
	if edges[0].DocID != "f2_ta" || edges[1].DocID != "f1_ta" {
		t.Errorf("tie order = %s, %s, want f2_ta then f1_ta (__name__ DESC)", edges[0].DocID, edges[1].DocID)
	}

	edges = read([]string{"f1", "f2", "f3"}, 3)
	if want := []string{"ta", "ta", "t6"}; !slices.Equal(followeesOf(edges), want) {
		t.Errorf("limit 3: followees %v, want %v", followeesOf(edges), want)
	}

	if edges = read([]string{"nobody"}, 30); len(edges) != 0 {
		t.Errorf("empty result: %d edges, want 0", len(edges))
	}

	tooMany := make([]string, 31)
	for i := range tooMany {
		tooMany[i] = fmt.Sprintf("f%d", i)
	}
	for name, tt := range map[string]struct {
		followers []string
		limit     int
	}{
		"31 followers":     {tooMany, 10},
		"no followers":     {nil, 10},
		"limit 0":          {[]string{"f1"}, 0},
		"limit 51":         {[]string{"f1"}, 51},
		"invalid follower": {[]string{"f1", "bad id!"}, 10},
	} {
		if _, err := w.graph.repo.ListEdgesByFollowers(ctx, tt.followers, tt.limit); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

// seedSuggestionWorld creates viewer "v", followees fe-0..fe-29 (the viewer follows them in that order, so fe-29 is the
// newest) and candidates ca-0..ca-11. Followee i follows candidates i%12 and (i+5)%12 at a time that grows with i, so
// the newest 30 edges come from followees 15..29 and cover all 12 candidates; the newest 20 (the default EdgeLimit) come
// from followees 20..29 and still cover all 12.
func seedSuggestionWorld(t *testing.T, w wired) (viewer string, followees, candidates []string) {
	t.Helper()
	viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	followees = mustCreateUsers(t, w.identity, "fe", 30)
	candidates = mustCreateUsers(t, w.identity, "ca", 12)
	base := time.Now().Add(-48 * time.Hour).UTC()
	for i, fe := range followees {
		seedFollow(t, w, viewer, fe, base.Add(time.Duration(i)*time.Second))
	}
	for i, fe := range followees {
		at := base.Add(time.Hour + time.Duration(i)*time.Minute)
		seedFollow(t, w, fe, candidates[i%12], at)
		seedFollow(t, w, fe, candidates[(i+5)%12], at.Add(time.Second))
	}
	return viewer, followees, candidates
}

// TestListSuggestedUsers_ColdWarmAndSecondInstance runs the service boundary with EdgeLimit pinned to 30 (a supported
// setting up to 30): a cold call on a fresh instance (empty caches) returns five hydrated candidates, and the warm call
// returns the same rows. The stale snapshot case is TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere; the
// config default is TestListSuggestedUsers_ColdAtTheDefault.
func TestListSuggestedUsers_ColdWarmAndSecondInstance(t *testing.T) {
	w := newWired(t)
	viewer, followees, candidates := seedSuggestionWorld(t, w)

	fresh := newInstance(w.client, withSuggestions(graph.SuggestionLimits{SampleFollowees: 30, EdgeLimit: 30, HydrateMax: 10, MaxResults: 5, CacheTTL: time.Hour}))
	cold := listSuggested(t, fresh, viewer, 0)
	if len(cold) != 5 {
		t.Fatalf("rows = %v, want 5", rowUIDs(cold))
	}
	for _, it := range cold {
		uid := it.User.UserID
		if !slices.Contains(candidates, uid) {
			t.Errorf("row %s is not a candidate (viewer %s, followees %v)", uid, viewer, followees)
		}
		if it.Relationship.FollowState != graph.FollowStateNone || it.Relationship.Blocking || it.Relationship.Muting || !it.Since.IsZero() {
			t.Errorf("row %s: relationship %+v since %v, want NONE and no since", uid, it.Relationship, it.Since)
		}
		if it.User.Handle == "" {
			t.Errorf("row %s was not hydrated", uid)
		}
	}

	warm := listSuggested(t, fresh, viewer, 0)
	if !slices.Equal(rowUIDs(warm), rowUIDs(cold)) {
		t.Errorf("warm rows %v differ from cold rows %v", rowUIDs(warm), rowUIDs(cold))
	}
	if three := listSuggested(t, fresh, viewer, 3); len(three) != 3 || !slices.Equal(rowUIDs(three), rowUIDs(cold)[:3]) {
		t.Errorf("max_results 3 = %v, want the first three of %v", rowUIDs(three), rowUIDs(cold))
	}

	// A second instance has its own caches: it builds the answer again, and the order (a hash of viewer, candidate and
	// the IST day) is the same.
	// It is pinned to the same EdgeLimit 30 as the first: at the default 20 the window, and so the candidate set, differs.
	other := newInstance(w.client, withSuggestions(graph.SuggestionLimits{EdgeLimit: 30}))
	again := listSuggested(t, other, viewer, 0)
	if !slices.Equal(rowUIDs(again), rowUIDs(cold)) {
		t.Errorf("second instance: rows %v, want %v", rowUIDs(again), rowUIDs(cold))
	}
}

// TestListSuggestedUsers_ColdAtTheDefault is the same world at the config default
// (EdgeLimit 20, zero SuggestionLimits normalize to it): the 20 newest edges still hold all 12 candidates, so the
// cold call returns five of them.
func TestListSuggestedUsers_ColdAtTheDefault(t *testing.T) {
	w := newWired(t)
	viewer, _, candidates := seedSuggestionWorld(t, w)

	fresh := newInstance(w.client, withSuggestions(graph.SuggestionLimits{}))
	cold := listSuggested(t, fresh, viewer, 0)
	if len(cold) != 5 {
		t.Fatalf("rows = %v, want 5", rowUIDs(cold))
	}
	for _, it := range cold {
		if !slices.Contains(candidates, it.User.UserID) {
			t.Errorf("row %s is not a candidate", it.User.UserID)
		}
	}
}

// TestListSuggestedUsers_ExclusionMatrixOnRealDocuments: self, a followee, blocked, blocking, muted, suspended and a
// uid with no profile are dropped; only the three eligible friends of friends come back, from the friends-of-friends
// source (so the curated list, which holds a decoy, is not used).
func TestListSuggestedUsers_ExclusionMatrixOnRealDocuments(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("a friend-of-friend edge to a uid with no profile")
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	fe := mustCreateUsers(t, w.identity, "fe", 4) // fe-0..fe-2 followed by the viewer; fe-3 is "already followed" via fe-0's edge below
	ok := mustCreateUsers(t, w.identity, "ok", 3)
	bad := mustCreateUsers(t, w.identity, "bad", 4) // 0 blocked by the viewer, 1 blocks the viewer, 2 muted, 3 suspended
	decoy := mustCreateUsers(t, w.identity, "decoy", 1)

	now := time.Now().Add(-24 * time.Hour).UTC()
	for i, f := range fe {
		seedFollow(t, w, viewer, f, now.Add(time.Duration(i)*time.Second))
	}
	seedBlock(t, w.client, viewer, bad[0])
	seedBlock(t, w.client, bad[1], viewer)
	if _, err := w.client.Collection("graph").Doc(viewer).Update(context.Background(), []firestore.Update{{Path: "muted", Value: firestore.ArrayUnion(bad[2])}}); err != nil {
		t.Fatalf("seed muted: %v", err)
	}
	seedUserField(t, w, bad[3], "status", "SUSPENDED")

	at := now.Add(time.Hour)
	seedEdge(t, w, fe[0], ok[0], at)
	seedEdge(t, w, fe[1], ok[1], at.Add(time.Second))
	seedEdge(t, w, fe[2], ok[2], at.Add(2*time.Second))
	for i, target := range []string{viewer, fe[3], bad[0], bad[1], bad[2], bad[3], "ghost-user"} {
		seedEdge(t, w, fe[i%3], target, at.Add(time.Duration(10+i)*time.Second))
	}

	inst := newInstance(w.client, withSuggestions(graph.SuggestionLimits{CuratedUIDs: []string{decoy[0]}}))
	items := listSuggested(t, inst, viewer, 5)
	got := rowUIDs(items)
	slices.Sort(got)
	if want := slices.Clone(ok); !slices.Equal(got, want) {
		t.Errorf("rows = %v, want exactly %v", got, want)
	}
}

// TestListSuggestedUsers_CuratedFallback: a viewer who follows fewer than 3 accounts gets the curated list, minus
// anyone blocked, blocking, suspended or without a profile, without a friends-of-friends edge query.
func TestListSuggestedUsers_CuratedFallback(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	cu := mustCreateUsers(t, w.identity, "cu", 7) // 0 ok, 1 blocked by the viewer, 2 suspended, 3 ok, 4 blocks the viewer, 5 followed, 6 ok
	seedBlock(t, w.client, viewer, cu[1])
	seedUserField(t, w, cu[2], "status", "SUSPENDED")
	seedBlock(t, w.client, cu[4], viewer)
	seedFollow(t, w, viewer, cu[5], time.Now().Add(-time.Hour).UTC())

	list := []string{cu[0], cu[1], cu[2], "uid-never-created", cu[3], cu[4], cu[5], cu[6]}
	inst := newInstance(w.client, withSuggestions(graph.SuggestionLimits{CuratedUIDs: list}))
	items := listSuggested(t, inst, viewer, 5)
	if want := []string{cu[0], cu[3], cu[6]}; !slices.Equal(rowUIDs(items), want) {
		t.Errorf("rows = %v, want %v", rowUIDs(items), want)
	}

	// An empty graph and no curated list is an empty answer, not an error.
	bare := newInstance(w.client, withSuggestions(graph.SuggestionLimits{}))
	mustCreateProfile(t, bare.identity, "uid-lonely", "lonely_one")
	if items := listSuggested(t, bare, "uid-lonely", 5); len(items) != 0 {
		t.Errorf("empty world: rows %v, want none", rowUIDs(items))
	}
}

// TestListSuggestedUsers_FollowEvictsFromCache: this instance's own Follow removes the followed user from the cached
// answer, and the next call is still a cache hit that refills from the cached tail. The unit test
// TestListSuggestedUsers_CacheEviction records that no edge query or hydration runs.
func TestListSuggestedUsers_FollowEvictsFromCache(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	cu := mustCreateUsers(t, w.identity, "cu", 7)
	inst := newInstance(w.client, withSuggestions(graph.SuggestionLimits{CuratedUIDs: cu}))

	first := listSuggested(t, inst, viewer, 5)
	if want := cu[:5]; !slices.Equal(rowUIDs(first), want) {
		t.Fatalf("first = %v, want %v", rowUIDs(first), want)
	}
	if _, err := inst.graph.Follow(context.Background(), viewer, key1, cu[0]); err != nil {
		t.Fatalf("Follow: %v", err)
	}
	after := listSuggested(t, inst, viewer, 5)
	if want := cu[1:6]; !slices.Equal(rowUIDs(after), want) {
		t.Errorf("after Follow: rows %v, want %v", rowUIDs(after), want)
	}
	if again := listSuggested(t, inst, viewer, 5); !slices.Equal(rowUIDs(again), rowUIDs(after)) {
		t.Errorf("second call after Follow: rows %v, want %v", rowUIDs(again), rowUIDs(after))
	}
}

// TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere (L-1) on real documents: instance A builds the
// viewer's answer, instance B then records a Block of the viewer by one of the suggested users (it writes
// graph/{viewer}.blockedBy), and A's 60 s snapshot entry for the viewer is gone. A's next call is a warm hit on the
// 1 h answer, yet it must not show the blocker: it reloads the snapshot, and the call after that gives the same rows.
func TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	cu := mustCreateUsers(t, w.identity, "cu", 8)
	lim := graph.SuggestionLimits{CuratedUIDs: cu, HydrateMax: 8}

	snapCache := graph.NewCache(time.Minute)
	instA := newInstance(w.client, withSuggestions(lim), func(d *graph.Deps) { d.Cache = snapCache })
	instB := newInstance(w.client, withSuggestions(lim))

	first := listSuggested(t, instA, viewer, 5)
	if want := cu[:5]; !slices.Equal(rowUIDs(first), want) {
		t.Fatalf("first = %v, want %v", rowUIDs(first), want)
	}
	if _, err := instB.graph.Block(context.Background(), cu[1], key1, viewer); err != nil {
		t.Fatalf("Block on instance B: %v", err)
	}
	snapCache.Invalidate(viewer) // the 60 s entry expiring on instance A

	after := listSuggested(t, instA, viewer, 5)
	if want := []string{cu[0], cu[2], cu[3], cu[4], cu[5]}; !slices.Equal(rowUIDs(after), want) {
		t.Errorf("after the block: rows %v, want %v (the blocker hidden, the tail refilled)", rowUIDs(after), want)
	}
	if next := listSuggested(t, instA, viewer, 5); !slices.Equal(rowUIDs(next), rowUIDs(after)) {
		t.Errorf("next warm hit: rows %v, want %v", rowUIDs(next), rowUIDs(after))
	}
}

// TestListSuggestedUsers_FloodingSuspendedFolloweeIsSkipped (L-5) on the real wiring: identity's service really
// implements the optional KnownInactive extension graph asserts on its Directory (the assertion is checked here, so a
// rename on either side fails loudly instead of silently disabling the skip), and a suspended followee whose profile
// this instance's cache has seen no longer steers: none of its flood of newest edges reaches the answer.
func TestListSuggestedUsers_FloodingSuspendedFolloweeIsSkipped(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	fe := mustCreateUsers(t, w.identity, "fe", 4) // fe-3 is the newest followee and the flooder
	ok := mustCreateUsers(t, w.identity, "ok", 3)
	flood := mustCreateUsers(t, w.identity, "fl", 8)

	base := time.Now().Add(-48 * time.Hour).UTC()
	for i, f := range fe {
		seedFollow(t, w, viewer, f, base.Add(time.Duration(i)*time.Second))
	}
	at := base.Add(time.Hour)
	for i := 0; i < 3; i++ {
		seedFollow(t, w, fe[i], ok[i], at.Add(time.Duration(i)*time.Second))
	}
	for i, c := range flood { // the flooder's edges are the newest of all
		seedFollow(t, w, fe[3], c, at.Add(time.Minute+time.Duration(i)*time.Second))
	}
	seedUserField(t, w, fe[3], "status", "SUSPENDED")

	inst := newInstance(w.client, withSuggestions(graph.SuggestionLimits{HydrateMax: 10}))
	dir := inst.identity.(identity.Directory)
	if _, ok := dir.(interface {
		KnownInactive([]string) map[string]bool
	}); !ok {
		t.Fatal("identity's service no longer implements KnownInactive: the friends-of-friends skip of suspended followees is silently off")
	}
	// Whoever hydrates the suspended account's profile on this instance (a list, the interceptor) teaches the cache.
	if got, err := dir.GetProfiles(context.Background(), []string{fe[3]}); err != nil || len(got) != 0 {
		t.Fatalf("GetProfiles(suspended) = %v, %v, want none and no error", got, err)
	}

	items := listSuggested(t, inst, viewer, 5)
	got := rowUIDs(items)
	slices.Sort(got)
	if want := slices.Clone(ok); !slices.Equal(got, want) {
		t.Errorf("rows = %v, want exactly %v (the suspended flooder steers nothing)", got, want)
	}
}
