// removals_firestore.go is the Firestore side of the moderation removal log (ADR-0016 D10): the writes that
// moderate.go batches with the moderation field, and the RemovalSource the instance cache reads.
//
// Both queries order by createdAt then __name__ in the same direction, which the built-in single-field index on
// createdAt serves (no firestore.indexes.json composite), and carry an explicit Limit. The collection is deny-all to clients and holds no user id.
package posts

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

var _ RemovalSource = (*FirestoreRepo)(nil)

// removalDoc is postRemovals/{postId}. The id is the post id, so a hide that is re-run, or a second takedown of
// the same post, overwrites one document instead of adding another (idempotent); a restore overwrites it with
// RESTORED and a new createdAt. createdAt is the server commit time (never the operator's clock) so the reader's
// incremental cursor and the timeline tokens share one clock; expireAt is the TTL field (Terraform ttl_fields).
type removalDoc struct {
	State     string    `firestore:"state"`
	CreatedAt time.Time `firestore:"createdAt,serverTimestamp"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

func (r *FirestoreRepo) removalRef(postID string) *firestore.DocumentRef {
	return r.client.Collection(removalsCollection).Doc(postID)
}

// setRemoval adds the log write for postID to b (1 write). now only sets expireAt.
func (r *FirestoreRepo) setRemoval(b store.Batch, postID string, state RemovalState, now time.Time) {
	b.Set(r.removalRef(postID), removalDoc{State: string(state), ExpireAt: expiryBase(now).UTC().Add(RemovalRetention)})
}

// Newest implements RemovalSource. Reads: one per entry returned, minimum 1.
func (r *FirestoreRepo) Newest(ctx context.Context, floor time.Time, limit int) ([]RemovalEntry, error) {
	q := r.client.Collection(removalsCollection).Where("createdAt", ">", floor.UTC()).
		OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(limit)
	return r.readRemovals(ctx, q)
}

// After implements RemovalSource. Reads: one per entry returned, minimum 1.
func (r *FirestoreRepo) After(ctx context.Context, afterAt time.Time, afterID string, limit int) ([]RemovalEntry, error) {
	q := r.client.Collection(removalsCollection).OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if afterID == "" {
		q = q.Where("createdAt", ">", afterAt.UTC())
	} else {
		q = q.StartAfter(afterAt.UTC(), afterID)
	}
	return r.readRemovals(ctx, q.Limit(limit))
}

func (r *FirestoreRepo) readRemovals(ctx context.Context, q firestore.Query) ([]RemovalEntry, error) {
	docs, err := q.Documents(ctx).GetAll()
	n := int64(len(docs))
	if n == 0 {
		n = 1
	}
	budget.FromContext(ctx).AddReads(n)
	if err != nil {
		return nil, fmt.Errorf("posts: removals query: %w", err)
	}
	out := make([]RemovalEntry, 0, len(docs))
	for _, s := range docs {
		var d removalDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: removals decode %s: %w", s.Ref.ID, err)
		}
		out = append(out, RemovalEntry{PostID: s.Ref.ID, State: RemovalState(d.State), At: d.CreatedAt.UTC()})
	}
	return out, nil
}
