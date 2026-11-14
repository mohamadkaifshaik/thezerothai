// repo_counter_repair.go is the shard-aware side of the absolute counter writers (hot counters plan, PR 3). A hot post
// keeps part of its likeCount, repostCount and shareCount as pending deltas on posts/{id}/viewShards (repo_engagement.go
// stageCounter), which the rollup adds to the plain field with a delta fold (repo_view_rollup.go FoldCounters). A repair
// that overwrote only the plain field would leave those deltas behind, and the next fold would count them twice.
//
// So a repair sets the plain field to the true total AND drains the field's shards in the same transaction:
//
//	tx.GetAll(post + its ViewShardCount shards)     1 + N reads
//	Update(post, field = n)                          1 write (implicit Exists: a missing post fails, nothing is written)
//	Update(shard, field = Increment(-v)) per v != 0  at most N writes; the views field and the other fields are untouched
//
// The database runs with OPTIMISTIC concurrency, so the transaction aborts (and the SDK retries it) when a shard or the
// post is written between its read and its commit: a hot like, a view, a fold. That is acceptable for a one-shot operator
// repair. A fold that races it is the one aborted when the repair commits first (it read the shard the repair wrote),
// and on its retry it reads the shard at 0 and moves nothing; a fold that commits first makes the repair re-read.
package posts

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// StoredCount is a post counter as stored: the plain field and the deltas still pending on the post's shards (folded
// into the plain field by the next rollup tick). Total is what the counter stands for.
type StoredCount struct {
	Plain   int64
	Pending int64
}

// Total is Plain + Pending.
func (c StoredCount) Total() int64 { return c.Plain + c.Pending }

// counterDocs are the post and its shard refs, the post first (one GetAll).
func (r *FirestoreRepo) counterDocs(postID string) []*firestore.DocumentRef {
	post := r.ref(postID)
	return append([]*firestore.DocumentRef{post}, viewShards.Refs(post)...)
}

// storedCounterOf reads field from a GetAll of counterDocs: found is false for a missing post. The shards are returned
// for the drain (only the existing ones).
func storedCounterOf(snaps []*firestore.DocumentSnapshot, want int, field firestore.FieldPath) (StoredCount, []shardcount.Shard, bool, error) {
	if len(snaps) != want {
		return StoredCount{}, nil, false, fmt.Errorf("posts: read counter: got %d documents for %d refs", len(snaps), want)
	}
	if snaps[0] == nil || !snaps[0].Exists() {
		return StoredCount{}, nil, false, nil
	}
	shards := shardcount.ShardsOf(snaps[1:])
	docs := make([]map[string]any, 0, len(shards))
	for _, s := range shards {
		docs = append(docs, s.Data)
	}
	plain := shardcount.Sum([]map[string]any{snaps[0].Data()}, field).Get(field) // absent: 0
	return StoredCount{Plain: plain, Pending: shardcount.Sum(docs, field).Get(field)}, shards, true, nil
}

// storedCounter is one non-transactional GetAll of the post and its shards (1 + N reads): the counter as stored.
func (r *FirestoreRepo) storedCounter(ctx context.Context, postID string, field firestore.FieldPath) (StoredCount, bool, error) {
	refs := r.counterDocs(postID)
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return StoredCount{}, false, fmt.Errorf("posts: read %s: %w", field[0], err)
	}
	c, _, found, err := storedCounterOf(snaps, len(refs), field)
	return c, found, err
}

// stageSetCounter appends the shard-aware absolute write: the plain field set to n and every shard that holds a
// non-zero value of field drained by exactly that value (Increment(-v)), so plain + pending == n once committed. The
// shards must have been read in the same transaction. Only field is written on the shards.
func stageSetCounter(b store.Batch, post *firestore.DocumentRef, shards []shardcount.Shard, field firestore.FieldPath, n int64) {
	b.Update(post, []firestore.Update{{FieldPath: field, Value: n}})
	for _, s := range shards {
		if v := shardcount.Sum([]map[string]any{s.Data}, field).Get(field); v != 0 {
			b.Update(s.Ref, []firestore.Update{{FieldPath: field, Value: firestore.Increment(-v)}})
		}
	}
}

// setCounter is the shard-aware absolute write of one engagement counter in ONE transaction (see the file comment). It
// reads the shards whatever HOT_COUNTER_THRESHOLD says (opsctl runs with it off, but the API's hot writes may have left
// deltas). A missing post is ErrNotFound.
func (r *FirestoreRepo) setCounter(ctx context.Context, postID string, field firestore.FieldPath, n int64) error {
	refs := r.counterDocs(postID)
	_, err := store.RunTransaction(ctx, r.client, func(_ context.Context, tx *firestore.Transaction) error {
		snaps, err := tx.GetAll(refs)
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		_, shards, found, err := storedCounterOf(snaps, len(refs), field)
		switch {
		case err != nil:
			return err
		case !found:
			return ErrNotFound
		}
		b := store.NewFirestoreTxBatch(tx)
		stageSetCounter(b, refs[0], shards, field, n)
		return b.Err()
	})
	if err != nil {
		return fmt.Errorf("posts: set %s: %w", field[0], err)
	}
	return nil
}
