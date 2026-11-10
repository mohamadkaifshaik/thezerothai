//go:build integration

package apiserver

// F-03 on the owner-only lists through the real Build chain on the emulators (security review M1): once an author is
// SUSPENDED through identity's own moderation write (SetAccountStatus, which changes users/{uid} only and never the
// posts, as before suspend-user's HideAuthor and copy clean-up pages run), a cold instance drops the author's post and an
// ACTIVE user's REPOST of it from the viewer's ListBookmarks and ListLikedPosts, and keeps an ACTIVE user's QUOTE of it
// with its own text and the embed tombstoned. The bookmark docs and userLikes.recent are untouched, and a restore brings
// every row back.

import (
	"context"
	"slices"
	"testing"
	"time"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// engListsStatusOn turns bookmarks, engagement (RepostPost), quotes and the likes list on with the limits relaxed.
func engListsStatusOn(c *config.Config) {
	quoteChain(c)
	likesListChain(c)
}

func TestEngagementListsChain_SuspendedAuthorLeavesBookmarksAndLikes(t *testing.T) {
	ctx := context.Background()
	w := newBMChain(t, engListsStatusOn)
	author, copier, viewer := w.user(t), w.user(t), w.user(t)

	orig := w.post(t, author, "by the author")
	q, err := w.posts.CreatePost(ctx, authed(copier.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("f03-q"), Text: "quoting it", QuoteOfPostId: orig}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	quote := q.Msg.GetPost().GetPost().GetPostId()
	rp, err := w.eng.RepostPost(ctx, authed(copier.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("f03-rp"), PostId: orig}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repost := rp.Msg.GetRepostPostId()
	plain := w.post(t, copier, "the copier's own")

	// The rows are seeded directly: AddBookmark and LikePost resolve a REPOST id to its original, so the REPOST row (a
	// bookmark or like made before that rule, or an id in userLikes.recent) cannot be made through the API.
	all := []string{orig, repost, quote, plain} // oldest first
	for i, id := range all {
		w.bookmarkDirect(t, viewer.uid, id, i)
	}
	w.likeDirect(t, viewer.uid, all)

	type seen struct {
		bookmarks, likes         []string
		bmQuote, likeQuote       *postsv1.Post
		bmInactive, likeInactive int64
	}
	read := func(t *testing.T) seen {
		t.Helper()
		r := newBMChain(t, engListsStatusOn) // cold: the identity cache's 60 s bound is the same on every surface
		var s seen
		bl, err := r.list(viewer, 50, "")
		if err != nil {
			t.Fatalf("ListBookmarks: %v", err)
		}
		s.bookmarks = postIDs(bl)
		for _, row := range bl.GetBookmarks() {
			if row.GetPost().GetPost().GetPostId() == quote {
				s.bmQuote = row.GetPost().GetPost()
			}
		}
		s.bmInactive = num(r.line(t, rpcListBookmarks), "rows_dropped_inactive")
		ll, err := r.listLiked(viewer, 50, "")
		if err != nil {
			t.Fatalf("ListLikedPosts: %v", err)
		}
		s.likes = likedPostIDs(ll)
		for _, v := range ll.GetPosts() {
			if v.GetPost().GetPostId() == quote {
				s.likeQuote = v.GetPost()
			}
		}
		s.likeInactive = num(r.line(t, rpcListLikedPosts), "rows_dropped_inactive")
		return s
	}
	check := func(t *testing.T, name string, got, want []string) {
		t.Helper()
		g, wnt := slices.Clone(got), slices.Clone(want)
		slices.Sort(g)
		slices.Sort(wnt)
		if !slices.Equal(g, wnt) {
			t.Errorf("%s = %v, want %v", name, got, want)
		}
	}
	fullEmbed := func(t *testing.T, name string, p *postsv1.Post) {
		t.Helper()
		if e := p.GetEmbedded(); p == nil || e.GetUnavailable() || e.GetText() != "by the author" || e.GetAuthor().GetUserId() != author.uid {
			t.Errorf("%s QUOTE embed = %v, want the snapshot", name, e)
		}
	}

	t.Run("ACTIVE: every row shows", func(t *testing.T) {
		s := read(t)
		check(t, "bookmarks", s.bookmarks, all)
		check(t, "likes", s.likes, all)
		fullEmbed(t, "bookmarks", s.bmQuote)
		fullEmbed(t, "likes", s.likeQuote)
		if s.bmInactive != 0 || s.likeInactive != 0 {
			t.Errorf("rows_dropped_inactive = %d / %d, want 0", s.bmInactive, s.likeInactive)
		}
	})

	idRepo := identity.NewFirestoreRepo(w.fs, graph.NewFirestoreRepo(w.fs))
	if changed, err := idRepo.SetAccountStatus(ctx, author.uid, identity.AccountStatusActive, identity.AccountStatusSuspended, time.Now()); err != nil || !changed {
		t.Fatalf("SetAccountStatus: changed %v err %v", changed, err)
	}

	t.Run("SUSPENDED: the author's post and the REPOST leave, the QUOTE is tombstoned, storage untouched", func(t *testing.T) {
		s := read(t)
		check(t, "bookmarks", s.bookmarks, []string{quote, plain})
		check(t, "likes", s.likes, []string{quote, plain})
		for name, p := range map[string]*postsv1.Post{"bookmarks": s.bmQuote, "likes": s.likeQuote} {
			if p.GetText() != "quoting it" {
				t.Errorf("%s QUOTE text = %q, want its own", name, p.GetText())
			}
			if e := p.GetEmbedded(); !e.GetUnavailable() || e.GetPostId() != orig || e.GetText() != "" || e.GetAuthor() != nil || len(e.GetMedia()) != 0 {
				t.Errorf("%s QUOTE embed = %v, want the tombstone", name, e)
			}
		}
		if s.bmInactive != 2 || s.likeInactive != 2 {
			t.Errorf("rows_dropped_inactive = %d / %d, want 2 (the post and the REPOST)", s.bmInactive, s.likeInactive)
		}
		for _, id := range all {
			if !w.bookmarkDocExists(t, viewer.uid, id) {
				t.Errorf("bookmark doc %s was deleted: a restore must bring it back", id)
			}
		}
		if got := userLikesRecent(t, w, viewer.uid); !slices.Equal(got, all) {
			t.Errorf("userLikes.recent = %v, want %v untouched", got, all)
		}
	})

	if changed, err := idRepo.SetAccountStatus(ctx, author.uid, identity.AccountStatusSuspended, identity.AccountStatusActive, time.Now()); err != nil || !changed {
		t.Fatalf("restore: changed %v err %v", changed, err)
	}
	t.Run("restored: every row is back", func(t *testing.T) {
		s := read(t)
		check(t, "bookmarks", s.bookmarks, all)
		check(t, "likes", s.likes, all)
		fullEmbed(t, "bookmarks", s.bmQuote)
		fullEmbed(t, "likes", s.likeQuote)
	})
}
