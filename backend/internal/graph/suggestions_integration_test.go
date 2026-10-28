//go:build integration

// suggestions_integration_test.go: ListSuggestedUsers (ADR-0024 D8, ticket W3-12) against the Firestore emulator:
// the friends-of-friends `in` + order-by query, the exclusion matrix on real documents, the curated fallback, the
// cold cap (31 reads at the default EdgeLimit 20, 32 with the interceptor, which these tests do not run; 41 and 42 with
// EdgeLimit pinned to 30; ADR-0024 Amendment 2 B1(b)), the 0-read warm call and the Follow eviction. The emulator does not enforce composite indexes: the index the query needs is the existing follows
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
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

// listSuggested runs ListSuggestedUsers with a fresh counter and returns the rows and the reads it charged.
func listSuggested(t *testing.T, w wired, viewer string, maxResults int32) ([]graph.ListItem, int64) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	items, err := w.graph.ListSuggestedUsers(ctx, viewer, maxResults)
	if err != nil {
		t.Fatalf("ListSuggestedUsers: %v", err)
	}
	return items, counter.Reads()
}

// TestListEdgesByFollowers_OrderedAcrossFollowers: the `in` query returns the newest edges of ALL named followers
// globally newest first (interleaved, not grouped per follower), ties by document id descending, honours the limit,
// bills one read per document (one for an empty result) and refuses malformed input without a read.
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

	read := func(followers []string, limit int) ([]graph.Edge, int64) {
		t.Helper()
		cctx, counter := budget.WithCounter(ctx)
		edges, err := w.graph.repo.ListEdgesByFollowers(cctx, followers, limit)
		if err != nil {
			t.Fatalf("ListEdgesByFollowers: %v", err)
		}
		return edges, counter.Reads()
	}
	followeesOf := func(edges []graph.Edge) []string {
		out := make([]string, len(edges))
		for i, e := range edges {
			out[i] = e.FolloweeID
		}
		return out
	}

	edges, reads := read([]string{"f1", "f2", "f3"}, 50)
	if want := []string{"ta", "ta", "t6", "t5", "t4", "t3", "t2", "t1", "t7"}; !slices.Equal(followeesOf(edges), want) {
		t.Errorf("followees = %v, want %v (globally newest first)", followeesOf(edges), want)
	}
	if edges[0].DocID != "f2_ta" || edges[1].DocID != "f1_ta" {
		t.Errorf("tie order = %s, %s, want f2_ta then f1_ta (__name__ DESC)", edges[0].DocID, edges[1].DocID)
	}
	if reads != int64(len(edges)) {
		t.Errorf("reads = %d, want %d (one per document)", reads, len(edges))
	}

	edges, reads = read([]string{"f1", "f2", "f3"}, 3)
	if want := []string{"ta", "ta", "t6"}; !slices.Equal(followeesOf(edges), want) || reads != 3 {
		t.Errorf("limit 3: followees %v reads %d, want %v and 3", followeesOf(edges), reads, want)
	}

	if edges, reads = read([]string{"nobody"}, 30); len(edges) != 0 || reads != 1 {
		t.Errorf("empty result: %d edges, %d reads, want 0 and 1 (an empty query bills one read)", len(edges), reads)
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
		cctx, counter := budget.WithCounter(ctx)
		if _, err := w.graph.repo.ListEdgesByFollowers(cctx, tt.followers, tt.limit); err == nil {
			t.Errorf("%s: want an error", name)
		}
		budgettest.Assert(t, name, counter, budgettest.Budget{})
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

// TestListSuggestedUsers_ColdWarmReadCap is the budget assertion of ticket W3-12 at the service boundary, with EdgeLimit
// pinned to 30 (the pre-Amendment 2 default, still a supported setting up to 30): a cold call on a fresh instance (empty
// caches) reads the caller graph (1), the 30 newest edges (30) and hydrates 10 candidates (10) = 41, which is 42 with
// the interceptor's read; a warm call with the snapshot still cached reads nothing (1 when the 60 s snapshot entry has
// expired, W3-22 L-1: TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere). The config default is
// TestListSuggestedUsers_ColdReadCapAtTheDefault.
func TestListSuggestedUsers_ColdWarmReadCap(t *testing.T) {
	w := newWired(t)
	viewer, followees, candidates := seedSuggestionWorld(t, w)

	fresh := newInstance(w.client, withSuggestions(graph.SuggestionLimits{SampleFollowees: 30, EdgeLimit: 30, HydrateMax: 10, MaxResults: 5, CacheTTL: time.Hour}))
	cold, coldReads := listSuggested(t, fresh, viewer, 0)
	t.Logf("BUDGET ListSuggestedUsers cold reads=%d (+1 interceptor = %d, documented hard cap 42)", coldReads, coldReads+1)
	if coldReads != 41 {
		t.Errorf("cold reads = %d, want exactly 41 for this world (1 graph + 30 edges + 10 profiles); fewer means the cap was not reached", coldReads)
	}
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

	warm, warmReads := listSuggested(t, fresh, viewer, 0)
	t.Logf("BUDGET ListSuggestedUsers warm reads=%d (+1 interceptor = %d, documented 1, or 2 without a cached snapshot)", warmReads, warmReads+1)
	if warmReads != 0 {
		t.Errorf("warm reads = %d, want 0", warmReads)
	}
	if !slices.Equal(rowUIDs(warm), rowUIDs(cold)) {
		t.Errorf("warm rows %v differ from cold rows %v", rowUIDs(warm), rowUIDs(cold))
	}
	if three, _ := listSuggested(t, fresh, viewer, 3); len(three) != 3 || !slices.Equal(rowUIDs(three), rowUIDs(cold)[:3]) {
		t.Errorf("max_results 3 = %v, want the first three of %v", rowUIDs(three), rowUIDs(cold))
	}

	// A second instance has its own caches: it pays the cold cost again, and the order (a hash of viewer, candidate and
	// the IST day) is the same.
	// It is pinned to the same EdgeLimit 30 as the first: at the default 20 the window, and so the candidate set, differs.
	other := newInstance(w.client, withSuggestions(graph.SuggestionLimits{EdgeLimit: 30}))
	again, againReads := listSuggested(t, other, viewer, 0)
	if againReads > 41 || !slices.Equal(rowUIDs(again), rowUIDs(cold)) {
		t.Errorf("second instance: reads %d rows %v, want <= 41 and %v", againReads, rowUIDs(again), rowUIDs(cold))
	}
}

// TestListSuggestedUsers_ColdReadCapAtTheDefault is the same world at the config default (ADR-0024 Amendment 2 B1(b):
// EdgeLimit 20, zero SuggestionLimits normalize to it): the query reads the 20 newest edges, which still hold all 12
// candidates, so the cold call is exactly the graph (1) + 20 + 10 hydrated = 31, the documented 32 with the interceptor.
func TestListSuggestedUsers_ColdReadCapAtTheDefault(t *testing.T) {
	w := newWired(t)
	viewer, _, candidates := seedSuggestionWorld(t, w)

	fresh := newInstance(w.client, withSuggestions(graph.SuggestionLimits{}))
	cold, coldReads := listSuggested(t, fresh, viewer, 0)
	t.Logf("BUDGET ListSuggestedUsers cold reads=%d at the default EdgeLimit 20 (+1 interceptor = %d, documented hard cap 32)", coldReads, coldReads+1)
	if coldReads != 31 {
		t.Errorf("cold reads = %d, want exactly 31 for this world (1 graph + 20 edges + 10 profiles); fewer means the cap was not reached", coldReads)
	}
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
	items, reads := listSuggested(t, inst, viewer, 5)
	got := rowUIDs(items)
	slices.Sort(got)
	if want := slices.Clone(ok); !slices.Equal(got, want) {
		t.Errorf("rows = %v, want exactly %v", got, want)
	}
	if reads > 31 { // default limits: 1 graph + at most 20 edges + at most 10 profiles
		t.Errorf("reads = %d, want <= 31", reads)
	}
}

// TestListSuggestedUsers_CuratedFallback: a viewer who follows fewer than 3 accounts gets the curated list, minus
// anyone blocked, blocking, suspended or without a profile, with no edge query (graph 1 + hydration <= 10 reads).
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
	items, reads := listSuggested(t, inst, viewer, 5)
	t.Logf("BUDGET ListSuggestedUsers curated cold reads=%d (+1 interceptor = %d, documented hard cap 12)", reads, reads+1)
	if want := []string{cu[0], cu[3], cu[6]}; !slices.Equal(rowUIDs(items), want) {
		t.Errorf("rows = %v, want %v", rowUIDs(items), want)
	}
	if reads > 11 {
		t.Errorf("reads = %d, want <= 11 (1 graph + <= 10 profiles)", reads)
	}

	// An empty graph and no curated list is an empty answer, not an error.
	bare := newInstance(w.client, withSuggestions(graph.SuggestionLimits{}))
	mustCreateProfile(t, bare.identity, "uid-lonely", "lonely_one")
	if items, reads := listSuggested(t, bare, "uid-lonely", 5); len(items) != 0 || reads > 1 {
		t.Errorf("empty world: rows %v reads %d, want none and <= 1", rowUIDs(items), reads)
	}
}

// TestListSuggestedUsers_FollowEvictsFromCache: this instance's own Follow removes the followed user from the cached
// answer, and the next call is still a cache hit that refills from the cached tail: no edge query, no hydration. It costs
// the ONE read that reloads the viewer's snapshot (Follow invalidated it; W3-22 L-1), and the call after that costs 0.
func TestListSuggestedUsers_FollowEvictsFromCache(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	cu := mustCreateUsers(t, w.identity, "cu", 7)
	inst := newInstance(w.client, withSuggestions(graph.SuggestionLimits{CuratedUIDs: cu}))

	first, _ := listSuggested(t, inst, viewer, 5)
	if want := cu[:5]; !slices.Equal(rowUIDs(first), want) {
		t.Fatalf("first = %v, want %v", rowUIDs(first), want)
	}
	if _, err := inst.graph.Follow(context.Background(), viewer, key1, cu[0]); err != nil {
		t.Fatalf("Follow: %v", err)
	}
	after, reads := listSuggested(t, inst, viewer, 5)
	if want := cu[1:6]; !slices.Equal(rowUIDs(after), want) || reads != 1 {
		t.Errorf("after Follow: rows %v reads %d, want %v and 1 (the snapshot reload)", rowUIDs(after), reads, want)
	}
	if _, reads = listSuggested(t, inst, viewer, 5); reads != 0 {
		t.Errorf("second call after Follow: reads %d, want 0", reads)
	}
}

// TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere (W3-22 L-1) on real documents: instance A builds the
// viewer's answer, instance B then records a Block of the viewer by one of the suggested users (it writes
// graph/{viewer}.blockedBy), and A's 60 s snapshot entry for the viewer is gone. A's next call is a warm hit on the
// 1 h answer, yet it must not show the blocker: it reloads the snapshot (exactly 1 read, nothing else), and the call
// after that is free again.
func TestListSuggestedUsers_WarmHitDropsABlockerAddedElsewhere(t *testing.T) {
	w := newWired(t)
	const viewer = "uid-v"
	mustCreateProfile(t, w.identity, viewer, "viewer_v")
	cu := mustCreateUsers(t, w.identity, "cu", 8)
	lim := graph.SuggestionLimits{CuratedUIDs: cu, HydrateMax: 8}

	snapCache := graph.NewCache(time.Minute)
	instA := newInstance(w.client, withSuggestions(lim), func(d *graph.Deps) { d.Cache = snapCache })
	instB := newInstance(w.client, withSuggestions(lim))

	first, _ := listSuggested(t, instA, viewer, 5)
	if want := cu[:5]; !slices.Equal(rowUIDs(first), want) {
		t.Fatalf("first = %v, want %v", rowUIDs(first), want)
	}
	if _, err := instB.graph.Block(context.Background(), cu[1], key1, viewer); err != nil {
		t.Fatalf("Block on instance B: %v", err)
	}
	snapCache.Invalidate(viewer) // the 60 s entry expiring on instance A

	after, reads := listSuggested(t, instA, viewer, 5)
	if want := []string{cu[0], cu[2], cu[3], cu[4], cu[5]}; !slices.Equal(rowUIDs(after), want) {
		t.Errorf("after the block: rows %v, want %v (the blocker hidden, the tail refilled)", rowUIDs(after), want)
	}
	if reads != 1 {
		t.Errorf("warm hit without a cached snapshot: reads %d, want exactly 1", reads)
	}
	t.Logf("BUDGET ListSuggestedUsers warm without a cached snapshot reads=%d (+1 interceptor = %d)", reads, reads+1)
	if _, reads = listSuggested(t, instA, viewer, 5); reads != 0 {
		t.Errorf("next warm hit: reads %d, want 0 (the snapshot is cached for 60 s again)", reads)
	}
}

// TestListSuggestedUsers_FloodingSuspendedFolloweeIsSkipped (W3-22 L-5) on the real wiring: identity's service really
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

	items, reads := listSuggested(t, inst, viewer, 5)
	got := rowUIDs(items)
	slices.Sort(got)
	if want := slices.Clone(ok); !slices.Equal(got, want) {
		t.Errorf("rows = %v, want exactly %v (the suspended flooder steers nothing)", got, want)
	}
	// graph 1 + 3 edges (the flooder is not in the query) + 3 profiles.
	if reads != 7 {
		t.Errorf("reads = %d, want 7", reads)
	}
}
