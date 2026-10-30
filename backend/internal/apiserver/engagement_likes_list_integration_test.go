//go:build integration

package apiserver

// ListLikedPosts (ADR-0024 D6, ticket W3-10) over the real Build chain on the emulators: paging (25 likes give 20 + a
// token, then 5 + ""), the clamp, the caller-bound token, the drop rules with no pruning, a like removed or repeated
// between two pages, and the budget table of the RPC doc comment (23 reads at page 20, 53 at page 50, 2 for an empty
// array), asserted with budgettest on the logged fs_reads / fs_writes / fs_deletes of the request line. The plan ticket
// named 24 / 54 as the ceiling; ADR-0024 D6 corrected the count to 23 / 53 and the test holds both.
//
// As for bookmarks, the data is written through one chain (the "writer") and read through a second, freshly booted chain
// (the "reader") on the same emulator project, so the reader's instance caches (posts, graph, userLikes, users) are cold,
// which is the worst case the documented budget describes.

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcListLikedPosts = "/dzeroth.engagement.v1.EngagementService/ListLikedPosts"

// likesListChain turns FEATURE_LIKES_LIST and FEATURE_ENGAGEMENT on (the likes are made through the real LikePost) with
// the abuse limits relaxed.
func likesListChain(c *config.Config) {
	c.RateLimit.LikesPerUserPerMinute = 1_000_000
	c.RateLimit.LikesListPerUserPerMinute = 1_000_000
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureLikesList = flags.Spec{Name: "likes_list", Mode: flags.On}
}

func (e *bmChain) listLiked(u bmUser, pageSize int32, token string) (*engagementv1.ListLikedPostsResponse, error) {
	r, err := e.eng.ListLikedPosts(context.Background(), authed(u.token, &engagementv1.ListLikedPostsRequest{PageSize: pageSize, PageToken: token}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *bmChain) like(t *testing.T, u bmUser, postID string) {
	t.Helper()
	if _, err := e.eng.LikePost(context.Background(), authed(u.token, &engagementv1.LikePostRequest{IdempotencyKey: contractKey("lk-like"), PostId: postID})); err != nil {
		t.Fatalf("LikePost: %v", err)
	}
}

func (e *bmChain) unlike(t *testing.T, u bmUser, postID string) {
	t.Helper()
	if _, err := e.eng.UnlikePost(context.Background(), authed(u.token, &engagementv1.UnlikePostRequest{IdempotencyKey: contractKey("lk-unlike"), PostId: postID})); err != nil {
		t.Fatalf("UnlikePost: %v", err)
	}
}

func likedPostIDs(r *engagementv1.ListLikedPostsResponse) []string {
	out := make([]string, 0, len(r.GetPosts()))
	for _, p := range r.GetPosts() {
		out = append(out, p.GetPost().GetPostId())
	}
	return out
}

// reversed returns ids newest first (the like order is oldest first).
func reversed(ids []string) []string {
	out := slices.Clone(ids)
	slices.Reverse(out)
	return out
}

// likeDirect writes userLikes.recent without a request, for seeding at volume (ids oldest first, as the real array).
func (e *bmChain) likeDirect(t *testing.T, uid string, ids []string) {
	t.Helper()
	vals := make([]any, len(ids))
	for i, id := range ids {
		vals[i] = id
	}
	if _, err := e.fs.Doc("userLikes/"+uid).Set(context.Background(), map[string]any{"recent": firestore.ArrayUnion(vals...)}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
}

// 25 likes: the first call returns the 20 most recently liked posts and a token, the second the remaining 5 and "". Cold
// reader: page 1 costs exactly 23 reads (interceptor 1, userLikes 1, GetMany 20, graph 1) and writes nothing.
func TestListLikedPostsChain_PagingAndColdBudget(t *testing.T) {
	w, r := listChains(t, likesListChain)
	author, viewer := w.user(t), w.user(t)
	var liked []string // oldest liked first
	for i := 0; i < 25; i++ {
		id := w.post(t, author, fmt.Sprint("post ", i))
		w.like(t, viewer, id)
		liked = append(liked, id)
	}
	expect := reversed(liked)

	p1, err := r.listLiked(viewer, 0, "")
	if err != nil {
		t.Fatalf("ListLikedPosts: %v", err)
	}
	if got := likedPostIDs(p1); !slices.Equal(got, expect[:20]) || p1.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v token %q; want the 20 most recently liked %v and a token", got, p1.GetNextPageToken(), expect[:20])
	}
	c := r.lineBudget(t, rpcListLikedPosts)
	budgettest.Assert(t, "ListLikedPosts page 20 cold (plan ceiling)", c, budgettest.Budget{Reads: 24})
	budgettest.Assert(t, "ListLikedPosts page 20 cold (ADR-0024 D6)", c, budgettest.Budget{Reads: 23})
	if c.Reads() != 23 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("ListLikedPosts page 20 cold reads/writes/deletes = %d/%d/%d, want exactly 23/0/0", c.Reads(), c.Writes(), c.Deletes())
	}
	// The rows are the live posts with the author snapshot and, with engagement on, the caller's own like.
	first := p1.GetPosts()[0]
	if first.GetPost().GetAuthor().GetUserId() != author.uid || first.GetPost().GetText() != "post 24" {
		t.Errorf("row 0 = %v", first)
	}
	for i, row := range p1.GetPosts() {
		if !row.GetLikedByViewer() {
			t.Errorf("row %d: liked_by_viewer = false on the caller's own likes list", i)
		}
	}
	l := r.line(t, rpcListLikedPosts)
	if l["outcome"] != "done" || num(l, "rows_returned") != 20 || num(l, "rows_dropped") != 0 {
		t.Errorf("request line = %v", l)
	}

	p2, err := r.listLiked(viewer, 0, p1.GetNextPageToken())
	if err != nil {
		t.Fatalf("ListLikedPosts page 2: %v", err)
	}
	if got := likedPostIDs(p2); !slices.Equal(got, expect[20:]) || p2.GetNextPageToken() != "" {
		t.Fatalf("page 2 = %v token %q, want the last 5 and \"\"", got, p2.GetNextPageToken())
	}
	// Warm: the interceptor, userLikes and graph are cached now; only the 5 uncached posts are read.
	c = r.lineBudget(t, rpcListLikedPosts)
	budgettest.Assert(t, "ListLikedPosts page 2 warm", c, budgettest.Budget{Reads: 5})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}
}

// A full page of 50 (page_size 99 is clamped) costs 53 reads cold, and a page that ends exactly at the oldest like has no
// token (no empty trailing page to pay for).
func TestListLikedPostsChain_MaxPageColdBudget(t *testing.T) {
	w, r := listChains(t, likesListChain)
	author, viewer := w.user(t), w.user(t)
	var liked []string
	for i := 0; i < 50; i++ {
		liked = append(liked, w.post(t, author, fmt.Sprint("p", i)))
	}
	w.likeDirect(t, viewer.uid, liked)
	p1, err := r.listLiked(viewer, 99, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := likedPostIDs(p1); !slices.Equal(got, reversed(liked)) || p1.GetNextPageToken() != "" {
		t.Fatalf("page = %d rows, token %q; want all 50 newest first and no token", len(got), p1.GetNextPageToken())
	}
	c := r.lineBudget(t, rpcListLikedPosts)
	budgettest.Assert(t, "ListLikedPosts page 50 cold (plan ceiling)", c, budgettest.Budget{Reads: 54})
	budgettest.Assert(t, "ListLikedPosts page 50 cold (ADR-0024 D6)", c, budgettest.Budget{Reads: 53})
	if c.Reads() != 53 || c.Writes() != 0 {
		t.Errorf("ListLikedPosts page 50 cold reads/writes = %d/%d, want exactly 53/0", c.Reads(), c.Writes())
	}
}

// An empty array (a user who never liked anything, and one who liked and unliked) costs 2 reads cold: the interceptor and
// userLikes. No post, graph or second userLikes read.
func TestListLikedPostsChain_EmptyArrayIsTwoReads(t *testing.T) {
	w, r := listChains(t, likesListChain)
	author, never, undone := w.user(t), w.user(t), w.user(t)
	id := w.post(t, author, "liked then unliked")
	w.like(t, undone, id)
	w.unlike(t, undone, id)
	for name, u := range map[string]bmUser{"never liked": never, "liked then unliked": undone} {
		resp, err := r.listLiked(u, 0, "")
		if err != nil || len(resp.GetPosts()) != 0 || resp.GetNextPageToken() != "" {
			t.Fatalf("%s: %v, %v", name, resp, err)
		}
		c := r.lineBudget(t, rpcListLikedPosts)
		budgettest.Assert(t, "ListLikedPosts empty, "+name, c, budgettest.Budget{Reads: 2})
		if c.Reads() != 2 || c.Writes() != 0 {
			t.Errorf("%s: reads/writes = %d/%d, want 2/0", name, c.Reads(), c.Writes())
		}
	}
}

// A foreign, tampered or cross-list token is INVALID_ARGUMENT VALIDATION page_token and the handler reads nothing: the
// calls below are on a warm interceptor, so the whole request line shows 0 reads.
func TestListLikedPostsChain_ForeignAndTamperedTokens(t *testing.T) {
	w, r := listChains(t, likesListChain)
	author, a, b := w.user(t), w.user(t), w.user(t)
	var liked []string
	for i := 0; i < 3; i++ {
		id := w.post(t, author, fmt.Sprint("x", i))
		w.like(t, a, id)
		w.bookmarkDirect(t, a.uid, id, i)
		liked = append(liked, id)
	}
	pa, err := r.listLiked(a, 2, "")
	if err != nil || pa.GetNextPageToken() == "" {
		t.Fatalf("a's page = %v, %v", pa, err)
	}
	bookmarks, err := r.list(a, 2, "") // ListBookmarks: a token of the other list
	if err != nil || bookmarks.GetNextPageToken() == "" {
		t.Fatalf("a's bookmarks page = %v, %v", bookmarks, err)
	}
	if _, err := r.listLiked(b, 0, ""); err != nil { // warms b's account-status read
		t.Fatal(err)
	}
	tampered := cursortest.Tamper(pa.GetNextPageToken())
	for name, token := range map[string]string{
		"another user's token": pa.GetNextPageToken(), "tampered": tampered, "garbage": "not-a-token",
		"the bookmarks list's token": bookmarks.GetNextPageToken(),
	} {
		_, err := r.listLiked(b, 0, token)
		d := wireError(t, err, connect.CodeInvalidArgument)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if d.GetMetadata()["field"] != "page_token" {
			t.Errorf("%s: metadata = %v, want field=page_token", name, d.GetMetadata())
		}
		budgettest.Assert(t, "ListLikedPosts bad token "+name, r.lineBudget(t, rpcListLikedPosts), budgettest.Budget{})
	}
	// The likes token is no good for ListBookmarks either.
	if _, err := r.list(a, 0, pa.GetNextPageToken()); err == nil {
		t.Error("ListBookmarks accepted a likes token")
	}
	// The token is still good for its owner.
	if p, err := r.listLiked(a, 2, pa.GetNextPageToken()); err != nil || !slices.Equal(likedPostIDs(p), []string{liked[0]}) {
		t.Errorf("owner's page 2 = %v, %v", p, err)
	}
}

// A like removed or repeated between two pages neither skips nor repeats a row (ADR-0024 D6 resume order). The reader
// makes the changes itself, so its userLikes cache sees them, like a real client's next scroll on the same instance.
func TestListLikedPostsChain_ChangesBetweenPages(t *testing.T) {
	tests := []struct {
		name string
		// change runs between page 1 (the 10 newest of 25) and page 2; liked is oldest first. It returns the ids the
		// remaining walk (page 2 on, page size 10) must produce, newest liked first.
		change func(t *testing.T, r *bmChain, v bmUser, liked []string) []string
	}{
		{"nothing changes", func(t *testing.T, r *bmChain, v bmUser, liked []string) []string { return reversed(liked)[10:] }},
		{"the next row is unliked", func(t *testing.T, r *bmChain, v bmUser, liked []string) []string {
			next := reversed(liked)[10]
			r.unlike(t, v, next)
			return slices.DeleteFunc(slices.Clone(reversed(liked)[10:]), func(id string) bool { return id == next })
		}},
		{"the last returned row is unliked", func(t *testing.T, r *bmChain, v bmUser, liked []string) []string {
			r.unlike(t, v, reversed(liked)[9])
			return reversed(liked)[10:]
		}},
		{"the next row is unliked and liked again: it moves to the top, so it is not shown twice", func(t *testing.T, r *bmChain, v bmUser, liked []string) []string {
			next := reversed(liked)[10]
			r.unlike(t, v, next)
			r.like(t, v, next)
			return slices.DeleteFunc(slices.Clone(reversed(liked)[10:]), func(id string) bool { return id == next })
		}},
		{"a row already shown is unliked", func(t *testing.T, r *bmChain, v bmUser, liked []string) []string {
			r.unlike(t, v, reversed(liked)[3])
			return reversed(liked)[10:]
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w, r := listChains(t, likesListChain)
			author, viewer := w.user(t), w.user(t)
			var liked []string
			for i := 0; i < 25; i++ {
				id := w.post(t, author, fmt.Sprint("post ", i))
				w.like(t, viewer, id)
				liked = append(liked, id)
			}
			p1, err := r.listLiked(viewer, 10, "")
			if err != nil || !slices.Equal(likedPostIDs(p1), reversed(liked)[:10]) || p1.GetNextPageToken() == "" {
				t.Fatalf("page 1 = %v token %q err %v", likedPostIDs(p1), p1.GetNextPageToken(), err)
			}
			want := tt.change(t, r, viewer, liked)
			var got []string
			for token := p1.GetNextPageToken(); token != ""; {
				p, err := r.listLiked(viewer, 10, token)
				if err != nil {
					t.Fatalf("next page: %v", err)
				}
				got = append(got, likedPostIDs(p)...)
				token = p.GetNextPageToken()
			}
			if !slices.Equal(got, want) {
				t.Errorf("the rest of the walk = %v\nwant %v", got, want)
			}
		})
	}
}

// The drop rules end to end, and no pruning. v likes seven posts; afterwards one post is deleted, one taken down, one
// author is blocked by v, one muted by v and one author blocks v. The page keeps the live post and v's own; nothing is
// written or deleted (the like path owns the array) and the array still names every post.
func TestListLikedPostsChain_DropRulesAndNoPruning(t *testing.T) {
	ctx := context.Background()
	w, r := listChains(t, likesListChain)
	v, a, x, y, z := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)
	live := w.post(t, a, "live")
	deleted := w.post(t, a, "deleted")
	hidden := w.post(t, a, "hidden")
	byBlocked := w.post(t, x, "by the blocked author")
	byMuted := w.post(t, y, "by the muted author")
	byBlocker := w.post(t, z, "by an author who blocks v")
	own := w.post(t, v, "mine")
	order := []string{live, deleted, hidden, byBlocked, byMuted, byBlocker, own}
	for _, id := range order {
		w.like(t, v, id)
	}
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("lk-del"), PostId: deleted})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.fs.Doc("posts/"+hidden).Set(ctx, map[string]any{"moderation": "TAKEN_DOWN"}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("lk-blk"), UserId: x.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("lk-mute"), UserId: y.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(z.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("lk-blk"), UserId: v.uid})); err != nil {
		t.Fatal(err)
	}
	before := userLikesRecent(t, w, v.uid)

	resp, err := r.listLiked(v, 0, "")
	if err != nil {
		t.Fatalf("ListLikedPosts: %v", err)
	}
	if got, want := likedPostIDs(resp), []string{own, live}; !slices.Equal(got, want) {
		t.Fatalf("rows = %v, want %v (most recently liked first: own, live)", got, want)
	}
	if resp.GetNextPageToken() != "" {
		t.Errorf("token = %q on a page that reached the oldest like", resp.GetNextPageToken())
	}
	l := r.line(t, rpcListLikedPosts)
	for k, want := range map[string]int64{
		"rows_dropped": 5, "rows_dropped_missing": 1, "rows_dropped_hidden": 1, "rows_dropped_blocked": 2, "rows_dropped_muted": 1,
		"rows_returned": 2,
	} {
		if got := num(l, k); got != want {
			t.Errorf("%s = %d, want %d", k, got, want)
		}
	}
	if _, ok := l["rows_pruned"]; ok {
		t.Errorf("request line carries rows_pruned: %v", l)
	}
	// Interceptor 1 + userLikes 1 + GetMany 7 + graph 1 = 10 reads, and no write or delete at all.
	c := r.lineBudget(t, rpcListLikedPosts)
	budgettest.Assert(t, "ListLikedPosts with dropped rows", c, budgettest.Budget{Reads: 10})
	if c.Reads() != 10 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 10/0/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if after := userLikesRecent(t, w, v.uid); !slices.Equal(after, before) || len(after) != 7 {
		t.Errorf("userLikes.recent = %v, want it untouched %v", after, before)
	}

	// Unblocking brings the blocked author's row back without any re-like.
	if _, err := w.graph.Unblock(ctx, authed(v.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("lk-unblk"), UserId: x.uid})); err != nil {
		t.Fatal(err)
	}
	r2 := newBMChain(t, likesListChain)
	resp, err = r2.listLiked(v, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := likedPostIDs(resp), []string{own, byBlocked, live}; !slices.Equal(got, want) {
		t.Errorf("after the unblock rows = %v, want %v", got, want)
	}
}

func userLikesRecent(t *testing.T, e *bmChain, uid string) []string {
	t.Helper()
	snap, err := e.fs.Doc("userLikes/" + uid).Get(context.Background())
	if err != nil {
		return nil
	}
	v, _ := snap.DataAt("recent")
	var out []string
	if arr, ok := v.([]any); ok {
		for _, x := range arr {
			out = append(out, fmt.Sprint(x))
		}
	}
	return out
}
