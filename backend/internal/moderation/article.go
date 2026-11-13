// article.go is moderation's side of "report an article": a POST report whose post is an article root also keeps a
// bounded snapshot of the article itself, so the author cannot rewrite the body before triage. moderation never reads
// articles/* itself: articles implements EvidenceReader and the composition root adapts it (the ListLookup pattern).
package moderation

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ReportedArticle is what an ArticleLookup answers: a bounded plain-text snapshot of one published article.
type ReportedArticle struct {
	ArticleID string
	Title     string
	Revision  int64
	// Body is the article's plain text, bounded by the lookup (articles.MaxEvidenceBodyBytes); Truncated says it was cut.
	Body      string
	Truncated bool
	// ImageMediaIDs are the article's inline image ids, kept in the report's evidence with the cover's.
	ImageMediaIDs []string
}

// ErrArticleNotFound is an ArticleLookup's answer when no published article is rooted at the reported post (deleted or
// unpublished between the post read and this one). The report then keeps the post's frozen article preview instead.
var ErrArticleNotFound = errors.New("moderation: article not found")

// ArticleLookup returns the published article articleID rooted at postID. The caller has already authorized the post
// with GetForViewer; the lookup checks no visibility and no flag. It returns ErrArticleNotFound or an infrastructure error.
type ArticleLookup interface {
	ReportedArticle(ctx context.Context, articleID, postID string) (ReportedArticle, error)
}

// articleEvidence fills the ARTICLE fields of a POST report's evidence when p is an article root. With no lookup wired, or
// when the article is gone, it keeps the preview frozen on the post (id, title, excerpt). Any other lookup failure fails the
// report (an internal error the client retries) rather than filing it without the body.
func (s *service) articleEvidence(ctx context.Context, uid string, p *posts.Post, ev *Evidence) error {
	if p.Article == nil || p.Article.ArticleID == "" || p.Kind == posts.KindRepost {
		return nil
	}
	ev.ArticleID, ev.ArticleTitle, ev.ArticleBody = p.Article.ArticleID, p.Article.Title, p.Article.Excerpt
	if s.d.Articles == nil {
		return nil
	}
	a, err := s.d.Articles.ReportedArticle(ctx, p.Article.ArticleID, p.ID)
	switch {
	case errors.Is(err, ErrArticleNotFound):
		return nil
	case err != nil:
		return logger.RedactErr(fmt.Errorf("moderation: load article evidence: %w", err), p.ID, uid)
	}
	ev.ArticleTitle, ev.ArticleRevision, ev.ArticleBody, ev.ArticleBodyTruncated = a.Title, a.Revision, a.Body, a.Truncated
	ev.MediaIDs = append(ev.MediaIDs, a.ImageMediaIDs...)
	return nil
}
