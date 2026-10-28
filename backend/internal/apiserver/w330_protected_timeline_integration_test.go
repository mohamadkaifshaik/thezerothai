//go:build integration

package apiserver

// W3-30 (ADR-0025 D4) through the real Build chain on the emulators, with the real protected-set loader and the real
// UpdateProfile(is_private) toggle (FEATURE_PRIVATE_ACCOUNTS on):
//   - GetUserTimeline of a protected P for an unapproved viewer answers author_protected on all four tabs at 3 cold
//     reads (interceptor, target users, caller graph) and 0 page reads, with no posts and no tokens, even when a
//     follower filled the shared author-recent entry first and even for a since token issued while P was public;
//   - a follower reads the tabs at the unchanged W3-20 ceilings (24 at page 20) and P reads their own;
//   - Home, another user's tabs and the caller's own Reposts tab: X's REPOST of P's post is dropped for an unapproved
//     viewer and X's QUOTE of it is stripped (PROTECTED, no text, post_id and handle kept); an approved viewer sees
//     both unchanged; Home reads never exceed the same page before P protected.

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcGetHomeTimeline = timelinev1connect.TimelineServiceGetHomeTimelineProcedure

func w330On(c *config.Config) {
	w320TabsOn(c)
	c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
	c.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.On}
}

func (e *bmChain) w330Home(t *testing.T, u bmUser) *timelinev1.GetHomeTimelineResponse {
	t.Helper()
	r, err := e.timeline.GetHomeTimeline(context.Background(), authed(u.token, &timelinev1.GetHomeTimelineRequest{PageSize: 20}))
	if err != nil {
		t.Fatalf("GetHomeTimeline: %v", err)
	}
	return r.Msg
}

func w330Views(posts []*postsv1.PostView) map[string]*postsv1.PostView {
	out := map[string]*postsv1.PostView{}
	for _, v := range posts {
		out[v.GetPost().GetPostId()] = v
	}
	return out
}

func TestW330_ProtectedTimelinesThroughTheChain(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w330On)
	p, x, stranger, follower, other := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)

	pid := w.post(t, p, "protected author's post")
	w.w320MarkMedia(t, pid)
	w.post(t, p, "second post")
	w.repostOthers(t, p, other, 1) // P's Reposts tab has a row
	// X copies P's post while P is public.
	rp, err := w.eng.RepostPost(ctx, authed(x.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w330-rp"), PostId: pid}))
	if err != nil {
		t.Fatalf("repost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()
	qr, err := w.posts.CreatePost(ctx, authed(x.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w330-q"), Text: "my take", QuoteOfPostId: pid}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	quoteID := qr.Msg.GetPost().GetPost().GetPostId()
	control := w.post(t, x, "x control post")
	w.w320Follow(t, stranger, x.uid)
	w.w320Follow(t, follower, x.uid)
	w.w320Follow(t, follower, p.uid)

	// Baseline while P is public: a stranger's cold Home and a since token for P's Posts tab.
	pre := newW320Chain(t, w330On)
	preHome := pre.w330Home(t, stranger)
	if len(preHome.GetPosts()) != 3 {
		t.Fatalf("pre-protect Home = %d rows, want X's 3", len(preHome.GetPosts()))
	}
	preReads := pre.lineBudget(t, rpcGetHomeTimeline).Reads()
	preTok, err := pre.tabCall(stranger, p.uid, tabPostsPB, 20, "", "")
	if err != nil || preTok.GetSinceToken() == "" {
		t.Fatalf("pre-protect Posts tab: %v %v", preTok, err)
	}

	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}

	tabs := []struct {
		name string
		tab  timelinev1.UserTimelineTab
	}{{"posts", tabPostsPB}, {"replies", tabRepliesPB30}, {"media", tabMediaPB}, {"reposts", tabRepostsPB}}

	t.Run("unapproved viewer: author_protected at 3 cold reads, 0 page reads, on every tab", func(t *testing.T) {
		for _, tc := range tabs {
			r := newW320Chain(t, w330On)
			resp, err := r.tabCall(stranger, p.uid, tc.tab, 20, "", "")
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			if !resp.GetAuthorProtected() || len(resp.GetPosts()) != 0 || resp.GetNextPageToken() != "" || resp.GetSinceToken() != "" || resp.GetGapPageToken() != "" {
				t.Fatalf("%s: %v, want only author_protected", tc.name, resp)
			}
			budgettest.Assert(t, "GetUserTimeline "+tc.name+" protected, cold", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 3})
			if v, _ := r.line(t, rpcGetUserTimeline)["author_protected"].(bool); !v {
				t.Errorf("%s: request line lacks author_protected=true", tc.name)
			}
		}
	})

	t.Run("a since token issued while P was public gets the same answer", func(t *testing.T) {
		r := newW320Chain(t, w330On)
		resp, err := r.tabCall(stranger, p.uid, tabPostsPB, 20, preTok.GetSinceToken(), "")
		if err != nil || !resp.GetAuthorProtected() || len(resp.GetPosts()) != 0 || resp.GetSinceToken() != "" {
			t.Fatalf("old token: %v err=%v", resp, err)
		}
		budgettest.Assert(t, "old since token, cold", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 3})
	})

	t.Run("the author-recent entry a follower filled never answers a stranger", func(t *testing.T) {
		r := newW320Chain(t, w330On)
		if resp, err := r.tabCall(follower, p.uid, tabPostsPB, 20, "", ""); err != nil || len(resp.GetPosts()) != 3 {
			t.Fatalf("follower fill: %v %v", resp, err)
		}
		resp, err := r.tabCall(stranger, p.uid, tabPostsPB, 20, "", "")
		if err != nil || !resp.GetAuthorProtected() || len(resp.GetPosts()) != 0 {
			t.Fatalf("stranger on a warm instance: %v err=%v", resp, err)
		}
	})

	t.Run("approved follower and the author: unchanged, within the W3-20 ceilings", func(t *testing.T) {
		for _, tc := range tabs {
			for _, who := range []struct {
				name string
				u    bmUser
			}{{"follower", follower}, {"author", p}} {
				r := newW320Chain(t, w330On)
				resp, err := r.tabCall(who.u, p.uid, tc.tab, 20, "", "")
				if err != nil || resp.GetAuthorProtected() || len(resp.GetPosts()) == 0 {
					t.Fatalf("%s %s: %v err=%v", who.name, tc.name, resp, err)
				}
				if tc.name == "posts" || tc.name == "replies" {
					for _, v := range resp.GetPosts() {
						if v.GetPost().GetVisibility() != postsv1.Visibility_VISIBILITY_FOLLOWERS {
							t.Errorf("%s %s: wire visibility = %v, want FOLLOWERS", who.name, tc.name, v.GetPost().GetVisibility())
						}
					}
				}
				budgettest.Assert(t, who.name+" "+tc.name+" cold", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 24})
			}
		}
	})

	t.Run("a protected author who blocks the stranger: the profile NOT_FOUND bytes, never author_protected", func(t *testing.T) {
		b := w.user(t)
		if _, err := w.graph.Block(ctx, authed(b.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("w330-blk"), UserId: stranger.uid})); err != nil {
			t.Fatal(err)
		}
		if _, err := w.w320Update(b, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
			t.Fatal(err)
		}
		r := newW320Chain(t, w330On)
		wantSt, wantCT, wantBody := r.rawRPC(t, stranger.token, "/dzeroth.identity.v1.IdentityService/GetProfile", fmt.Sprintf(`{"userId":%q}`, b.uid))
		if wantSt != http.StatusNotFound {
			t.Fatalf("GetProfile of the blocker = %d %s", wantSt, wantBody)
		}
		for _, tab := range []string{"USER_TIMELINE_TAB_POSTS", "USER_TIMELINE_TAB_REPLIES", "USER_TIMELINE_TAB_MEDIA", "USER_TIMELINE_TAB_REPOSTS"} {
			st, ct, body := r.rawRPC(t, stranger.token, rpcGetUserTimeline, fmt.Sprintf(`{"userId":%q,"tab":%q}`, b.uid, tab))
			if st != wantSt || ct != wantCT || body != wantBody {
				t.Errorf("%s: %d %s %s, want GetProfile's %d %s %s", tab, st, ct, body, wantSt, wantCT, wantBody)
			}
		}
	})

	t.Run("Home: the repost of P is dropped, the quote is stripped, reads do not grow", func(t *testing.T) {
		r := newW320Chain(t, w330On)
		resp := r.w330Home(t, stranger)
		got := w330Views(resp.GetPosts())
		if got[repostID] != nil || got[control] == nil || got[quoteID] == nil {
			t.Fatalf("repost kept=%v control=%v quote=%v", got[repostID] != nil, got[control] != nil, got[quoteID] != nil)
		}
		q := got[quoteID]
		e := q.GetPost().GetEmbedded()
		if q.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || e.GetText() != "" || len(e.GetMedia()) != 0 ||
			e.GetPostId() != pid || e.GetAuthor().GetHandle() == "" {
			t.Fatalf("quote embed = %v state %v, want a stripped PROTECTED copy keeping post_id and handle", e, q.GetEmbedViewerState())
		}
		budgettest.Assert(t, "Home after protect, cold", r.lineBudget(t, rpcGetHomeTimeline), budgettest.Budget{Reads: preReads})

		f := newW320Chain(t, w330On)
		fgot := w330Views(f.w330Home(t, follower).GetPosts())
		if fgot[repostID] == nil || fgot[quoteID] == nil || fgot[quoteID].GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED ||
			fgot[quoteID].GetPost().GetEmbedded().GetText() == "" {
			t.Fatalf("approved Home must be unchanged: repost=%v quote=%v", fgot[repostID] != nil, fgot[quoteID])
		}
	})

	t.Run("another user's tabs and the copier's own profile apply the same rule", func(t *testing.T) {
		for _, tc := range []struct {
			name   string
			viewer bmUser
			tab    timelinev1.UserTimelineTab
			ceil   int64
		}{
			{"stranger on X replies", stranger, tabRepliesPB30, 24},
			{"stranger on X reposts", stranger, tabRepostsPB, 24},
			{"X's own replies tab", x, tabRepliesPB30, 25},
			{"X's own reposts tab", x, tabRepostsPB, 25},
		} {
			r := newW320Chain(t, w330On)
			resp, err := r.tabCall(tc.viewer, x.uid, tc.tab, 20, "", "")
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			got := w330Views(resp.GetPosts())
			// W3-41a (W3-36 L-2): the copier's own profile keeps the REPOST as an undoable PROTECTED row; others drop it.
			if own := tc.viewer.uid == x.uid; (got[repostID] != nil) != own {
				t.Errorf("%s: repost of P kept = %v, want %v", tc.name, got[repostID] != nil, own)
			} else if own {
				rv := got[repostID]
				e := rv.GetPost().GetEmbedded()
				if rv.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || !rv.GetRepostedByViewer() || rv.GetViewerReplyPermission() != postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN || e.GetPostId() != pid || e.GetText() != "" || len(e.GetMedia()) != 0 {
					t.Errorf("%s: own repost = %v, want PROTECTED, reposted_by_viewer, embedded post_id only", tc.name, rv)
				}
			}
			if q := got[quoteID]; tc.tab == tabRepliesPB30 && (q == nil || q.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || q.GetPost().GetEmbedded().GetText() != "") {
				t.Errorf("%s: quote = %v, want a stripped PROTECTED copy", tc.name, q)
			}
			budgettest.Assert(t, tc.name+" cold", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: tc.ceil})
		}
		r := newW320Chain(t, w330On)
		resp, err := r.tabCall(follower, x.uid, tabRepliesPB30, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if got := w330Views(resp.GetPosts()); got[repostID] == nil || got[quoteID].GetPost().GetEmbedded().GetText() == "" {
			t.Errorf("approved viewer lost the copies: repost=%v", got[repostID] != nil)
		}
	})
}

const tabRepliesPB30 = timelinev1.UserTimelineTab_USER_TIMELINE_TAB_REPLIES
