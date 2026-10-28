//go:build integration

package apiserver

// AddBookmark / RemoveBookmark (ADR-0023, ticket W2-3) over the real Build chain on the emulators: the transaction's
// documents, replay, the cap and the quota, visibility (byte-identical to GetPost), REPOST resolution, and the
// budget table of the RPC doc comments (Add 7 reads / 4 writes, Remove 2 reads / 2 writes / 1 delete), asserted with
// budgettest on the logged fs_reads / fs_writes / fs_deletes of the request line.

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

const (
	rpcAddBookmark    = "/dzeroth.engagement.v1.EngagementService/AddBookmark"
	rpcRemoveBookmark = "/dzeroth.engagement.v1.EngagementService/RemoveBookmark"
)

// bookmarksOn turns FEATURE_BOOKMARKS on with the abuse limits relaxed (the loopback seeding would trip them) and
// leaves FEATURE_ENGAGEMENT at its default, off: bookmarks must not depend on it.
func bookmarksOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.BookmarksPerUserPerMinute = 1_000_000
	c.RateLimit.BookmarksListPerUserPerMinute = 1_000_000
	c.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.On}
}

type bmUser struct{ token, uid string }

type bmChain struct {
	*chainEnv
	eng   engagementv1connect.EngagementServiceClient
	graph graphv1connect.GraphServiceClient
}

func newBMChain(t *testing.T, mutate func(*config.Config)) *bmChain {
	t.Helper()
	env := newChain(t, func(c *config.Config) {
		bookmarksOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &bmChain{
		chainEnv: env,
		eng:      engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
}

func (e *bmChain) user(t *testing.T) bmUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	e.createProfile(t, tok)
	return bmUser{tok, uid}
}

func (e *bmChain) post(t *testing.T, u bmUser, text string) string {
	t.Helper()
	r, err := e.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bm-post"), Text: text}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

func (e *bmChain) add(u bmUser, key, postID string) (*engagementv1.BookmarkState, error) {
	r, err := e.eng.AddBookmark(context.Background(), authed(u.token, &engagementv1.AddBookmarkRequest{IdempotencyKey: key, PostId: postID}))
	if err != nil {
		return nil, err
	}
	return r.Msg.GetState(), nil
}

func (e *bmChain) remove(u bmUser, key, postID string) (*engagementv1.BookmarkState, error) {
	r, err := e.eng.RemoveBookmark(context.Background(), authed(u.token, &engagementv1.RemoveBookmarkRequest{IdempotencyKey: key, PostId: postID}))
	if err != nil {
		return nil, err
	}
	return r.Msg.GetState(), nil
}

// lineBudget is the last logged request line of rpc as a budget.Counter, so budgettest.Assert can check it.
func (e *chainEnv) lineBudget(t *testing.T, rpc string) *budget.Counter {
	t.Helper()
	lines := e.logs.requestLines(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	l := lines[len(lines)-1]
	num := func(k string) int64 { v, _ := l[k].(float64); return int64(v) }
	c := &budget.Counter{}
	c.AddReads(num("fs_reads"))
	c.AddWrites(num("fs_writes"))
	c.AddDeletes(num("fs_deletes"))
	t.Logf("BUDGET %s reads=%d writes=%d deletes=%d outcome=%v", rpc, c.Reads(), c.Writes(), c.Deletes(), l["outcome"])
	return c
}

func (e *bmChain) lastOutcome(rpc string) string {
	lines := e.logs.requestLines(rpc)
	if len(lines) == 0 {
		return ""
	}
	s, _ := lines[len(lines)-1]["outcome"].(string)
	return s
}

func (e *bmChain) bookmarkIDs(t *testing.T, uid string) []string {
	t.Helper()
	snap, err := e.fs.Doc("userLikes/" + uid).Get(context.Background())
	if err != nil {
		return nil
	}
	v, _ := snap.DataAt("bookmarks")
	var out []string
	if arr, ok := v.([]any); ok {
		for _, x := range arr {
			out = append(out, fmt.Sprint(x))
		}
	}
	return out
}

func (e *bmChain) bookmarkDocExists(t *testing.T, uid, postID string) bool {
	t.Helper()
	return fsDocExists(t, e.fs, "users/"+uid+"/bookmarks/"+postID)
}

func (e *bmChain) quotaUsed(t *testing.T, uid string) int64 {
	t.Helper()
	snap, err := e.fs.Doc("quotas/" + uid).Get(context.Background())
	if err != nil {
		return 0
	}
	v, _ := snap.DataAt("bookmarks")
	n, _ := v.(int64)
	return n
}

func TestBookmarksChain_AddRemoveLifecycleAndBudget(t *testing.T) {
	ctx := context.Background()
	e := newBMChain(t, nil)
	a, b := e.user(t), e.user(t)
	pid := e.post(t, a, "bookmark me")
	addKey, rmKey := contractKey("bm-add"), contractKey("bm-rm")

	// Seed a like on B's userLikes: every bookmark write must leave it alone (field-level writes only), and with
	// FEATURE_ENGAGEMENT off it must never reach a response as liked_by_viewer.
	if _, err := e.fs.Doc("userLikes/"+b.uid).Set(ctx, map[string]any{"recent": []string{pid}}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}

	// First add: 7 reads (interceptor 1, visibility 3, idempotency, quotas, userLikes), 4 writes.
	st, err := e.add(b, addKey, pid)
	if err != nil || st.GetPostId() != pid || !st.GetBookmarked() {
		t.Fatalf("AddBookmark = %v, %v", st, err)
	}
	budgettest.Assert(t, "AddBookmark", e.lineBudget(t, rpcAddBookmark), budgettest.Budget{Reads: 7, Writes: 4})
	if w := e.lineBudget(t, rpcAddBookmark).Writes(); w != 4 {
		t.Errorf("AddBookmark writes = %d, want exactly 4 (bookmark, idempotency, quotas, userLikes)", w)
	}
	if got := e.lastOutcome(rpcAddBookmark); got != "done" {
		t.Errorf("outcome = %q, want done", got)
	}
	if !e.bookmarkDocExists(t, b.uid, pid) {
		t.Fatal("users/{uid}/bookmarks/{postId} not created")
	}
	snap, _ := e.fs.Doc("users/" + b.uid + "/bookmarks/" + pid).Get(ctx)
	if d := snap.Data(); len(d) != 1 || d["createdAt"] == nil {
		t.Errorf("bookmark doc = %v, want exactly {createdAt}: no copy of the post", d)
	}
	if ids := e.bookmarkIDs(t, b.uid); len(ids) != 1 || ids[0] != pid {
		t.Errorf("userLikes.bookmarks = %v, want [%s]", ids, pid)
	}
	if rec, _ := e.fs.Doc("userLikes/" + b.uid).Get(ctx); rec == nil {
		t.Fatal("userLikes missing")
	} else if v, _ := rec.DataAt("recent"); fmt.Sprint(v) != "["+pid+"]" {
		t.Errorf("userLikes.recent = %v after AddBookmark, want [%s]: a bookmark write must be field-level", v, pid)
	}
	if got := e.quotaUsed(t, b.uid); got != 1 {
		t.Errorf("quotas.bookmarks = %d, want 1", got)
	}
	idemID := idempotency.Key(b.uid, "AddBookmark", addKey)
	if snap, err := e.fs.Doc("idempotency/" + idemID).Get(ctx); err != nil {
		t.Errorf("idempotency doc: %v", err)
	} else if exp, _ := snap.DataAt("expireAt"); exp == nil {
		t.Error("idempotency doc has no expireAt (TTL)")
	}

	// A bookmark is invisible to the post's author: nothing was written under the author or the post.
	if n, _ := e.fs.Collection("users").Doc(a.uid).Collection("bookmarks").Documents(ctx).GetAll(); len(n) != 0 {
		t.Errorf("author has %d bookmark docs", len(n))
	}

	// GetPost for B: with FEATURE_ENGAGEMENT off the like in userLikes must not surface, bookmarks on or not.
	gp, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid}))
	if err != nil || gp.Msg.GetPost().GetLikedByViewer() || gp.Msg.GetPost().GetRepostedByViewer() {
		t.Fatalf("GetPost with engagement off = %v, %v: liked/reposted flags must stay false", gp, err)
	}
	// ... but the bookmark itself is on the wire (bookmarks-only hydration, ADR-0023 D3/D5), only for the caller who
	// made it: the author sees false for the same post.
	if !gp.Msg.GetPost().GetBookmarkedByViewer() {
		t.Fatalf("GetPost bookmarked_by_viewer = false for the caller's bookmark, want true: %v", gp)
	}
	if ga, err := e.posts.GetPost(ctx, authed(a.token, &postsv1.GetPostRequest{PostId: pid})); err != nil || ga.Msg.GetPost().GetBookmarkedByViewer() {
		t.Fatalf("GetPost by the author = %v, %v: another user's bookmark must not show", ga, err)
	}
	// The timelines carry it too: the author's profile timeline as seen by B, liked/reposted still false.
	if ut, err := e.timeline.GetUserTimeline(ctx, authed(b.token, &timelinev1.GetUserTimelineRequest{UserId: a.uid, PageSize: 10})); err != nil ||
		len(ut.Msg.GetPosts()) != 1 || !ut.Msg.GetPosts()[0].GetBookmarkedByViewer() ||
		ut.Msg.GetPosts()[0].GetLikedByViewer() || ut.Msg.GetPosts()[0].GetRepostedByViewer() {
		t.Fatalf("GetUserTimeline = %v, %v: want bookmarked_by_viewer only", ut, err)
	}

	// Replay: the stored state, 5 reads at most and 0 writes.
	st, err = e.add(b, addKey, pid)
	if err != nil || !st.GetBookmarked() {
		t.Fatalf("AddBookmark replay = %v, %v", st, err)
	}
	budgettest.Assert(t, "AddBookmark replay", e.lineBudget(t, rpcAddBookmark), budgettest.Budget{Reads: 5})
	if got := e.lastOutcome(rpcAddBookmark); got != "replay" {
		t.Errorf("replay outcome = %q", got)
	}

	// The same key for another post is IDEMPOTENCY_KEY_REUSED.
	other := e.post(t, a, "another")
	_, err = e.add(b, addKey, other)
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	// ... and a post B never bookmarked is false.
	if go1, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: other})); err != nil || go1.Msg.GetPost().GetBookmarkedByViewer() {
		t.Fatalf("GetPost of a post outside the set = %v, %v: bookmarked_by_viewer must be false", go1, err)
	}

	// A fresh key for the bookmarked post: success, 1 write (the idempotency doc), no quota charge.
	st, err = e.add(b, contractKey("bm-add"), pid)
	if err != nil || !st.GetBookmarked() || st.GetPostId() != pid {
		t.Fatalf("AddBookmark existing = %v, %v", st, err)
	}
	budgettest.Assert(t, "AddBookmark existing", e.lineBudget(t, rpcAddBookmark), budgettest.Budget{Reads: 7, Writes: 1})
	if got := e.quotaUsed(t, b.uid); got != 1 {
		t.Errorf("quotas.bookmarks = %d after an existing add, want 1", got)
	}

	// Remove: 2 reads (interceptor, idempotency), 2 writes (idempotency doc, userLikes) and 1 delete.
	st, err = e.remove(b, rmKey, pid)
	if err != nil || st.GetBookmarked() || st.GetPostId() != pid {
		t.Fatalf("RemoveBookmark = %v, %v", st, err)
	}
	budgettest.Assert(t, "RemoveBookmark", e.lineBudget(t, rpcRemoveBookmark), budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})
	if c := e.lineBudget(t, rpcRemoveBookmark); c.Writes() != 2 || c.Deletes() != 1 {
		t.Errorf("RemoveBookmark writes/deletes = %d/%d, want 2/1", c.Writes(), c.Deletes())
	}
	if e.bookmarkDocExists(t, b.uid, pid) || len(e.bookmarkIDs(t, b.uid)) != 0 {
		t.Error("bookmark or its array entry survived RemoveBookmark")
	}
	// The viewer set follows the write (the instance cache is updated from it): the removed bookmark reads false.
	if gr, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid})); err != nil || gr.Msg.GetPost().GetBookmarkedByViewer() {
		t.Fatalf("GetPost after RemoveBookmark = %v, %v: bookmarked_by_viewer must be false", gr, err)
	}
	if rec, _ := e.fs.Doc("userLikes/" + b.uid).Get(ctx); rec != nil {
		if v, _ := rec.DataAt("recent"); fmt.Sprint(v) != "["+pid+"]" {
			t.Errorf("userLikes.recent = %v after RemoveBookmark, want [%s]", v, pid)
		}
	}

	// Replay after Remove: the stored state, 0 writes, the bookmark does not come back; Add's replay, too, returns
	// its stored bookmarked=true without re-creating anything (a late retry never undoes or redoes a newer toggle).
	st, err = e.remove(b, rmKey, pid)
	if err != nil || st.GetBookmarked() {
		t.Fatalf("RemoveBookmark replay = %v, %v", st, err)
	}
	budgettest.Assert(t, "RemoveBookmark replay", e.lineBudget(t, rpcRemoveBookmark), budgettest.Budget{Reads: 2})
	st, err = e.add(b, addKey, pid)
	if err != nil || !st.GetBookmarked() {
		t.Fatalf("AddBookmark replay after remove = %v, %v", st, err)
	}
	if e.bookmarkDocExists(t, b.uid, pid) {
		t.Fatal("a replayed Add re-created a removed bookmark")
	}

	// Add again and remove with a replayed Remove key: the late retry must not remove the newer bookmark.
	if _, err := e.add(b, contractKey("bm-add"), pid); err != nil {
		t.Fatal(err)
	}
	if _, err := e.remove(b, rmKey, pid); err != nil {
		t.Fatal(err)
	}
	if !e.bookmarkDocExists(t, b.uid, pid) {
		t.Fatal("a replayed Remove deleted a bookmark that was added again after it")
	}

	// Remove of something never bookmarked: a no-op, 1 write (the idempotency doc), 0 deletes.
	st, err = e.remove(b, contractKey("bm-rm"), other)
	if err != nil || st.GetBookmarked() {
		t.Fatalf("RemoveBookmark no-op = %v, %v", st, err)
	}
	budgettest.Assert(t, "RemoveBookmark no-op", e.lineBudget(t, rpcRemoveBookmark), budgettest.Budget{Reads: 2, Writes: 1})
	if got := e.lastOutcome(rpcRemoveBookmark); got != "noop" {
		t.Errorf("no-op outcome = %q", got)
	}
}

// A post the caller cannot see is the one NOT_FOUND GetPost answers, byte for byte, and writes nothing; a deleted
// post too; Remove still works for a post that became invisible.
func TestBookmarksChain_VisibilityMatchesGetPost(t *testing.T) {
	ctx := context.Background()
	e := newBMChain(t, nil)
	a, b := e.user(t), e.user(t)
	blocked := e.post(t, a, "x")
	deleted := e.post(t, a, "y")
	visible := e.post(t, a, "z")

	if _, err := e.add(b, contractKey("bm-add"), visible); err != nil {
		t.Fatal(err)
	}
	if _, err := e.add(b, contractKey("bm-add"), blocked); err != nil {
		t.Fatal(err)
	}
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: deleted})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.graph.Block(ctx, authed(a.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: b.uid})); err != nil {
		t.Fatal(err)
	}
	before := e.quotaUsed(t, b.uid)

	for name, id := range map[string]string{"deleted": deleted, "author blocks the caller": visible, "never existed": "1234567890123456789"} {
		_, getErr := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: id}))
		_, addErr := e.add(b, contractKey("bm-add"), id)
		want, got := wireError(t, getErr, connect.CodeNotFound), wireError(t, addErr, connect.CodeNotFound)
		if want.GetMessage() != got.GetMessage() || want.GetReason() != got.GetReason() || fmt.Sprint(want.GetMetadata()) != fmt.Sprint(got.GetMetadata()) {
			t.Errorf("%s: AddBookmark error %v differs from GetPost's %v", name, got, want)
		}
		if got.GetMessage() != "post not found" {
			t.Errorf("%s: message = %q", name, got.GetMessage())
		}
	}
	if after := e.quotaUsed(t, b.uid); after != before {
		t.Errorf("quota %d -> %d: a refused add was charged", before, after)
	}
	// Remove needs no visibility: the blocked author's post can still be removed.
	if _, err := e.remove(b, contractKey("bm-rm"), blocked); err != nil {
		t.Fatalf("RemoveBookmark of a post that became invisible: %v", err)
	}
	if e.bookmarkDocExists(t, b.uid, blocked) {
		t.Error("the bookmark of the invisible post survived RemoveBookmark")
	}
}

// The cap is exact (from the array length), an existing bookmark at the cap is still a success, and the daily quota
// answers QUOTA_EXCEEDED quota=bookmarks without charging a replay or an existing bookmark.
func TestBookmarksChain_CapAndQuota(t *testing.T) {
	t.Run("cap", func(t *testing.T) {
		e := newBMChain(t, func(c *config.Config) { c.Quota.BookmarksMaxPerUser = 2 })
		a, b := e.user(t), e.user(t)
		p1, p2, p3 := e.post(t, a, "1"), e.post(t, a, "2"), e.post(t, a, "3")
		for _, p := range []string{p1, p2} {
			if _, err := e.add(b, contractKey("bm-add"), p); err != nil {
				t.Fatal(err)
			}
		}
		_, err := e.add(b, contractKey("bm-add"), p3)
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
		if d.GetMetadata()["limit"] != "bookmarks" {
			t.Errorf("metadata = %v, want limit=bookmarks", d.GetMetadata())
		}
		budgettest.Assert(t, "AddBookmark at the cap", e.lineBudget(t, rpcAddBookmark), budgettest.Budget{Reads: 7})
		if w := e.lineBudget(t, rpcAddBookmark).Writes(); w != 0 {
			t.Errorf("writes at the cap = %d, want 0", w)
		}
		if _, err := e.add(b, contractKey("bm-add"), p1); err != nil {
			t.Errorf("an existing bookmark at the cap must still succeed: %v", err)
		}
		if _, err := e.remove(b, contractKey("bm-rm"), p1); err != nil {
			t.Fatal(err)
		}
		if _, err := e.add(b, contractKey("bm-add"), p3); err != nil {
			t.Errorf("after a remove there is room again: %v", err)
		}
	})

	t.Run("quota, new-account window", func(t *testing.T) {
		e := newBMChain(t, func(c *config.Config) { c.Quota.BookmarksPerDay, c.Quota.NewAccountBookmarksPerDay = 5, 2 })
		a, b := e.user(t), e.user(t) // both accounts are minutes old: the 2/day new-account quota applies
		p1, p2, p3 := e.post(t, a, "1"), e.post(t, a, "2"), e.post(t, a, "3")
		k1 := contractKey("bm-add")
		for i, p := range []string{p1, p2} {
			key := contractKey("bm-add")
			if i == 0 {
				key = k1
			}
			if _, err := e.add(b, key, p); err != nil {
				t.Fatal(err)
			}
		}
		_, err := e.add(b, contractKey("bm-add"), p3)
		d := wireError(t, err, connect.CodeResourceExhausted)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		if d.GetMetadata()["quota"] != "bookmarks" {
			t.Errorf("metadata = %v, want quota=bookmarks", d.GetMetadata())
		}
		// A replay and an existing bookmark are not charged, so they still succeed at the quota.
		if _, err := e.add(b, k1, p1); err != nil {
			t.Errorf("replay at the quota: %v", err)
		}
		if _, err := e.add(b, contractKey("bm-add"), p2); err != nil {
			t.Errorf("existing bookmark at the quota: %v", err)
		}
		// Remove is never quota-gated.
		if _, err := e.remove(b, contractKey("bm-rm"), p1); err != nil {
			t.Errorf("remove at the quota: %v", err)
		}
		if got := e.quotaUsed(t, b.uid); got != 2 {
			t.Errorf("quotas.bookmarks = %d, want 2", got)
		}
	})

	t.Run("quota, established account gets the daily limit", func(t *testing.T) {
		e := newBMChain(t, func(c *config.Config) {
			c.Quota.BookmarksPerDay, c.Quota.NewAccountBookmarksPerDay = 3, 1
			c.Quota.NewAccountWindow = time.Nanosecond // every account is already "established"
		})
		a, b := e.user(t), e.user(t)
		time.Sleep(5 * time.Millisecond)
		for i := 0; i < 3; i++ {
			if _, err := e.add(b, contractKey("bm-add"), e.post(t, a, fmt.Sprint(i))); err != nil {
				t.Fatalf("add %d: %v", i, err)
			}
		}
		_, err := e.add(b, contractKey("bm-add"), e.post(t, a, "over"))
		assertReason(t, wireError(t, err, connect.CodeResourceExhausted), commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
	})
}

// A retry storm (ten requests carrying the same key) and a double tap of different posts, concurrently, by one user:
// the same key never charges the quota twice or adds the id twice, and for different posts the transactions on the
// user's quotas and userLikes docs serialise; a caller that gives up under contention gets an error (the client
// retries), never a corrupted set. The invariant is consistency: array == quota == bookmark docs.
func TestBookmarksChain_ConcurrentAddsStayConsistent(t *testing.T) {
	e := newBMChain(t, nil)
	a, b, c := e.user(t), e.user(t), e.user(t)
	ids := make([]string, 4)
	for i := range ids {
		ids[i] = e.post(t, a, fmt.Sprint("p", i))
	}
	run := func(u bmUser, n int, key func(i int) string, post func(i int) string) {
		errs := make([]error, n)
		var wg sync.WaitGroup
		for i := range errs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, errs[i] = e.add(u, key(i), post(i))
			}()
		}
		wg.Wait()
	}
	sameKey := contractKey("bm-conc")
	run(b, 10, func(int) string { return sameKey }, func(int) string { return ids[0] })
	if n, q := len(e.bookmarkIDs(t, b.uid)), e.quotaUsed(t, b.uid); n != 1 || q != 1 {
		t.Errorf("one key: array %d, quota %d, want 1/1", n, q)
	}
	run(c, len(ids), func(int) string { return contractKey("bm-conc") }, func(i int) string { return ids[i] })
	// A call that timed out on the client may still have committed, so the reference is the bookmark docs themselves.
	docs := 0
	for _, id := range ids {
		if e.bookmarkDocExists(t, c.uid, id) {
			docs++
		}
	}
	if n, q := len(e.bookmarkIDs(t, c.uid)), e.quotaUsed(t, c.uid); n != docs || q != int64(docs) {
		t.Errorf("distinct posts: %d bookmark docs, array %d, quota %d, want all three equal", docs, n, q)
	}
}

// A REPOST id bookmarks the original (with FEATURE_ENGAGEMENT on, which RepostPost needs); with it on the viewer state
// is hydrated and the flags describe the original.
func TestBookmarksChain_RepostResolvesToOriginal(t *testing.T) {
	ctx := context.Background()
	e := newBMChain(t, func(c *config.Config) {
		c.RateLimit.LikesPerUserPerMinute = 1_000_000
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	})
	a, b, c := e.user(t), e.user(t), e.user(t)
	pid := e.post(t, a, "original")
	rp, err := e.eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("bm-rp"), PostId: pid}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()

	st, err := e.add(c, contractKey("bm-add"), repostID)
	if err != nil || st.GetPostId() != pid || !st.GetBookmarked() {
		t.Fatalf("AddBookmark(REPOST id) = %v, %v, want the original %s", st, err, pid)
	}
	budgettest.Assert(t, "AddBookmark(REPOST id)", e.lineBudget(t, rpcAddBookmark), budgettest.Budget{Reads: 7 + 2, Writes: 4})
	if !e.bookmarkDocExists(t, c.uid, pid) || e.bookmarkDocExists(t, c.uid, repostID) {
		t.Error("the bookmark must be keyed by the original's id, never the REPOST's")
	}
	// Removing by the returned id works; removing by the REPOST id is a no-op.
	if _, err := e.remove(c, contractKey("bm-rm"), repostID); err != nil || !e.bookmarkDocExists(t, c.uid, pid) {
		t.Fatalf("RemoveBookmark(REPOST id) must be a no-op: %v", err)
	}
	if _, err := e.remove(c, contractKey("bm-rm"), st.GetPostId()); err != nil || e.bookmarkDocExists(t, c.uid, pid) {
		t.Fatalf("RemoveBookmark(original): %v", err)
	}
}
