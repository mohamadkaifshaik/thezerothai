//go:build integration

package apiserver

// W3-41a (ADR-0025 note W3-36 L-2) through the real Build chain on the emulators: the owner keeps an undo on their own
// REPOST, like and bookmark of a protected author they can no longer see.
//   - S liked, bookmarked and reposted P's post while P was public; P protects. S's own Likes and Bookmarks lists keep the
//     row as a withheld placeholder (post_id, kind, author; no text, media, counts or timestamp), S's own profile keeps
//     the REPOST with embed_viewer_state PROTECTED and reposted_by_viewer, and another viewer of S's profile and S's
//     Home still drop the REPOST (GetPost stays the deleted post's NOT_FOUND: TestW335a_VisibilityMatrix);
//   - Unlike, Remove bookmark and Undo repost from those ids land and the next page no longer holds the rows;
//   - a follower and an unprotect bring the full rows back;
//   - every list and tab stays inside its documented cold budget (+0 reads, +0 writes).

import (
	"context"
	"testing"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// w341aSeed makes S like, bookmark and repost P's post while P is public, then P protects.
func w341aSeed(t *testing.T, w *w335aWorld) (s bmUser, repostID string) {
	t.Helper()
	s = w.w.user(t)
	if _, err := w.w.add(s, contractKey("w341a-bm"), w.pid); err != nil {
		t.Fatalf("bookmark: %v", err)
	}
	w.w.like(t, s, w.pid)
	rp, err := w.w.eng.RepostPost(context.Background(), authed(s.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w341a-rp"), PostId: w.pid}))
	if err != nil {
		t.Fatalf("repost: %v", err)
	}
	w.protect(t, true)
	return s, rp.Msg.GetRepostPostId()
}

func w341aRow(vs []*postsv1.PostView, id string) *postsv1.PostView {
	for _, v := range vs {
		if v.GetPost().GetPostId() == id {
			return v
		}
	}
	return nil
}

// w341aLists reads S's two owner lists, each on its own cold chain, and returns the post views.
func w341aLists(t *testing.T, s bmUser) (bookmarks, liked []*postsv1.PostView) {
	t.Helper()
	bm, err := newW320Chain(t, w335aOn).list(s, 20, "")
	if err != nil {
		t.Fatalf("ListBookmarks: %v", err)
	}
	for _, b := range bm.GetBookmarks() {
		bookmarks = append(bookmarks, b.GetPost())
	}
	lk, err := newW320Chain(t, w335aOn).listLiked(s, 20, "")
	if err != nil {
		t.Fatalf("ListLikedPosts: %v", err)
	}
	return bookmarks, lk.GetPosts()
}

func TestW341a_OwnerPlaceholdersAndUndo(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	s, repostID := w341aSeed(t, w)
	other := w.w.user(t)

	t.Run("lists: withheld placeholders, flags true, cold budgets unchanged", func(t *testing.T) {
		r := newW320Chain(t, w335aOn)
		bm, err := r.list(s, 20, "")
		if err != nil {
			t.Fatal(err)
		}
		var row *postsv1.PostView
		for _, b := range bm.GetBookmarks() {
			if b.GetPost().GetPost().GetPostId() == w.pid {
				row = b.GetPost()
			}
		}
		if row == nil || !row.GetWithheld() || !row.GetBookmarkedByViewer() {
			t.Fatalf("bookmark row = %v, want a withheld placeholder with bookmarked_by_viewer", row)
		}
		budgettest.Assert(t, "ListBookmarks cold page 20", r.lineBudget(t, rpcListBookmarks), budgettest.Budget{Reads: 43})
		if line := r.line(t, rpcListBookmarks); num(line, "rows_withheld") < 1 || num(line, "rows_dropped_protected") != 0 {
			t.Errorf("request line rows_withheld = %v rows_dropped_protected = %v", line["rows_withheld"], line["rows_dropped_protected"])
		}

		r = newW320Chain(t, w335aOn)
		lk, err := r.listLiked(s, 20, "")
		if err != nil {
			t.Fatal(err)
		}
		row = w341aRow(lk.GetPosts(), w.pid)
		if row == nil || !row.GetWithheld() || !row.GetLikedByViewer() {
			t.Fatalf("liked row = %v, want a withheld placeholder with liked_by_viewer", row)
		}
		budgettest.Assert(t, "ListLikedPosts cold page 20", r.lineBudget(t, rpcListLiked), budgettest.Budget{Reads: 23})
		// The byte check: only post_id, kind and the author snapshot are set on the post.
		p := row.GetPost()
		if p.GetText() != "" || len(p.GetMedia()) != 0 || len(p.GetHashtags()) != 0 || len(p.GetMentions()) != 0 || p.GetCreatedAt() != nil ||
			p.GetLikeCount() != 0 || p.GetReplyCount() != 0 || p.GetRepostCount() != 0 || p.GetConversationId() != "" || p.GetEmbedded() != nil ||
			p.GetAuthor().GetUserId() != w.p.uid || p.GetKind() != postsv1.PostKind_POST_KIND_POST || p.GetVisibility() != postsv1.Visibility_VISIBILITY_UNSPECIFIED ||
			row.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
			t.Errorf("placeholder carries more than post_id, kind and author: %v", row)
		}
	})

	t.Run("own profile: the REPOST stays as a PROTECTED row; another viewer and Home drop it", func(t *testing.T) {
		r := newW320Chain(t, w335aOn)
		resp, err := r.tabCall(s, s.uid, tabRepostsPB, 20, "", "")
		if err != nil {
			t.Fatalf("Reposts tab: %v", err)
		}
		row := w341aRow(resp.GetPosts(), repostID)
		if row == nil {
			t.Fatalf("the own REPOST is missing from the Reposts tab: %v", w329bIDs(resp.GetPosts()))
		}
		e := row.GetPost().GetEmbedded()
		if row.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || !row.GetRepostedByViewer() ||
			e.GetPostId() != w.pid || e.GetAuthor().GetHandle() == "" || e.GetText() != "" || len(e.GetMedia()) != 0 || e.GetCreatedAt() != nil {
			t.Errorf("own REPOST = %v, want PROTECTED, reposted_by_viewer, embedded post_id and author only", row)
		}
		budgettest.Assert(t, "GetUserTimeline own Reposts cold", r.lineBudget(t, rpcGetUserTimeline), budgettest.Budget{Reads: 4 + 20})

		// Another viewer of S's profile: D4 unchanged, the REPOST is dropped.
		resp, err = newW320Chain(t, w335aOn).tabCall(other, s.uid, tabRepostsPB, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if w341aRow(resp.GetPosts(), repostID) != nil {
			t.Errorf("another viewer sees S's REPOST of protected P: %v", w329bIDs(resp.GetPosts()))
		}
		// S's Home: dropped too (the owner rule is the profile and the two lists only).
		if home := newW320Chain(t, w335aOn).w330Home(t, s); w341aRow(home.GetPosts(), repostID) != nil {
			t.Error("S's Home shows S's REPOST of protected P")
		}
	})

	t.Run("undo from the placeholders lands and the rows go", func(t *testing.T) {
		if _, err := w.w.eng.UnlikePost(ctx, authed(s.token, &engagementv1.UnlikePostRequest{IdempotencyKey: contractKey("w341a-ul"), PostId: w.pid})); err != nil {
			t.Fatalf("UnlikePost of the placeholder: %v", err)
		}
		if _, err := w.w.remove(s, contractKey("w341a-rm"), w.pid); err != nil {
			t.Fatalf("RemoveBookmark of the placeholder: %v", err)
		}
		// Undo repost acts on the original's id (embedded.post_id), as the client does from the kept row.
		if _, err := w.w.eng.UndoRepost(ctx, authed(s.token, &engagementv1.UndoRepostRequest{IdempotencyKey: contractKey("w341a-ur"), PostId: w.pid})); err != nil {
			t.Fatalf("UndoRepost of the placeholder: %v", err)
		}
		bms, lks := w341aLists(t, s)
		if w341aRow(bms, w.pid) != nil || w341aRow(lks, w.pid) != nil {
			t.Error("the placeholder rows survived the undo")
		}
		resp, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if w341aRow(resp.GetPosts(), repostID) != nil {
			t.Errorf("the own REPOST survived Undo repost: %v", w329bIDs(resp.GetPosts()))
		}
		if fsDocExists(t, w.w.fs, "likes/"+w.pid+"_"+s.uid) || fsDocExists(t, w.w.fs, "reposts/"+w.pid+"_"+s.uid) {
			t.Error("the like or repost doc remains")
		}
	})
}

// An unprotect and an approval bring the full rows back (the matrix cells of the ticket that need a state change).
func TestW341a_ApprovedAndUnprotectedRowsAreFull(t *testing.T) {
	w := newW335aWorld(t)
	s, repostID := w341aSeed(t, w)
	full := func(label string) {
		t.Helper()
		bms, lks := w341aLists(t, s)
		for what, vs := range map[string][]*postsv1.PostView{"bookmarks": bms, "likes": lks} {
			row := w341aRow(vs, w.pid)
			if row == nil || row.GetWithheld() || row.GetPost().GetText() == "" {
				t.Fatalf("%s: %s row = %v, want the full row", label, what, row)
			}
		}
		resp, err := newW320Chain(t, w335aOn).tabCall(s, s.uid, tabRepostsPB, 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		row := w341aRow(resp.GetPosts(), repostID)
		if row == nil || row.GetEmbedViewerState() == postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED || row.GetPost().GetEmbedded().GetText() == "" {
			t.Fatalf("%s: own REPOST = %v, want the full embed", label, row)
		}
	}

	w.protect(t, false)
	full("unprotected")
	w.protect(t, true)

	// S asks to follow P and P accepts: approved, the full rows.
	w.w.w328Request(t, s, w.p.uid)
	if _, err := w.w.w328Respond(w.p, s.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}
	full("approved follower")
}
