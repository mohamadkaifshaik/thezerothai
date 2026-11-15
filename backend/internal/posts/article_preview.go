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
	// ReadMinutes is the reading time frozen at publish (whole minutes, at least 1); 0 on a post published before the
	// field existed, which the wire carries as "unknown".
	ReadMinutes int32 `firestore:"readMinutes,omitempty"`
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
	return &postsv1.ArticlePreview{ArticleId: a.ArticleID, Title: a.Title, Excerpt: a.Excerpt, CoverUrl: a.CoverURL, ReadMinutes: a.ReadMinutes}
}

// Legacy requests retain their exact hash. Internal publications include every
// preview field so a reused key cannot silently point at different content.
// ReadMinutes is left out on purpose: it is a pure function of the body, which the
// publication key already binds (article id + revision), and adding it would change
// the hash of a publication pending across a deploy.
func articleRequestHash(base string, a *ArticlePreview) string {
	if a == nil {
		return base
	}
	return idempotency.HashRequest(fmt.Sprintf("%s|article=%q|title=%q|excerpt=%q|cover=%q", base, a.ArticleID, a.Title, a.Excerpt, a.CoverURL))
}
