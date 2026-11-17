package search

import (
	"context"
	"fmt"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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

// exploreMedia runs one ExploreMedia page: decode the token, read the newest mediaFeedWindow posts with hasMedia strictly
// older than the token's position, keep the feed rows, apply the per-viewer filter (moderation, blocks, mutes, author
// status, protected accounts), cut at the page size and render. A page may be short or empty while a token is set.
func (r *postsRuntime) exploreMedia(ctx context.Context, uid string, pageSize int32, token string) (*searchv1.ExploreMediaResponse, error) {
	if pageSize < 0 {
		return nil, apierr.Validation("page_size", "page_size must not be negative")
	}
	limit := limits.ClampPageSize(pageSize)
	bind := mediaFeedBinding(uid)
	var w posts.Window
	if token != "" {
		c, err := cursor.DecodeAt(r.d.CursorKey, bind, token, r.d.Now())
		if err != nil || cursor.IsFirstPage(c) {
			return nil, tokenError()
		}
		w.Before = &posts.Position{CreatedAt: c.CreatedAt, ID: c.DocID}
	}
	rows, err := r.d.Posts.ByMediaFeed(ctx, w, mediaFeedWindow)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("search: media feed: %w", err), uid)
	}
	cands := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if keepMediaFeed(p) {
			cands = append(cands, p)
		}
	}
	fl, err := r.filter(ctx, uid, cands, false)
	if err != nil {
		return nil, err
	}
	kept := fl.kept
	more := len(rows) == mediaFeedWindow
	var resume *posts.Post
	if len(rows) > 0 {
		resume = rows[len(rows)-1] // the last SCANNED row, kept or not, so a dropped post never stalls the token
	}
	if len(kept) > limit {
		kept = kept[:limit]
		resume, more = kept[limit-1], true
	}
	resp := &searchv1.ExploreMediaResponse{Posts: r.views(ctx, uid, kept, fl)}
	if more && resume != nil {
		resp.NextPageToken = cursor.EncodeAt(r.d.CursorKey, bind, cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}, r.d.Now())
	}
	logTally(ctx, len(resp.Posts), fl.tally)
	return resp, nil
}
