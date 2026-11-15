// repo_thread.go holds the reply-specific storage paths (plan replies-and-threads.md):
//
//	Q-T  Conversation, conversationId == X ORDER BY createdAt ASC, __name__ ASC, StartAfter(cursor), LIMIT n
//	     -> the existing (conversationId ASC, createdAt ASC) index; __name__ follows the last field's direction.
//
// and the parent's replyCount counter (FieldValue.Increment, the counter rule). The create path routes it through
// stageCounter (repo_engagement.go), so a hot parent's +1 goes to a shard (HOT_COUNTER_THRESHOLD, hot counters plan PR 5);
// the release paths here and in purge_release.go have no count to decide with and stay plain Increments.
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
// precondition, so a deleted parent fails the whole commit with NotFound. Always cold (the purge release).
func bumpReplyCount(b store.Batch, parent *firestore.DocumentRef, delta int64) {
	bumpCount(b, parent, "replyCount", delta)
}

// bumpCount appends a FieldValue.Increment on one counter field (the same implicit Exists precondition).
func bumpCount(b store.Batch, ref *firestore.DocumentRef, field string, delta int64) {
	b.Update(ref, []firestore.Update{{Path: field, Value: firestore.Increment(delta)}})
}

// The absolute writers of replyCount and quoteCount (RecountChildren and RepairChildCounts: opsctl recount-replies,
// recount-quotes, recount-children) read the post's shards in their transaction and set the total while draining the
// pending deltas (stageSetCounter / stageSetCounters in repo_counter_repair.go, as SetShareCount does): a plain set would
// leave those deltas for the next fold to count twice.

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
// exists is not an error (the counter died with it). Nothing is written when the parent is gone. It stays cold whatever
// HOT_COUNTER_THRESHOLD says: the caller (DeletePost's release) has no parent count to decide with, and a plain -1 on a
// hot parent is exact (the delta fold keeps the plain field as the source of truth).
//
// author and actor are the parent's author and the reply's: the author's engagements for today move by delta in the
// same batch (creator stats, F2), unless author is "" or the actor (identity.StatsWriter); a gone parent writes neither.
func (r *FirestoreRepo) AddReplyCount(ctx context.Context, parentID string, delta int64, author, actor string) error {
	return r.addCount(ctx, parentID, "replyCount", delta, author, actor)
}

// AddQuoteCount implements Repo: AddReplyCount for quoteCount.
func (r *FirestoreRepo) AddQuoteCount(ctx context.Context, quotedID string, delta int64, author, actor string) error {
	return r.addCount(ctx, quotedID, "quoteCount", delta, author, actor)
}

func (r *FirestoreRepo) addCount(ctx context.Context, id, field string, delta int64, author, actor string) error {
	b := store.NewFirestoreBatch(r.client)
	bumpCount(b, r.ref(id), field, delta)
	if author != "" {
		r.stageEngagementStat(b, author, actor, delta)
	}
	if err := b.Commit(ctx); err != nil {
		if status.Code(err) == codes.NotFound {
			return nil
		}
		return fmt.Errorf("posts: %s: %w", field, err)
	}
	return nil
}
