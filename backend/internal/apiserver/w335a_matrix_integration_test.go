//go:build integration

package apiserver

// W3-35a (ADR-0025 D4) the visibility matrix: one protected account P, ten viewer classes, every read path, on cold
// instances through the real Build chain, the real protected-set loader and the real UpdateProfile(is_private) toggle.
//
// The expected cells are the ADR-0025 D4 table, written down per class below (not read off the code):
//   - self, an approved follower and a follower who muted P see P; a follower whose blockedBy overflowed (and who is not
//     blocked) sees P too, at one extra read;
//   - a requester, a stranger, a user P blocks, a user who blocked P (the edge is gone), and a user P blocks whose
//     blockedBy entry was lost to overflow (the fallback read still finds the block) do not;
//   - the refusal of a single post is the deleted post's answer, byte for byte;
//   - nothing an unapproved viewer receives, on any path, contains P's post text or the id of P's post image
//     (the leak scan; the approved viewers' GetPost body carries both, so the scan can see them).
//
// Cells that depend on ADR-0010 block and mute behaviour rather than on protection are asserted only where that
// behaviour is documented (GetPost shows a muted author's post: D6; a list drops it); the rest of such a class is held
// to the leak scan. Notification fan-out (W3-31) and the lifecycle paths have their own files.

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w335aOn is every flag the matrix paths need: the four Part A flags, quotes, replies, bookmarks, likes list, reports,
// notifications and private accounts.
func w335aOn(c *config.Config) {
	w329bOn(c)
	w330On(c)
	c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
}

// tri is a matrix cell: the viewer must get it (yes), must not (no), or the cell is not asserted (na) because it rests on
// ADR-0010 block or mute behaviour that this ticket does not own.
type tri int

const (
	na tri = iota
	yes
	no
)

// w335aMarker is the text of P's posts; w335aMarkerPrefix is what the leak scan looks for in every body.
const w335aMarkerPrefix = "w335a-SECRET-"

// w335aWorld is the seeded matrix: P's posts, X's copies of them, the viewers.
type w335aWorld struct {
	e    *lifecycleEnv
	w    *w320Chain
	p, x bmUser
	// P's post with an image, its reply to X's root, X's root, X's copies of P's post, a deleted post (the oracle).
	pid, img, pReply, xroot, quoteID, repostID, gone string
}

// w335aViewer is one class: who it is and what the ADR says it gets.
type w335aViewer struct {
	name string
	u    bmUser
	// getPost: GetPost, GetThread of the post and (yes) its image in the body; no = the deleted post's answer.
	getPost tri
	// tabs: the four profile tabs (yes = rows, no = author_protected). lists: ListFollowers and ListFollowing of P.
	// pin: GetProfile(P).pinned_post_id. bookmarks and likes: P's post in the viewer's own owner-only lists.
	tabs, lists, pin, bookmarks, likes tri
	// homeRepost: X's repost of P's post in the viewer's Home. homeQuote: X's quote of it, intact (yes) or stripped (no).
	homeRepost, homeQuote tri
}

func (v w335aViewer) sees() bool { return v.getPost == yes }

func (w *w335aWorld) post(t *testing.T, u bmUser, req *postsv1.CreatePostRequest) string {
	t.Helper()
	req.IdempotencyKey = contractKey("w335a-cp")
	r, err := w.w.posts.CreatePost(context.Background(), authed(u.token, req))
	if err != nil {
		t.Fatalf("CreatePost(%q): %v", req.GetText(), err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

func (w *w335aWorld) protect(t *testing.T, prot bool) {
	t.Helper()
	if _, err := w.w.w320Update(w.p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("is_private=%v: %v", prot, err)
	}
}

// newW335aWorld seeds P (public), X's root and copies, and a deleted post; it does not protect.
func newW335aWorld(t *testing.T) *w335aWorld { return newW335aWorldCfg(t, nil) }

// newW335aWorldCfg is newW335aWorld with an extra config mutation (a retire mode, a lowered flag).
func newW335aWorldCfg(t *testing.T, mutate func(*config.Config)) *w335aWorld {
	t.Helper()
	ctx := context.Background()
	e, w := newW320Life(t, func(c *config.Config) {
		w335aOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	x := &w335aWorld{e: e, w: w, p: w.user(t), x: w.user(t)}
	x.img = e.seedMedia(t, x.p.uid, media.PurposePost)
	x.pid = x.post(t, x.p, &postsv1.CreatePostRequest{Text: w335aMarkerPrefix + "post", MediaIds: []string{x.img}})
	gone := x.post(t, x.p, &postsv1.CreatePostRequest{Text: "deleted soon"})
	if _, err := w.posts.DeletePost(ctx, authed(x.p.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w335a-del"), PostId: gone})); err != nil {
		t.Fatal(err)
	}
	x.gone = gone
	x.xroot = x.post(t, x.x, &postsv1.CreatePostRequest{Text: "x's root post"})
	x.pReply = x.post(t, x.p, &postsv1.CreatePostRequest{Text: w335aMarkerPrefix + "reply", ReplyToPostId: x.xroot})
	x.quoteID = x.post(t, x.x, &postsv1.CreatePostRequest{Text: "x quotes p", QuoteOfPostId: x.pid})
	rp, err := w.eng.RepostPost(ctx, authed(x.x.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w335a-rp"), PostId: x.pid}))
	if err != nil {
		t.Fatalf("repost: %v", err)
	}
	x.repostID = rp.Msg.GetRepostPostId()
	// P pins the post (GetProfile omits it for the unapproved).
	if _, err := w.w320Update(x.p, &identityv1.UpdateProfileRequest{PinnedPostId: &x.pid}); err != nil {
		t.Fatalf("pin: %v", err)
	}
	return x
}

// raw posts a protojson request and returns status, content type and body.
func (w *w335aWorld) raw(t *testing.T, r *w320Chain, u bmUser, proc string, req proto.Message) (int, string, string) {
	t.Helper()
	b, err := protojson.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	return r.rawRPC(t, u.token, proc, string(b))
}

// scanBodies returns, for one viewer on a cold chain, the raw body of every read path that could carry P's content.
func (w *w335aWorld) scanBodies(t *testing.T, r *w320Chain, u bmUser) map[string]string {
	t.Helper()
	out := map[string]string{}
	add := func(name, proc string, req proto.Message) {
		_, _, b := w.raw(t, r, u, proc, req)
		out[name] = b
	}
	add("GetPost", postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.pid})
	add("GetPost(X's quote)", postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.quoteID})
	add("GetPost(X's repost)", postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.repostID})
	add("GetPost(P's reply)", postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.pReply})
	for _, id := range []string{w.pid, w.xroot, w.pReply, w.quoteID} {
		add("GetThread("+id+")", postsv1connect.PostServiceGetThreadProcedure, &postsv1.GetThreadRequest{PostId: id, PageSize: 30})
	}
	for _, tab := range []timelinev1.UserTimelineTab{tabPostsPB, tabRepliesPB30, tabMediaPB, tabRepostsPB} {
		add("GetUserTimeline("+tab.String()+")", timelinev1connect.TimelineServiceGetUserTimelineProcedure,
			&timelinev1.GetUserTimelineRequest{UserId: w.p.uid, Tab: tab, PageSize: 20})
	}
	add("GetHomeTimeline", timelinev1connect.TimelineServiceGetHomeTimelineProcedure, &timelinev1.GetHomeTimelineRequest{PageSize: 20})
	add("ListBookmarks", "/dzeroth.engagement.v1.EngagementService/ListBookmarks", &engagementv1.ListBookmarksRequest{PageSize: 20})
	add("ListLikedPosts", "/dzeroth.engagement.v1.EngagementService/ListLikedPosts", &engagementv1.ListLikedPostsRequest{PageSize: 20})
	add("ListFollowers", graphv1connect.GraphServiceListFollowersProcedure, &graphv1.ListFollowersRequest{UserId: w.p.uid, PageSize: 20})
	add("ListFollowing", graphv1connect.GraphServiceListFollowingProcedure, &graphv1.ListFollowingRequest{UserId: w.p.uid, PageSize: 20})
	add("GetProfile", identityv1connect.IdentityServiceGetProfileProcedure,
		&identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: w.p.uid}})
	add("GetProfileRelationship", graphv1connect.GraphServiceGetProfileRelationshipProcedure, &graphv1.GetProfileRelationshipRequest{UserId: w.p.uid})
	add("ListSuggestedUsers", graphv1connect.GraphServiceListSuggestedUsersProcedure, &graphv1.ListSuggestedUsersRequest{})
	add("ListNotifications", notificationsv1connect.NotificationServiceListNotificationsProcedure, &notificationsv1.ListNotificationsRequest{PageSize: 20})
	return out
}

func (w *w335aWorld) leaks(body string) bool {
	return strings.Contains(body, w335aMarkerPrefix) || strings.Contains(body, w.img)
}

func TestW335a_VisibilityMatrix(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	ch := w.w
	user := func() bmUser { return ch.user(t) }
	self, follower, requester, stranger := w.p, user(), user(), user()
	muter, pBlocked, aBlocks := user(), user(), user()
	ovBlocked, ovClean := user(), user()

	// Seeded while P is public: every class follows X (Home) and follows P unless it is a requester or a stranger; every
	// class, P included, bookmarks and likes P's post.
	for _, u := range []bmUser{follower, requester, stranger, muter, pBlocked, aBlocks, ovBlocked, ovClean, w.p} {
		ch.w320Follow(t, u, w.x.uid)
	}
	for _, u := range []bmUser{follower, muter, pBlocked, aBlocks, ovBlocked, ovClean} {
		ch.w320Follow(t, u, w.p.uid)
	}
	for _, u := range []bmUser{self, follower, requester, stranger, muter, pBlocked, aBlocks, ovBlocked, ovClean} {
		if _, err := ch.add(u, contractKey("w335a-bm"), w.pid); err != nil {
			t.Fatalf("bookmark: %v", err)
		}
		ch.like(t, u, w.pid)
	}
	// Relationship states.
	if _, err := ch.graph.Mute(ctx, authed(muter.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("w335a-mute"), UserId: w.p.uid})); err != nil {
		t.Fatalf("mute: %v", err)
	}
	if _, err := ch.graph.Block(ctx, authed(aBlocks.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w335a-ab"), UserId: w.p.uid})); err != nil {
		t.Fatalf("A blocks P: %v", err)
	}
	for _, u := range []bmUser{pBlocked, ovBlocked} {
		if _, err := ch.graph.Block(ctx, authed(w.p.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w335a-pb"), UserId: u.uid})); err != nil {
			t.Fatalf("P blocks: %v", err)
		}
	}
	// Overflow: ovBlocked's blockedBy entry for P was lost to the cap, so it is flagged overflowed and the entry is gone.
	// The follow edge is gone too (Block removes it), so protection refuses every path anyway. ovStale is the same plus a
	// follow edge that was never cleaned (not reachable through the RPCs): only the fallback read of P's own blocked
	// list can refuse it, which is what TestW335a_OverflowFallbackRefusesAStaleEdge checks. ovClean is only flagged.
	if _, err := w.e.fs.Doc("graph/"+ovBlocked.uid).Update(ctx, []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove(w.p.uid)},
		{Path: "blockedByOverflow", Value: true},
	}); err != nil {
		t.Fatalf("overflow setup: %v", err)
	}
	if _, err := w.e.fs.Doc("graph/"+ovClean.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatalf("overflow flag: %v", err)
	}

	w.protect(t, true)
	ch.w328Request(t, requester, w.p.uid)

	viewers := []w335aViewer{
		{"self", self, yes, yes, yes, yes, yes, yes, yes, yes},
		{"approved follower", follower, yes, yes, yes, yes, yes, yes, yes, yes},
		{"requester", requester, no, no, no, no, no, no, no, no},
		{"stranger", stranger, no, no, no, no, no, no, no, no},
		{"follower who muted P", muter, yes, na, yes, yes, no, no, na, na},
		{"P blocks the viewer", pBlocked, no, na, na, na, no, no, no, na},
		{"viewer blocked P", aBlocks, no, na, na, na, no, no, no, na},
		{"P blocks, blockedBy overflowed", ovBlocked, no, na, na, na, no, no, no, na},
		{"follower, blockedBy overflowed (lists and feeds fail closed, ADR-0010)", ovClean, yes, yes, yes, yes, na, na, na, na},
		{"X, who copied P while public", w.x, no, no, no, no, no, no, no, no},
	}
	// X copied P: its own copies are not asked about; the leak scan below is what applies to X.
	viewers[len(viewers)-1].homeRepost, viewers[len(viewers)-1].homeQuote = na, na

	for _, v := range viewers {
		t.Run(v.name, func(t *testing.T) {
			r := newW320Chain(t, w335aOn) // cold: nothing cached from the seeding
			w.checkGetPost(t, r, v)
			if v.getPost == no {
				w.oracleWrites(t, r, v)
			}
			w.checkTabsListsPin(t, r, v)
			w.checkOwnerLists(t, r, v)
			w.checkHome(t, r, v)
			// The leak scan, on another cold instance so no earlier call warmed anything.
			bodies := w.scanBodies(t, newW320Chain(t, w335aOn), v.u)
			if v.sees() {
				if !w.leaks(bodies["GetPost"]) {
					t.Errorf("positive control: the approved viewer's GetPost carries neither the text nor the image id: %s", bodies["GetPost"])
				}
				return
			}
			for name, b := range bodies {
				if w.leaks(b) {
					t.Errorf("%s leaks P's text or image id to %q: %s", name, v.name, b)
				}
			}
		})
	}
}

// checkGetPost: GetPost and the GetThread focal are the deleted post's answer for the unapproved, byte for byte.
func (w *w335aWorld) checkGetPost(t *testing.T, r *w320Chain, v w335aViewer) {
	t.Helper()
	if v.getPost == na {
		return
	}
	for _, c := range []struct {
		name, proc string
		mk         func(id string) proto.Message
	}{
		{"GetPost", postsv1connect.PostServiceGetPostProcedure, func(id string) proto.Message { return &postsv1.GetPostRequest{PostId: id} }},
		{"GetThread", postsv1connect.PostServiceGetThreadProcedure, func(id string) proto.Message { return &postsv1.GetThreadRequest{PostId: id, PageSize: 30} }},
	} {
		st, ct, b := w.raw(t, r, v.u, c.proc, c.mk(w.pid))
		if v.getPost == yes {
			if st != http.StatusOK {
				t.Errorf("%s as %s = %d %s, want 200", c.name, v.name, st, b)
			}
			continue
		}
		wst, wct, wb := w.raw(t, r, v.u, c.proc, c.mk(w.gone))
		if wst != http.StatusNotFound {
			t.Fatalf("%s oracle (deleted post) as %s = %d %s", c.name, v.name, wst, wb)
		}
		if st != wst || ct != wct || b != wb {
			t.Errorf("%s as %s differs from the deleted post\n  deleted:   %d %s %s\n  protected: %d %s %s", c.name, v.name, wst, wct, wb, st, ct, b)
		}
	}
}

func (w *w335aWorld) checkTabsListsPin(t *testing.T, r *w320Chain, v w335aViewer) {
	t.Helper()
	if v.tabs != na {
		for _, tab := range []timelinev1.UserTimelineTab{tabPostsPB, tabRepliesPB30, tabMediaPB, tabRepostsPB} {
			resp, err := r.tabCall(v.u, w.p.uid, tab, 20, "", "")
			if err != nil {
				t.Errorf("%s tab %v: %v", v.name, tab, err)
				continue
			}
			if got := resp.GetAuthorProtected(); got != (v.tabs == no) {
				t.Errorf("%s tab %v: author_protected = %v, want %v", v.name, tab, got, v.tabs == no)
			}
			if v.tabs == no && (len(resp.GetPosts()) != 0 || resp.GetSinceToken() != "" || resp.GetNextPageToken() != "") {
				t.Errorf("%s tab %v: rows or tokens with author_protected: %v", v.name, tab, resp)
			}
			if v.tabs == yes && tab == tabPostsPB {
				found := false
				for _, pv := range resp.GetPosts() {
					found = found || pv.GetPost().GetPostId() == w.pid
				}
				if !found {
					t.Errorf("%s: P's post is not on the Posts tab", v.name)
				}
			}
		}
	}
	if v.lists != na {
		_, errFollowers := r.graph.ListFollowers(context.Background(), authed(v.u.token, &graphv1.ListFollowersRequest{UserId: w.p.uid, PageSize: 20}))
		_, errFollowing := r.graph.ListFollowing(context.Background(), authed(v.u.token, &graphv1.ListFollowingRequest{UserId: w.p.uid, PageSize: 20}))
		for what, err := range map[string]error{"ListFollowers": errFollowers, "ListFollowing": errFollowing} {
			if v.lists == yes && err != nil {
				t.Errorf("%s as %s: %v", what, v.name, err)
			}
			if v.lists == no {
				d := wireError(t, err, connect.CodeFailedPrecondition)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
					t.Errorf("%s as %s reason = %v, want PROTECTED_ACCOUNT", what, v.name, d.GetReason())
				}
			}
		}
	}
	if v.pin != na {
		if got := r.w326bGetProfile(t, v.u, w.p.uid).GetPinnedPostId(); (got == w.pid) != (v.pin == yes) || (v.pin == no && got != "") {
			t.Errorf("%s: GetProfile pinned_post_id = %q, want %v", v.name, got, v.pin == yes)
		}
	}
}

func (w *w335aWorld) checkOwnerLists(t *testing.T, r *w320Chain, v w335aViewer) {
	t.Helper()
	if v.bookmarks != na {
		bm, err := r.list(v.u, 20, "")
		if err != nil {
			t.Fatalf("%s ListBookmarks: %v", v.name, err)
		}
		var ids []string
		for _, b := range bm.GetBookmarks() {
			ids = append(ids, b.GetPost().GetPost().GetPostId())
		}
		if got := slices.Contains(ids, w.pid); got != (v.bookmarks == yes) {
			t.Errorf("%s: P's post in ListBookmarks = %v, want %v (%v)", v.name, got, v.bookmarks == yes, ids)
		}
	}
	if v.likes != na {
		lk, err := r.listLiked(v.u, 20, "")
		if err != nil {
			t.Fatalf("%s ListLikedPosts: %v", v.name, err)
		}
		if got := slices.Contains(w329bIDs(lk.GetPosts()), w.pid); got != (v.likes == yes) {
			t.Errorf("%s: P's post in ListLikedPosts = %v, want %v", v.name, got, v.likes == yes)
		}
	}
}

// checkHome: X's REPOST of P's post is dropped for the unapproved and X's QUOTE of it keeps post_id and the handle only.
func (w *w335aWorld) checkHome(t *testing.T, r *w320Chain, v w335aViewer) {
	t.Helper()
	if v.homeRepost == na && v.homeQuote == na {
		return
	}
	home := r.w330Home(t, v.u)
	views := w330Views(home.GetPosts())
	if v.homeRepost != na {
		if _, got := views[w.repostID]; got != (v.homeRepost == yes) {
			t.Errorf("%s: X's repost of P in Home = %v, want %v", v.name, got, v.homeRepost == yes)
		}
	}
	if v.homeQuote != na {
		q, ok := views[w.quoteID]
		if !ok {
			t.Errorf("%s: X's quote is missing from Home (the quote of a protected post is stripped, never dropped)", v.name)
			return
		}
		intact := q.GetPost().GetEmbedded().GetText() != ""
		stripped := q.GetEmbedViewerState() == postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED
		if v.homeQuote == yes && (!intact || stripped) {
			t.Errorf("%s: X's quote embed = %v state %v, want it intact", v.name, q.GetPost().GetEmbedded(), q.GetEmbedViewerState())
		}
		if v.homeQuote == no && (intact || !stripped || q.GetPost().GetEmbedded().GetPostId() != w.pid || q.GetPost().GetEmbedded().GetAuthor().GetHandle() == "") {
			t.Errorf("%s: X's quote embed = %v state %v, want PROTECTED with post_id and handle only", v.name, q.GetPost().GetEmbedded(), q.GetEmbedViewerState())
		}
	}
}

// oracleParity asserts GetPost and the GetThread focal of id are the deleted post's answer for u.
func (w *w335aWorld) oracleParity(t *testing.T, r *w320Chain, what string, u bmUser, id string) {
	t.Helper()
	for _, c := range []struct {
		name, proc string
		mk         func(id string) proto.Message
	}{
		{"GetPost", postsv1connect.PostServiceGetPostProcedure, func(id string) proto.Message { return &postsv1.GetPostRequest{PostId: id} }},
		{"GetThread", postsv1connect.PostServiceGetThreadProcedure, func(id string) proto.Message { return &postsv1.GetThreadRequest{PostId: id, PageSize: 30} }},
	} {
		wst, wct, wb := w.raw(t, r, u, c.proc, c.mk(w.gone))
		if wst != http.StatusNotFound {
			t.Fatalf("%s oracle = %d %s", c.name, wst, wb)
		}
		st, ct, b := w.raw(t, r, u, c.proc, c.mk(id))
		if st != wst || ct != wct || b != wb {
			t.Errorf("%s (%s) differs from the deleted post\n  deleted: %d %s %s\n  got:     %d %s %s", c.name, what, wst, wct, wb, st, ct, b)
		}
	}
}

// ADR-0025 D4 row "P blocks A" with A's blockedBy overflowed: the fallback read of P's blocked list refuses a viewer whose
// follow edge was left behind. The same state without the block shows the post.
func TestW335a_OverflowFallbackRefusesAStaleEdge(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	stale, clean := w.w.user(t), w.w.user(t)
	w.w.w320Follow(t, stale, w.p.uid)
	w.w.w320Follow(t, clean, w.p.uid)
	if _, err := w.w.graph.Block(ctx, authed(w.p.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w335a-st"), UserId: stale.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := w.e.fs.Doc("graph/"+stale.uid).Update(ctx, []firestore.Update{
		{Path: "blockedBy", Value: firestore.ArrayRemove(w.p.uid)},
		{Path: "following", Value: firestore.ArrayUnion(w.p.uid)},
		{Path: "blockedByOverflow", Value: true},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.e.fs.Doc("graph/"+clean.uid).Update(ctx, []firestore.Update{{Path: "blockedByOverflow", Value: true}}); err != nil {
		t.Fatal(err)
	}
	w.protect(t, true)
	r := newW320Chain(t, w335aOn)
	w.oracleParity(t, r, "stale edge, P blocks, blockedBy overflowed", stale, w.pid)
	if st, _, b := w.raw(t, newW320Chain(t, w335aOn), clean, postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.pid}); st != http.StatusOK || !w.leaks(b) {
		t.Errorf("a follower with the overflow flag and no block = %d %s, want the post", st, b)
	}
}

// ADR-0025 D4 rows "P suspended" and "post taken down": an approved follower gets the deleted post's answer.
func TestW335a_SuspendedAuthorAndTakenDownPostHideFromApprovedFollowers(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	f := w.w.user(t)
	w.w.w320Follow(t, f, w.p.uid)
	down := w.post(t, w.p, &postsv1.CreatePostRequest{Text: w335aMarkerPrefix + "taken down"})
	w.protect(t, true)

	if st, _, b := w.raw(t, newW320Chain(t, w335aOn), f, postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: down}); st != http.StatusOK {
		t.Fatalf("control: the follower reads the post before the takedown: %d %s", st, b)
	}
	if _, err := w.e.fs.Doc("posts/"+down).Set(ctx, map[string]any{"moderation": "TAKEN_DOWN"}, firestore.MergeAll); err != nil {
		t.Fatal(err)
	}
	w.oracleParity(t, newW320Chain(t, w335aOn), "taken down, approved follower", f, down)

	w.w.w320SetStatus(t, w.p.uid, "SUSPENDED")
	w.oracleParity(t, newW320Chain(t, w335aOn), "author suspended, approved follower", f, w.pid)
	for _, b := range w.scanBodies(t, newW320Chain(t, w335aOn), f) {
		if strings.Contains(b, w335aMarkerPrefix) && strings.Contains(b, "taken down") {
			t.Errorf("a taken-down post's text reached the follower: %s", b)
		}
	}
}

// Owed by W3-29b (it covered this only with fakes): following a protected account again, request then accept, brings
// that account's rows back in the follower's ListBookmarks and ListLikedPosts; until the accept they stay hidden.
func TestW335a_RefollowRequestAcceptBringsBackBookmarksAndLikes(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	u := w.w.user(t)
	w.w.w320Follow(t, u, w.p.uid)
	if _, err := w.w.add(u, contractKey("w335a-rf-bm"), w.pid); err != nil {
		t.Fatal(err)
	}
	w.w.like(t, u, w.pid)
	rows := func(what string, want bool) {
		t.Helper()
		r := newW320Chain(t, w335aOn)
		w.checkOwnerLists(t, r, w335aViewer{name: what, u: u, bookmarks: triOf(want), likes: triOf(want)})
	}
	rows("follower, P public", true)
	w.protect(t, true)
	rows("still an approved follower after P protects", true)
	if _, err := w.w.graph.Unfollow(ctx, authed(u.token, &graphv1.UnfollowRequest{IdempotencyKey: contractKey("w335a-rf-uf"), UserId: w.p.uid})); err != nil {
		t.Fatal(err)
	}
	rows("unfollowed", false)
	w.w.w328Request(t, u, w.p.uid)
	rows("requested again, not yet accepted", false)
	if _, err := w.w.w328Respond(w.p, u.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}
	rows("accepted", true)
	// Home too: X's repost of P's post is back for a follower of X.
	w.w.w320Follow(t, u, w.x.uid)
	if _, ok := w330Views(newW320Chain(t, w335aOn).w330Home(t, u).GetPosts())[w.repostID]; !ok {
		t.Errorf("after the accept, X's repost of P's post is not in the follower's Home")
	}
}

func triOf(b bool) tri {
	if b {
		return yes
	}
	return no
}

// oracleWrites asserts that every write that names a post (like, bookmark, report, reply, quote, repost) answers for P's
// post exactly what it answers for a deleted post, for a viewer who may not see P.
func (w *w335aWorld) oracleWrites(t *testing.T, r *w320Chain, v w335aViewer) {
	t.Helper()
	body := func(kind, id string) (string, string) {
		key := contractKey("w335a-" + kind)
		switch kind {
		case "like":
			return "/dzeroth.engagement.v1.EngagementService/LikePost", fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, key, id)
		case "bookmark":
			return rpcAddBookmark, fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, key, id)
		case "repost":
			return "/dzeroth.engagement.v1.EngagementService/RepostPost", fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, key, id)
		case "report":
			return "/dzeroth.moderation.v1.ModerationService/ReportContent", fmt.Sprintf(`{"idempotencyKey":%q,"targetType":"REPORT_TARGET_TYPE_POST","targetId":%q,"reason":"REPORT_REASON_SPAM"}`, key, id)
		case "reply":
			return postsv1connect.PostServiceCreatePostProcedure, fmt.Sprintf(`{"idempotencyKey":%q,"text":"hi","replyToPostId":%q}`, key, id)
		default: // quote
			return postsv1connect.PostServiceCreatePostProcedure, fmt.Sprintf(`{"idempotencyKey":%q,"text":"q","quoteOfPostId":%q}`, key, id)
		}
	}
	for _, kind := range []string{"like", "bookmark", "repost", "report", "reply", "quote"} {
		proc, goneBody := body(kind, w.gone)
		wst, wct, wb := r.rawRPC(t, v.u.token, proc, goneBody)
		_, protBody := body(kind, w.pid)
		st, ct, b := r.rawRPC(t, v.u.token, proc, protBody)
		if wst != http.StatusNotFound {
			t.Errorf("%s as %s: oracle (deleted post) = %d %s", kind, v.name, wst, wb)
			continue
		}
		if st != wst || ct != wct || b != wb {
			t.Errorf("%s as %s differs from the deleted post\n  deleted:   %d %s %s\n  protected: %d %s %s", kind, v.name, wst, wct, wb, st, ct, b)
		}
	}
}
