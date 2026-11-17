package search

import (
	"context"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// mediaFeedWindow is how many posts one ExploreMedia call scans, the same scan size as the hashtag MEDIA tab. A page is
// cut at the page size afterwards; the token resumes after the last row returned (or the last row scanned).
const mediaFeedWindow = mediaScan

// mediaFeedBinding seals the ExploreMedia tokens to the caller (a token from another uid is VALIDATION page_token).
func mediaFeedBinding(uid string) string {
	return "search|" + uid + "|MEDIA_FEED"
}

// keepMediaFeed is the feed's own row rule, before the per-viewer filter: a root post or a quote that carries its own
// images. A reply and a REPOST never list (a REPOST stores hasMedia false anyway), and a quote's embedded images do not
// count (they are not in Media).
func keepMediaFeed(p *posts.Post) bool {
	return len(p.Media) > 0 && !p.IsReply && p.Kind != posts.KindReply && p.Kind != posts.KindRepost
}

// exploreMedia runs one ExploreMedia page (postsRuntime.explore over posts.Reader.ByMediaFeed, mediaFeedWindow rows a
// call, keepMediaFeed).
func (r *postsRuntime) exploreMedia(ctx context.Context, uid string, pageSize int32, token string) (*searchv1.ExploreMediaResponse, error) {
	views, next, err := r.explore(ctx, uid, pageSize, token, exploreFeed{
		label: "media feed", binding: mediaFeedBinding, scan: mediaFeedWindow, query: r.d.Posts.ByMediaFeed, keep: keepMediaFeed,
	})
	if err != nil {
		return nil, err
	}
	return &searchv1.ExploreMediaResponse{Posts: views, NextPageToken: next}, nil
}
