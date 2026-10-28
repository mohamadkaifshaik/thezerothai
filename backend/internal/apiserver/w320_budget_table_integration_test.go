//go:build integration

package apiserver

// W3-20: the read / write / delete budget of every Part A RPC against the ADR-0024 "Cost impact" ceilings, measured on a
// COLD instance (a chain booted after the data was written, so no cache is warm) and asserted with budgettest. Each
// measurement prints one machine-readable line,
//
//	W320BUDGET rpc="..." case="..." reads=N writes=N deletes=N ceil_reads=N ceil_writes=N
//
// which docs/reviews/test-report-w3.md quotes. The page-50 figures (54 / 53) are measured here too (50 rows of each kind
// are seeded); the banner upload, finalize and resolve figures by the media package integration tests and
// banner_matrix_integration_test.go (they cannot be reached through the chain: a signed PUT URL cannot be minted against the
// emulators); the post_delete pin clean-up by identity.TestClearIfPinned_Integration; the backfill by W320BUDGET lines of
// TestW320_LegacyPostIsOffTheMediaTabUntilBackfilled; the suggestions' 32 hard cap (42 with EdgeLimit pinned to 30), the 12 of the curated path, the known-
// inactive skip and the 2-read expired-snapshot warm hit by the W320BUDGET lines of the suggestions file; the UpdateProfile
// no-op (1 read, 0 writes) by TestW320_UpdateProfileDailyCapAndNoOpWrites.

import (
	"context"
	"fmt"
	"testing"

	"cloud.google.com/go/firestore"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w320Measure asserts the last request line of rpc against the ceiling and prints its W320BUDGET line.
func (e *bmChain) w320Measure(t *testing.T, rpc, label string, ceil budgettest.Budget) {
	t.Helper()
	c := e.lineBudget(t, rpc)
	budgettest.Assert(t, rpc+" "+label, c, ceil)
	t.Logf("W320BUDGET rpc=%q case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", rpc, label, c.Reads(), c.Writes(), c.Deletes(), ceil.Reads, ceil.Writes)
}

func TestW320_BudgetTable(t *testing.T) { w320BudgetTable(t, nil) }

// w320BudgetTable is the W3-20 table. partB (W3-35a) is an extra config applied to every chain it builds: with Part B on
// and a protected account in the set, every existing read path keeps its W3-20 ceiling (ADR-0025: the predicate adds 0).
func w320BudgetTable(t *testing.T, partB func(*config.Config)) {
	ctx := context.Background()
	allOn := func(c *config.Config) {
		w320AllW3On(c)
		if partB != nil {
			partB(c)
		}
	}
	e, w := newW320Life(t, partB)
	author, viewer, other := w.user(t), w.user(t), w.user(t)
	if partB != nil {
		// A non-empty protected set that none of the measured data belongs to.
		prot := true
		if _, err := w.w320Update(w.user(t), &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
			t.Fatalf("protect an unrelated account: %v", err)
		}
	}

	// --- data: 50 media posts, 50 reposts of other's posts, 50 likes by the viewer (the first media post gets pinned) ---
	var mediaIDs []string
	for i := 0; i < 50; i++ {
		id := w.post(t, author, fmt.Sprint("media ", i))
		w.w320MarkMedia(t, id)
		mediaIDs = append(mediaIDs, id)
	}
	w.repostOthers(t, author, other, 50)
	for i := 0; i < 50; i++ {
		id := w.post(t, other, fmt.Sprint("liked ", i))
		w.like(t, viewer, id)
	}
	banner := e.seedMedia(t, author.uid, media.PurposeBanner)
	pinID := mediaIDs[0]

	// --- UpdateProfile: ADR "2 / 1 + 1 banner resolve + 1 pin check (4 worst cold)", 1 write ---
	r := newW320Chain(t, allOn)
	if _, err := r.w320Update(author, &identityv1.UpdateProfileRequest{BannerMediaId: &banner, Location: w320Str("Pune"), Website: w320Str("https://example.com"), PinnedPostId: &pinID}); err != nil {
		t.Fatalf("UpdateProfile all fields: %v", err)
	}
	r.w320Measure(t, rpcUpdateProfile, "banner+location+website+pin, cold interceptor", budgettest.Budget{Reads: 4, Writes: 1})
	r2 := newW320Chain(t, allOn)
	if _, err := r2.w320Update(viewer, &identityv1.UpdateProfileRequest{Location: w320Str("Mumbai")}); err != nil {
		t.Fatal(err)
	}
	r2.w320Measure(t, rpcUpdateProfile, "location only, cold interceptor", budgettest.Budget{Reads: 2, Writes: 1})
	if _, err := r2.w320Update(viewer, &identityv1.UpdateProfileRequest{Location: w320Str("Delhi")}); err != nil {
		t.Fatal(err)
	}
	r2.w320Measure(t, rpcUpdateProfile, "location only, warm interceptor", budgettest.Budget{Reads: 1, Writes: 1})

	// --- GetPost of the pinned post: ADR "4 / 0" (existing RPC) ---
	// ADR-0024: "4 / 0". The GetPost doc comment adds +1 (userLikes) cold when engagement or bookmarks is on, so the table measures
	// both: engagement off is the ADR figure, engagement on is 5.
	r3off := newW320Chain(t, func(c *config.Config) {
		allOn(c)
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.Off}
		// GetPost reads userLikes (+1) when engagement OR bookmarks is on; Part B turns bookmarks on, so the ADR figure of 4 needs both off.
		c.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.Off}
	})
	if _, err := r3off.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: pinID})); err != nil {
		t.Fatal(err)
	}
	r3off.w320Measure(t, "/dzeroth.posts.v1.PostService/GetPost", "the pinned post, cold, engagement off (ADR figure)", budgettest.Budget{Reads: 4})
	r3 := newW320Chain(t, allOn)
	if _, err := r3.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: pinID})); err != nil {
		t.Fatal(err)
	}
	r3.w320Measure(t, "/dzeroth.posts.v1.PostService/GetPost", "the pinned post, cold, engagement on (+1 userLikes)", budgettest.Budget{Reads: 5})
	if _, err := r3.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: pinID})); err != nil {
		t.Fatal(err)
	}
	r3.w320Measure(t, "/dzeroth.posts.v1.PostService/GetPost", "the pinned post, warm", budgettest.Budget{})

	// --- tabs: ADR 24 cold / 20 warm at page 20 ---
	for _, tc := range []struct {
		name string
		tab  func(rr *w320Chain) error
	}{
		{"MEDIA", func(rr *w320Chain) error {
			_, err := rr.w320TabCall(viewer, author.uid, tabMediaPB, false, 20, "", "")
			return err
		}},
		{"REPOSTS", func(rr *w320Chain) error {
			_, err := rr.w320TabCall(viewer, author.uid, tabRepostsPB, false, 20, "", "")
			return err
		}},
	} {
		rr := newW320Chain(t, allOn)
		if err := tc.tab(rr); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		rr.w320Measure(t, w320RPCGetUserTimeline, tc.name+" page 20, cold", budgettest.Budget{Reads: 24})
		if err := tc.tab(rr); err != nil {
			t.Fatal(err)
		}
		rr.w320Measure(t, w320RPCGetUserTimeline, tc.name+" page 20, warm", budgettest.Budget{Reads: 20})
	}
	// page 50 (the clamp): ADR 54 cold (interceptor, target users, caller graph, 50 rows, userLikes) / 50 warm.
	for _, tc := range []struct {
		name string
		tab  timelinev1.UserTimelineTab
	}{{"MEDIA", tabMediaPB}, {"REPOSTS", tabRepostsPB}} {
		rr := newW320Chain(t, allOn)
		if resp, err := rr.w320TabCall(viewer, author.uid, tc.tab, false, 50, "", ""); err != nil || len(resp.GetPosts()) != 50 {
			t.Fatalf("%s page 50: %v", tc.name, err)
		}
		rr.w320Measure(t, w320RPCGetUserTimeline, tc.name+" page 50, cold", budgettest.Budget{Reads: 54})
		if _, err := rr.w320TabCall(viewer, author.uid, tc.tab, false, 50, "", ""); err != nil {
			t.Fatal(err)
		}
		rr.w320Measure(t, w320RPCGetUserTimeline, tc.name+" page 50, warm", budgettest.Budget{Reads: 50})
	}

	// --- ListLikedPosts: ADR 23 cold / 20 warm at page 20, 2 for an empty array ---
	rl := newW320Chain(t, allOn)
	if _, err := rl.listLiked(viewer, 20, ""); err != nil {
		t.Fatal(err)
	}
	rl.w320Measure(t, rpcListLikedPosts, "page 20, cold", budgettest.Budget{Reads: 23})
	if _, err := rl.listLiked(viewer, 20, ""); err != nil {
		t.Fatal(err)
	}
	rl.w320Measure(t, rpcListLikedPosts, "page 20, warm (every cache hit)", budgettest.Budget{Reads: 20})
	rl50 := newW320Chain(t, allOn)
	if p, err := rl50.listLiked(viewer, 50, ""); err != nil || len(p.GetPosts()) != 50 {
		t.Fatalf("ListLikedPosts page 50: %v", err)
	}
	rl50.w320Measure(t, rpcListLikedPosts, "page 50, cold", budgettest.Budget{Reads: 53})
	if _, err := rl50.listLiked(viewer, 50, ""); err != nil {
		t.Fatal(err)
	}
	rl50.w320Measure(t, rpcListLikedPosts, "page 50, warm (every cache hit)", budgettest.Budget{Reads: 50})
	re := newW320Chain(t, allOn)
	if _, err := re.listLiked(author, 20, ""); err != nil {
		t.Fatal(err)
	}
	re.w320Measure(t, rpcListLikedPosts, "empty array, cold", budgettest.Budget{Reads: 2})

	// --- GetProfileRelationship: ADR 3 cold (interceptor, caller graph, edge) with the header's GetProfile first, 0 warm ---
	w.w320Follow(t, other, viewer.uid)
	rr := newW320Chain(t, allOn)
	rr.w320Profile(t, viewer, other.uid)
	if _, err := rr.w320Rel(viewer, other.uid); err != nil {
		t.Fatal(err)
	}
	rr.w320Measure(t, w320RPCGetProfileRel, "header sequence: GetProfile first warmed the interceptor, target and caller graph (ADR 3 cold alone)", budgettest.Budget{Reads: 3})
	if _, err := rr.w320Rel(viewer, other.uid); err != nil {
		t.Fatal(err)
	}
	rr.w320Measure(t, w320RPCGetProfileRel, "warm", budgettest.Budget{})
	rn := newW320Chain(t, allOn)
	if _, err := rn.w320Rel(viewer, other.uid); err != nil { // no GetProfile first: the Directory read is the 4th
		t.Fatal(err)
	}
	rn.w320Measure(t, w320RPCGetProfileRel, "cold Directory too (no header GetProfile first)", budgettest.Budget{Reads: 4})
	if _, err := e.fs.Doc("graph/"+viewer.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	ro := newW320Chain(t, allOn)
	if _, err := ro.w320Rel(viewer, other.uid); err != nil {
		t.Fatal(err)
	}
	ro.w320Measure(t, w320RPCGetProfileRel, "blockedBy overflow, nothing warm (4 + 1)", budgettest.Budget{Reads: 5})
	if _, err := e.fs.Doc("graph/"+viewer.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: false}}); err != nil {
		t.Fatal(err)
	}

	// --- ListSuggestedUsers: 32 friends of friends (42 with EdgeLimit pinned to 30), 12 curated, 1 warm (ADR-0024 D8,
	// Amendment 2 B1(b)); the ceiling below is derived from the configured limits. Measured in the dedicated tests, repeated
	// here for the table with a small graph so the figure is the real shape, not the cap. ---
	sv := w.user(t)
	f, cand := w.w320Users(t, 3), w.w320Users(t, 4)
	for i, fe := range f {
		w.w320Follow(t, sv, fe.uid)
		w.w320Follow(t, fe, cand[i].uid)
		w.w320Follow(t, fe, cand[i+1].uid)
	}
	rs := newW320Chain(t, allOn)
	if _, err := rs.graph.ListSuggestedUsers(ctx, authed(sv.token, &graphv1.ListSuggestedUsersRequest{})); err != nil {
		t.Fatal(err)
	}
	rs.w320Measure(t, w320RPCListSuggested, "friends of friends, 3 followees / 6 edges / 4 candidates, cold", budgettest.Budget{Reads: w320SugColdCap(t)})
	if _, err := rs.graph.ListSuggestedUsers(ctx, authed(sv.token, &graphv1.ListSuggestedUsersRequest{})); err != nil {
		t.Fatal(err)
	}
	rs.w320Measure(t, w320RPCListSuggested, "warm (the cached rows re-filtered from the cached snapshot; ADR planning 1)", budgettest.Budget{Reads: 1})
	if c := rs.lineBudget(t, w320RPCListSuggested); c.Reads() != 0 {
		t.Errorf("a warm hit inside the 60 s snapshot TTL read %d, want 0 (the interceptor and the snapshot are both cached)", c.Reads())
	}
}
