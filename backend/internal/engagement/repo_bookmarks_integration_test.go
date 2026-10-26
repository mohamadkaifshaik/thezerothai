//go:build integration

package engagement

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const bmUID = "bm-user"

func addParams(uid, key, postID string) AddBookmarkParams {
	return AddBookmarkParams{
		UID: uid, PostID: postID, IdemKey: idempotency.Key(uid, "AddBookmark", key),
		RequestHash: bookmarkRequestHash(postID), QuotaLimit: 200, MaxPerUser: 1000,
	}
}

func rmParams(uid, key, postID string) RemoveBookmarkParams {
	return RemoveBookmarkParams{UID: uid, PostID: postID, IdemKey: idempotency.Key(uid, "RemoveBookmark", key), RequestHash: bookmarkRequestHash(postID)}
}

// measured runs fn under a fresh budget counter and asserts it against the documented repo-level budget.
func measured(t *testing.T, name string, b budgettest.Budget, fn func(ctx context.Context)) *budget.Counter {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	fn(ctx)
	budgettest.Assert(t, name, c, b)
	return c
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

// The Add transaction: 3 reads (idempotency, quotas, userLikes) and 4 writes; every userLikes and quota write keeps
// the other fields (field-level userLikes, whole-record quota with every kind).
func TestBookmarkRepo_AddWritesFourDocsAndKeepsTheRest(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid = "0000000000000000101"
	if _, err := e.client.Doc("userLikes/"+bmUID).Set(ctx, map[string]any{"recent": []string{"9"}, "recentReposts": []string{"8"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Doc("quotas/"+bmUID).Set(ctx, quota.Record{Day: quota.Today(), Likes: 7, Posts: 3, Schedules: 2}); err != nil {
		t.Fatal(err)
	}

	var res BookmarkResult
	c := measured(t, "Add", budgettest.Budget{Reads: 3, Writes: 4}, func(ctx context.Context) {
		var err error
		if res, err = e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", pid)); err != nil {
			t.Fatal(err)
		}
	})
	if res.Outcome != BookmarkWritten || res.State != (BookmarkState{PostID: pid, Bookmarked: true}) {
		t.Fatalf("result = %+v", res)
	}
	if c.Reads() != 3 || c.Writes() != 4 || c.Deletes() != 0 {
		t.Errorf("Add reads/writes/deletes = %d/%d/%d, want 3/4/0", c.Reads(), c.Writes(), c.Deletes())
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
	if got := e.quotaBookmarks(t, bmUID); got != 1 {
		t.Errorf("quotas.bookmarks = %d, want 1", got)
	}
	q, _ := e.client.Doc("quotas/" + bmUID).Get(ctx)
	var rec quota.Record
	_ = q.DataTo(&rec)
	if rec.Likes != 7 || rec.Posts != 3 || rec.Schedules != 2 {
		t.Errorf("quota record = %+v: the other kinds must survive the whole-record Set", rec)
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

	t.Run("replay: 1 read, 0 writes, the stored state", func(t *testing.T) {
		measured(t, "Add replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			res, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", p1))
			if err != nil || res.Outcome != BookmarkReplayed || !res.State.Bookmarked {
				t.Fatalf("replay = %+v, %v", res, err)
			}
		})
	})

	t.Run("existing bookmark under a new key: success, 1 write (the idempotency doc), no charge", func(t *testing.T) {
		c := measured(t, "Add existing", budgettest.Budget{Reads: 3, Writes: 1}, func(ctx context.Context) {
			res, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000002", p1))
			if err != nil || res.Outcome != BookmarkUnchanged || !res.State.Bookmarked {
				t.Fatalf("existing = %+v, %v", res, err)
			}
		})
		if c.Writes() != 1 || !e.exists(t, "idempotency/"+idempotency.Key(bmUID, "AddBookmark", "key-0000000000002")) {
			t.Errorf("existing: writes %d, want 1 and the idempotency doc stored", c.Writes())
		}
		if got := e.quotaBookmarks(t, bmUID); got != 1 {
			t.Errorf("quota = %d, want 1", got)
		}
	})

	t.Run("the doc exists but the array lost it: AlreadyExists at commit is success with 1 write (the idempotency doc)", func(t *testing.T) {
		const uid = "bm-drift"
		if _, err := e.client.Doc("users/"+uid+"/bookmarks/"+p2).Set(ctx, map[string]any{"createdAt": firestore.ServerTimestamp}); err != nil {
			t.Fatal(err)
		}
		c := measured(t, "Add drift", budgettest.Budget{Reads: 3, Writes: 1}, func(ctx context.Context) {
			res, err := e.repo.Add(ctx, addParams(uid, "key-0000000000003", p2))
			if err != nil || res.Outcome != BookmarkUnchanged {
				t.Fatalf("drift = %+v, %v", res, err)
			}
		})
		if c.Writes() != 1 || e.quotaBookmarks(t, uid) != 0 || !e.exists(t, "idempotency/"+idempotency.Key(uid, "AddBookmark", "key-0000000000003")) {
			t.Errorf("writes %d quota %d, want 1/0 and the idempotency doc stored", c.Writes(), e.quotaBookmarks(t, uid))
		}
	})

	t.Run("a key reused for another post is ErrIdempotencyKeyReused", func(t *testing.T) {
		_, err := e.repo.Add(ctx, addParams(bmUID, "key-0000000000001", p2))
		if !errors.Is(err, ErrIdempotencyKeyReused) {
			t.Fatalf("err = %v, want ErrIdempotencyKeyReused", err)
		}
	})

	t.Run("the cap is exact: at the cap a new post is refused with 0 writes, an existing one succeeds", func(t *testing.T) {
		const uid = "bm-cap"
		ids := make([]string, 1000)
		for i := range ids {
			ids[i] = fmt.Sprintf("%019d", 5000+i)
		}
		if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": ids}); err != nil {
			t.Fatal(err)
		}
		c := measured(t, "Add at cap", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
			if _, err := e.repo.Add(ctx, addParams(uid, "key-0000000000004", p2)); !errors.Is(err, ErrBookmarkLimit) {
				t.Fatalf("err = %v, want ErrBookmarkLimit", err)
			}
		})
		if c.Writes() != 0 {
			t.Errorf("writes at the cap = %d", c.Writes())
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

	t.Run("the daily quota: QUOTA_EXCEEDED quota=bookmarks, 0 writes; a replay still succeeds", func(t *testing.T) {
		const uid = "bm-quota"
		for i, post := range []string{p1, p2} {
			q := addParams(uid, fmt.Sprintf("key-000000000001%d", i), post)
			q.QuotaLimit = 2
			if _, err := e.repo.Add(ctx, q); err != nil {
				t.Fatalf("add %d: %v", i, err)
			}
		}
		third := addParams(uid, "key-0000000000099", "0000000000000000113")
		third.QuotaLimit = 2
		c := measured(t, "Add over quota", budgettest.Budget{Reads: 3}, func(ctx context.Context) {
			_, err := e.repo.Add(ctx, third)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["quota"] != "bookmarks" {
				t.Fatalf("err = %v, want QUOTA_EXCEEDED quota=bookmarks", err)
			}
		})
		if c.Writes() != 0 {
			t.Errorf("writes over quota = %d", c.Writes())
		}
		first := addParams(uid, "key-0000000000010", p1)
		first.QuotaLimit = 2
		if res, err := e.repo.Add(ctx, first); err != nil || res.Outcome != BookmarkReplayed {
			t.Fatalf("replay at the quota = %+v, %v", res, err)
		}
		if got := e.quotaBookmarks(t, uid); got != 2 {
			t.Errorf("quota = %d, want 2", got)
		}
	})
}

// Remove: 1 read; 2 writes + 1 delete; a missing bookmark rolls the transaction back and records only its idempotency
// doc (1 write); a replay answers the stored state and never undoes a bookmark added since.
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

	c := measured(t, "Remove", budgettest.Budget{Reads: 1, Writes: 2, Deletes: 1}, func(ctx context.Context) {
		res, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000002", pid))
		if err != nil || res.Outcome != BookmarkWritten || res.State.Bookmarked {
			t.Fatalf("Remove = %+v, %v", res, err)
		}
	})
	if c.Reads() != 1 || c.Writes() != 2 || c.Deletes() != 1 {
		t.Errorf("Remove reads/writes/deletes = %d/%d/%d, want 1/2/1", c.Reads(), c.Writes(), c.Deletes())
	}
	if e.bookmarkExists(t, bmUID, pid) || len(e.bookmarks(t, bmUID)) != 0 {
		t.Error("bookmark or array entry survived")
	}
	snap, _ := e.client.Doc("userLikes/" + bmUID).Get(ctx)
	if v, _ := snap.DataAt("recent"); fmt.Sprint(v) != "[9]" {
		t.Errorf("userLikes.recent = %v: Remove must not touch it", v)
	}

	t.Run("replay after remove: stored state, 0 writes", func(t *testing.T) {
		c := measured(t, "Remove replay", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			res, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000002", pid))
			if err != nil || res.Outcome != BookmarkReplayed || res.State.Bookmarked {
				t.Fatalf("replay = %+v, %v", res, err)
			}
		})
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("replay writes/deletes = %d/%d", c.Writes(), c.Deletes())
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

	t.Run("a missing bookmark is a no-op: 1 read, 1 write (the idempotency doc), no delete", func(t *testing.T) {
		c := measured(t, "Remove no-op", budgettest.Budget{Reads: 1, Writes: 1}, func(ctx context.Context) {
			res, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000004", other))
			if err != nil || res.Outcome != BookmarkUnchanged || res.State.Bookmarked {
				t.Fatalf("no-op = %+v, %v", res, err)
			}
		})
		if c.Writes() != 1 || c.Deletes() != 0 || c.Reads() != 1 {
			t.Errorf("no-op reads/writes/deletes = %d/%d/%d, want 1/1/0", c.Reads(), c.Writes(), c.Deletes())
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
		c := measured(t, "late Remove retry", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			res, err := e.repo.Remove(ctx, rmParams(uid, "key-late-rm-0000001", p))
			if err != nil || res.Outcome != BookmarkReplayed {
				t.Fatalf("late retry of K = %+v, %v, want a replay", res, err)
			}
		})
		if c.Writes() != 0 || c.Deletes() != 0 || !e.bookmarkExists(t, uid, p) || len(e.bookmarks(t, uid)) != 1 {
			t.Errorf("the late retry changed state: writes %d deletes %d", c.Writes(), c.Deletes())
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
		c := measured(t, "late Add retry", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			res, err := e.repo.Add(ctx, addParams(uid, "key-late-add-000003", p))
			if err != nil || res.Outcome != BookmarkReplayed {
				t.Fatalf("late retry of K = %+v, %v, want a replay", res, err)
			}
		})
		if c.Writes() != 0 || e.bookmarkExists(t, uid, p) || len(e.bookmarks(t, uid)) != 0 {
			t.Errorf("the late retry re-added the bookmark: writes %d", c.Writes())
		}
	})

	t.Run("a key reused for another post is ErrIdempotencyKeyReused", func(t *testing.T) {
		if _, err := e.repo.Remove(ctx, rmParams(bmUID, "key-0000000000002", other)); !errors.Is(err, ErrIdempotencyKeyReused) {
			t.Fatalf("err = %v", err)
		}
	})
}

// Concurrent Adds by one user all lock quotas/{uid} and userLikes/{uid}: the transactions serialise, and under heavy
// contention some give up (a deadline or Aborted after the bounded retries) instead of corrupting anything. The
// invariant asserted here is consistency, never "everyone wins": the array, the quota and the bookmark docs agree with
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

	// Ten retries of the SAME request (one key, one post): at most one write, never a second charge.
	outs := run("bm-same-key", 10, func(int) string { return "key-conc-same-0001" }, func(int) string { return "0000000000000000131" })
	written := 0
	for _, o := range outs {
		if o.err == nil && o.res.Outcome == BookmarkWritten {
			written++
		}
	}
	if n, q := len(e.bookmarks(t, "bm-same-key")), e.quotaBookmarks(t, "bm-same-key"); written > 1 || n != 1 || q != 1 {
		t.Errorf("one key: written %d, array %d, quota %d, want at most 1 write and 1/1", written, n, q)
	}

	// Distinct posts: whatever the contention outcome, the array, the quota and the bookmark docs agree with each other.
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
	if n, q := len(e.bookmarks(t, "bm-many")), e.quotaBookmarks(t, "bm-many"); n != docs || q != int64(docs) {
		t.Errorf("distinct posts: %d bookmark docs, array %d, quota %d: want all three equal", docs, n, q)
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
