package posts

import (
	"context"
	"fmt"
)

// ByAuthorArticles uses a dedicated indexed query, never a filtered Posts page.
func (r *FirestoreRepo) ByAuthorArticles(ctx context.Context, author string, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("authorId", "==", author).Where("hasArticle", "==", true)
	return r.run(ctx, q, w, limit)
}
func (s *service) ByAuthorArticles(ctx context.Context, author string, w Window, limit int) ([]*Post, error) {
	if author == "" {
		return nil, fmt.Errorf("posts: article query needs an author")
	}
	if err := w.validate(); err != nil {
		return nil, err
	}
	repo, ok := s.repo.(ArticleReader)
	if !ok {
		return nil, fmt.Errorf("posts: article query is unavailable")
	}
	at := s.now()
	out, err := repo.ByAuthorArticles(ctx, author, w, clampLimit(limit))
	if err != nil {
		return nil, err
	}
	s.fill(out, at)
	return out, nil
}
