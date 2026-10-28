//go:build integration

package apiserver

// W3-29b (ADR-0025 D4) through the real Build chain on the emulators, FEATURE_PRIVATE_ACCOUNTS on, the real
// protected-set loader and the real UpdateProfile(is_private) toggle. Every reader below is a cold instance, so the
// budgets are cold and the interceptor read is included:
//   - GetThread: a protected focal is byte-identical to a deleted focal; a protected parent or root is a tombstone
//     (parent_unavailable / root_unavailable) and the focal reply's text stays; replies by the protected author are
//     dropped for a stranger and kept for a follower; the reads stay inside GetThread's 38 cold ceiling;
//   - ListBookmarks and ListLikedPosts (owner-only): rows by the protected author stay for an unapproved caller as
//     stripped withheld placeholders (W3-41a); a REPOST of the author's post is dropped; a QUOTE of it is kept with the
//     stripped PROTECTED embed, nothing is pruned, the placeholders are counted under rows_withheld (rows_dropped_protected
//     is 0), and the cold budgets stay 43 and 23 at page 20;
//   - a follower keeps the rows (wire visibility FOLLOWERS); unfollowing turns them into placeholders and the author unprotecting brings them back (a Follow of a
//     protected account is a follow request, W3-27, so "follow again" is covered by the engagement unit table).

import (
	"context"
	"net/http"
	"slices"
	"testing"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcListLiked = "/dzeroth.engagement.v1.EngagementService/ListLikedPosts"

func w329bOn(c *config.Config) {
	w329aOn(c)
	c.FeatureLikesList = flags.Spec{Name: "likes_list", Mode: flags.On}
}

func (w *w320Chain) w329bReply(t *testing.T, u bmUser, parent, text string) string {
	t.Helper()
	r, err := w.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w329b-reply"), Text: text, ReplyToPostId: parent}))
	if err != nil {
		t.Fatalf("reply: %v", err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

func (w *w320Chain) w329bThread(u bmUser, focal string) (*postsv1.GetThreadResponse, error) {
	r, err := w.posts.GetThread(context.Background(), authed(u.token, &postsv1.GetThreadRequest{PostId: focal, PageSize: 30}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func w329bIDs(vs []*postsv1.PostView) []string {
	var out []string
	for _, v := range vs {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func TestW329b_ThreadAndOwnerListsThroughTheChain(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w329bOn)
	p, stranger, follower, x, quoter, reposter := w.user(t), w.user(t), w.user(t), w.user(t), w.user(t), w.user(t)

	root := w.post(t, p, "protected root")
	pReply := w.w329bReply(t, p, root, "protected reply")
	xReply := w.w329bReply(t, x, root, "x replies to the protected root")
	xDeep := w.w329bReply(t, x, pReply, "x replies to the protected reply")
	public := w.post(t, x, "a public post")
	gone := w.post(t, p, "to be deleted")
	if _, err := w.posts.DeletePost(ctx, authed(p.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w329b-del"), PostId: gone})); err != nil {
		t.Fatal(err)
	}
	qr, err := w.posts.CreatePost(ctx, authed(quoter.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w329b-q"), Text: "my take", QuoteOfPostId: root}))
	if err != nil {
		t.Fatal(err)
	}
	quoteID := qr.Msg.GetPost().GetPost().GetPostId()
	rp, err := w.eng.RepostPost(ctx, authed(reposter.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w329b-rp"), PostId: root}))
	if err != nil {
		t.Fatal(err)
	}
	repostID := rp.Msg.GetRepostPostId()

	// Seeded while P is public: the stranger and the follower bookmark and like P's posts, a quote of one and a plain
	// public post; the stranger also holds a REPOST of P's post (written directly: the repost id is not a public target).
	w.w320Follow(t, follower, p.uid)
	for _, u := range []bmUser{stranger, follower} {
		for i, id := range []string{root, pReply, quoteID, public} {
			if _, err := w.add(u, contractKey("w329b-bm"), id); err != nil {
				t.Fatalf("bookmark %d: %v", i, err)
			}
			w.like(t, u, id)
		}
	}
	w.bookmarkDirect(t, stranger.uid, repostID, 50)
	w.likeDirect(t, stranger.uid, []string{repostID})

	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}

	const rpcThread = postsv1connect.PostServiceGetThreadProcedure

	t.Run("GetThread: a protected focal is the deleted focal", func(t *testing.T) {
		r := newW320Chain(t, w329bOn)
		wantSt, wantCT, wantBody := r.rawRPC(t, stranger.token, rpcThread, `{"postId":"`+gone+`"}`)
		if wantSt != http.StatusNotFound {
			t.Fatalf("oracle = %d %s", wantSt, wantBody)
		}
		st, ct, b := r.rawRPC(t, stranger.token, rpcThread, `{"postId":"`+root+`"}`)
		if st != wantSt || ct != wantCT || b != wantBody {
			t.Errorf("protected focal differs from deleted focal\n  deleted:   %d %s %s\n  protected: %d %s %s", wantSt, wantCT, wantBody, st, ct, b)
		}
		budgettest.Assert(t, "GetThread refusal", r.lineBudget(t, rpcThread), budgettest.Budget{Reads: 38})
	})

	t.Run("GetThread: tombstones, dropped replies, cold budget", func(t *testing.T) {
		r := newW320Chain(t, w329bOn)
		got, err := r.w329bThread(stranger, xDeep)
		if err != nil {
			t.Fatal(err)
		}
		if got.GetFocal().GetPost().GetText() == "" || got.GetParent() != nil || !got.GetParentUnavailable() || got.GetRoot() != nil || !got.GetRootUnavailable() {
			t.Errorf("want the focal text with parent_unavailable and root_unavailable: %v", got)
		}
		budgettest.Assert(t, "GetThread stranger cold", r.lineBudget(t, rpcThread), budgettest.Budget{Reads: 38})

		r = newW320Chain(t, w329bOn)
		got, err = r.w329bThread(stranger, xReply)
		if err != nil {
			t.Fatal(err)
		}
		if ids := w329bIDs(got.GetReplies()); slices.Contains(ids, pReply) || !slices.Contains(ids, xDeep) {
			t.Errorf("stranger replies = %v, want %s dropped and %s kept", ids, pReply, xDeep)
		}
		if line := r.line(t, rpcThread); num(line, "audience_dropped_protected") != 1 {
			t.Errorf("audience_dropped_protected = %v, want 1", line["audience_dropped_protected"])
		}

		r = newW320Chain(t, w329bOn)
		got, err = r.w329bThread(follower, xReply)
		if err != nil {
			t.Fatal(err)
		}
		if ids := w329bIDs(got.GetReplies()); !slices.Contains(ids, pReply) || !slices.Contains(ids, xDeep) {
			t.Errorf("follower replies = %v, want both", ids)
		}
		if got.GetRoot() == nil || got.GetRootUnavailable() {
			t.Errorf("a follower sees the root: %v", got)
		}
		if v := got.GetRoot().GetPost().GetVisibility(); v != postsv1.Visibility_VISIBILITY_FOLLOWERS {
			t.Errorf("root wire visibility = %v, want FOLLOWERS", v)
		}
	})

	marks := func(r *w320Chain, u bmUser) []*postsv1.PostView {
		t.Helper()
		bm, err := r.list(u, 20, "")
		if err != nil {
			t.Fatalf("ListBookmarks: %v", err)
		}
		var out []*postsv1.PostView
		for _, b := range bm.GetBookmarks() {
			out = append(out, b.GetPost())
		}
		return out
	}
	likes := func(r *w320Chain, u bmUser) []*postsv1.PostView {
		t.Helper()
		lk, err := r.listLiked(u, 20, "")
		if err != nil {
			t.Fatalf("ListLikedPosts: %v", err)
		}
		return lk.GetPosts()
	}

	t.Run("lists: a stranger keeps P's rows as withheld placeholders, drops the repost, and the stripped quote", func(t *testing.T) {
		r := newW320Chain(t, w329bOn)
		bm := marks(r, stranger)
		got := w329bIDs(bm)
		if !slices.Contains(got, root) || !slices.Contains(got, pReply) || slices.Contains(got, repostID) || !slices.Contains(got, public) || !slices.Contains(got, quoteID) {
			t.Fatalf("bookmarks = %v", got)
		}
		for _, v := range bm {
			if v.GetPost().GetPostId() != quoteID {
				continue
			}
			if v.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || v.GetPost().GetEmbedded().GetText() != "" ||
				v.GetPost().GetEmbedded().GetPostId() != root || v.GetPost().GetEmbedded().GetAuthor().GetHandle() == "" {
				t.Errorf("quote embed = %v state %v, want post_id and handle only, PROTECTED", v.GetPost().GetEmbedded(), v.GetEmbedViewerState())
			}
		}
		if line := r.line(t, rpcListBookmarks); num(line, "rows_withheld") != 2 || num(line, "rows_dropped_protected") != 1 {
			t.Errorf("bookmarks rows_withheld = %v rows_dropped_protected = %v, want 2 and 1", line["rows_withheld"], line["rows_dropped_protected"])
		}
		for _, id := range []string{root, pReply, repostID} {
			if !w.bookmarkDocExists(t, stranger.uid, id) {
				t.Errorf("bookmark %s was pruned", id)
			}
		}

		r = newW320Chain(t, w329bOn)
		got = w329bIDs(likes(r, stranger))
		if !slices.Contains(got, root) || slices.Contains(got, repostID) || !slices.Contains(got, public) || !slices.Contains(got, quoteID) {
			t.Fatalf("liked = %v", got)
		}
		if line := r.line(t, rpcListLiked); num(line, "rows_withheld") != 2 || num(line, "rows_dropped_protected") != 1 {
			t.Errorf("likes rows_withheld = %v rows_dropped_protected = %v, want 2 and 1", line["rows_withheld"], line["rows_dropped_protected"])
		}
	})

	t.Run("lists: cold budgets are unchanged", func(t *testing.T) {
		r := newW320Chain(t, w329bOn)
		marks(r, stranger)
		budgettest.Assert(t, "ListBookmarks cold page 20", r.lineBudget(t, rpcListBookmarks), budgettest.Budget{Reads: 43})
		r = newW320Chain(t, w329bOn)
		likes(r, stranger)
		budgettest.Assert(t, "ListLikedPosts cold page 20", r.lineBudget(t, rpcListLiked), budgettest.Budget{Reads: 23})
	})

	t.Run("lists: a follower keeps rows; unfollow drops them without pruning; unprotect brings them back", func(t *testing.T) {
		r := newW320Chain(t, w329bOn)
		bm := marks(r, follower)
		if !slices.Contains(w329bIDs(bm), root) || !slices.Contains(w329bIDs(likes(newW320Chain(t, w329bOn), follower)), root) {
			t.Fatalf("the follower lost rows: %v", w329bIDs(bm))
		}
		for _, v := range bm {
			if v.GetPost().GetPostId() == root && v.GetPost().GetVisibility() != postsv1.Visibility_VISIBILITY_FOLLOWERS {
				t.Errorf("wire visibility = %v, want FOLLOWERS", v.GetPost().GetVisibility())
			}
		}

		w.w320Unfollow(t, follower, p.uid)
		for what, vs := range map[string][]*postsv1.PostView{"bookmarks": marks(newW320Chain(t, w329bOn), follower), "likes": likes(newW320Chain(t, w329bOn), follower)} {
			var row *postsv1.PostView
			for _, v := range vs {
				if v.GetPost().GetPostId() == root {
					row = v
				}
			}
			if row == nil || !row.GetWithheld() || row.GetPost().GetText() != "" {
				t.Fatalf("unfollowed: the %s row of %s = %v, want a withheld placeholder", what, root, row)
			}
		}
		if !w.bookmarkDocExists(t, follower.uid, root) {
			t.Error("the bookmark was pruned")
		}

		pub := false
		if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &pub}); err != nil {
			t.Fatalf("unprotect: %v", err)
		}
		if !slices.Contains(w329bIDs(marks(newW320Chain(t, w329bOn), stranger)), root) || !slices.Contains(w329bIDs(likes(newW320Chain(t, w329bOn), stranger)), root) {
			t.Fatal("unprotected but the stranger's rows are missing")
		}
	})
}
