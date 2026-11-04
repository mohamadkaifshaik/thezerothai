package posts

import (
	"fmt"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// ArticlePreview is a bounded snapshot; the structured article body is fetched
// separately, through its published post's audience check.
type ArticlePreview struct {
	ArticleID string `firestore:"articleId"`
	Title     string `firestore:"title"`
	Excerpt   string `firestore:"excerpt"`
	CoverURL  string `firestore:"coverUrl,omitempty"`
}

func cloneArticle(a *ArticlePreview) *ArticlePreview {
	if a == nil {
		return nil
	}
	copy := *a
	return &copy
}

func articleToProto(a *ArticlePreview) *postsv1.ArticlePreview {
	if a == nil {
		return nil
	}
	return &postsv1.ArticlePreview{ArticleId: a.ArticleID, Title: a.Title, Excerpt: a.Excerpt, CoverUrl: a.CoverURL}
}

// Legacy requests retain their exact hash. Internal publications include every
// preview field so a reused key cannot silently point at different content.
func articleRequestHash(base string, a *ArticlePreview) string {
	if a == nil {
		return base
	}
	return idempotency.HashRequest(fmt.Sprintf("%s|article=%q|title=%q|excerpt=%q|cover=%q", base, a.ArticleID, a.Title, a.Excerpt, a.CoverURL))
}
