//go:build integration

package apiserver

// W3-20: ListLikedPosts (ADR-0024 D6) over the real Build chain on the emulators. The cells the W3-10 chain tests
// (engagement_likes_list_integration_test.go) leave empty:
//   - the ADR-0010 D6 drop matrix with EMBEDDED authors: a QUOTE and a REPOST whose embedded author the viewer blocks,
//     who blocks the viewer, or whom the viewer mutes are dropped (counted under the right cause), the copy of an
//     unrelated author stays, the viewer's own copies stay, and a viewer whose blockedBy overflowed keeps only their
//     own posts (fail closed);
//   - the residual unlike / re-like cases the ADR names (both anchors unliked; the last row unliked and the next one
//     re-liked), a double unlike, and a trim that reaches the next anchor: termination and the documented bound;
//   - forged tokens: expired, wrong version, negative index, non-post anchors, a token of the same kind sealed for
//     another uid, a token that is good for its owner;
//   - owner-only: two users with overlapping likes each get only their own, in their own order.
// The exact budgets (23 / 53 / 2) are asserted by the W3-10 file and are measured again in the W3-20 budget table.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w320LikesChain turns likes_list, engagement and quotes on with the abuse limits relaxed.
func w320LikesChain(c *config.Config) {
	w320Base(c)
	c.FeatureLikesList = flags.Spec{Name: "likes_list", Mode: flags.On}
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
}

// w320LikesRepeatsAfterLastGoneAndNextRelike is a finding of this ticket (defect D-1 in docs/reviews/test-report-w3.md),
// not a W3-22 item. Pre-fix (true): when the last returned row is unliked AND the next row is unliked and liked again
// between two pages, the resume rule 1 of ADR-0024 D6 ("Next, when it is in recent and Last is gone: resume at it") puts
// the re-liked Next at the NEWEST end, so the walk restarts from the top and repeats every row of the earlier pages -
// more than "the rows changed in that window" the ADR promises. After a fix (false): the repeat stays within the changed
// rows. The client dedupes by post id (W3-18), so the cost is wasted reads, not a visible duplicate.
const w320LikesRepeatsAfterLastGoneAndNextRelike = true

func (e *bmChain) w320Walk(t *testing.T, u bmUser, size int32, token string) (rows []string, tokens int) {
	t.Helper()
	for pages := 0; ; pages++ {
		if pages > 20 {
			t.Fatal("the walk did not terminate in 20 pages")
		}
		p, err := e.listLiked(u, size, token)
		if err != nil {
			t.Fatalf("page: %v", err)
		}
		rows = append(rows, likedPostIDs(p)...)
		tokens++
		if token = p.GetNextPageToken(); token == "" {
			return rows, tokens
		}
	}
}

// TestW320_LikesDropMatrixWithEmbeddedAuthors: see the file comment. v likes, in this order, a plain post of an unrelated
// author, one QUOTE and one REPOST of each of: an unrelated author O, an author X that v blocks, an author Y that blocks
// v, an author Z that v mutes; then v's own post, and v's own QUOTE of X. The REPOST ids are seeded straight into
// userLikes (a like of a REPOST resolves to its original on the like path, so the array never holds one that way, but a
// list must still drop correctly when it does).
func TestW320_LikesDropMatrixWithEmbeddedAuthors(t *testing.T) {
	ctx := context.Background()
	w, r := listChains(t, func(c *config.Config) { w320LikesChain(c) })
	v, a, o, x, y, z := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)

	quoteOf := func(by bmUser, orig string) string {
		q, err := w.posts.CreatePost(ctx, authed(by.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w320-q"), Text: "quote", QuoteOfPostId: orig}))
		if err != nil {
			t.Fatalf("quote: %v", err)
		}
		return q.Msg.GetPost().GetPost().GetPostId()
	}
	repostOf := func(by bmUser, orig string) string {
		rp, err := w.eng.RepostPost(ctx, authed(by.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-rp"), PostId: orig}))
		if err != nil {
			t.Fatalf("repost: %v", err)
		}
		return rp.Msg.GetRepostPostId()
	}
	orig := map[string]string{}
	for name, u := range map[string]bmUser{"o": o, "x": x, "y": y, "z": z} {
		orig[name] = w.post(t, u, "original by "+name)
	}
	plain := w.post(t, a, "a plain post by an unrelated author")
	quotes, reposts := map[string]string{}, map[string]string{}
	for _, name := range []string{"o", "x", "y", "z"} {
		quotes[name] = quoteOf(a, orig[name])
		reposts[name] = repostOf(a, orig[name])
	}
	own := w.post(t, v, "v's own post")
	ownQuoteOfX := quoteOf(v, orig["x"])

	// v likes the plain post and the quotes through the real LikePost; the reposts go straight into the array.
	order := []string{plain, quotes["o"], quotes["x"], quotes["y"], quotes["z"]}
	for _, id := range order {
		w.like(t, v, id)
	}
	w.likeDirect(t, v.uid, []string{reposts["o"], reposts["x"], reposts["y"], reposts["z"]})
	w.like(t, v, own)
	w.like(t, v, ownQuoteOfX)
	all := append(slices.Clone(order), reposts["o"], reposts["x"], reposts["y"], reposts["z"], own, ownQuoteOfX)
	if _, err := w.graph.Block(ctx, authed(v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b1"), UserId: x.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(y.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w320-b2"), UserId: v.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w320-m1"), UserId: z.uid})); err != nil {
		t.Fatal(err)
	}

	resp, err := r.listLiked(v, 50, "")
	if err != nil {
		t.Fatalf("ListLikedPosts: %v", err)
	}
	// Kept: unrelated plain post, the O quote and O repost, v's own post and v's own quote of the blocked author.
	// Dropped: X (blocked) quote + repost, Y (blocks v) quote + repost = 4 blocked; Z (muted) quote + repost = 2 muted.
	wantKept := []string{ownQuoteOfX, own, reposts["o"], quotes["o"], plain} // newest liked first
	gotKept := likedPostIDs(resp)
	if !slices.Equal(w320Sorted(gotKept), w320Sorted(wantKept)) {
		t.Fatalf("rows = %v, want %v", gotKept, wantKept)
	}
	l := r.line(t, rpcListLikedPosts)
	for k, want := range map[string]int64{"rows_returned": 5, "rows_dropped": 6, "rows_dropped_blocked": 4, "rows_dropped_muted": 2, "rows_dropped_missing": 0, "rows_dropped_hidden": 0} {
		if got := num(l, k); got != want {
			t.Errorf("%s = %d, want %d", k, got, want)
		}
	}
	// 11 ids on the page: interceptor 1 + userLikes 1 + GetMany 11 + graph 1 = 14 reads cold, no write, no prune.
	c := r.lineBudget(t, rpcListLikedPosts)
	budgettest.Assert(t, "ListLikedPosts with embedded-author drops", c, budgettest.Budget{Reads: int64(len(all)) + 3})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("writes/deletes = %d/%d, want 0/0 (no pruning)", c.Writes(), c.Deletes())
	}
	if after := userLikesRecent(t, w, v.uid); len(after) != len(all) {
		t.Errorf("userLikes.recent has %d ids after the list, want all %d kept in storage", len(after), len(all))
	}

	// blockedBy overflow: a viewer who may be blocked by anyone fails closed for every foreign row, and keeps only
	// their own posts and own copies.
	ov := w.user(t)
	ownOv := w.post(t, ov, "ov's own")
	ownQuoteOv := quoteOf(ov, orig["o"])
	for _, id := range []string{plain, quotes["o"], ownOv, ownQuoteOv} {
		w.like(t, ov, id)
	}
	if _, err := w.fs.Doc("graph/"+ov.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	r2 := newBMChain(t, func(c *config.Config) { w320LikesChain(c) })
	got, err := r2.listLiked(ov, 50, "")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(w320Sorted(likedPostIDs(got)), w320Sorted([]string{ownOv, ownQuoteOv})) {
		t.Errorf("overflowed viewer's rows = %v, want only their own %s and %s", likedPostIDs(got), ownOv, ownQuoteOv)
	}
	if blocked := num(r2.line(t, rpcListLikedPosts), "rows_dropped_blocked"); blocked != 2 {
		t.Errorf("overflow rows_dropped_blocked = %d, want the 2 foreign rows", blocked)
	}
}

func w320Sorted(s []string) []string {
	out := slices.Clone(s)
	slices.Sort(out)
	return out
}

// TestW320_LikesResidualCasesAndTrim: page size 10 over 25 likes; between page 1 and page 2 the reader changes the boundary
// as ADR-0024 D6 describes. Every row is a live post, so any difference from the plain walk comes from the cursor alone.
// Asserted for each: the walk terminates, no row is returned twice within the walk after page 1, and the rows lost or
// repeated against the plain expectation stay within the documented bound. The two residual cases print the exact
// sequence (observed behaviour, not contract).
func TestW320_LikesResidualCasesAndTrim(t *testing.T) {
	// rev is newest-liked first: rev[0..9] is page 1, rev[10] is Next, rev[9] is Last.
	tests := []struct {
		name string
		do   func(t *testing.T, w, r *bmChain, v bmUser, rev []string)
		// want is the exact expected remainder, newest first; nil = only the invariants are checked.
		want func(rev []string) []string
		// maxLost and maxRepeated are the documented bound: at most the rows changed in the window.
		maxLost, maxRepeated int
	}{
		{"both anchors unliked: the next row after them is skipped (observed), nothing repeats",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				r.unlike(t, v, rev[9])
				r.unlike(t, v, rev[10])
			},
			func(rev []string) []string { return slices.Clone(rev[12:]) }, 2, 0},
		{"double unlike of Next and the row after it: resumes just older than Last, nothing lost",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				r.unlike(t, v, rev[10])
				r.unlike(t, v, rev[11])
			},
			func(rev []string) []string { return slices.Clone(rev[12:]) }, 0, 0},
		{"Last unliked and a row above it unliked: Next is still older, resumes at it",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				r.unlike(t, v, rev[9])
				r.unlike(t, v, rev[8])
			},
			func(rev []string) []string { return slices.Clone(rev[10:]) }, 0, 0},
		{"Last unliked, Next unliked and liked again (residual: see D-1)",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				r.unlike(t, v, rev[9])
				r.unlike(t, v, rev[10])
				r.like(t, v, rev[10])
			},
			nil, 2, 2},
		{"a trim of the 5 oldest likes (they were liked first)",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				for _, id := range rev[20:] {
					w.w320Trim(t, v.uid, id)
				}
			},
			func(rev []string) []string { return slices.Clone(rev[10:20]) }, 0, 0},
		{"a trim that reaches Next removes everything older: the list ends with no token",
			func(t *testing.T, w, r *bmChain, v bmUser, rev []string) {
				for _, id := range rev[10:] {
					w.w320Trim(t, v.uid, id)
				}
			},
			func(rev []string) []string { return nil }, 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w, _ := listChains(t, w320LikesChain)
			author, viewer := w.user(t), w.user(t)
			var liked []string
			for i := 0; i < 25; i++ {
				id := w.post(t, author, fmt.Sprint("p", i))
				w.like(t, viewer, id)
				liked = append(liked, id)
			}
			rev := reversed(liked)
			// The reader is created AFTER the seeding so its userLikes cache is cold, and makes the changes itself so its
			// cache sees them (like a real client's next scroll on the same instance). A trim is a server-side
			// effect on another instance; a second cold reader then serves page 2.
			r := newBMChain(t, w320LikesChain)
			p1, err := r.listLiked(viewer, 10, "")
			if err != nil || !slices.Equal(likedPostIDs(p1), rev[:10]) || p1.GetNextPageToken() == "" {
				t.Fatalf("page 1 = %v token %q err %v", likedPostIDs(p1), p1.GetNextPageToken(), err)
			}
			tt.do(t, w, r, viewer, rev)
			reader := r
			if tt.name[:6] == "a trim" {
				reader = newBMChain(t, w320LikesChain) // cold: sees the trimmed array
			}
			rest, pages := reader.w320Walk(t, viewer, 10, p1.GetNextPageToken())
			t.Logf("OBSERVED %q: %d rows in %d pages after page 1: %v", tt.name, len(rest), pages, rest)

			// Invariants: no duplicate inside the remainder; nothing outside the 25 liked posts.
			seen := map[string]bool{}
			for _, id := range rest {
				if seen[id] {
					t.Errorf("row %s returned twice in the remainder", id)
				}
				seen[id] = true
				if !slices.Contains(liked, id) {
					t.Errorf("row %s was never liked", id)
				}
			}
			if tt.want != nil {
				if want := tt.want(rev); !slices.Equal(rest, want) {
					t.Errorf("remainder = %v\nwant      %v", rest, want)
				}
				return
			}
			// Residual case: bound the damage against "every still-liked row after page 1, once".
			expectedPool := slices.DeleteFunc(slices.Clone(rev[10:]), func(id string) bool { return id == rev[10] })
			lost := 0
			for _, id := range expectedPool {
				if !seen[id] {
					lost++
				}
			}
			repeated := 0
			for _, id := range rev[:10] {
				if seen[id] {
					repeated++
				}
			}
			if lost > tt.maxLost {
				t.Errorf("lost %d rows, documented bound %d", lost, tt.maxLost)
			}
			if repeated > tt.maxRepeated {
				if w320LikesRepeatsAfterLastGoneAndNextRelike {
					t.Logf("DEFECT D-1 (pre-fix, expected): %d rows of the earlier pages are repeated, documented bound %d", repeated, tt.maxRepeated)
				} else {
					t.Errorf("repeated %d rows of the earlier pages, documented bound %d", repeated, tt.maxRepeated)
				}
			} else if w320LikesRepeatsAfterLastGoneAndNextRelike {
				t.Errorf("D-1 no longer reproduces (repeated %d <= %d): flip w320LikesRepeatsAfterLastGoneAndNextRelike to false", repeated, tt.maxRepeated)
			}
		})
	}
}

// w320Trim removes one id from userLikes.recent directly, the way the best-effort trim at the 1,000 cap does at the oldest
// end (the cap itself is too large to seed for every case).
func (e *bmChain) w320Trim(t *testing.T, uid, id string) {
	t.Helper()
	if _, err := e.fs.Doc("userLikes/"+uid).Update(context.Background(), []firestore.Update{{Path: "recent", Value: firestore.ArrayRemove(id)}}); err != nil {
		t.Fatalf("trim: %v", err)
	}
}

// TestW320_LikesForgedTokens: tokens made by hand with the real key. A good one for its owner opens (control); an expired
// one (25 h), one of another version, one with a negative index or non-post anchors, and one sealed for another uid or
// another list are VALIDATION field=page_token with exactly 0 reads (the interceptor is warm).
func TestW320_LikesForgedTokens(t *testing.T) {
	w, r := listChains(t, w320LikesChain)
	author, a, b := w.user(t), w.user(t), w.user(t)
	var liked []string
	for i := 0; i < 5; i++ {
		id := w.post(t, author, fmt.Sprint("p", i))
		w.like(t, a, id)
		liked = append(liked, id)
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	seal := func(binding, payload string, issued time.Time) string {
		return cursor.EncodeAt(cfg.CursorHMACKey, binding, cursor.Cursor{CreatedAt: issued, DocID: payload}, issued)
	}
	rev := reversed(liked)
	good := fmt.Sprintf("v1:%s:%s:%d", rev[2], rev[1], 2)
	r.enabledFeatures(t, a)

	if p, err := r.listLiked(a, 10, seal("likes|"+a.uid, good, time.Now())); err != nil || !slices.Equal(likedPostIDs(p), rev[2:]) {
		t.Fatalf("control: a forged but valid token for its owner = %v, %v; want the rows from Next on %v", likedPostIDs(p), err, rev[2:])
	}
	if _, err := r.listLiked(a, 10, seal("likes|"+a.uid, good, time.Now().Add(-23*time.Hour))); err != nil {
		t.Errorf("a 23 h old token must still open: %v", err)
	}
	bad := map[string]string{
		"expired (25 h)":                 seal("likes|"+a.uid, good, time.Now().Add(-25*time.Hour)),
		"another version":                seal("likes|"+a.uid, "v2:"+good[3:], time.Now()),
		"negative index":                 seal("likes|"+a.uid, fmt.Sprintf("v1:%s:%s:-1", rev[2], rev[1]), time.Now()),
		"non-numeric index":              seal("likes|"+a.uid, fmt.Sprintf("v1:%s:%s:x", rev[2], rev[1]), time.Now()),
		"anchors that are not post ids":  seal("likes|"+a.uid, "v1:aaa:bbb:1", time.Now()),
		"missing parts":                  seal("likes|"+a.uid, "v1:"+rev[2], time.Now()),
		"extra parts":                    seal("likes|"+a.uid, good+":9", time.Now()),
		"sealed for another uid":         seal("likes|"+b.uid, good, time.Now()),
		"sealed for the bookmarks list":  seal("bookmarks|"+a.uid, good, time.Now()),
		"sealed with the bare uid":       seal(a.uid, good, time.Now()),
		"a token from the future (25 h)": seal("likes|"+a.uid, good, time.Now().Add(25*time.Hour)),
	}
	for name, token := range bad {
		_, err := r.listLiked(a, 10, token)
		w320Reason(t, name, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
		r.w320AssertNothingBM(t, name, rpcListLikedPosts)
	}
}

// w320AssertNothingBM is w320AssertNothing for a bare bmChain.
func (e *bmChain) w320AssertNothingBM(t *testing.T, what, rpc string) {
	t.Helper()
	budgettest.Assert(t, what, e.lineBudget(t, rpc), budgettest.Budget{})
}

// TestW320_LikesAreOwnerOnly: two users like overlapping posts in different orders; each list is their own, in their own
// order, and one user's token is no key to the other's list. The request carries no user id at all.
func TestW320_LikesAreOwnerOnly(t *testing.T) {
	w, r := listChains(t, w320LikesChain)
	author, a, b := w.user(t), w.user(t), w.user(t)
	var ids []string
	for i := 0; i < 6; i++ {
		ids = append(ids, w.post(t, author, fmt.Sprint("p", i)))
	}
	for _, id := range ids[:4] { // a: 0,1,2,3
		w.like(t, a, id)
	}
	for _, id := range []string{ids[5], ids[2], ids[0]} { // b: 5,2,0
		w.like(t, b, id)
	}
	pa, err := r.listLiked(a, 0, "")
	if err != nil || !slices.Equal(likedPostIDs(pa), []string{ids[3], ids[2], ids[1], ids[0]}) {
		t.Fatalf("a's list = %v, %v", likedPostIDs(pa), err)
	}
	pb, err := r.listLiked(b, 0, "")
	if err != nil || !slices.Equal(likedPostIDs(pb), []string{ids[0], ids[2], ids[5]}) {
		t.Fatalf("b's list = %v, %v", likedPostIDs(pb), err)
	}
	// liked_by_viewer is each caller's own state.
	for _, row := range pb.GetPosts() {
		if !row.GetLikedByViewer() {
			t.Errorf("b's row %s has liked_by_viewer=false on b's own likes list", row.GetPost().GetPostId())
		}
	}
	// a's page-1 token does not open on b's list.
	small, err := r.listLiked(a, 2, "")
	if err != nil || small.GetNextPageToken() == "" {
		t.Fatalf("a small page: %v", err)
	}
	r.enabledFeatures(t, b)
	_, err = r.listLiked(b, 2, small.GetNextPageToken())
	w320Reason(t, "a's token on b's list", err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
}
