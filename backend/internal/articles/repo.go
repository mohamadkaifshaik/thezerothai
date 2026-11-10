package articles

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type record struct {
	ID           string    `firestore:"-"`
	AuthorID     string    `firestore:"authorId"`
	Revision     int64     `firestore:"revision"`
	Title        string    `firestore:"title"`
	Body         string    `firestore:"body"`
	CoverMediaID string    `firestore:"coverMediaId"`
	PostID       string    `firestore:"postId"`
	Published    bool      `firestore:"published"`
	UpdatedAt    time.Time `firestore:"updatedAt"`
	PendingKey   string    `firestore:"pendingKey"`
	PendingAt    time.Time `firestore:"pendingAt"`
	Caption      string    `firestore:"caption"`
	ReplyPolicy  int32     `firestore:"replyPolicy"`
}
type repository interface {
	get(context.Context, string) (*record, error)
	change(context.Context, string, func(*record) (*record, error)) (*record, error)
	// saveDraft is change for SaveArticle: fn may call drafts() to count uid's unpublished drafts, up to
	// maxDraftsPerAuthor+1, as a read of the same transaction (before any write).
	saveDraft(ctx context.Context, id, uid string, fn func(current *record, drafts func() (int, error)) (*record, error)) (*record, error)
	list(context.Context, string, bool, int, string) ([]*record, error)
}
type firestoreRepo struct{ client *firestore.Client }

func missing() error { return connect.NewError(connect.CodeNotFound, errors.New("article not found")) }
func conflict() error {
	return connect.NewError(connect.CodeAborted, errors.New("article changed; reload before saving"))
}
func locked() error {
	return connect.NewError(connect.CodeFailedPrecondition, errors.New("article publication is in progress or complete"))
}

// draftLimit refuses a new draft at maxDraftsPerAuthor: FAILED_PRECONDITION + LIMIT_REACHED, metadata["limit"] =
// "article_drafts". Not retryable; the author publishes or deletes a draft first.
func draftLimit() error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
		fmt.Sprintf("You have %d drafts. Publish or delete one to start a new draft.", maxDraftsPerAuthor)).
		WithMeta("limit", draftLimitName)
}
func (r *firestoreRepo) get(ctx context.Context, id string) (*record, error) {
	d, err := r.client.Collection("articles").Doc(id).Get(ctx)
	if status.Code(err) == codes.NotFound {
		return nil, missing()
	}
	if err != nil {
		return nil, err
	}
	var out record
	if err = d.DataTo(&out); err != nil {
		return nil, err
	}
	out.ID = id
	return &out, nil
}
func (r *firestoreRepo) change(ctx context.Context, id string, fn func(*record) (*record, error)) (*record, error) {
	return r.transact(ctx, id, func(_ *firestore.Transaction, current *record) (*record, error) { return fn(current) })
}
func (r *firestoreRepo) saveDraft(ctx context.Context, id, uid string, fn func(*record, func() (int, error)) (*record, error)) (*record, error) {
	return r.transact(ctx, id, func(tx *firestore.Transaction, current *record) (*record, error) {
		return fn(current, func() (int, error) { return r.countDrafts(tx, uid) })
	})
}

// countDrafts counts uid's unpublished drafts inside tx, reading at most maxDraftsPerAuthor+1 document names
// (an empty Select loads no bodies). Equality filters on authorId and published only: served by the existing
// (authorId, published) composite index that ListArticles already uses.
func (r *firestoreRepo) countDrafts(tx *firestore.Transaction, uid string) (int, error) {
	q := r.client.Collection("articles").Where("authorId", "==", uid).Where("published", "==", false).Select().Limit(maxDraftsPerAuthor + 1)
	docs, err := tx.Documents(q).GetAll()
	if err != nil {
		return 0, fmt.Errorf("articles: count drafts: %w", err)
	}
	return len(docs), nil
}
func (r *firestoreRepo) transact(ctx context.Context, id string, fn func(*firestore.Transaction, *record) (*record, error)) (*record, error) {
	var out *record
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		ref := r.client.Collection("articles").Doc(id)
		d, err := tx.Get(ref)
		var current *record
		if err == nil {
			current = &record{ID: id}
			if err = d.DataTo(current); err != nil {
				return err
			}
		} else if status.Code(err) != codes.NotFound {
			return err
		}
		next, err := fn(tx, current)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		if next == nil {
			if current != nil {
				b.Delete(ref)
			}
		} else {
			b.Set(ref, next)
		}
		out = next
		return b.Err()
	})
	return out, err
}
func (r *firestoreRepo) list(ctx context.Context, uid string, published bool, n int, after string) ([]*record, error) {
	q := r.client.Collection("articles").Where("authorId", "==", uid).Where("published", "==", published).OrderBy(firestore.DocumentID, firestore.Asc).Limit(n)
	if after != "" {
		q = q.StartAfter(after)
	}
	docs, err := q.Documents(ctx).GetAll()
	if err != nil {
		return nil, err
	}
	out := make([]*record, 0, len(docs))
	for _, d := range docs {
		a := &record{ID: d.Ref.ID}
		if err = d.DataTo(a); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}
