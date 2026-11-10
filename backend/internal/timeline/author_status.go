package timeline

import (
	"context"
	"fmt"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fieldDroppedInactive counts the rows a page dropped because their author, or the author a REPOST copies, is not ACTIVE.
const fieldDroppedInactive = "dropped_inactive"

// activeOnly applies the author-status rule (F-03, posts.ResolveActiveAuthors) to a page Merge has already cut: a row
// whose author is not ACTIVE (SUSPENDED, DELETING, no users doc) is dropped, a REPOST of such an author's post is dropped,
// and a QUOTE of one is replaced by its tombstoned copy (posts.TombstonedQuote; the shared cache rows are never changed),
// whose embed state is cleared because a tombstone has no author. It runs after Merge so the page's tokens stay on the raw
// window (Page.Last, HasMore): a page the rule empties still advances. One cache-first Directory read for the page's
// distinct authors and embedded authors (at most 50 rows, so at most two batches), none for the caller or for known uids
// already proven ACTIVE in this call. A Directory failure fails the page.
func (s *Server) activeOnly(ctx context.Context, uid string, items []*posts.Post, embed map[string]postsv1.EmbedViewerState, known ...string) ([]*posts.Post, error) {
	if len(items) == 0 {
		logger.SetRequestField(ctx, fieldDroppedInactive, 0)
		return items, nil
	}
	var dir posts.AuthorDirectory
	if s.deps.Directory != nil {
		dir = s.deps.Directory
	}
	active, err := posts.ResolveActiveAuthors(ctx, dir, uid, items, known...)
	if err != nil {
		return nil, fmt.Errorf("timeline: %w", err) // already redacted
	}
	out := make([]*posts.Post, 0, len(items))
	for _, p := range items {
		switch active.Verdict(p) {
		case posts.AuthorDrop:
			continue
		case posts.AuthorTombstone:
			delete(embed, p.ID)
			p = posts.TombstonedQuote(p)
		}
		out = append(out, p)
	}
	logger.SetRequestField(ctx, fieldDroppedInactive, len(items)-len(out))
	return out, nil
}
