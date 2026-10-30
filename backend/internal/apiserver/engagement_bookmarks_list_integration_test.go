//go:build integration

package apiserver

// ListBookmarks (ADR-0023 D2, D6, ticket W2-4) over the real Build chain on the emulators: paging (25 bookmarks give
// 20 + a token, then 5 + ""), the clamp, the caller-bound token, the drop rules, the lazy prune and the budget table
// of the RPC doc comment (43 reads at page 20, 103 at page 50, 2 for an empty list), asserted with budgettest on the
// logged fs_reads / fs_writes / fs_deletes of the request line.
//
// The data is written through one chain (the "writer") and read through a second, freshly booted chain (the "reader")
// on the same emulator project: the reader's instance caches (posts, graph, userLikes, users) are cold, which is the
// worst case the documented budget describes. Reading through the writer would warm them with the seeding and prove
// nothing about 43.

import (
	"context"
	"fmt"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
)

const rpcListBookmarks = "/dzeroth.engagement.v1.EngagementService/ListBookmarks"

func (e *bmChain) list(u bmUser, pageSize int32, token string) (*engagementv1.ListBookmarksResponse, error) {
	r, err := e.eng.ListBookmarks(context.Background(), authed(u.token, &engagementv1.ListBookmarksRequest{PageSize: pageSize, PageToken: token}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// line is the last logged request line of rpc.
func (e *bmChain) line(t *testing.T, rpc string) map[string]any {
	t.Helper()
	lines := e.logs.requestLines(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	return lines[len(lines)-1]
}

func num(l map[string]any, k string) int64 { v, _ := l[k].(float64); return int64(v) }

func postIDs(r *engagementv1.ListBookmarksResponse) []string {
	out := make([]string, 0, len(r.GetBookmarks()))
	for _, b := range r.GetBookmarks() {
		out = append(out, b.GetPost().GetPost().GetPostId())
	}
	return out
}

// bookmarkDirect writes the thin bookmark doc and the userLikes entry without a request, for seeding at volume.
func (e *bmChain) bookmarkDirect(t *testing.T, uid, postID string, at int) {
	t.Helper()
	ctx := context.Background()
	if _, err := e.fs.Doc("users/"+uid+"/bookmarks/"+postID).Set(ctx, map[string]any{"createdAt": time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC).Add(time.Duration(at) * time.Second)}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.fs.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": firestore.ArrayUnion(postID)}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
}

// listChains boots the writer and a cold reader on the same emulator project.
func listChains(t *testing.T, mutate func(*config.Config)) (writer, reader *bmChain) {
	t.Helper()
	return newBMChain(t, mutate), newBMChain(t, mutate)
}

// 25 bookmarks: the first call returns the newest 20 and a token, the second the remaining 5 and "". Cold reader:
// page 1 costs exactly 43 reads (interceptor 1, query 20, GetMany 20, graph 1, userLikes 1) and writes nothing.
func TestListBookmarksChain_PagingAndColdBudget(t *testing.T) {
	w, r := listChains(t, nil)
	author, viewer := w.user(t), w.user(t)
	var want []string // oldest bookmarked first
	for i := 0; i < 25; i++ {
		id := w.post(t, author, fmt.Sprint("post ", i))
		if _, err := w.add(viewer, contractKey("bm-add"), id); err != nil {
			t.Fatalf("AddBookmark %d: %v", i, err)
		}
		want = append(want, id)
	}
	newestFirst := func(ids []string) []string {
		out := make([]string, len(ids))
		for i, id := range ids {
			out[len(ids)-1-i] = id
		}
		return out
	}
	expect := newestFirst(want)

	p1, err := r.list(viewer, 0, "")
	if err != nil {
		t.Fatalf("ListBookmarks: %v", err)
	}
	if got := postIDs(p1); len(got) != 20 || got[0] != expect[0] || got[19] != expect[19] || p1.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %d rows (%v), token %q; want the newest 20 and a token", len(got), got, p1.GetNextPageToken())
	}
	c := r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "ListBookmarks page 20 cold", c, budgettest.Budget{Reads: 43})
	if c.Reads() != 43 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("ListBookmarks page 20 cold reads/writes/deletes = %d/%d/%d, want exactly 43/0/0", c.Reads(), c.Writes(), c.Deletes())
	}
	// The rows are the live posts: author snapshot, text, and the bookmark time, newest bookmarked first.
	b0 := p1.GetBookmarks()[0]
	if b0.GetPost().GetPost().GetAuthor().GetUserId() != author.uid || b0.GetPost().GetPost().GetText() != "post 24" || b0.GetBookmarkedAt() == nil {
		t.Errorf("row 0 = %v", b0)
	}
	for i := 1; i < len(p1.GetBookmarks()); i++ {
		if !p1.GetBookmarks()[i].GetBookmarkedAt().AsTime().Before(p1.GetBookmarks()[i-1].GetBookmarkedAt().AsTime()) {
			t.Errorf("row %d is not older than row %d", i, i-1)
		}
	}
	if b0.GetPost().GetLikedByViewer() || b0.GetPost().GetRepostedByViewer() {
		t.Error("like/repost flags leaked with FEATURE_ENGAGEMENT off")
	}
	// Every row is a bookmark of the caller, so every row says so (ADR-0023 D3), from the userLikes read the page
	// already made (the 43-read budget above is unchanged).
	for i, row := range p1.GetBookmarks() {
		if !row.GetPost().GetBookmarkedByViewer() {
			t.Errorf("row %d: bookmarked_by_viewer = false on the caller's own bookmark list", i)
		}
	}
	if got := r.lastOutcome(rpcListBookmarks); got != "done" {
		t.Errorf("outcome = %q", got)
	}

	p2, err := r.list(viewer, 0, p1.GetNextPageToken())
	if err != nil {
		t.Fatalf("ListBookmarks page 2: %v", err)
	}
	if got := postIDs(p2); len(got) != 5 || got[0] != expect[20] || got[4] != expect[24] || p2.GetNextPageToken() != "" {
		t.Fatalf("page 2 = %v token %q, want the last 5 and \"\"", got, p2.GetNextPageToken())
	}
	// Warm: the interceptor, graph and userLikes are cached now; the 5 posts are not.
	c = r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "ListBookmarks page 2", c, budgettest.Budget{Reads: 1 + 5 + 5})
	if c.Writes() != 0 {
		t.Errorf("writes = %d, want 0", c.Writes())
	}
}

// A full page of 50 (page_size 99 is clamped) costs 103 reads cold; the exactly-full page still has a token, whose
// next page is empty and costs 1 query read.
func TestListBookmarksChain_MaxPageColdBudget(t *testing.T) {
	w, r := listChains(t, nil)
	author, viewer := w.user(t), w.user(t)
	for i := 0; i < 50; i++ {
		w.bookmarkDirect(t, viewer.uid, w.post(t, author, fmt.Sprint("p", i)), i)
	}
	p1, err := r.list(viewer, 99, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.GetBookmarks()) != 50 || p1.GetNextPageToken() == "" {
		t.Fatalf("page = %d rows, token %q; want 50 and a token", len(p1.GetBookmarks()), p1.GetNextPageToken())
	}
	c := r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "ListBookmarks page 50 cold", c, budgettest.Budget{Reads: 103})
	if c.Reads() != 103 {
		t.Errorf("ListBookmarks page 50 cold reads = %d, want exactly 103", c.Reads())
	}
	p2, err := r.list(viewer, 99, p1.GetNextPageToken())
	if err != nil || len(p2.GetBookmarks()) != 0 || p2.GetNextPageToken() != "" {
		t.Fatalf("page after a full page = %v, %v; want empty and \"\"", p2, err)
	}
	budgettest.Assert(t, "ListBookmarks empty tail", r.lineBudget(t, rpcListBookmarks), budgettest.Budget{Reads: 1})
}

// An empty list costs 2 reads cold (interceptor + the empty query) and reads no post, graph or userLikes doc.
func TestListBookmarksChain_EmptyListIsTwoReads(t *testing.T) {
	w, r := listChains(t, nil)
	viewer := w.user(t)
	resp, err := r.list(viewer, 0, "")
	if err != nil || len(resp.GetBookmarks()) != 0 || resp.GetNextPageToken() != "" {
		t.Fatalf("empty list = %v, %v", resp, err)
	}
	c := r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "ListBookmarks empty", c, budgettest.Budget{Reads: 2})
	if c.Reads() != 2 || c.Writes() != 0 {
		t.Errorf("empty list reads/writes = %d/%d, want 2/0", c.Reads(), c.Writes())
	}
}

// A foreign or tampered token is INVALID_ARGUMENT VALIDATION page_token and the handler reads nothing: the second call
// below is on a warm interceptor, so the whole request line shows 0 reads.
func TestListBookmarksChain_ForeignAndTamperedTokens(t *testing.T) {
	w, r := listChains(t, nil)
	author, a, b := w.user(t), w.user(t), w.user(t)
	for i := 0; i < 3; i++ {
		w.bookmarkDirect(t, a.uid, w.post(t, author, fmt.Sprint("x", i)), i)
	}
	pa, err := r.list(a, 2, "")
	if err != nil || pa.GetNextPageToken() == "" {
		t.Fatalf("a's page = %v, %v", pa, err)
	}
	if _, err := r.list(b, 0, ""); err != nil { // warms b's account-status read
		t.Fatal(err)
	}
	tampered := cursortest.Tamper(pa.GetNextPageToken())
	for name, token := range map[string]string{"another user's token": pa.GetNextPageToken(), "tampered": tampered, "garbage": "not-a-token"} {
		_, err := r.list(b, 0, token)
		d := wireError(t, err, connect.CodeInvalidArgument)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if d.GetMetadata()["field"] != "page_token" {
			t.Errorf("%s: metadata = %v, want field=page_token", name, d.GetMetadata())
		}
		budgettest.Assert(t, "ListBookmarks bad token "+name, r.lineBudget(t, rpcListBookmarks), budgettest.Budget{})
	}
	// The token is still good for its owner.
	if p, err := r.list(a, 2, pa.GetNextPageToken()); err != nil || len(p.GetBookmarks()) != 1 {
		t.Errorf("owner's page 2 = %v, %v", p, err)
	}
	// A foreign token cannot reach another user's rows even when it decodes (it does not: it is bound to the uid).
	if got := postIDs(pa); len(got) != 2 {
		t.Errorf("a's page 1 = %v", got)
	}
}

// The drop rules and the lazy prune end to end. v bookmarks seven posts; afterwards one post is deleted, one taken
// down, one author is blocked by v, one muted by v and one author blocks v. The page keeps the live post and v's own;
// the deleted post's bookmark is pruned once (1 write for userLikes, 1 delete, no extra read), the rest stay.
func TestListBookmarksChain_DropRulesAndPrune(t *testing.T) {
	ctx := context.Background()
	w, r := listChains(t, nil)
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
		if _, err := w.add(v, contractKey("bm-add"), id); err != nil {
			t.Fatalf("AddBookmark: %v", err)
		}
	}
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("bm-del"), PostId: deleted})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.fs.Doc("posts/"+hidden).Set(ctx, map[string]any{"moderation": "TAKEN_DOWN"}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(v.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: x.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Mute(ctx, authed(v.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("bm-mute"), UserId: y.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, authed(z.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("bm-blk"), UserId: v.uid})); err != nil {
		t.Fatal(err)
	}

	resp, err := r.list(v, 0, "")
	if err != nil {
		t.Fatalf("ListBookmarks: %v", err)
	}
	if got, want := postIDs(resp), []string{own, live}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("rows = %v, want %v (newest bookmarked first: own, live)", got, want)
	}
	if resp.GetNextPageToken() != "" {
		t.Errorf("token = %q on a short page of 7 queried rows", resp.GetNextPageToken())
	}
	l := r.line(t, rpcListBookmarks)
	for k, want := range map[string]int64{
		"rows_dropped": 5, "rows_dropped_missing": 1, "rows_dropped_hidden": 1, "rows_dropped_blocked": 2, "rows_dropped_muted": 1,
		"rows_pruned": 1, "rows_returned": 2,
	} {
		if got := num(l, k); got != want {
			t.Errorf("%s = %d, want %d", k, got, want)
		}
	}
	// Interceptor 1 + query 7 + GetMany 7 + graph 1 + userLikes 1 = 17 reads; the prune adds 1 write and 1 delete.
	c := r.lineBudget(t, rpcListBookmarks)
	budgettest.Assert(t, "ListBookmarks with a prune", c, budgettest.Budget{Reads: 17, Writes: 1, Deletes: 1})
	if c.Reads() != 17 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 17/1/1", c.Reads(), c.Writes(), c.Deletes())
	}

	// Only the deleted post's row was pruned; hidden, blocked, muted and blocker rows stay (a restore or an unblock
	// brings them back).
	for id, wantDoc := range map[string]bool{live: true, deleted: false, hidden: true, byBlocked: true, byMuted: true, byBlocker: true, own: true} {
		if got := w.bookmarkDocExists(t, v.uid, id); got != wantDoc {
			t.Errorf("bookmark doc of %s exists = %v, want %v", id, got, wantDoc)
		}
	}
	set := w.bookmarkIDs(t, v.uid)
	if len(set) != 6 {
		t.Errorf("userLikes.bookmarks = %v, want the six surviving ids", set)
	}
	for _, id := range set {
		if id == deleted {
			t.Error("the pruned id is still in userLikes.bookmarks")
		}
	}

	// The next open does not prune again: same rows, no writes, no deletes.
	resp, err = r.list(v, 0, "")
	if err != nil || len(postIDs(resp)) != 2 {
		t.Fatalf("second open = %v, %v", resp, err)
	}
	l = r.line(t, rpcListBookmarks)
	if num(l, "rows_pruned") != 0 || num(l, "rows_dropped_missing") != 0 || num(l, "fs_writes") != 0 || num(l, "fs_deletes") != 0 {
		t.Errorf("second open pruned again: %v", l)
	}

	// Unblocking brings the blocked author's row back without any re-add.
	if _, err := w.graph.Unblock(ctx, authed(v.token, &graphv1.UnblockRequest{IdempotencyKey: contractKey("bm-unblk"), UserId: x.uid})); err != nil {
		t.Fatal(err)
	}
	r2 := newBMChain(t, nil)
	resp, err = r2.list(v, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := fmt.Sprint(postIDs(resp)); got != fmt.Sprint([]string{own, byBlocked, live}) {
		t.Errorf("after the unblock rows = %v, want own, byBlocked, live", got)
	}
}

// A caller can only ever read their own subcollection: another user's bookmarks never appear, and a page_token bound
// to bookmarks|<uid> cannot be replayed by someone else (see ForeignAndTamperedTokens).
func TestListBookmarksChain_OwnerOnly(t *testing.T) {
	w, r := listChains(t, nil)
	author, a, b := w.user(t), w.user(t), w.user(t)
	mine := w.post(t, author, "a's")
	w.bookmarkDirect(t, a.uid, mine, 1)
	resp, err := r.list(b, 0, "")
	if err != nil || len(resp.GetBookmarks()) != 0 {
		t.Fatalf("b sees %v, %v: lists are private to their owner", resp, err)
	}
	if got, err := r.list(a, 0, ""); err != nil || fmt.Sprint(postIDs(got)) != fmt.Sprint([]string{mine}) {
		t.Fatalf("a sees %v, %v", got, err)
	}
}
