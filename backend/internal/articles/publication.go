package articles

import (
	"context"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type publicationIntent struct {
	repo     repository
	expected *record
	now      time.Time
}
type publicationClaim struct {
	ref  *firestore.DocumentRef
	next record
	now  time.Time
}

func (p *publicationIntent) LoadForPublish(ctx context.Context, tx *firestore.Transaction) (posts.ArticlePublicationClaim, error) {
	r := p.repo.(*firestoreRepo)
	ref := r.client.Collection("articles").Doc(p.expected.ID)
	d, err := tx.Get(ref)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return nil, missing()
	}
	if err != nil {
		return nil, err
	}
	var a record
	if err = d.DataTo(&a); err != nil {
		return nil, err
	}
	if a.AuthorID != p.expected.AuthorID || a.Revision != p.expected.Revision || a.PendingKey != p.expected.PendingKey || a.Published {
		return nil, conflict()
	}
	return &publicationClaim{ref: ref, next: a, now: p.now}, nil
}
func (c *publicationClaim) Publish(b store.Batch, id string) {
	c.next.Published = true
	c.next.PostID = id
	c.next.UpdatedAt = c.now
	b.Set(c.ref, &c.next)
}
