//go:build integration

package apiserver

// W3-41a tester attacks (ADR-0025 note W3-36 L-2) through the real Build chain on the emulators, beyond the author's
// own file (w341a_owner_placeholders_integration_test.go): a REPOST by another user in the owner's lists, the protected
// set unavailable, an overflowed blockedBy, the own REPOST on every tab and on since refreshes, the viewer flags after a
// userLikes trim, and the wire bytes of a placeholder.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

const (
	w341aProcLiked     = "/dzeroth.engagement.v1.EngagementService/ListLikedPosts"
	w341aProcBookmarks = "/dzeroth.engagement.v1.EngagementService/ListBookmarks"
)

var w341aAllTabs = []timelinev1.UserTimelineTab{tabPostsPB, tabRepliesPB30, tabMediaPB, tabRepostsPB}

// w341aBin posts a binary-proto request and decodes the answer into out; it returns the raw bytes too.
func w341aBin(t *testing.T, r *w320Chain, token, proc string, req, out proto.Message) []byte {
	t.Helper()
	b, err := proto.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	hr, err := http.NewRequest(http.MethodPost, r.url+proc, bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	hr.Header.Set("Content-Type", "application/proto")
	hr.Header.Set("Connect-Protocol-Version", "1")
	hr.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("%s binary: %d %s", proc, resp.StatusCode, raw)
	}
	if err := proto.Unmarshal(raw, out); err != nil {
		t.Fatalf("%s binary decode: %v", proc, err)
	}
	return raw
}

// w341aSetFS merges fields into a document.
func w341aSetFS(t *testing.T, w *w335aWorld, path string, fields map[string]any) {
	t.Helper()
	if _, err := w.e.fs.Doc(path).Set(context.Background(), fields, firestore.MergeAll); err != nil {
		t.Fatalf("set %s: %v", path, err)
	}
}

// w341aFields lists the populated field names of m.
func w341aFields(m proto.Message) []string {
	var out []string
	m.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		out = append(out, string(fd.Name()))
		return true
	})
	slices.Sort(out)
	return out
}

// w341aCheckPlaceholder asserts v is a bare placeholder of id with kind and author uid: only post_id, kind, author and
// the viewer flag, no unknown fields.
func w341aCheckPlaceholder(t *testing.T, what string, v *postsv1.PostView, id string, kind postsv1.PostKind, author, flag string) {
	t.Helper()
	if v == nil {
		t.Errorf("%s: no row for %s", what, id)
		return
	}
	// The caller's own viewer flags are allowed (liked, reposted, bookmarked describe the caller); nothing else is.
	for _, f := range w341aFields(v) {
		if !slices.Contains([]string{"post", "withheld", "liked_by_viewer", "reposted_by_viewer", "bookmarked_by_viewer"}, f) {
			t.Errorf("%s: placeholder view carries field %q", what, f)
		}
	}
	if !slices.Contains(w341aFields(v), flag) {
		t.Errorf("%s: placeholder lacks %s", what, flag)
	}
	if got, want := w341aFields(v.GetPost()), []string{"author", "kind", "post_id"}; !slices.Equal(got, want) {
		t.Errorf("%s: post fields = %v, want %v", what, got, want)
	}
	if len(v.ProtoReflect().GetUnknown()) != 0 || len(v.GetPost().ProtoReflect().GetUnknown()) != 0 {
		t.Errorf("%s: unknown fields on the wire", what)
	}
	if v.GetPost().GetPostId() != id || v.GetPost().GetKind() != kind || v.GetPost().GetAuthor().GetUserId() != author || !v.GetWithheld() {
		t.Errorf("%s: row = %v, want post_id %s kind %v author %s withheld", what, v, id, kind, author)
	}
}

func w341aApprove(t *testing.T, w *w335aWorld, s bmUser) {
	t.Helper()
	w.w.w328Request(t, s, w.p.uid)
	if _, err := w.w.w328Respond(w.p, s.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}
}

// rawBody is the raw JSON answer of an owner list for u on a cold chain.
func (w *w335aWorld) rawBody(t *testing.T, u bmUser, proc string, req proto.Message) string {
	t.Helper()
	_, _, b := w.raw(t, newW320Chain(t, w335aOn), u, proc, req)
	return b
}

// ---- case 1 ---------------------------------------------------------------------------------------------------------

// A REPOST by another user R (X) of protected P's post in the caller's Likes list (m1: the ADR and the proto say "a post
// by P", so this row is dropped as before, never a placeholder). LikePost and AddBookmark of a REPOST id store the
// original's id, so a REPOST row reaches the list only through a seeded legacy array; the Bookmarks list holds the
// placeholder of P's post itself.
func TestW341aAttack_RepostByOtherInOwnerLists(t *testing.T) {
	w := newW335aWorld(t)
	s := w.w.user(t)
	if _, err := w.w.add(s, contractKey("w341a-bmrp"), w.repostID); err != nil {
		t.Fatalf("AddBookmark(X's REPOST): %v", err)
	}
	w.w.like(t, s, w.repostID) // resolves to the original
	w341aSetFS(t, w, "userLikes/"+s.uid, map[string]any{"recent": firestore.ArrayUnion(w.repostID)})
	w.protect(t, true)

	t.Run("the REPOST row is dropped, P's own row is the placeholder", func(t *testing.T) {
		r := newW320Chain(t, w335aOn)
		lk, err := r.listLiked(s, 20, "")
		if err != nil {
			t.Fatal(err)
		}
		if w341aRow(lk.GetPosts(), w.repostID) != nil {
			t.Errorf("likes: the REPOST row by R is listed: %v", w341aRow(lk.GetPosts(), w.repostID))
		}
		w341aCheckPlaceholder(t, "likes", w341aRow(lk.GetPosts(), w.pid), w.pid, postsv1.PostKind_POST_KIND_POST, w.p.uid, "liked_by_viewer")
		budgettest.Assert(t, "ListLikedPosts cold page 20 (REPOST row)", r.lineBudget(t, rpcListLiked), budgettest.Budget{Reads: 23})
		r = newW320Chain(t, w335aOn)
		bm, err := r.list(s, 20, "")
		if err != nil {
			t.Fatal(err)
		}
		var bms []*postsv1.PostView
		for _, b := range bm.GetBookmarks() {
			bms = append(bms, b.GetPost())
		}
		if w341aRow(bms, w.repostID) != nil {
			t.Error("Bookmarks holds a REPOST row: AddBookmark(REPOST id) is expected to store the original")
		}
		w341aCheckPlaceholder(t, "bookmarks", w341aRow(bms, w.pid), w.pid, postsv1.PostKind_POST_KIND_POST, w.p.uid, "bookmarked_by_viewer")
		budgettest.Assert(t, "ListBookmarks cold page 20", r.lineBudget(t, rpcListBookmarks), budgettest.Budget{Reads: 43})
		for _, body := range []string{
			w.rawBody(t, s, w341aProcLiked, &engagementv1.ListLikedPostsRequest{PageSize: 20}),
			w.rawBody(t, s, w341aProcBookmarks, &engagementv1.ListBookmarksRequest{PageSize: 20}),
		} {
			if w.leaks(body) {
				t.Errorf("a list body carries P's content: %s", body)
			}
		}
	})
	t.Run("S approved for P: the full REPOST row, embed intact", func(t *testing.T) {
		w341aApprove(t, w, s)
		_, likes := w341aLists(t, s)
		if row := w341aRow(likes, w.repostID); row == nil || row.GetWithheld() || row.GetPost().GetEmbedded().GetText() == "" {
			t.Errorf("likes: row = %v, want the full REPOST with its embed", row)
		}
	})
}

// ---- case 2 ---------------------------------------------------------------------------------------------------------

// Withheld rows with the protected set unavailable: a cold chain that cannot load privacy/protectedAuthors answers
// UNAVAILABLE on both lists and every tab of the caller's own profile; the raw body never carries P's content, a
// placeholder or a full row, and the error does not say PROTECTED_ACCOUNT.
func TestW341aAttack_SetUnavailableNeverSendsRows(t *testing.T) {
	ctx := context.Background()
	project := "demo-w341a-" + strings.ReplaceAll(contractKey("p"), "contract-p-", "")
	cfg := func(c *config.Config) {
		w320Base(c)
		w320AllW3On(c)
		w335aOn(c)
		c.ProjectID = project
		c.CacheTTL = time.Second
		c.Privacy.ProtectedSetMaxStale = 3 * time.Second
	}
	boot := func() *w320Chain { return w320Wrap(newChainWith(t, cfg, stubVerifier{})) }
	r0 := boot()
	now := time.Now()
	for _, uid := range []string{"p", "s", "x"} {
		doc := map[string]any{"handle": "h" + uid, "handleLower": "h" + uid, "displayName": "Name " + uid, "status": "ACTIVE",
			"isPrivate": false, "createdAt": now.Add(-48 * time.Hour), "updatedAt": now}
		if _, err := r0.fs.Doc("users/"+uid).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	pPost, err := r0.posts.CreatePost(ctx, authed("p", &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w341a-u1"), Text: w335aMarkerPrefix + "unavailable"}))
	if err != nil {
		t.Fatal(err)
	}
	pid := pPost.Msg.GetPost().GetPost().GetPostId()
	s := bmUser{token: "s", uid: "s"}
	r0.like(t, s, pid)
	if _, err := r0.add(s, contractKey("w341a-u2"), pid); err != nil {
		t.Fatal(err)
	}
	if _, err := r0.eng.RepostPost(ctx, authed("s", &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w341a-u3"), PostId: pid})); err != nil {
		t.Fatal(err)
	}
	// P protects: user doc and the derived set.
	if _, err := r0.fs.Doc("users/p").Update(ctx, []firestore.Update{{Path: "isPrivate", Value: true}}); err != nil {
		t.Fatal(err)
	}
	if _, err := r0.fs.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": []string{"p"}}); err != nil {
		t.Fatal(err)
	}
	// Fixture check: with the set readable the Likes row is a placeholder and the own Reposts tab keeps the REPOST.
	r1 := boot()
	lk, err := r1.listLiked(s, 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if row := w341aRow(lk.GetPosts(), pid); row == nil || !row.GetWithheld() {
		t.Fatalf("fixture: liked row = %v, want a placeholder while the set is readable", row)
	}
	if tl, err := boot().tabCall(s, "s", tabRepostsPB, 20, "", ""); err != nil || len(tl.GetPosts()) == 0 {
		t.Fatalf("fixture: own Reposts tab = %v, %v, want the kept REPOST while the set is readable", tl, err)
	}

	// The set becomes unreadable.
	if _, err := r0.fs.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": "not-an-array"}); err != nil {
		t.Fatal(err)
	}
	type call struct {
		name string
		proc string
		req  proto.Message
	}
	calls := []call{
		{"ListLikedPosts", w341aProcLiked, &engagementv1.ListLikedPostsRequest{PageSize: 20}},
		{"ListBookmarks", w341aProcBookmarks, &engagementv1.ListBookmarksRequest{PageSize: 20}},
	}
	for _, tab := range w341aAllTabs {
		calls = append(calls, call{"GetUserTimeline " + tab.String(), timelinev1connect.TimelineServiceGetUserTimelineProcedure,
			&timelinev1.GetUserTimelineRequest{UserId: "s", Tab: tab, PageSize: 20}})
	}
	wld := &w335aWorld{}
	for _, c := range calls {
		// Each call on a fresh chain (no last-good copy: the load fails at once) and then on one warm chain polled across
		// the stale bound (MaxStale 3 s): every answer is UNAVAILABLE, never a row.
		warm := boot()
		for i, r := range []*w320Chain{boot(), warm, warm, warm, warm} {
			if i > 1 {
				time.Sleep(1500 * time.Millisecond)
			}
			st, _, body := wld.raw(t, r, s, c.proc, c.req)
			if strings.Contains(body, w335aMarkerPrefix) || strings.Contains(body, `"withheld"`) || strings.Contains(body, `"postId"`) {
				t.Errorf("%s (poll %d): set unavailable but the body carries rows: %d %s", c.name, i, st, body)
			}
			var e struct {
				Code string `json:"code"`
			}
			_ = json.Unmarshal([]byte(body), &e)
			// The Media tab of an account with no media post needs no set (no row to decide): 200 with no rows is fine.
			emptyOK := st == http.StatusOK && strings.Contains(c.name, "MEDIA")
			if !emptyOK && (st != http.StatusServiceUnavailable || e.Code != "unavailable") {
				t.Errorf("%s (poll %d): %d %s, want 503 unavailable", c.name, i, st, body)
			}
			if strings.Contains(body, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT.String()) {
				t.Errorf("%s (poll %d): UNAVAILABLE must not say PROTECTED_ACCOUNT", c.name, i)
			}
		}
	}
	if _, err := boot().listLiked(s, 20, ""); connect.CodeOf(err) != connect.CodeUnavailable {
		t.Errorf("ListLikedPosts typed error = %v, want UNAVAILABLE", err)
	}
}

// ---- case 3 ---------------------------------------------------------------------------------------------------------

// A caller whose blockedBy set overflowed: S reposted, liked and bookmarked P's post, P blocked S, and the overflow left
// P out of blockedBy. P is protected and S is unapproved.
//   - the lists drop every foreign row on overflow (blockCause fails closed): no placeholder, nothing leaks;
//   - the own Reposts tab must drop the REPOST too (block is decided first); a placeholder shows P's author snapshot to
//     a user P blocked.
func TestW341aAttack_BlockedByOverflow(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	s, repostID := w341aSeed(t, w)
	w.protect(t, false)
	if _, err := w.w.graph.Block(ctx, authed(w.p.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w341a-ob"), UserId: s.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.e.fs.Doc("graph/"+s.uid).Update(ctx, []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove(w.p.uid)},
		{Path: "blockedByOverflow", Value: true},
	}); err != nil {
		t.Fatal(err)
	}
	// Control (pre-existing, not W3-41a): P still public, so the own REPOST is kept in full on the own profile.
	if ctl, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 20, "", ""); err == nil {
		row := w341aRow(ctl.GetPosts(), repostID)
		t.Logf("CONTROL (P public, P blocks S, overflow): own REPOST present=%v, embedded text %q", row != nil, row.GetPost().GetEmbedded().GetText())
	}
	w.protect(t, true)

	bms, likes := w341aLists(t, s)
	if w341aRow(bms, w.pid) != nil || w341aRow(likes, w.pid) != nil {
		t.Errorf("an overflowed caller blocked by P got a row of P in a list: bookmarks=%v likes=%v", w341aRow(bms, w.pid), w341aRow(likes, w.pid))
	}
	r := newW320Chain(t, w335aOn)
	resp, err := r.tabCall(s, s.uid, tabRepostsPB, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if row := w341aRow(resp.GetPosts(), repostID); row != nil {
		t.Errorf("P blocks S and S's blockedBy overflowed: the own Reposts tab still returns the REPOST of P (state %v, embedded %v): block must be decided first",
			row.GetEmbedViewerState(), row.GetPost().GetEmbedded())
	}
	budgettest.Assert(t, "GetUserTimeline own Reposts, overflowed caller", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 4 + 20})

	// The same overflow with no block by P: an overflowed blockedBy set cannot prove P does not block S, so the tab fails
	// closed like the lists (D-1 fix; the owner loses the undoable row only while the overflow lasts, a rare residual).
	w2 := newW335aWorld(t)
	s2, repost2 := w341aSeed(t, w2)
	if _, err := w2.e.fs.Doc("graph/"+s2.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	resp, err = newW320Chain(t, w335aOn).tabCall(s2, s2.uid, tabRepostsPB, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if row := w341aRow(resp.GetPosts(), repost2); row != nil {
		t.Errorf("overflowed caller, no block: own REPOST = %v, want it dropped (fail closed)", row)
	}
	bms, likes = w341aLists(t, s2)
	t.Logf("overflowed caller, no block (lists fail closed, no way to undo from a list): bookmarks row present=%v, likes row present=%v", w341aRow(bms, w2.pid) != nil, w341aRow(likes, w2.pid) != nil)
}

// ---- case 4 ---------------------------------------------------------------------------------------------------------

func w341aTabHas(r *timelinev1.GetUserTimelineResponse, id string) *postsv1.PostView {
	return w341aRow(r.GetPosts(), id)
}

// The own REPOST on every profile tab, on since refreshes (warm and cold chain), on paged reads, and on one chain
// shared with another viewer and Home in both orders.
func TestW341aAttack_OwnRepostOnEveryTabAndRefresh(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	s, other := w.w.user(t), w.w.user(t)
	pid2 := w.post(t, w.p, &postsv1.CreatePostRequest{Text: w335aMarkerPrefix + "second"})
	rp := func(id string) string {
		r, err := w.w.eng.RepostPost(ctx, authed(s.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w341a-t4"), PostId: id}))
		if err != nil {
			t.Fatalf("repost %s: %v", id, err)
		}
		return r.Msg.GetRepostPostId()
	}
	repost1 := rp(w.pid)
	own := w.post(t, s, &postsv1.CreatePostRequest{Text: "S's own post"})

	// Baseline while P is public: which tabs hold the REPOST, and a since token per tab.
	hasTab := map[timelinev1.UserTimelineTab]bool{}
	since := map[timelinev1.UserTimelineTab]string{}
	warm := newW320Chain(t, w335aOn)
	for _, tab := range w341aAllTabs {
		resp, err := warm.tabCall(s, s.uid, tab, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		hasTab[tab] = w341aTabHas(resp, repost1) != nil
		since[tab] = resp.GetSinceToken()
		t.Logf("baseline (P public): tab %v holds the REPOST = %v, own post present = %v", tab, hasTab[tab], w341aTabHas(resp, own) != nil)
	}
	homeBefore, err := warm.timeline.GetHomeTimeline(ctx, authed(s.token, &timelinev1.GetHomeTimelineRequest{PageSize: 20}))
	if err != nil {
		t.Fatal(err)
	}
	homeSince := homeBefore.Msg.GetSinceToken()
	repost2 := rp(pid2)
	w.protect(t, true)
	// A chain started after P protected, warmed by one first-page read per tab (graph, author-recent entry and set cached): its
	// since refreshes run on warm caches. (The baseline chain keeps the protected set it cached before P protected, bounded
	// by CACHE_TTL, so it is no witness for the new state.)
	warm = newW320Chain(t, w335aOn)
	for _, tab := range w341aAllTabs {
		if _, err := warm.tabCall(s, s.uid, tab, 20, "", ""); err != nil {
			t.Fatal(err)
		}
	}

	checkRow := func(what string, row *postsv1.PostView, id string) {
		t.Helper()
		if row == nil {
			t.Errorf("%s: REPOST %s is missing", what, id)
			return
		}
		e := row.GetPost().GetEmbedded()
		if row.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || !row.GetRepostedByViewer() ||
			e.GetText() != "" || len(e.GetMedia()) != 0 || e.GetCreatedAt() != nil || row.GetPost().GetText() != "" {
			t.Errorf("%s: row %s = %v, want PROTECTED, reposted_by_viewer, embedded post_id and author only", what, id, row)
		}
	}

	// Each tab, first page, cold chain: the placeholder iff the tab held the REPOST before; another viewer never.
	for _, tab := range w341aAllTabs {
		cold := newW320Chain(t, w335aOn)
		resp, err := cold.tabCall(s, s.uid, tab, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		for _, id := range []string{repost1, repost2} {
			row := w341aTabHas(resp, id)
			if hasTab[tab] {
				checkRow("cold first page, tab "+tab.String(), row, id)
			} else if row != nil {
				t.Errorf("tab %v returned the REPOST %s although it did not before P protected", tab, id)
			}
		}
		ov, err := cold.tabCall(other, s.uid, tab, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if w341aTabHas(ov, repost1) != nil || w341aTabHas(ov, repost2) != nil {
			t.Errorf("another viewer got S's REPOST of protected P on tab %v", tab)
		}
	}

	// since refresh on the warm chain (author-recent entry, instance caches) and on a cold chain, and for another viewer.
	for _, tab := range w341aAllTabs {
		if !hasTab[tab] {
			continue
		}
		for name, r := range map[string]*w320Chain{"warm": warm, "cold": newW320Chain(t, w335aOn)} {
			resp, err := r.tabCall(s, s.uid, tab, 20, since[tab], "")
			if err != nil {
				t.Fatalf("%s since refresh tab %v: %v", name, tab, err)
			}
			checkRow(name+" since refresh, tab "+tab.String(), w341aTabHas(resp, repost2), repost2)
			if row := w341aTabHas(resp, repost1); row != nil { // the since window overlaps: an older row may come back, stripped
				checkRow(name+" since refresh (overlap row), tab "+tab.String(), row, repost1)
			}
			// A since_token is bound to its viewer: another viewer refreshing with S's token is refused.
			if _, err := r.tabCall(other, s.uid, tab, 20, since[tab], ""); err == nil {
				t.Errorf("%s since refresh: another viewer used S's since token on tab %v", name, tab)
			}
		}
	}
	// Home since refresh and first page, on cold chains: the REPOST of protected P is dropped. (A warm chain serves the
	// Home page it cached before P protected, pre-existing and bounded by the instance cache TTL; see the report.)
	for _, req := range []*timelinev1.GetHomeTimelineRequest{{PageSize: 20, SinceToken: homeSince}, {PageSize: 20}} {
		h, err := newW320Chain(t, w335aOn).timeline.GetHomeTimeline(ctx, authed(s.token, req))
		if err != nil {
			t.Fatal(err)
		}
		if w341aRow(h.Msg.GetPosts(), repost2) != nil || w341aRow(h.Msg.GetPosts(), repost1) != nil {
			t.Errorf("S's Home (since=%q) shows S's REPOST of protected P", req.GetSinceToken())
		}
	}

	// Paged reads with page_size 1 keep the placeholder on later pages.
	if hasTab[tabRepostsPB] {
		seen := map[string]bool{}
		tok := ""
		for i := 0; i < 6; i++ {
			resp, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 1, "", tok)
			if err != nil {
				t.Fatal(err)
			}
			for _, v := range resp.GetPosts() {
				seen[v.GetPost().GetPostId()] = true
			}
			if tok = resp.GetNextPageToken(); tok == "" {
				break
			}
		}
		if !seen[repost1] || !seen[repost2] {
			t.Errorf("paged Reposts tab (page_size 1) saw %v, want both REPOSTs", seen)
		}
	}

	// One chain shared by S, another viewer and Home, in both orders: no row crosses viewers.
	for _, order := range [][]string{{"s", "other", "home"}, {"other", "home", "s", "other"}} {
		shared := newW320Chain(t, w335aOn)
		for _, who := range order {
			switch who {
			case "s":
				for _, tab := range w341aAllTabs {
					resp, err := shared.tabCall(s, s.uid, tab, 20, "", "")
					if err != nil {
						t.Fatal(err)
					}
					if hasTab[tab] && w341aTabHas(resp, repost2) == nil {
						t.Errorf("order %v: S lost the placeholder on tab %v", order, tab)
					}
				}
			case "other":
				for _, tab := range w341aAllTabs {
					resp, err := shared.tabCall(other, s.uid, tab, 20, "", "")
					if err != nil {
						t.Fatal(err)
					}
					if w341aTabHas(resp, repost2) != nil || w341aTabHas(resp, repost1) != nil {
						t.Errorf("order %v: another viewer got the REPOST on tab %v", order, tab)
					}
				}
			case "home":
				if h := shared.w330Home(t, s); w341aRow(h.GetPosts(), repost2) != nil {
					t.Errorf("order %v: Home shows the REPOST", order)
				}
			}
		}
	}
}

// ---- case 5 ---------------------------------------------------------------------------------------------------------

// The viewer flags after a userLikes trim or cap: the kept REPOST says reposted_by_viewer whatever recentReposts
// holds, and a placeholder says liked/bookmarked.
func TestW341aAttack_FlagsAfterUserLikesTrim(t *testing.T) {
	w := newW335aWorld(t)
	s, repostID := w341aSeed(t, w)
	check := func(label string) {
		t.Helper()
		resp, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		row := w341aRow(resp.GetPosts(), repostID)
		if row == nil || !row.GetRepostedByViewer() || row.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
			t.Errorf("%s: own REPOST = %v, want PROTECTED with reposted_by_viewer", label, row)
		}
		bms, likes := w341aLists(t, s)
		if r := w341aRow(bms, w.pid); r != nil && (!r.GetWithheld() || !r.GetBookmarkedByViewer()) {
			t.Errorf("%s: bookmark row = %v", label, r)
		}
		if r := w341aRow(likes, w.pid); r != nil && (!r.GetWithheld() || !r.GetLikedByViewer()) {
			t.Errorf("%s: likes row = %v", label, r)
		}
	}
	check("untouched")
	// Trim: the original leaves recentReposts (cap 500, best-effort trim of the oldest 100).
	w341aSetFS(t, w, "userLikes/"+s.uid, map[string]any{"recentReposts": firestore.ArrayRemove(w.pid)})
	check("recentReposts trimmed")
	// Cap: recent dropped the like (the Likes row is gone, ADR-0018 D8) and the reposts array is empty too.
	w341aSetFS(t, w, "userLikes/"+s.uid, map[string]any{"recent": firestore.ArrayRemove(w.pid), "recentReposts": []string{}})
	check("recent and recentReposts empty")
	if _, err := w.e.fs.Doc("userLikes/" + s.uid).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	resp, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if row := w341aRow(resp.GetPosts(), repostID); row == nil || !row.GetRepostedByViewer() {
		t.Errorf("userLikes document gone: own REPOST = %v, want reposted_by_viewer", row)
	}
}

// ---- wire bytes, other viewers and other surfaces --------------------------------------------------------------------

// A placeholder's JSON and binary bytes carry only post_id, kind, author and withheld (plus the viewer flag and the
// bookmark time of the owner's own wrapper); another viewer, GetPost and GetThread keep D4, byte for byte against the
// deleted post's NOT_FOUND.
func TestW341aAttack_WireBytesAndUnchangedSurfaces(t *testing.T) {
	w := newW335aWorld(t)
	s, repostID := w341aSeed(t, w)
	other := w.w.user(t)
	r := newW320Chain(t, w335aOn)

	// JSON: allowlist the keys of every placeholder of both lists.
	for _, c := range []struct {
		proc string
		req  proto.Message
		path string
	}{
		{w341aProcLiked, &engagementv1.ListLikedPostsRequest{PageSize: 20}, "posts"},
		{w341aProcBookmarks, &engagementv1.ListBookmarksRequest{PageSize: 20}, "bookmarks"},
	} {
		_, _, body := w.raw(t, r, s, c.proc, c.req)
		if w.leaks(body) {
			t.Fatalf("%s body carries P's content: %s", c.proc, body)
		}
		var got map[string][]map[string]any
		if err := json.Unmarshal([]byte(body), &got); err != nil {
			t.Fatalf("%s: %v (%s)", c.proc, err, body)
		}
		rows := got[c.path]
		if len(rows) == 0 {
			t.Fatalf("%s: no rows in %s", c.proc, body)
		}
		placeholders := 0
		for _, row := range rows {
			view := row
			if c.path == "bookmarks" {
				view, _ = row["post"].(map[string]any)
				for k := range row {
					if k != "post" && k != "bookmarkedAt" {
						t.Errorf("bookmark wrapper key %q", k)
					}
				}
			}
			if wh, _ := view["withheld"].(bool); !wh {
				continue
			}
			placeholders++
			for k := range view {
				if !slices.Contains([]string{"post", "withheld", "likedByViewer", "repostedByViewer", "bookmarkedByViewer"}, k) {
					t.Errorf("%s: placeholder view key %q", c.proc, k)
				}
			}
			post, _ := view["post"].(map[string]any)
			for k := range post {
				if !slices.Contains([]string{"postId", "kind", "author"}, k) {
					t.Errorf("%s: placeholder post key %q (%v)", c.proc, k, post[k])
				}
			}
		}
		if placeholders == 0 {
			t.Errorf("%s: no placeholder in %s", c.proc, body)
		}
	}

	// Binary: field sets, no unknown fields, the message equals the expected one.
	var lk engagementv1.ListLikedPostsResponse
	raw := w341aBin(t, r, s.token, w341aProcLiked, &engagementv1.ListLikedPostsRequest{PageSize: 20}, &lk)
	row := w341aRow(lk.GetPosts(), w.pid)
	w341aCheckPlaceholder(t, "binary likes", row, w.pid, postsv1.PostKind_POST_KIND_POST, w.p.uid, "liked_by_viewer")
	want := &postsv1.PostView{
		Post:          &postsv1.Post{PostId: w.pid, Kind: postsv1.PostKind_POST_KIND_POST, Author: row.GetPost().GetAuthor()},
		LikedByViewer: true, RepostedByViewer: row.GetRepostedByViewer(), BookmarkedByViewer: row.GetBookmarkedByViewer(), Withheld: true,
	}
	if !proto.Equal(row, want) {
		t.Errorf("binary placeholder = %v, want exactly %v", row, want)
	}
	if bytes.Contains(raw, []byte(w335aMarkerPrefix)) || bytes.Contains(raw, []byte(w.img)) {
		t.Error("binary Likes answer carries P's text or image id")
	}
	var bm engagementv1.ListBookmarksResponse
	raw = w341aBin(t, r, s.token, w341aProcBookmarks, &engagementv1.ListBookmarksRequest{PageSize: 20}, &bm)
	for _, b := range bm.GetBookmarks() {
		if b.GetPost().GetPost().GetPostId() == w.pid {
			w341aCheckPlaceholder(t, "binary bookmarks", b.GetPost(), w.pid, postsv1.PostKind_POST_KIND_POST, w.p.uid, "bookmarked_by_viewer")
		}
	}
	if bytes.Contains(raw, []byte(w335aMarkerPrefix)) || bytes.Contains(raw, []byte(w.img)) {
		t.Error("binary Bookmarks answer carries P's text or image id")
	}
	// The own REPOST row over the wire: binary and JSON hold no body of P.
	var tl timelinev1.GetUserTimelineResponse
	raw = w341aBin(t, r, s.token, timelinev1connect.TimelineServiceGetUserTimelineProcedure,
		&timelinev1.GetUserTimelineRequest{UserId: s.uid, Tab: tabRepostsPB, PageSize: 20}, &tl)
	if w341aTabHas(&tl, repostID) == nil || bytes.Contains(raw, []byte(w335aMarkerPrefix)) || bytes.Contains(raw, []byte(w.img)) {
		t.Errorf("own Reposts tab binary: row=%v, carries P's content=%v", w341aTabHas(&tl, repostID), bytes.Contains(raw, []byte(w335aMarkerPrefix)))
	}
	_, _, body := w.raw(t, r, s, timelinev1connect.TimelineServiceGetUserTimelineProcedure, &timelinev1.GetUserTimelineRequest{UserId: s.uid, Tab: tabRepostsPB, PageSize: 20})
	if w.leaks(body) {
		t.Errorf("own Reposts tab JSON carries P's content: %s", body)
	}

	// NOT_FOUND parity with the deleted post: S (owner of the placeholders) and another viewer, on P's post and on S's REPOST.
	for _, u := range []bmUser{s, other} {
		w.oracleParity(t, newW320Chain(t, w335aOn), "post of protected P, viewer "+u.uid, u, w.pid)
	}
	w.oracleParity(t, newW320Chain(t, w335aOn), "S's own REPOST of protected P, viewer S", s, repostID)
	w.oracleParity(t, newW320Chain(t, w335aOn), "S's own REPOST of protected P, another viewer", other, repostID)

	// Another viewer: S's tabs carry neither the REPOST, P, nor a placeholder.
	for _, tab := range w341aAllTabs {
		_, _, b := w.raw(t, newW320Chain(t, w335aOn), other, timelinev1connect.TimelineServiceGetUserTimelineProcedure,
			&timelinev1.GetUserTimelineRequest{UserId: s.uid, Tab: tab, PageSize: 20})
		if w.leaks(b) || strings.Contains(b, repostID) || strings.Contains(b, `"withheld"`) || strings.Contains(b, w.p.uid) {
			t.Errorf("another viewer, S's %v tab: body mentions the REPOST, P or a placeholder: %s", tab, b)
		}
	}
}
