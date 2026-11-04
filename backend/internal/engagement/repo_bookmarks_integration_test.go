//go:build integration

package engagement

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const bmUID = "bm-user"

func addParams(uid, key, postID string) AddBookmarkParams {
	return AddBookmarkParams{
		UID: uid, PostID: postID, IdemKey: idempotency.Key(uid, "AddBookmark", key),
		RequestHash: bookmarkRequestHash(postID), MaxPerUser: 1000,
	}
}

func rmParams(uid, key, postID string) RemoveBookmarkParams {
	return RemoveBookmarkParams{UID: uid, PostID: postID, IdemKey: idempotency.Key(uid, "RemoveBookmark", key), RequestHash: bookmarkRequestHash(postID)}
}

func (e *repoEnv) bookmarks(t *testing.T, uid string) []string {
	t.Helper()
	s, err := e.client.Doc("userLikes/" + uid).Get(context.Background())
	if err != nil {
		return nil
	}
	v, _ := s.DataAt("bookmarks")
	var out []string
	if arr, ok := v.([]any); ok {
		for _, x := range arr {
			out = append(out, fmt.Sprint(x))
		}
	}
	return out
}

func (e *repoEnv) bookmarkExists(t *testing.T, uid, postID string) bool {
	t.Helper()
	return e.exists(t, "users/"+uid+"/bookmarks/"+postID)
}

func (e *repoEnv) quotaBookmarks(t *testing.T, uid string) int64 {
	t.Helper()
	s, err := e.client.Doc("quotas/" + uid).Get(context.Background())
	if err != nil {
		return 0
	}
	v, _ := s.DataAt("bookmarks")
	n, _ := v.(int64)
	return n
}

// The Add transaction writes the bookmark, the userLikes array and the idempotency doc; every userLikes write keeps the other
// fields (field-level userLikes), and a legacy quotas doc is neither read for a limit nor written.
func TestBookmarkRepo_AddWritesThreeDocsAndKeepsTheRest(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid = "0000000000000000101"
	if _, err := e.client.Doc("userLikes/"+bmUID).Set(ctx, map[string]any{"recent": []string{"9"}, "recentReposts": []string{"8"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Doc("quotas/"+bmUID).Set(ctx, map[string]any{"day": quota.Today(), "likes": int64(7), "bookmarks": int64(200)}); err != nil {
		t.Fatal(err)
	}

	res, err := e.repo.Add(context.Background(), addParams(bmUID, "key-0000000000001", pid))
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != BookmarkWritten || res.State != (BookmarkState{PostID: pid, Bookmarked: true}) {
		t.Fatalf("result = %+v", res)
	}
	if ids := e.bookmarks(t, bmUID); len(ids) != 1 || ids[0] != pid {
		t.Errorf("userLikes.bookmarks = %v", ids)
	}
	snap, _ := e.client.Doc("userLikes/" + bmUID).Get(ctx)
	if v, _ := snap.DataAt("recent"); fmt.Sprint(v) != "[9]" {
		t.Errorf("userLikes.recent = %v: Add must not touch it", v)
	}
	if v, _ := snap.DataAt("recentReposts"); fmt.Sprint(v) != "[8]" {
		t.Errorf("userLikes.recentReposts = %v: Add must not touch it", v)
	}
	if got := e.quotaBookmarks(t, bmUID); got != 200 {
		t.Errorf("quotas.bookmarks = %d, want the seeded 200 untouched (no daily quota)", got)
	}
	b, _ := e.client.Doc("users/" + bmUID + "/bookmarks/" + pid).Get(ctx)
	if d := b.Data(); len(d) != 1 || d["createdAt"] == nil {
		t.Errorf("bookmark doc = %v, want exactly {createdAt}", d)
	}
	idem, err := e.client.Doc("idempotency/" + idempotency.Key(bmUID, "AddBookmark", "key-0000000000001")).Get(ctx)
	if err != nil {
		t.Fatalf("idempotency doc: %v", err)
	}
	if exp, _ := idem.DataAt("expireAt"); exp == nil {
		t.Error("idempotency doc has no expireAt")
	}
}

func TestBookmarkRepo_ReplayExistingCapQuotaAndKeyReuse(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const p1, p2 = "0000000000000000111", "0000000000000000112"

	if _, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", p1)); err != nil {
		t.Fatal(err)
	}

	t.Run("replay: the stored state, nothing written", func(t *testing.T) {
		res, err := e.repo.Add(context.Background(), addParams(bmUID, "key-0000000000001", p1))
		if err != nil || res.Outcome != BookmarkReplayed || !res.State.Bookmarked {
			t.Fatalf("replay = %+v, %v", res, err)
		}
		if len(e.bookmarks(t, bmUID)) != 1 {
			t.Errorf("a replay changed state: bookmarks %v", e.bookmarks(t, bmUID))
		}
	})

	t.Run("existing bookmark under a new key: success, the idempotency doc is stored", func(t *testing.T) {
		res, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000002", p1))
		if err != nil || res.Outcome != BookmarkUnchanged || !res.State.Bookmarked {
			t.Fatalf("existing = %+v, %v", res, err)
		}
		if !e.exists(t, "idempotency/"+idempotency.Key(bmUID, "AddBookmark", "key-0000000000002")) {
			t.Error("existing: the idempotency doc was not stored")
		}
	})

	t.Run("the doc exists but the array lost it: AlreadyExists at commit is success with the idempotency doc stored", func(t *testing.T) {
		const uid = "bm-drift"
		if _, err := e.client.Doc("users/"+uid+"/bookmarks/"+p2).Set(ctx, map[string]any{"createdAt": firestore.ServerTimestamp}); err != nil {
			t.Fatal(err)
		}
		res, err := e.repo.Add(ctx, addParams(uid, "key-0000000000003", p2))
		if err != nil || res.Outcome != BookmarkUnchanged {
			t.Fatalf("drift = %+v, %v", res, err)
		}
		if !e.exists(t, "idempotency/"+idempotency.Key(uid, "AddBookmark", "key-0000000000003")) {
			t.Error("the idempotency doc was not stored")
		}
	})

	t.Run("a key reused for another post is ErrIdempotencyKeyReused", func(t *testing.T) {
		_, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", p2))
		if !errors.Is(err, ErrIdempotencyKeyReused) {
			t.Fatalf("err = %v, want ErrIdempotencyKeyReused", err)
		}
	})

	t.Run("the cap is exact: at the cap a new post is refused and nothing is written, an existing one succeeds", func(t *testing.T) {
		const uid = "bm-cap"
		ids := make([]string, 1000)
		for i := range ids {
			ids[i] = fmt.Sprintf("%019d", 5000+i)
		}
		if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": ids}); err != nil {
			t.Fatal(err)
		}
		if _, err := e.repo.Add(context.Background(), addParams(uid, "key-0000000000004", p2)); !errors.Is(err, ErrBookmarkLimit) {
			t.Fatalf("err = %v, want ErrBookmarkLimit", err)
		}
		if e.bookmarkExists(t, uid, p2) || len(e.bookmarks(t, uid)) != 1000 || e.exists(t, "idempotency/"+idempotency.Key(uid, "AddBookmark", "key-0000000000004")) {
			t.Error("a refusal at the cap wrote something")
		}
		res, err := e.repo.Add(ctx, addParams(uid, "key-0000000000005", ids[17]))
		if err != nil || res.Outcome != BookmarkUnchanged {
			t.Fatalf("existing at the cap = %+v, %v", res, err)
		}
		// 999 entries: one more fits (the 1,000th), the next one does not.
		if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": ids[:999]}); err != nil {
			t.Fatal(err)
		}
		if res, err := e.repo.Add(ctx, addParams(uid, "key-0000000000006", p2)); err != nil || res.Outcome != BookmarkWritten {
			t.Fatalf("1,000th = %+v, %v", res, err)
		}
		if _, err := e.repo.Add(ctx, addParams(uid, "key-0000000000007", p1)); !errors.Is(err, ErrBookmarkLimit) {
			t.Fatalf("1,001st err = %v, want ErrBookmarkLimit", err)
		}
	})

}

// Remove: a missing bookmark rolls the transaction back and records only its idempotency
// doc; a replay answers the stored state and never undoes a bookmark added since.
func TestBookmarkRepo_Remove(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid, other = "0000000000000000121", "0000000000000000122"
	if _, err := e.client.Doc("userLikes/"+bmUID).Set(ctx, map[string]any{"recent": []string{"9"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", pid)); err != nil {
		t.Fatal(err)
	}

	res, err := e.repo.Remove(context.Background(), rmParams(bmUID, "key-0000000000002", pid))
	if err != nil || res.Outcome != BookmarkWritten || res.State.Bookmarked {
		t.Fatalf("Remove = %+v, %v", res, err)
	}
	if e.bookmarkExists(t, bmUID, pid) || len(e.bookmarks(t, bmUID)) != 0 {
		t.Error("bookmark or array entry survived")
	}
	snap, _ := e.client.Doc("userLikes/" + bmUID).Get(ctx)
	if v, _ := snap.DataAt("recent"); fmt.Sprint(v) != "[9]" {
		t.Errorf("userLikes.recent = %v: Remove must not touch it", v)
	}

	t.Run("replay after remove: the stored state, nothing written", func(t *testing.T) {
		res, err := e.repo.Remove(context.Background(), rmParams(bmUID, "key-0000000000002", pid))
		if err != nil || res.Outcome != BookmarkReplayed || res.State.Bookmarked {
			t.Fatalf("replay = %+v, %v", res, err)
		}
		if e.bookmarkExists(t, bmUID, pid) || len(e.bookmarks(t, bmUID)) != 0 {
			t.Error("a replay of Remove changed the bookmarks")
		}
	})

	t.Run("a late retry never removes a bookmark added again", func(t *testing.T) {
		if _, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000003", pid)); err != nil {
			t.Fatal(err)
		}
		if res, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000002", pid)); err != nil || res.Outcome != BookmarkReplayed {
			t.Fatalf("late retry = %+v, %v", res, err)
		}
		if !e.bookmarkExists(t, bmUID, pid) || len(e.bookmarks(t, bmUID)) != 1 {
			t.Error("the late retry removed the newer bookmark")
		}
	})

	t.Run("a missing bookmark is a no-op: only the idempotency doc is stored", func(t *testing.T) {
		res, err := e.repo.Remove(context.Background(), rmParams(bmUID, "key-0000000000004", other))
		if err != nil || res.Outcome != BookmarkUnchanged || res.State.Bookmarked {
			t.Fatalf("no-op = %+v, %v", res, err)
		}
		if !e.exists(t, "idempotency/"+idempotency.Key(bmUID, "RemoveBookmark", "key-0000000000004")) {
			t.Error("a no-op did not store its idempotency doc")
		}
	})

	// The scenario the proto promises: a late retry of a no-op key must not undo or redo a newer toggle.
	t.Run("late retry of a Remove no-op never deletes a bookmark added after it", func(t *testing.T) {
		const uid, p = "bm-late-rm", "0000000000000000141"
		if res, err := e.repo.Remove(ctx, rmParams(uid, "key-late-rm-0000001", p)); err != nil || res.Outcome != BookmarkUnchanged {
			t.Fatalf("Remove K (no-op) = %+v, %v", res, err)
		}
		if _, err := e.repo.Add(ctx, addParams(uid, "key-late-add-000001", p)); err != nil {
			t.Fatal(err)
		}
		res, err := e.repo.Remove(ctx, rmParams(uid, "key-late-rm-0000001", p))
		if err != nil || res.Outcome != BookmarkReplayed {
			t.Fatalf("late retry of K = %+v, %v, want a replay", res, err)
		}
		if !e.bookmarkExists(t, uid, p) || len(e.bookmarks(t, uid)) != 1 {
			t.Error("the late retry changed state")
		}
	})

	t.Run("late retry of an Add no-op never re-adds a bookmark removed after it", func(t *testing.T) {
		const uid, p = "bm-late-add", "0000000000000000142"
		if _, err := e.repo.Add(ctx, addParams(uid, "key-late-add-000002", p)); err != nil {
			t.Fatal(err)
		}
		if res, err := e.repo.Add(ctx, addParams(uid, "key-late-add-000003", p)); err != nil || res.Outcome != BookmarkUnchanged {
			t.Fatalf("Add K (no-op) = %+v, %v", res, err)
		}
		if res, err := e.repo.Remove(ctx, rmParams(uid, "key-late-rm-0000002", p)); err != nil || res.Outcome != BookmarkWritten {
			t.Fatalf("Remove = %+v, %v", res, err)
		}
		res, err := e.repo.Add(ctx, addParams(uid, "key-late-add-000003", p))
		if err != nil || res.Outcome != BookmarkReplayed {
			t.Fatalf("late retry of K = %+v, %v, want a replay", res, err)
		}
		if e.bookmarkExists(t, uid, p) || len(e.bookmarks(t, uid)) != 0 {
			t.Error("the late retry re-added the bookmark")
		}
	})

	t.Run("a key reused for another post is ErrIdempotencyKeyReused", func(t *testing.T) {
		if _, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000002", other)); !errors.Is(err, ErrIdempotencyKeyReused) {
			t.Fatalf("err = %v", err)
		}
	})
}

// Concurrent Adds by one user all lock userLikes/{uid}: the transactions serialise, and under heavy
// contention some give up (a deadline or Aborted after the bounded retries) instead of corrupting anything. The
// invariant asserted here is consistency, never "everyone wins": the array and the bookmark docs agree with
// the number of successful writes, and a retry of the same key converges on one bookmark.
func TestBookmarkRepo_ConcurrentAddsStayConsistent(t *testing.T) {
	e := newRepoEnv(t)
	type outcome struct {
		res BookmarkResult
		err error
	}
	run := func(uid string, n int, key func(i int) string, post func(i int) string) []outcome {
		var wg sync.WaitGroup
		outs := make([]outcome, n)
		for i := range outs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				outs[i].res, outs[i].err = e.repo.Add(context.Background(), addParams(uid, key(i), post(i)))
			}()
		}
		wg.Wait()
		return outs
	}

	// Ten retries of the SAME request (one key, one post): at most one write.
	outs := run("bm-same-key", 10, func(int) string { return "key-conc-same-0001" }, func(int) string { return "0000000000000000131" })
	written := 0
	for _, o := range outs {
		if o.err == nil && o.res.Outcome == BookmarkWritten {
			written++
		}
	}
	if n := len(e.bookmarks(t, "bm-same-key")); written > 1 || n != 1 {
		t.Errorf("one key: written %d, array %d, want at most 1 write and 1", written, n)
	}

	// Distinct posts: whatever the contention outcome, the array and the bookmark docs agree with each other.
	outs = run("bm-many", 4, func(i int) string { return fmt.Sprintf("key-conc-many-%04d", i) }, func(i int) string { return fmt.Sprintf("%019d", 200+i) })
	// A call that timed out on the client may still have committed, so the reference is the bookmark docs themselves.
	docs := 0
	for i, o := range outs {
		if exists := e.bookmarkExists(t, "bm-many", fmt.Sprintf("%019d", 200+i)); exists {
			docs++
		} else if o.err == nil {
			t.Errorf("add %d succeeded but its bookmark doc is missing", i)
		}
	}
	if n := len(e.bookmarks(t, "bm-many")); n != docs {
		t.Errorf("distinct posts: %d bookmark docs, array %d: want them equal", docs, n)
	}
}

func TestBookmarkRepo_UnconfiguredRepoFailsWithoutPanicking(t *testing.T) {
	e := newRepoEnv(t)
	bare := NewFirestoreRepo(e.client, WriteDeps{})
	if _, err := bare.Add(context.Background(), addParams(bmUID, "key-0000000000001", "1")); err == nil {
		t.Error("Add on an unconfigured repo must fail")
	}
	if _, err := bare.Remove(context.Background(), rmParams(bmUID, "key-0000000000001", "1")); err == nil {
		t.Error("Remove on an unconfigured repo must fail")
	}
}
