// removals_firestore.go is the Firestore side of the moderation removal log (ADR-0016 D10): the writes that
// moderate.go batches with the moderation field, and the RemovalSource the instance cache reads.
//
// The cache queries (Newest, After) order by createdAt then __name__ in the same direction, which the built-in
// single-field index on createdAt serves. Window filters on authorId and orders by createdAt DESC, which needs the
// composite (authorId ASC, createdAt DESC) in firestore.indexes.json (the same index serves the erase query by
// authorId). Every query carries an explicit Limit. The collection is deny-all to clients; authorId is a
// pseudonymous uid link, erased by the posts step (PurgeUser phase 2).
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
	State string `firestore:"state"`
	// AuthorID scopes the entry to the feeds that show the author (amendment 2026-10-18 (b)); absent on entries
	// written before it, which readers treat as visible to every feed.
	AuthorID  string    `firestore:"authorId"`
	CreatedAt time.Time `firestore:"createdAt,serverTimestamp"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

func (r *FirestoreRepo) removalRef(postID string) *firestore.DocumentRef {
	return r.client.Collection(removalsCollection).Doc(postID)
}

// setRemoval adds the log write for postID (written by authorID) to b (1 write). now only sets expireAt.
func (r *FirestoreRepo) setRemoval(b store.Batch, postID, authorID string, state RemovalState, now time.Time) {
	b.Set(r.removalRef(postID), removalDoc{State: string(state), AuthorID: authorID, ExpireAt: expiryBase(now).UTC().Add(RemovalRetention)})
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

// Window implements RemovalSource. Reads: one per entry returned, minimum 1.
func (r *FirestoreRepo) Window(ctx context.Context, authors []string, after, upTo time.Time, limit int) ([]RemovalEntry, error) {
	q := r.client.Collection(removalsCollection).Query
	if len(authors) == 1 {
		q = q.Where("authorId", "==", authors[0])
	} else {
		q = q.Where("authorId", "in", authors)
	}
	q = q.Where("createdAt", ">", after.UTC()).Where("createdAt", "<=", upTo.UTC()).
		OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(limit)
	return r.readRemovals(ctx, q)
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
		out = append(out, RemovalEntry{PostID: s.Ref.ID, AuthorID: d.AuthorID, State: RemovalState(d.State), At: d.CreatedAt.UTC()})
	}
	return out, nil
}
