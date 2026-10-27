//go:build integration

package apiserver

// W3-20: GraphService.ListSuggestedUsers (ADR-0024 D8) over the real Build chain on the emulators, with the graph built by
// real Follow / Block / Mute calls (the W3-12 chain test seeds edges directly). Covered here: the exclusion matrix (self,
// already followed, blocked, blocks the caller, muted, SUSPENDED, DELETING, a user that does not exist), blockedBy
// overflow suggesting nothing, the curated fallback (also with blocked, blocking, followed, muted, DELETING, ghost and
// the viewer's own uid on the list), friends of friends first and the curated rows after them, the exact 42-read hard cap
// with 30 followees (also on a dense graph), the W3-22 L-5 per-followee cap of 3 and the known-inactive followee skip, and
// the W3-22 L-1 re-filter: a user who blocks the viewer on ANOTHER instance leaves the viewer's warm rows once the
// snapshot expires (2 reads), and a warm hit inside the snapshot's TTL is free.
//
// The candidate window of the friends-of-friends query is the newest 30 follow edges of the sampled followees and each
// followee contributes at most its newest 3 usable edges (maxCandidatesPerFollowee), so the fixtures keep the number of
// edges per followee at 3 or fewer unless the test is about that cap; assertions are on membership and exclusions, never
// on which of several equally ranked candidates comes first.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func w320SugChain(c *config.Config) {
	c.FeatureFollowSuggestions = flags.Spec{Name: "follow_suggestions", Mode: flags.On}
}

func (e *bmChain) w320Suggest(u bmUser, max int32) (*graphv1.ListSuggestedUsersResponse, error) {
	r, err := e.graph.ListSuggestedUsers(context.Background(), authed(u.token, &graphv1.ListSuggestedUsersRequest{MaxResults: max}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func w320SugUIDs(r *graphv1.ListSuggestedUsersResponse) []string {
	out := make([]string, 0, len(r.GetUsers()))
	for _, it := range r.GetUsers() {
		out = append(out, it.GetUser().GetUserId())
	}
	return out
}

// w320Users mints n users with profiles on w.
func (e *bmChain) w320Users(t *testing.T, n int) []bmUser {
	t.Helper()
	out := make([]bmUser, n)
	for i := range out {
		out[i] = e.user(t)
	}
	return out
}

// w320SetStatus writes users/{uid}.status directly (SUSPENDED / DELETING).
func (e *bmChain) w320SetStatus(t *testing.T, uid, status string) {
	t.Helper()
	if _, err := e.fs.Doc("users/"+uid).Update(context.Background(), []firestore.Update{{Path: "status", Value: status}}); err != nil {
		t.Fatal(err)
	}
}

// TestW320_SuggestionsExclusionMatrix: see the file comment. F1..F4 are followed by the viewer; each of ok1..ok4 is followed
// by two of them, and F1 alone follows every excluded kind of candidate (and the viewer). Only ok1..ok4 may come back.
func TestW320_SuggestionsExclusionMatrix(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w320SugChain)
	v := w.user(t)
	f := w.w320Users(t, 4)
	ok := w.w320Users(t, 4)
	af, bv, bk, mu, su, dl := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)
	ghost := "w320ghost" + fmt.Sprint(time.Now().UnixNano())

	for _, fe := range f {
		w.w320Follow(t, v, fe.uid)
	}
	w.w320Follow(t, v, af.uid) // already followed: a candidate through F1, but dropped
	for i, fe := range f {
		w.w320Follow(t, fe, ok[i].uid)
		w.w320Follow(t, fe, ok[(i+1)%4].uid)
	}
	for _, c := range []bmUser{af, bv, bk, mu, su, dl, v} { // F1 follows every excluded kind and the viewer
		w.w320Follow(t, f[0], c.uid)
	}
	seedFollowEdge(t, w.fs, f[0].uid, ghost, time.Now()) // a followee of F1 with no user document at all
	w.w320Block(t, v, bv.uid)                            // the viewer blocks bv (after F1 followed it)
	w.w320Block(t, bk, v.uid)                            // bk blocks the viewer
	if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m"), UserId: mu.uid})); err != nil {
		t.Fatal(err)
	}
	w.w320SetStatus(t, su.uid, "SUSPENDED")
	w.w320SetStatus(t, dl.uid, "DELETING")

	r := newW320Chain(t, w320SugChain) // a cold instance: nothing cached from the seeding
	got, err := r.w320Suggest(v, 0)
	if err != nil {
		t.Fatalf("ListSuggestedUsers: %v", err)
	}
	uids := w320SugUIDs(got)
	want := []string{ok[0].uid, ok[1].uid, ok[2].uid, ok[3].uid}
	if !slices.Equal(w320Sorted(uids), w320Sorted(want)) {
		t.Errorf("rows = %v, want exactly ok1..ok4 %v", uids, want)
	}
	for name, ex := range map[string]string{"the viewer": v.uid, "an already followed account": af.uid, "an account the viewer blocks": bv.uid,
		"an account that blocks the viewer": bk.uid, "an account the viewer mutes": mu.uid, "a SUSPENDED account": su.uid, "a DELETING account": dl.uid, "a ghost": ghost} {
		if slices.Contains(uids, ex) {
			t.Errorf("%s was suggested", name)
		}
	}
	for _, it := range got.GetUsers() {
		if rel := it.GetRelationship(); rel.GetFollowState() != graphv1.FollowState_FOLLOW_STATE_NONE || rel.GetBlocking() || rel.GetMuting() {
			t.Errorf("row %s: relationship = %v, want NONE", it.GetUser().GetUserId(), rel)
		}
		if it.GetSince() != nil {
			t.Errorf("row %s: since is set", it.GetUser().GetUserId())
		}
	}
	c := r.lineBudget(t, w320RPCListSuggested)
	r.w320Measure(t, w320RPCListSuggested, "friends of friends, 16 edges, 7 hydrated, cold", budgettest.Budget{Reads: 42})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}
	l := r.line(t, w320RPCListSuggested)
	// 4 ok + SUSPENDED + DELETING + ghost go to hydration (the snapshot cannot tell them from an active user).
	if l["source"] != "fof" || num(l, "candidates") != 7 || l["suggestions_cache_hit"] != false {
		t.Errorf("request line: source=%v candidates=%v suggestions_cache_hit=%v, want fof, 7, false", l["source"], l["candidates"], l["suggestions_cache_hit"])
	}
	// max_results is a clamp on the same cached list (1..5), at no cost.
	for _, n := range []int32{1, 3, 5, 99} {
		got, err := r.w320Suggest(v, n)
		if err != nil || len(got.GetUsers()) != int(min(n, 4)) {
			t.Errorf("max_results=%d: %d rows, %v", n, len(got.GetUsers()), err)
		}
	}
	r.w320Measure(t, w320RPCListSuggested, "warm (cached rows)", budgettest.Budget{})
}

// TestW320_SuggestionsOverflowSuggestsNothing: a viewer whose blockedBy overflowed cannot rule out a candidate who blocked
// them at 0 reads, so nothing is suggested (source none) and nothing past the caller graph is read.
func TestW320_SuggestionsOverflowSuggestsNothing(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w320SugChain)
	v := w.user(t)
	f, cand := w.w320Users(t, 3), w.w320Users(t, 3)
	for i, fe := range f {
		w.w320Follow(t, v, fe.uid)
		w.w320Follow(t, fe, cand[i].uid)
	}
	if _, err := w.fs.Doc("graph/"+v.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	r := newW320Chain(t, w320SugChain)
	got, err := r.w320Suggest(v, 0)
	if err != nil || len(got.GetUsers()) != 0 {
		t.Fatalf("overflowed viewer: %v, %v; want no suggestion", w320SugUIDs(got), err)
	}
	if l := r.line(t, w320RPCListSuggested); l["source"] != "none" {
		t.Errorf("source = %v, want none", l["source"])
	}
	r.w320Measure(t, w320RPCListSuggested, "blockedBy overflow: nothing suggested", budgettest.Budget{Reads: 2}) // interceptor + caller graph
}

// TestW320_SuggestionsCuratedFallback: SUGGESTED_USER_IDS is used below 3 followees, and fills after the friends-of-friends
// rows when fewer than 3 usable ones exist. The same exclusion matrix applies to the curated list; a blocked, blocking,
// followed, muted, DELETING, ghost or own uid on it never comes back.
func TestW320_SuggestionsCuratedFallback(t *testing.T) {
	ctx := context.Background()
	setup := newW320Chain(t, w320SugChain)
	v := setup.user(t)
	c1, c2, c3dl, c4blocked, c5blocks, c6followed, c7muted := setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	ghost := "w320curatedghost" + fmt.Sprint(time.Now().UnixNano())
	curated := []string{c1.uid, c3dl.uid, c4blocked.uid, c5blocks.uid, c6followed.uid, c7muted.uid, ghost, v.uid, c2.uid}
	setup.w320SetStatus(t, c3dl.uid, "DELETING")
	setup.w320Follow(t, v, c6followed.uid) // v follows one account: fewer than 3 followees
	setup.w320Block(t, v, c4blocked.uid)
	setup.w320Block(t, c5blocks, v.uid)
	if _, err := setup.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m"), UserId: c7muted.uid})); err != nil {
		t.Fatal(err)
	}
	withCurated := func(c *config.Config) { w320SugChain(c); c.Suggestions.UserIDs = curated }

	t.Run("fewer than 3 followees: the curated list, filtered", func(t *testing.T) {
		r := newW320Chain(t, withCurated)
		got, err := r.w320Suggest(v, 0)
		if err != nil {
			t.Fatal(err)
		}
		if uids := w320SugUIDs(got); !slices.Equal(w320Sorted(uids), w320Sorted([]string{c1.uid, c2.uid})) {
			t.Errorf("rows = %v, want only the two usable curated users %v", uids, []string{c1.uid, c2.uid})
		}
		if l := r.line(t, w320RPCListSuggested); l["source"] != "curated" {
			t.Errorf("source = %v, want curated", l["source"])
		}
		// interceptor 1 + graph 1 + hydration of the 3 candidates the snapshot lets through (c1, c3, ghost, c2 => 4).
		r.w320Measure(t, w320RPCListSuggested, "curated list, cold (ADR ceiling 12)", budgettest.Budget{Reads: 12})
	})
	t.Run("no followees and no curated list: an empty answer for two reads", func(t *testing.T) {
		r := newW320Chain(t, w320SugChain)
		lone := r.user(t)
		got, err := r.w320Suggest(lone, 0)
		if err != nil || len(got.GetUsers()) != 0 {
			t.Fatalf("lone viewer: %v, %v", w320SugUIDs(got), err)
		}
		r.w320Measure(t, w320RPCListSuggested, "no followees, no curated list", budgettest.Budget{Reads: 2})
	})
	t.Run("3 followees but a single usable friend of a friend: that one first, the curated users after", func(t *testing.T) {
		v2 := setup.user(t)
		f := setup.w320Users(t, 3)
		fof := setup.user(t)
		for _, fe := range f {
			setup.w320Follow(t, v2, fe.uid)
		}
		setup.w320Follow(t, f[0], fof.uid)
		setup.w320Follow(t, f[1], fof.uid)
		r := newW320Chain(t, withCurated)
		got, err := r.w320Suggest(v2, 0)
		if err != nil {
			t.Fatal(err)
		}
		uids := w320SugUIDs(got)
		// For v2 the curated list is just a list of strangers: c4..c7 are unrelated to v2 (their relations belong to v), v is a
		// valid candidate too, and the DELETING user and the ghost drop out at hydration. The first five in list order:
		wantRows := []string{fof.uid, c1.uid, c4blocked.uid, c5blocks.uid, c6followed.uid}
		if !slices.Equal(uids, wantRows) {
			t.Fatalf("rows = %v, want %v (the friend of a friend first, then the curated list in order)", uids, wantRows)
		}
		if l := r.line(t, w320RPCListSuggested); l["source"] != "curated" {
			t.Errorf("source = %v, want curated (the curated list filled the rest)", l["source"])
		}
		r.w320Measure(t, w320RPCListSuggested, "friends of friends then curated, cold", budgettest.Budget{Reads: 42})
	})
}

// TestW320_SuggestionsHardCap42: 30 followees (the sample), each following ONE of 12 candidates, so the friends-of-friends
// query returns its full 30-edge window (Limit), the per-followee cap of 3 (W3-22 L-5) takes nothing away and 12 distinct
// candidates reach hydration, which stops at the cap of 10. The whole request is interceptor 1 + graph 1 + 30 + 10 = 42,
// exactly, and not one read more however large the graph around the viewer is. A denser graph (every followee following 4
// of the candidates, 120 edges) still reads the same 30 edges and hydrates at most 10: the cap is a ceiling, never a target.
func TestW320_SuggestionsHardCap42(t *testing.T) {
	w := newW320Chain(t, w320SugChain)
	v := w.user(t)
	f, cand := w.w320Users(t, 30), w.w320Users(t, 12)
	for _, fe := range f {
		w.w320Follow(t, v, fe.uid)
	}
	base := time.Now().Add(-time.Hour)
	for i, fe := range f {
		seedFollowEdge(t, w.fs, fe.uid, cand[i%len(cand)].uid, base.Add(time.Duration(i)*time.Second))
	}
	r := newW320Chain(t, w320SugChain)
	got, err := r.w320Suggest(v, 0)
	if err != nil || len(got.GetUsers()) != 5 {
		t.Fatalf("rows = %d, %v; want 5", len(got.GetUsers()), err)
	}
	c := r.lineBudget(t, w320RPCListSuggested)
	r.w320Measure(t, w320RPCListSuggested, "hard cap: 30 followees, 30 edges, 10 hydrated, cold", budgettest.Budget{Reads: 42})
	if c.Reads() != 42 {
		t.Errorf("cold reads = %d, want exactly 42 (interceptor 1 + graph 1 + 30 edges + 10 hydrated): the fixture must exercise the full cap", c.Reads())
	}
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}
	l := r.line(t, w320RPCListSuggested)
	if num(l, "candidates") != 10 || l["source"] != "fof" {
		t.Errorf("source=%v candidates=%v, want fof and the hydration cap of 10", l["source"], l["candidates"])
	}

	// A denser graph: every followee now follows 3 more candidates. Same 30-edge window, same 10 hydrations.
	for i, fe := range f {
		for j := 1; j <= 3; j++ {
			seedFollowEdge(t, w.fs, fe.uid, cand[(i+j)%len(cand)].uid, base.Add(time.Hour+time.Duration(i*4+j)*time.Second))
		}
	}
	r2 := newW320Chain(t, w320SugChain)
	if got, err := r2.w320Suggest(v, 0); err != nil || len(got.GetUsers()) != 5 {
		t.Fatalf("dense graph: rows = %d, %v; want 5", len(got.GetUsers()), err)
	}
	r2.w320Measure(t, w320RPCListSuggested, "hard cap, dense graph (120 edges, window 30), cold", budgettest.Budget{Reads: 42})
	if c2 := r2.lineBudget(t, w320RPCListSuggested); c2.Reads() > 42 {
		t.Errorf("dense graph read %d, the cap is 42", c2.Reads())
	}
}

// TestW320_SuggestionsPerFolloweeCap: W3-22 L-5(b). One sampled followee that follows many accounts at once (a follow-back
// bait account) may contribute only its NEWEST maxCandidatesPerFollowee = 3 usable edges, so it cannot fill the window and
// steer every row. The viewer follows three accounts; the bait follows six candidates (newest first c6, c5, c4, c3, c2, c1)
// and the other two follow one each: the rows are c6, c5, c4 and the two ordinary candidates, never c3, c2 or c1.
func TestW320_SuggestionsPerFolloweeCap(t *testing.T) {
	w := newW320Chain(t, w320SugChain)
	v := w.user(t)
	bait, f1, f2 := w.user(t), w.user(t), w.user(t)
	c, x := w.w320Users(t, 6), w.w320Users(t, 2)
	for _, fe := range []bmUser{bait, f1, f2} {
		w.w320Follow(t, v, fe.uid)
	}
	base := time.Now().Add(-time.Hour)
	for i, cu := range c { // c[0] oldest ... c[5] newest
		seedFollowEdge(t, w.fs, bait.uid, cu.uid, base.Add(time.Duration(i)*time.Minute))
	}
	seedFollowEdge(t, w.fs, f1.uid, x[0].uid, base.Add(-time.Minute))
	seedFollowEdge(t, w.fs, f2.uid, x[1].uid, base.Add(-2*time.Minute))

	r := newW320Chain(t, w320SugChain)
	got, err := r.w320Suggest(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	uids := w320SugUIDs(got)
	want := []string{c[5].uid, c[4].uid, c[3].uid, x[0].uid, x[1].uid}
	if !slices.Equal(w320Sorted(uids), w320Sorted(want)) {
		t.Errorf("rows = %v, want the bait's newest 3 plus the two ordinary candidates %v", uids, want)
	}
	for i := 0; i < 3; i++ {
		if slices.Contains(uids, c[i].uid) {
			t.Errorf("candidate c%d (the bait's 4th-6th newest edge) was suggested: the per-followee cap did not hold", 6-i)
		}
	}
	l := r.line(t, w320RPCListSuggested)
	if l["source"] != "fof" || num(l, "candidates") != 5 {
		t.Errorf("source=%v candidates=%v, want fof and 5 (3 from the bait + 2)", l["source"], l["candidates"])
	}
	// interceptor 1 + graph 1 + 8 edges + 5 hydrated = 15.
	r.w320Measure(t, w320RPCListSuggested, "per-followee cap: 8 edges, 5 hydrated, cold", budgettest.Budget{Reads: 15})
}

// TestW320_SuggestionsKnownInactiveFolloweeIsSkipped: W3-22 L-5(a). A followee the instance's profile cache already knows is
// SUSPENDED no longer steers the suggestions and no longer costs reads: it is left out of the edge query and its share of
// the window goes to the others. The cache is primed by an ordinary GetProfile of the suspended account (NOT_FOUND on the
// wire). A control instance that has not seen the account yet still suggests the spam candidates (the probe is
// cache-only and never "active by default"), so the difference between the two answers is exactly the probe.
func TestW320_SuggestionsKnownInactiveFolloweeIsSkipped(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w320SugChain)
	v := w.user(t)
	spam, f1, f2 := w.user(t), w.user(t), w.user(t)
	spamC, x := w.w320Users(t, 3), w.w320Users(t, 3)
	for _, fe := range []bmUser{spam, f1, f2} {
		w.w320Follow(t, v, fe.uid)
	}
	base := time.Now().Add(-time.Hour)
	for i, cu := range spamC { // the spam account's edges are the newest in the window
		seedFollowEdge(t, w.fs, spam.uid, cu.uid, base.Add(time.Duration(i+10)*time.Minute))
	}
	seedFollowEdge(t, w.fs, f1.uid, x[0].uid, base)
	seedFollowEdge(t, w.fs, f2.uid, x[1].uid, base.Add(time.Minute))
	seedFollowEdge(t, w.fs, f2.uid, x[2].uid, base.Add(2*time.Minute))
	w.w320SetStatus(t, spam.uid, "SUSPENDED")

	control := newW320Chain(t, w320SugChain) // has never looked at the spam account
	cg, err := control.w320Suggest(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	controlCands := num(control.line(t, w320RPCListSuggested), "candidates")
	controlReads := control.lineBudget(t, w320RPCListSuggested).Reads()

	r := newW320Chain(t, w320SugChain)
	_, err = r.identity.GetProfile(ctx, authed(v.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: spam.uid}}))
	wireError(t, err, connect.CodeNotFound) // the suspended account is NOT_FOUND, and this instance now knows it
	got, err := r.w320Suggest(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	uids := w320SugUIDs(got)
	for _, cu := range spamC {
		if slices.Contains(uids, cu.uid) {
			t.Errorf("a candidate of the known-suspended followee was suggested: %s", cu.uid)
		}
	}
	if !slices.Equal(w320Sorted(uids), w320Sorted([]string{x[0].uid, x[1].uid, x[2].uid})) {
		t.Errorf("rows = %v, want the three ordinary candidates %v", uids, []string{x[0].uid, x[1].uid, x[2].uid})
	}
	if n := num(r.line(t, w320RPCListSuggested), "candidates"); n != 3 {
		t.Errorf("candidates hydrated = %d, want 3 (the suspended followee's edges are not even read)", n)
	}
	cr := r.lineBudget(t, w320RPCListSuggested)
	if controlCands != 6 || len(cg.GetUsers()) != 5 {
		t.Errorf("control: %d candidates and %d rows, want 6 and 5 (the probe is cache-only: an instance that has not seen the account still samples it)", controlCands, len(cg.GetUsers()))
	}
	// Reads past the interceptor and graph: control 3 + 3 edges... the primed instance reads 3 edges and hydrates 3.
	if cr.Reads() >= controlReads {
		t.Errorf("primed instance read %d, control %d: skipping the suspended followee must cost less", cr.Reads(), controlReads)
	}
	t.Logf("W320BUDGET rpc=%q case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", w320RPCListSuggested, "known-suspended followee skipped (control read "+fmt.Sprint(controlReads)+")", cr.Reads(), cr.Writes(), cr.Deletes(), 42, 0)
}

// TestW320_SuggestionsBlockerOnAnotherInstance: W3-22 L-1 (fixed in #350). The viewer's rows are cached for an hour on
// instance A. A candidate then blocks the viewer through instance B. A's own graph snapshot expires after CACHE_TTL (1 s
// here, 60 s in production) and EVERY warm hit is re-filtered against the snapshot: the next call loads it (1 read, plus
// the interceptor's own profile read that expired with the same TTL: 2 in all, the ADR-0024 "2 when the 60 s snapshot
// expired" figure) and the blocker is gone from the rows. Inside the 60 s window the re-filter is free (0 reads).
func TestW320_SuggestionsBlockerOnAnotherInstance(t *testing.T) {
	a := newW320Chain(t, func(c *config.Config) { w320SugChain(c); c.CacheTTL = time.Second })
	b := newW320Chain(t, nil)
	v := a.user(t)
	f, cand := a.w320Users(t, 3), a.w320Users(t, 3)
	for i, fe := range f {
		a.w320Follow(t, v, fe.uid)
		for j := range cand {
			if j != i {
				a.w320Follow(t, fe, cand[j].uid) // every candidate is followed by two followees
			}
		}
	}
	first, err := a.w320Suggest(v, 0)
	if err != nil || len(first.GetUsers()) != 3 {
		t.Fatalf("first call on A: %v, %v; want the 3 candidates", w320SugUIDs(first), err)
	}
	blocker := cand[0]
	b.w320Block(t, blocker, v.uid)
	time.Sleep(1500 * time.Millisecond) // A's snapshot and profile entries age out (TTL 1 s); the 1 h rows entry does not

	second, err := a.w320Suggest(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(w320SugUIDs(second), blocker.uid) {
		t.Errorf("the blocker %s is still suggested on a warm hit after the snapshot expired (W3-22 L-1)", blocker.uid)
	}
	if l := a.line(t, w320RPCListSuggested); l["suggestions_cache_hit"] != true {
		t.Errorf("suggestions_cache_hit = %v, want true: the second call must be the warm path that re-filters", l["suggestions_cache_hit"])
	}
	a.w320Measure(t, w320RPCListSuggested, "warm hit, snapshot expired (interceptor 1 + snapshot 1; ADR: 2)", budgettest.Budget{Reads: 2})
	if c := a.lineBudget(t, w320RPCListSuggested); c.Reads() == 0 {
		t.Error("the re-filter read nothing after the snapshot expired: it cannot have seen the block")
	}
	// Inside the snapshot's TTL the next warm hit is free.
	if _, err := a.w320Suggest(v, 0); err != nil {
		t.Fatal(err)
	}
	a.w320Measure(t, w320RPCListSuggested, "warm hit, snapshot cached (0; ADR planning 1)", budgettest.Budget{})
	// A fresh instance has no cached rows and sees the block too.
	fresh := newW320Chain(t, w320SugChain)
	got, err := fresh.w320Suggest(v, 0)
	if err != nil || slices.Contains(w320SugUIDs(got), blocker.uid) {
		t.Errorf("a fresh instance suggests the blocker or fails: %v, %v", w320SugUIDs(got), err)
	}
	// Whatever the rows say, the server refuses the Follow and the profile.
	_, err = a.graph.Follow(context.Background(), authed(v.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("w320-f"), UserId: blocker.uid}))
	wireError(t, err, connect.CodeNotFound)
}
