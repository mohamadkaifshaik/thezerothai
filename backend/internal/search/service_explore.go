package search

import (
	"context"
	"fmt"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// exploreFeed is one of the global (author-less) Trending feeds: ExploreMedia and ExplorePosts. Both page the same way and
// apply the same per-viewer filter; they differ only in the query, the scan size, the feed's own row rule and the token
// binding.
type exploreFeed struct {
	// label names the feed in a wrapped query error ("media feed", "posts feed").
	label string
	// binding seals the feed's tokens to the caller and to this feed (a token of another uid or of the other feed is
	// VALIDATION page_token).
	binding func(uid string) string
	// scan is how many posts one call reads, whatever the page size.
	scan int
	// query is the posts.Reader method of the feed (newest first, strictly older than the window's Before).
	query func(ctx context.Context, w posts.Window, limit int) ([]*posts.Post, error)
	// keep is the feed's own row rule, applied before the per-viewer filter.
	keep func(p *posts.Post) bool
}

// explore runs one page of feed f: decode the token, read the newest f.scan posts strictly older than the token's
// position, keep the feed rows, apply the per-viewer filter (moderation, blocks and mutes either way, author status,
// protected accounts), cut at the page size and render with the viewer's flags. A page may be short or empty while a token
// is set: the token resumes after the last row returned when the page was cut, else after the last row SCANNED (kept or
// not), so a dropped post never stalls the chain and nothing between two pages is skipped or repeated.
func (r *postsRuntime) explore(ctx context.Context, uid string, pageSize int32, token string, f exploreFeed) ([]*postsv1.PostView, string, error) {
	if pageSize < 0 {
		return nil, "", apierr.Validation("page_size", "page_size must not be negative")
	}
	limit := limits.ClampPageSize(pageSize)
	bind := f.binding(uid)
	var w posts.Window
	if token != "" {
		c, err := cursor.DecodeAt(r.d.CursorKey, bind, token, r.d.Now())
		if err != nil || cursor.IsFirstPage(c) {
			return nil, "", tokenError()
		}
		w.Before = &posts.Position{CreatedAt: c.CreatedAt, ID: c.DocID}
	}
	rows, err := f.query(ctx, w, f.scan)
	if err != nil {
		return nil, "", logger.RedactErr(fmt.Errorf("search: %s: %w", f.label, err), uid)
	}
	cands := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if f.keep(p) {
			cands = append(cands, p)
		}
	}
	fl, err := r.filter(ctx, uid, cands, false)
	if err != nil {
		return nil, "", err
	}
	kept := fl.kept
	more := len(rows) == f.scan
	var resume *posts.Post
	if len(rows) > 0 {
		resume = rows[len(rows)-1] // the last SCANNED row, kept or not, so a dropped post never stalls the token
	}
	if len(kept) > limit {
		kept = kept[:limit]
		resume, more = kept[limit-1], true
	}
	views := r.views(ctx, uid, kept, fl)
	next := ""
	if more && resume != nil {
		next = cursor.EncodeAt(r.d.CursorKey, bind, cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}, r.d.Now())
	}
	logTally(ctx, len(views), fl.tally)
	return views, next, nil
}
