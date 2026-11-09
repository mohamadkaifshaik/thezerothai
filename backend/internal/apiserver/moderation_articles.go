package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/articles"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// articleReportLookup adapts articles.EvidenceReader to moderation.ArticleLookup (moderation never imports articles).
type articleReportLookup struct{ r articles.EvidenceReader }

var _ moderation.ArticleLookup = articleReportLookup{}

// ReportedArticle maps articles' answer to moderation's: ErrNotFound becomes moderation.ErrArticleNotFound, the evidence
// is copied field by field, anything else passes through.
func (l articleReportLookup) ReportedArticle(ctx context.Context, articleID, postID string) (moderation.ReportedArticle, error) {
	if l.r == nil {
		return moderation.ReportedArticle{}, errors.New("article reports are not wired")
	}
	e, err := l.r.ReportEvidence(ctx, articleID, postID)
	switch {
	case errors.Is(err, articles.ErrNotFound):
		return moderation.ReportedArticle{}, moderation.ErrArticleNotFound
	case err != nil:
		return moderation.ReportedArticle{}, err
	}
	return moderation.ReportedArticle{ArticleID: e.ArticleID, Title: e.Title, Revision: e.Revision, Body: e.Body, Truncated: e.Truncated}, nil
}
