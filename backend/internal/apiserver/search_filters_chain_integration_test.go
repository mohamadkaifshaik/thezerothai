//go:build integration

package apiserver

// SearchPosts from_following (F22) over the real Build chain: the flag gate and the following filter through the real graph.

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func (e *searchChain) postsFollowing(who sUser, query string, tab searchv1.SearchTab) (*searchv1.SearchPostsResponse, error) {
	r, err := e.search.SearchPosts(context.Background(), authed(who.token, &searchv1.SearchPostsRequest{Query: query, Tab: tab, FromFollowing: true}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func TestSearchFiltersChain_FlagOff(t *testing.T) {
	e := newSearchChain(t, nil) // FEATURE_SEARCH_FILTERS unset: off
	u := e.user(t)
	_, err := e.postsFollowing(u, "go", searchv1.SearchTab_SEARCH_TAB_LATEST)
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "search_filters")
	if _, err := e.posts(u, "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, ""); err != nil {
		t.Fatalf("from_following=false must not need the flag: %v", err)
	}
}

// TestSearchFiltersChain_OnlyFollowed: with the flag on, a tag's posts by an account the caller follows are returned, a
// stranger's and the caller's own are not.
func TestSearchFiltersChain_OnlyFollowed(t *testing.T) {
	e := newSearchChain(t, func(c *config.Config) { c.FeatureSearchFilters = flags.Spec{Name: "search_filters", Mode: flags.On} })
	viewer, friend, stranger := e.user(t), e.user(t), e.user(t)
	if _, err := e.graph.Follow(context.Background(), authed(viewer.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("ff-follow"), UserId: friend.uid})); err != nil {
		t.Fatal(err)
	}
	tag := uniqueTag()
	seedTagged(t, e.fs, friend.uid, tag, 3, 0)
	seedTagged(t, e.fs, stranger.uid, tag, 3, 0)
	seedTagged(t, e.fs, viewer.uid, tag, 2, 0)
	for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_LATEST} {
		resp, err := e.postsFollowing(viewer, tag, tab)
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.GetPosts()) != 3 {
			t.Fatalf("%v: %d posts, want the friend's 3", tab, len(resp.GetPosts()))
		}
		for _, p := range resp.GetPosts() {
			if p.GetPost().GetAuthor().GetUserId() != friend.uid {
				t.Fatalf("%v: a post by %s leaked", tab, p.GetPost().GetAuthor().GetUserId())
			}
		}
	}
}
