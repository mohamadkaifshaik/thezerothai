package articles

import (
	"context"
	"errors"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
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
func (r *firestoreRepo) get(ctx context.Context, id string) (*record, error) {
	d, err := r.client.Collection("articles").Doc(id).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
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
	var out *record
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		ref := r.client.Collection("articles").Doc(id)
		d, err := tx.Get(ref)
		budget.FromContext(ctx).AddReads(1)
		var current *record
		if err == nil {
			current = &record{ID: id}
			if err = d.DataTo(current); err != nil {
				return err
			}
		} else if status.Code(err) != codes.NotFound {
			return err
		}
		next, err := fn(current)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
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
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
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
