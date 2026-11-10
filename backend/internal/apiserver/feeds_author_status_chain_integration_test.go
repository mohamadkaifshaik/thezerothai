//go:build integration

package apiserver

// F-03 on the feeds through the real Build chain on the emulators: once an author is SUSPENDED through identity's own
// moderation write (SetAccountStatus, which changes users/{uid} only and never the posts, as before suspend-user's
// HideAuthor pages run), a cold instance drops the author's rows from the Home, list and community feeds and from a
// thread's reply rows, drops an ACTIVE user's REPOST of the author's post, keeps an ACTIVE user's QUOTE of it with the
// embed tombstoned, and GetPost answers the same way for the copies. A restore brings everything back.

import (
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func feedsStatusOn(c *config.Config) {
	listsOn(c)
	communitiesOn(c)
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	c.RateLimit.ListTimelinePerUserPerMinute = 1_000_000
}

// fsPost writes one post doc (a unique id, createdAt ago) and returns its id. extra overrides or adds fields.
func fsPost(t *testing.T, fs *firestore.Client, author string, ago time.Duration, extra map[string]any) string {
	t.Helper()
	id := fmt.Sprintf("%019d", time.Now().Add(-ago).UnixMilli()*1000+rand.Int64N(1000))
	doc := map[string]any{
		"authorId": author, "author": map[string]any{"userId": author, "handle": "h" + author},
		"kind": "POST", "isReply": false, "text": "by " + author, "conversationId": id, "hashtags": []string{},
		"mentions": []map[string]any{}, "likeCount": int64(0), "repostCount": int64(0), "replyCount": int64(0), "quoteCount": int64(0),
		"visibility": "PUBLIC", "createdAt": time.Now().UTC().Add(-ago), "hasMedia": false,
	}
	for k, v := range extra {
		doc[k] = v
	}
	if _, err := fs.Collection("posts").Doc(id).Set(context.Background(), doc); err != nil {
		t.Fatalf("seed post: %v", err)
	}
	return id
}

// copyFields makes a post a REPOST or QUOTE of orig by origAuthor.
func copyFields(kind, orig, origAuthor string) map[string]any {
	m := map[string]any{
		"kind": kind, "embeddedAuthorId": origAuthor,
		"embedded": map[string]any{"postId": orig, "author": map[string]any{"userId": origAuthor, "handle": "h" + origAuthor}, "text": "the original"},
	}
	if kind == "REPOST" {
		m["repostOfId"] = orig
	} else {
		m["quoteOfId"] = orig
	}
	return m
}

func TestFeedsChain_SuspendedAuthorLeavesEveryFeed(t *testing.T) {
	setup := newLTChain(t, feedsStatusOn)
	ctx := context.Background()
	author, copier, viewer := setup.user(t), setup.user(t), setup.user(t)
	for _, target := range []ltUser{author, copier} {
		if _, err := setup.graph.Follow(ctx, authed(viewer.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("f03-follow"), UserId: target.uid})); err != nil {
			t.Fatalf("follow: %v", err)
		}
	}
	fs := setup.fs
	// Home and list rows (root posts, no community).
	orig := fsPost(t, fs, author.uid, 60*time.Second, nil)
	repost := fsPost(t, fs, copier.uid, 50*time.Second, copyFields("REPOST", orig, author.uid))
	quote := fsPost(t, fs, copier.uid, 40*time.Second, copyFields("QUOTE", orig, author.uid))
	plain := fsPost(t, fs, copier.uid, 35*time.Second, nil)
	// The list: the author and the copier, owned by the viewer (seedList with no members writes no posts).
	listID, _ := seedList(t, fs, viewer.uid, false, nil)
	if _, err := fs.Collection("lists").Doc(listID).Update(ctx, []firestore.Update{{Path: "memberIds", Value: []string{author.uid, copier.uid}}}); err != nil {
		t.Fatal(err)
	}
	// The community: one post each, the viewer a member.
	cid := seedCommunity(t, fs, copier.uid, viewer.uid, "ACTIVE")
	inCommunity := func(cid string) map[string]any {
		return map[string]any{"communityId": cid, "conversationCommunityId": cid, "community": map[string]any{"id": cid, "name": "Seeded"}}
	}
	cAuthor := fsPost(t, fs, author.uid, 45*time.Second, inCommunity(cid))
	cCopier := fsPost(t, fs, copier.uid, 44*time.Second, inCommunity(cid))
	// A thread rooted at the copier's plain post with one reply each.
	reply := func(by ltUser, ago time.Duration) string {
		return fsPost(t, fs, by.uid, ago, map[string]any{"kind": "REPLY", "isReply": true, "replyToId": plain, "conversationId": plain, "replyToHandle": "h" + copier.uid})
	}
	rAuthor, rCopier := reply(author, 30*time.Second), reply(copier, 29*time.Second)

	type seen struct{ home, list, community, replies []string }
	read := func(t *testing.T) (seen, map[string]*postsv1.PostView) {
		t.Helper()
		c := newLTChain(t, feedsStatusOn) // cold caches: the identity cache's 60 s bound is the same on every surface
		var s seen
		views := map[string]*postsv1.PostView{}
		h, err := c.timeline.GetHomeTimeline(ctx, authed(viewer.token, &timelinev1.GetHomeTimelineRequest{PageSize: 50}))
		if err != nil {
			t.Fatalf("home: %v", err)
		}
		for _, v := range h.Msg.GetPosts() {
			s.home = append(s.home, v.GetPost().GetPostId())
			views[v.GetPost().GetPostId()] = v
		}
		l, err := c.listTimeline(viewer, listID, 50, "", "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		s.list = idsOf(l)
		cm, err := c.timeline.GetCommunityTimeline(ctx, authed(viewer.token, &timelinev1.GetCommunityTimelineRequest{CommunityId: cid, PageSize: 50}))
		if err != nil {
			t.Fatalf("community: %v", err)
		}
		s.community = feedIDs(cm.Msg)
		th, err := c.posts.GetThread(ctx, authed(viewer.token, &postsv1.GetThreadRequest{PostId: plain, PageSize: 30}))
		if err != nil {
			t.Fatalf("thread: %v", err)
		}
		for _, r := range th.Msg.GetReplies() {
			s.replies = append(s.replies, r.GetPost().GetPostId())
		}
		return s, views
	}
	// check wants every id of want in got and none of gone. Home and list may also hold the community posts (root posts by
	// the same authors), which the community feed checks exactly.
	check := func(t *testing.T, name string, got, want, gone []string) {
		t.Helper()
		for _, id := range want {
			if !slices.Contains(got, id) {
				t.Errorf("%s = %v, missing %s", name, got, id)
			}
		}
		for _, id := range gone {
			if slices.Contains(got, id) {
				t.Errorf("%s = %v, still shows %s", name, got, id)
			}
		}
	}
	all := []string{orig, repost, quote, plain}

	t.Run("ACTIVE: every row shows", func(t *testing.T) {
		s, views := read(t)
		check(t, "home", s.home, all, nil)
		check(t, "list", s.list, all, nil)
		check(t, "community", s.community, []string{cAuthor, cCopier}, nil)
		check(t, "replies", s.replies, []string{rAuthor, rCopier}, nil)
		if e := views[quote].GetPost().GetEmbedded(); e.GetUnavailable() || e.GetText() != "the original" {
			t.Fatalf("QUOTE embed = %v, want the snapshot", e)
		}
	})

	idRepo := identity.NewFirestoreRepo(fs, graph.NewFirestoreRepo(fs))
	if changed, err := idRepo.SetAccountStatus(ctx, author.uid, identity.AccountStatusActive, identity.AccountStatusSuspended, time.Now()); err != nil || !changed {
		t.Fatalf("SetAccountStatus: changed %v err %v", changed, err)
	}

	t.Run("SUSPENDED: the author's rows and REPOSTs leave, the QUOTE is tombstoned", func(t *testing.T) {
		s, views := read(t)
		check(t, "home", s.home, []string{quote, plain}, []string{orig, repost, cAuthor})
		check(t, "list", s.list, []string{quote, plain}, []string{orig, repost, cAuthor})
		check(t, "community", s.community, []string{cCopier}, []string{cAuthor})
		check(t, "replies", s.replies, []string{rCopier}, []string{rAuthor})
		if e := views[quote].GetPost().GetEmbedded(); !e.GetUnavailable() || e.GetPostId() != orig || e.GetText() != "" || e.GetAuthor() != nil {
			t.Fatalf("QUOTE embed = %v, want the tombstone", e)
		}
		// GetPost (security review Low 1): the REPOST is NOT_FOUND, the QUOTE renders the tombstone.
		c := newLTChain(t, feedsStatusOn)
		_, err := c.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: repost}))
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("GetPost(REPOST) err = %v, want NOT_FOUND", err)
		}
		q, err := c.posts.GetPost(ctx, authed(viewer.token, &postsv1.GetPostRequest{PostId: quote}))
		if err != nil {
			t.Fatalf("GetPost(QUOTE): %v", err)
		}
		if e := q.Msg.GetPost().GetPost().GetEmbedded(); !e.GetUnavailable() || e.GetText() != "" || e.GetAuthor() != nil {
			t.Fatalf("GetPost(QUOTE) embed = %v, want the tombstone", e)
		}
	})

	if changed, err := idRepo.SetAccountStatus(ctx, author.uid, identity.AccountStatusSuspended, identity.AccountStatusActive, time.Now()); err != nil || !changed {
		t.Fatalf("restore: changed %v err %v", changed, err)
	}
	t.Run("restored: every row is back", func(t *testing.T) {
		s, _ := read(t)
		check(t, "home", s.home, all, nil)
		check(t, "list", s.list, all, nil)
		check(t, "community", s.community, []string{cAuthor, cCopier}, nil)
		check(t, "replies", s.replies, []string{rAuthor, rCopier}, nil)
	})
}
