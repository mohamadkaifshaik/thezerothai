package search

import (
	"context"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// postsFeedWindow is how many posts one ExplorePosts call scans: the largest page (limits.MaxPageSize, the same size as
// the wide LATEST tier), because replies and REPOSTs dilute the newest rows and are dropped in memory (the query has no
// isReply filter: that would need a composite index that does not exist).
//
// Cost per call (page_size 1..50): 1 query billing max(rows, 1) post reads, at most postsFeedWindow = 50; one graph
// snapshot (60 s instance cache); one cache-first identity.Directory.GetProfiles over the candidates' authors and embedded
// authors (batches of 50, so at most 2); one cached userLikes read when a row is returned and engagement or bookmarks is
// on; at most one batched plan-preview GetAll when a returned row carries a plan. Nothing is written.
const postsFeedWindow = limits.MaxPageSize

// postsFeedBinding seals the ExplorePosts tokens to the caller and to this feed (an ExploreMedia token, or a token from
// another uid, is VALIDATION page_token).
func postsFeedBinding(uid string) string {
	return "search|" + uid + "|POSTS_FEED"
}

// keepPostsFeed is the feed's own row rule, before the per-viewer filter: a root post or a quote, with or without images.
// A reply never lists (as in ExploreMedia: out of its thread a reply has no context, and replies would crowd out the
// top-level posts), and neither does a REPOST: in a global newest-first feed it would show an older post again as new,
// once per reposter.
func keepPostsFeed(p *posts.Post) bool {
	return !p.IsReply && p.Kind != posts.KindReply && p.Kind != posts.KindRepost
}

// explorePosts runs one ExplorePosts page (postsRuntime.explore over posts.Reader.ByLatestFeed, postsFeedWindow rows a
// call, keepPostsFeed).
func (r *postsRuntime) explorePosts(ctx context.Context, uid string, pageSize int32, token string) (*searchv1.ExplorePostsResponse, error) {
	views, next, err := r.explore(ctx, uid, pageSize, token, exploreFeed{
		label: "posts feed", binding: postsFeedBinding, scan: postsFeedWindow, query: r.d.Posts.ByLatestFeed, keep: keepPostsFeed,
	})
	if err != nil {
		return nil, err
	}
	return &searchv1.ExplorePostsResponse{Posts: views, NextPageToken: next}, nil
}
