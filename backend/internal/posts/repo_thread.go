// repo_thread.go holds the reply-specific storage paths (plan replies-and-threads.md):
//
//	Q-T  Conversation, conversationId == X ORDER BY createdAt ASC, __name__ ASC, StartAfter(cursor), LIMIT n
//	     -> the existing (conversationId ASC, createdAt ASC) index; __name__ follows the last field's direction.
//
// and the parent's replyCount counter (FieldValue.Increment, the counter rule).
package posts

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// bumpReplyCount appends the replyCount increment to a batch or transaction. The Update has an implicit Exists
// precondition, so a deleted parent fails the whole commit with NotFound.
func bumpReplyCount(b store.Batch, parent *firestore.DocumentRef, delta int64) {
	bumpCount(b, parent, "replyCount", delta)
}

// bumpCount appends a FieldValue.Increment on one counter field (the same implicit Exists precondition).
func bumpCount(b store.Batch, ref *firestore.DocumentRef, field string, delta int64) {
	b.Update(ref, []firestore.Update{{Path: field, Value: firestore.Increment(delta)}})
}

// setCount is the one place a recount writes a corrected counter: a plain set of the field to n (never an Increment), for
// a transaction's or a batch's Update. Callers: RecountChildren and RepairChildCounts (opsctl recount-replies,
// recount-quotes, recount-children). A sharded-counter migration (pkg/platform/shardcount) must replace this body so a
// recount resets every shard to the corrected total, not just the field.
func setCount(field string, n int64) firestore.Update {
	return firestore.Update{Path: field, Value: n}
}

// Conversation implements Repo (Q-T).
func (r *FirestoreRepo) Conversation(ctx context.Context, conversationID string, after *Position, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).
		Where("conversationId", "==", conversationID).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, r.ref(after.ID))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
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
// exists is not an error (the counter died with it). Nothing is written when the parent is gone.
func (r *FirestoreRepo) AddReplyCount(ctx context.Context, parentID string, delta int64) error {
	return r.addCount(ctx, parentID, "replyCount", delta)
}

// AddQuoteCount implements Repo: AddReplyCount for quoteCount.
func (r *FirestoreRepo) AddQuoteCount(ctx context.Context, quotedID string, delta int64) error {
	return r.addCount(ctx, quotedID, "quoteCount", delta)
}

func (r *FirestoreRepo) addCount(ctx context.Context, id, field string, delta int64) error {
	b := store.NewFirestoreBatch(r.client)
	bumpCount(b, r.ref(id), field, delta)
	if err := b.Commit(ctx); err != nil {
		if status.Code(err) == codes.NotFound {
			return nil
		}
		return fmt.Errorf("posts: %s: %w", field, err)
	}
	return nil
}
