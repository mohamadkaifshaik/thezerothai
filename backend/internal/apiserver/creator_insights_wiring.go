// creator_insights_wiring.go adapts posts to identity's consumer-side TopPostsReader (identity cannot import posts) for
// GetCreatorInsights (F2): the conversion, the 140-character text preview and the index-missing mapping.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// topPostTextMax is CreatorTopPost.text's cut, in characters (runes).
const topPostTextMax = 140

// topPostsSource is the one method of posts.FirestoreRepo the adapter needs.
type topPostsSource interface {
	TopPostsByViews(ctx context.Context, uid string, limit int) ([]*posts.Post, error)
}

// topPostsAdapter implements identity.TopPostsReader.
type topPostsAdapter struct{ src topPostsSource }

func (a topPostsAdapter) TopPostsByViews(ctx context.Context, uid string, limit int) ([]identity.TopPost, error) {
	ps, err := a.src.TopPostsByViews(ctx, uid, limit)
	if errors.Is(err, posts.ErrTopPostsIndexMissing) {
		return nil, identity.ErrTopPostsUnavailable
	}
	if err != nil {
		return nil, err
	}
	out := make([]identity.TopPost, 0, len(ps))
	for _, p := range ps {
		out = append(out, identity.TopPost{
			ID: p.ID, Text: cutRunes(p.Text, topPostTextMax), CreatedAt: p.CreatedAt, ViewCount: p.ViewCount,
			LikeCount: p.LikeCount, RepostCount: p.RepostCount, ReplyCount: p.ReplyCount, QuoteCount: p.QuoteCount,
		})
	}
	return out, nil
}

// cutRunes is s cut to at most n runes.
func cutRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
