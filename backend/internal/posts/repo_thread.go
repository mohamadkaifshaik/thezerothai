// repo_thread.go holds the reply-specific storage paths (P3, plan replies-and-threads.md):
//
//	Q-T  Conversation, conversationId == X ORDER BY createdAt ASC, __name__ ASC, StartAfter(cursor), LIMIT n
//	     -> the existing (conversationId ASC, createdAt ASC) index; __name__ follows the last field's direction.
//
// and the parent's replyCount counter (FieldValue.Increment, CLAUDE.md rule 3).
package posts

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// bumpReplyCount appends the replyCount increment to a batch or transaction. The Update has an implicit Exists
// precondition, so a deleted parent fails the whole commit with NotFound (0 writes).
func bumpReplyCount(b store.Batch, parent *firestore.DocumentRef, delta int64) {
	b.Update(parent, []firestore.Update{{Path: "replyCount", Value: firestore.Increment(delta)}})
}

// Conversation implements Repo (Q-T). Reads: len(result), minimum 1.
func (r *FirestoreRepo) Conversation(ctx context.Context, conversationID string, after *Position, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).
		Where("conversationId", "==", conversationID).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, r.ref(after.ID))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("posts: conversation query: %w", err)
	}
	out := make([]*Post, 0, len(docs))
	for _, s := range docs {
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: decode post %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toPost(s.Ref.ID))
	}
	return out, nil
}

// AddReplyCount implements Repo: one Update with FieldValue.Increment on the parent. A parent that no longer
// exists is not an error (the counter died with it). Writes 1 (0 when the parent is gone).
func (r *FirestoreRepo) AddReplyCount(ctx context.Context, parentID string, delta int64) error {
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	bumpReplyCount(b, r.ref(parentID), delta)
	if err := b.Commit(ctx); err != nil {
		if status.Code(err) == codes.NotFound {
			return nil
		}
		return fmt.Errorf("posts: reply count: %w", err)
	}
	return nil
}
