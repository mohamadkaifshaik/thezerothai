// repo_counter_repair.go is the shard-aware side of the absolute counter writers (hot counters plan, PR 3 and PR 5). A hot
// post keeps part of its likeCount, repostCount, shareCount, replyCount and quoteCount as pending deltas on posts/{id}/viewShards (repo_engagement.go
// stageCounter), which the rollup adds to the plain field with a delta fold (repo_view_rollup.go FoldCounters). A repair
// that overwrote only the plain field would leave those deltas behind, and the next fold would count them twice.
//
// So a repair sets the plain field to the true total AND drains the field's shards in the same transaction:
//
//	tx.GetAll(post + its ViewShardCount shards)     1 + N reads
//	Update(post, field = n)                          1 write (implicit Exists: a missing post fails, nothing is written)
//	Update(shard, field = Increment(-v)) per v != 0  at most N writes; the views field and the other fields are untouched
//
// Callers: SetShareCount (opsctl recount-shares), RecountChildren (recount-replies / recount-quotes) and RepairChildCounts
// (recount-children, both child counters in one post write and one write per shard: stageSetCounters).
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
	cs, shards, found, err := storedCountersOf(snaps, want, field)
	if !found || err != nil {
		return StoredCount{}, nil, found, err
	}
	return cs[0], shards, true, nil
}

// storedCountersOf is storedCounterOf for several fields of the same GetAll, one StoredCount per field in order.
func storedCountersOf(snaps []*firestore.DocumentSnapshot, want int, fields ...firestore.FieldPath) ([]StoredCount, []shardcount.Shard, bool, error) {
	if len(snaps) != want {
		return nil, nil, false, fmt.Errorf("posts: read counter: got %d documents for %d refs", len(snaps), want)
	}
	if snaps[0] == nil || !snaps[0].Exists() {
		return nil, nil, false, nil
	}
	shards := shardcount.ShardsOf(snaps[1:])
	plain := shardcount.Sum([]map[string]any{snaps[0].Data()}, fields...) // absent: 0
	pending := pendingOf(shards, fields...)
	out := make([]StoredCount, len(fields))
	for i, f := range fields {
		out[i] = StoredCount{Plain: plain.Get(f), Pending: pending.Get(f)}
	}
	return out, shards, true, nil
}

// pendingOf sums fields over the shards (the deltas the next rollup fold would add).
func pendingOf(shards []shardcount.Shard, fields ...firestore.FieldPath) shardcount.Totals {
	docs := make([]map[string]any, 0, len(shards))
	for _, s := range shards {
		docs = append(docs, s.Data)
	}
	return shardcount.Sum(docs, fields...)
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
	stageSetCounters(b, post, shards, counterSet{field: field, n: n})
}

// counterSet is one field of an absolute write and its value.
type counterSet struct {
	field firestore.FieldPath
	n     int64
}

// stageSetCounters is stageSetCounter for several fields at once: ONE Update of the post with every set (in order), and
// ONE Update per shard holding a non-zero value of any of the fields, with an Increment(-v) per such field (in the same
// order). With one field it stages exactly what stageSetCounter always did. No sets stages nothing.
func stageSetCounters(b store.Batch, post *firestore.DocumentRef, shards []shardcount.Shard, sets ...counterSet) {
	if len(sets) == 0 {
		return
	}
	ups := make([]firestore.Update, len(sets))
	fields := make([]firestore.FieldPath, len(sets))
	for i, s := range sets {
		ups[i] = firestore.Update{FieldPath: s.field, Value: s.n}
		fields[i] = s.field
	}
	b.Update(post, ups)
	for _, s := range shards {
		t := shardcount.Sum([]map[string]any{s.Data}, fields...)
		var drain []firestore.Update
		for _, f := range fields {
			if v := t.Get(f); v != 0 {
				drain = append(drain, firestore.Update{FieldPath: f, Value: firestore.Increment(-v)})
			}
		}
		if len(drain) > 0 {
			b.Update(s.Ref, drain)
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
