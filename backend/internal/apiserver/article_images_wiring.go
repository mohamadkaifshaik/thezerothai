package apiserver

import (
	"context"

	"cloud.google.com/go/firestore"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/articles"
	"github.com/dzeroth/dzeroth/backend/internal/media"
)

// articleImageResolver adapts media.Library to articles.ImageResolver: the same usable-image rules as a post's cover,
// answered as the shared MediaRef the reader and the editor render.
type articleImageResolver struct{ lib *media.Library }

var _ articles.ImageResolver = articleImageResolver{}

func (r articleImageResolver) ResolveArticleImages(ctx context.Context, authorID, postID string, ids []string) (map[string]*commonv1.MediaRef, error) {
	refs, err := r.lib.ResolveArticleImages(ctx, authorID, postID, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]*commonv1.MediaRef, len(refs))
	for id, ref := range refs {
		out[id] = &commonv1.MediaRef{
			MediaId: ref.ID, Url: ref.URL, ThumbUrl: ref.ThumbURL, Width: int32(ref.Width), Height: int32(ref.Height), //nolint:gosec // validated <= 4096 at CreateUpload
			Blurhash: ref.Blurhash, ContentType: ref.ContentType,
		}
	}
	return out, nil
}

// articleImageAttacher adapts media.Library.LoadForArticle to articles.ImageAttacher. A refusal of any kind (missing,
// not the author's, not ready, attached, marked, a GIF) becomes articles.ErrImageNotReady; only infrastructure errors
// pass through.
type articleImageAttacher struct{ lib *media.Library }

var _ articles.ImageAttacher = articleImageAttacher{}

func (a articleImageAttacher) LoadForArticle(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (articles.ImageClaim, error) {
	c, err := a.lib.LoadForArticle(ctx, tx, uid, ids)
	switch {
	case media.IsNotReady(err):
		return nil, articles.ErrImageNotReady
	case err != nil:
		return nil, err
	}
	return c, nil
}
