package articles

import (
	"context"
	"errors"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// publicationIntent is the article side of a publication: posts.Create calls LoadForPublish inside the root post
// transaction (before any write), and the returned claim finalizes the article and attaches its inline images to the
// root post in the same batch. The images go through this claim, never posts.Create's MediaIDs: those are the post's own
// photos (at most 4, shown on timeline cards), and an article's inline images are not.
type publicationIntent struct {
	repo     repository
	expected *record
	now      time.Time
	uid      string
	images   ImageAttacher
}
type publicationClaim struct {
	ref    *firestore.DocumentRef
	next   record
	now    time.Time
	images ImageClaim
}

func (p *publicationIntent) LoadForPublish(ctx context.Context, tx *firestore.Transaction) (posts.ArticlePublicationClaim, error) {
	r := p.repo.(*firestoreRepo)
	ref := r.client.Collection("articles").Doc(p.expected.ID)
	d, err := tx.Get(ref)
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
	var claim ImageClaim
	if ids := imageIDsOf(a.Body); len(ids) > 0 {
		if p.images == nil {
			return nil, connect.NewError(connect.CodeUnavailable, errors.New("article image verification unavailable"))
		}
		// Reads only, before the root post's first write. A refusal is ErrImageNotReady, which fails the publication
		// as a FAILED_PRECONDITION, so the draft is released for the author to fix.
		claim, err = p.images.LoadForArticle(ctx, tx, p.uid, ids)
		if err != nil {
			return nil, err
		}
	}
	return &publicationClaim{ref: ref, next: a, now: p.now, images: claim}, nil
}
func (c *publicationClaim) Publish(b store.Batch, id string) {
	c.next.Published = true
	c.next.PostID = id
	c.next.UpdatedAt = c.now
	b.Set(c.ref, &c.next)
	if c.images != nil {
		c.images.Attach(b, id)
	}
}
