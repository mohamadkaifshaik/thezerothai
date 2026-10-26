//go:build integration

package apiserver

// W2-13: the ADR-0023 D2 drop matrix of ListBookmarks end to end, one state change at a time, each read through a COLD
// chain (a new Build over the same emulator project, so the 60 s post / graph / userLikes caches cannot hide a change):
// deleted (pruned once), takedown then restore, suspended author then reinstated, DELETING author (kept), blocks in both
// directions, unblock, mute, unmute, and a QUOTE whose embedded author is blocked, blocks the caller or is muted.
// The prune is once per open, skipped under DEGRADED_MODE=readonly, and leaves no residue in userLikes.bookmarks.

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func quoteChain(c *config.Config) {
	bookmarksOn(c)
	c.RateLimit.LikesPerUserPerMinute = 1_000_000
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
}

// wantRows asserts the bookmark ids a cold reader returns, newest bookmarked first.
func wantRows(t *testing.T, phase string, r *bmChain, v bmUser, want []string) map[string]any {
	t.Helper()
	resp, err := r.list(v, 0, "")
	if err != nil {
		t.Fatalf("%s: ListBookmarks: %v", phase, err)
	}
	if got := postIDs(resp); !slices.Equal(got, want) {
		t.Fatalf("%s: rows = %v, want %v", phase, got, want)
	}
	return r.line(t, rpcListBookmarks)
}

func TestListBookmarksChain_DropMatrixStepByStep(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, quoteChain)
	cold := func() *bmChain { return newBMChain(t, quoteChain) }

	v := w.user(t)
	aLive, aDel, aHid, aSus, aDelg := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)
	x, y, z, e, c := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)

	live := w.post(t, aLive, "live")
	deleted := w.post(t, aDel, "to be deleted")
	hidden := w.post(t, aHid, "to be taken down")
	suspended := w.post(t, aSus, "by a suspended author")
	deleting := w.post(t, aDelg, "by a DELETING author")
	byBlocked := w.post(t, x, "by the author v blocks")
	byMuted := w.post(t, y, "by the author v mutes")
	byBlocker := w.post(t, z, "by the author who blocks v")
	original := w.post(t, e, "original")
	q, err := w.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("bm-q"), Text: "quote", QuoteOfPostId: original}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	quote := q.Msg.GetPost().GetPost().GetPostId()

	order := []string{live, deleted, hidden, suspended, deleting, byBlocked, byMuted, byBlocker, quote}
	for _, id := range order {
		if _, err := w.add(v, contractKey("bm-add"), id); err != nil {
			t.Fatalf("AddBookmark: %v", err)
		}
	}
	// newest bookmarked first
	newestFirst := func(drop ...string) []string {
		var out []string
		for i := len(order) - 1; i >= 0; i-- {
			if !slices.Contains(drop, order[i]) {
				out = append(out, order[i])
			}
		}
		return out
	}
	setStatus := func(u bmUser, status string) {
		if _, err := w.fs.Doc("users/"+u.uid).Update(ctx, []firestore.Update{{Path: "status", Value: status}}); err != nil {
			t.Fatal(err)
		}
	}
	setModeration := func(id, mod string) {
		var up firestore.Update
		if mod == "" {
			up = firestore.Update{Path: "moderation", Value: firestore.Delete}
		} else {
			up = firestore.Update{Path: "moderation", Value: mod}
		}
		if _, err := w.fs.Doc("posts/"+id).Update(ctx, []firestore.Update{up}); err != nil {
			t.Fatal(err)
		}
	}
	block := func(who, target bmUser) {
		if _, err := w.graph.Block(ctx, authed(who.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: target.uid})); err != nil {
			t.Fatal(err)
		}
	}
	unblock := func(who, target bmUser) {
		if _, err := w.graph.Unblock(ctx, authed(who.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("bm-unblk"), UserId: target.uid})); err != nil {
			t.Fatal(err)
		}
	}
	mute := func(who, target bmUser) {
		if _, err := w.graph.Mute(ctx, authed(who.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("bm-mute"), UserId: target.uid})); err != nil {
			t.Fatal(err)
		}
	}
	unmute := func(who, target bmUser) {
		if _, err := w.graph.Unmute(ctx, authed(who.token, &graphv1.UnmuteRequest{IdempotencyKey: contractKey("bm-unmute"), UserId: target.uid})); err != nil {
			t.Fatal(err)
		}
	}
	tally := func(l map[string]any, missing, hid, blocked, muted, pruned, returned int64) {
		t.Helper()
		for k, want := range map[string]int64{
			"rows_dropped_missing": missing, "rows_dropped_hidden": hid, "rows_dropped_blocked": blocked,
			"rows_dropped_muted": muted, "rows_pruned": pruned, "rows_returned": returned,
			"rows_dropped": missing + hid + blocked + muted,
		} {
			if got := num(l, k); got != want {
				t.Errorf("%s = %d, want %d", k, got, want)
			}
		}
	}

	// Phase 0: nothing changed yet, every row shows, newest bookmarked first.
	wantRows(t, "phase 0", cold(), v, newestFirst())

	// Phase 1: the post is deleted, taken down, its author suspended; v blocks x, mutes y; z blocks v; the embedded author
	// of the quote is blocked by v. A DELETING author's post stays (Home column: no extra read, the purge removes it).
	if _, err := w.posts.DeletePost(ctx, authed(aDel.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: deleted})); err != nil {
		t.Fatal(err)
	}
	setModeration(hidden, "TAKEN_DOWN")
	setModeration(suspended, "SUSPENDED_AUTHOR")
	setStatus(aSus, "SUSPENDED")
	setStatus(aDelg, "DELETING")
	block(v, x)
	mute(v, y)
	block(z, v)
	block(v, e)

	r := cold()
	l := wantRows(t, "phase 1", r, v, newestFirst(deleted, hidden, suspended, byBlocked, byMuted, byBlocker, quote))
	// rows: live + deleting kept; dropped: missing 1, hidden 2 (takedown + suspended), blocked 3 (x, z, the quote's embedded e), muted 1
	tally(l, 1, 2, 3, 1, 1, 2)
	// Cold: interceptor 1 + query 9 + GetMany 9 (the deleted one is a read too) + graph 1 + userLikes 1 = 21 reads; the
	// prune of the one missing row adds 1 write and 1 delete.
	cb := r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "phase 1 list", cb, budgettest.Budget{Reads: 9 + 9 + 3, Writes: 1, Deletes: 1})
	if cb.Reads() > 21 || cb.Writes() != 1 || cb.Deletes() != 1 {
		t.Errorf("phase 1 reads/writes/deletes = %d/%d/%d, want <=21/1/1", cb.Reads(), cb.Writes(), cb.Deletes())
	}
	// Prune exactly once: only the deleted post's doc is gone, nothing else, no residue in the array.
	for id, want := range map[string]bool{live: true, deleted: false, hidden: true, suspended: true, deleting: true, byBlocked: true, byMuted: true, byBlocker: true, quote: true} {
		if got := w.bookmarkDocExists(t, v.uid, id); got != want {
			t.Errorf("bookmark doc %s exists = %v, want %v", id, got, want)
		}
	}
	if ids := w.bookmarkIDs(t, v.uid); slices.Contains(ids, deleted) || len(ids) != len(order)-1 {
		t.Errorf("userLikes.bookmarks = %v: the pruned id must be gone and every other id kept", ids)
	}
	// ... and the next open prunes nothing and writes nothing.
	r = cold()
	l = wantRows(t, "phase 1, second open", r, v, newestFirst(deleted, hidden, suspended, byBlocked, byMuted, byBlocker, quote))
	tally(l, 0, 2, 3, 1, 0, 2)
	if cb := r.lineBudget(t, rpcListBookmarks); cb.Writes() != 0 || cb.Deletes() != 0 {
		t.Errorf("second open writes/deletes = %d/%d, want 0/0", cb.Writes(), cb.Deletes())
	}

	// Phase 2: the takedown is restored and the author reinstated: both rows are back, no re-add.
	setModeration(hidden, "")
	setModeration(suspended, "")
	setStatus(aSus, "ACTIVE")
	l = wantRows(t, "phase 2 (restore, reinstate)", cold(), v, newestFirst(deleted, byBlocked, byMuted, byBlocker, quote))
	tally(l, 0, 0, 3, 1, 0, 4)

	// Phase 3: unblock x, unmute y, z unblocks v, v unblocks e: every remaining row is back.
	unblock(v, x)
	unmute(v, y)
	unblock(z, v)
	unblock(v, e)
	l = wantRows(t, "phase 3 (unblock, unmute)", cold(), v, newestFirst(deleted))
	tally(l, 0, 0, 0, 0, 0, 8)

	// Phase 4: the QUOTE's embedded author in each way: blocks the caller, is muted by the caller, is blocked by it.
	block(e, v)
	l = wantRows(t, "phase 4a (embedded author blocks v)", cold(), v, newestFirst(deleted, quote))
	tally(l, 0, 0, 1, 0, 0, 7)
	unblock(e, v)
	mute(v, e)
	l = wantRows(t, "phase 4b (embedded author muted by v)", cold(), v, newestFirst(deleted, quote))
	tally(l, 0, 0, 0, 1, 0, 7)
	unmute(v, e)
	l = wantRows(t, "phase 4c (all clear)", cold(), v, newestFirst(deleted))
	tally(l, 0, 0, 0, 0, 0, 8)

	// Phase 5: the original post itself is deleted: the QUOTE keeps its tombstone and its row (the quote post is live),
	// and the viewer's own post (v is the author) is kept even when v blocks nobody.
	if _, err := w.posts.DeletePost(ctx, authed(e.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: original})); err != nil {
		t.Fatal(err)
	}
	wantRows(t, "phase 5 (quoted original deleted)", cold(), v, newestFirst(deleted))
}

// The prune is skipped under DEGRADED_MODE=readonly (the list is NO_SIDE_EFFECTS and must stay write-free); a normal
// chain then prunes it once, and afterwards neither the doc nor the userLikes.bookmarks entry remains.
func TestListBookmarksChain_PruneSkippedUnderReadOnly(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, nil)
	a, v := w.user(t), w.user(t)
	keep, gone := w.post(t, a, "keep"), w.post(t, a, "gone")
	for _, id := range []string{keep, gone} {
		if _, err := w.add(v, contractKey("bm-add"), id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: gone})); err != nil {
		t.Fatal(err)
	}

	ro := newBMChain(t, func(c *config.Config) { bookmarksOn(c); c.Degraded = config.DegradedReadonly })
	resp, err := ro.list(v, 0, "")
	if err != nil || fmt.Sprint(postIDs(resp)) != fmt.Sprint([]string{keep}) {
		t.Fatalf("readonly list = %v, %v; want [keep]", postIDs(resp), err)
	}
	l := ro.line(t, rpcListBookmarks)
	if num(l, "rows_pruned") != 0 || num(l, "rows_dropped_missing") != 1 || num(l, "fs_writes") != 0 || num(l, "fs_deletes") != 0 {
		t.Errorf("readonly request line = %v: the missing row must be counted, not pruned, and nothing written", l)
	}
	if !w.bookmarkDocExists(t, v.uid, gone) || !slices.Contains(w.bookmarkIDs(t, v.uid), gone) {
		t.Fatal("the readonly list pruned a bookmark")
	}
	// Add and Remove are refused cleanly in the same mode: DEGRADED_MODE (UNAVAILABLE), nothing written.
	_, aerr := ro.add(v, contractKey("bm-add"), keep)
	assertReason(t, wireError(t, aerr, connect.CodeUnavailable), commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
	_, rerr := ro.remove(v, contractKey("bm-rm"), keep)
	assertReason(t, wireError(t, rerr, connect.CodeUnavailable), commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
	if !w.bookmarkDocExists(t, v.uid, keep) {
		t.Fatal("a refused Remove deleted the bookmark")
	}

	// Back to normal: the next open prunes the row, once.
	r := newBMChain(t, nil)
	if resp, err := r.list(v, 0, ""); err != nil || fmt.Sprint(postIDs(resp)) != fmt.Sprint([]string{keep}) {
		t.Fatalf("normal list = %v, %v", postIDs(resp), err)
	}
	if l := r.line(t, rpcListBookmarks); num(l, "rows_pruned") != 1 || num(l, "fs_deletes") != 1 || num(l, "fs_writes") != 1 {
		t.Errorf("normal request line = %v, want 1 pruned / 1 write / 1 delete", l)
	}
	if w.bookmarkDocExists(t, v.uid, gone) || slices.Contains(w.bookmarkIDs(t, v.uid), gone) {
		t.Error("residue of the pruned bookmark (doc or userLikes.bookmarks entry)")
	}
	if ids := w.bookmarkIDs(t, v.uid); !slices.Equal(ids, []string{keep}) {
		t.Errorf("userLikes.bookmarks = %v, want [keep]", ids)
	}
	if _, err := r.list(v, 0, ""); err != nil {
		t.Fatal(err)
	}
	if l := r.line(t, rpcListBookmarks); num(l, "rows_pruned") != 0 || num(l, "fs_writes") != 0 {
		t.Errorf("the open after the prune pruned again: %v", l)
	}
}

// A user dropped from the allowlist keeps their list: ListBookmarks and RemoveBookmark work, the rows come back with
// bookmarked_by_viewer as the server states it for a caller the flag is off for, and a dropped user's prune still runs.
func TestListBookmarksChain_DroppedFromAllowlistKeepsTheirList(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, nil)
	a, v := w.user(t), w.user(t)
	keep, gone := w.post(t, a, "keep"), w.post(t, a, "gone")
	for _, id := range []string{keep, gone} {
		if _, err := w.add(v, contractKey("bm-add"), id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: gone})); err != nil {
		t.Fatal(err)
	}
	dropped := newBMChain(t, func(c *config.Config) {
		bookmarksOn(c)
		c.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}
	})
	resp, err := dropped.list(v, 0, "")
	if err != nil || fmt.Sprint(postIDs(resp)) != fmt.Sprint([]string{keep}) {
		t.Fatalf("dropped user's list = %v, %v", postIDs(resp), err)
	}
	if w.bookmarkDocExists(t, v.uid, gone) {
		t.Error("the prune does not run for a user dropped from the allowlist (cleanup is never flag-gated, ADR-0023 D5)")
	}
	for _, row := range resp.GetBookmarks() {
		// Observation, not a rule: with neither flag on for the caller the server hydrates no viewer state, so the row
		// does not say it is bookmarked. The client hides the icon when GetMe lacks `bookmarks`.
		t.Logf("dropped user's row: bookmarked_by_viewer = %v", row.GetPost().GetBookmarkedByViewer())
	}
	if _, err := dropped.remove(v, contractKey("bm-rm"), keep); err != nil {
		t.Fatalf("Remove by a dropped user: %v", err)
	}
	if after, err := dropped.list(v, 0, ""); err != nil || len(after.GetBookmarks()) != 0 {
		t.Fatalf("list after Remove = %v, %v", after, err)
	}
}
