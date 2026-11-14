// repo_recount.go serves `opsctl recount-replies` and `opsctl recount-quotes`: a post's stored replyCount or
// quoteCount compared with a count() of the posts that reply to or quote it.
//
//	Q-RC posts where replyToId == X  (count, LIMIT planCountCap)  -> automatic single-field index
//	Q-QC posts where quoteOfId == X  (count, LIMIT planCountCap)  -> automatic single-field index
//
// Every existing reply/quote doc counts, whatever its moderation state: moderation keeps the counters so a restore is
// exact, and the recount matches what the live counters hold. The stored side is shard-aware (repo_counter_repair.go): a
// hot post's counter is its plain field plus the deltas pending on posts/{id}/viewShards, and a repair drains them.
package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ChildCount names the counter a recount repairs.
type ChildCount int

const (
	// ChildReplies is posts/{id}.replyCount against the posts with replyToId == id.
	ChildReplies ChildCount = iota
	// ChildQuotes is posts/{id}.quoteCount against the posts with quoteOfId == id.
	ChildQuotes
)

// fields returns the counter field and the back-reference field the count filters on.
func (c ChildCount) fields() (counter, ref string, err error) {
	switch c {
	case ChildReplies:
		return fieldReplyCount, fieldReplyToID, nil
	case ChildQuotes:
		return fieldQuoteCount, fieldQuoteOfID, nil
	}
	return "", "", fmt.Errorf("posts: unknown child count %d", c)
}

// ChildRecount is the outcome of RecountChildren.
type ChildRecount struct {
	// Stored is the counter the post stands for: the plain field plus the deltas still pending on its shards (a hot post,
	// hot counters plan PR 5; the next rollup tick folds them into the plain field). It is what is compared with Counted.
	Stored int64
	// Pending is the part of Stored still on the shards (0 for a cold post).
	Pending int64
	Counted int64
	Written bool
	// Capped is set when the count reached planCountCap: the true count may be higher, so nothing is written.
	Capped bool
}

// ChildRecounter is the repair behind the recount commands (*FirestoreRepo).
type ChildRecounter interface {
	// RecountChildren compares the stored counter (plain + pending shard deltas) with the count of the posts referencing
	// postID. With write and a difference, it sets the counter in one transaction (the post, its shards and the count
	// read inside it, so a concurrent reply or quote conflicts and the transaction retries) and drains the field's
	// shards, so the next rollup fold adds nothing on top. A count at planCountCap (Capped) is never written. A missing
	// post is ErrNotFound.
	RecountChildren(ctx context.Context, postID string, which ChildCount, write bool) (ChildRecount, error)
}

var _ ChildRecounter = (*FirestoreRepo)(nil)

// RecountChildren implements ChildRecounter. Reads: the post and its ViewShardCount shards (one GetAll) and one
// aggregation; at most one post write plus one write per shard holding a pending delta of the counter.
func (r *FirestoreRepo) RecountChildren(ctx context.Context, postID string, which ChildCount, write bool) (ChildRecount, error) {
	if !ids.ValidPostID(postID) {
		return ChildRecount{}, ErrInvalidID
	}
	counter, ref, err := which.fields()
	if err != nil {
		return ChildRecount{}, err
	}
	field := firestore.FieldPath{counter}
	refs := r.counterDocs(postID)
	q := r.client.Collection(postsCollection).Where(ref, "==", postID).Limit(planCountCap)
	agg := q.NewAggregationQuery().WithCount("n")
	read := func(ctx context.Context, tx *firestore.Transaction) (ChildRecount, []shardcount.Shard, error) {
		var snaps []*firestore.DocumentSnapshot
		var res firestore.AggregationResult
		var err error
		if tx != nil {
			snaps, err = tx.GetAll(refs)
		} else {
			snaps, err = r.client.GetAll(ctx, refs)
		}
		if err != nil {
			return ChildRecount{}, nil, fmt.Errorf("posts: recount %s: read: %w", counter, err)
		}
		stored, shards, found, err := storedCounterOf(snaps, len(refs), field)
		switch {
		case err != nil:
			return ChildRecount{}, nil, fmt.Errorf("posts: recount %s: %w", counter, err)
		case !found:
			return ChildRecount{}, nil, ErrNotFound
		}
		if tx != nil {
			res, err = agg.Transaction(tx).Get(ctx)
		} else {
			res, err = agg.Get(ctx)
		}
		if err != nil {
			return ChildRecount{}, nil, fmt.Errorf("posts: recount %s: count: %w", counter, err)
		}
		var n struct {
			N int64 `firestore:"n"`
		}
		if err := res.DataTo(&n); err != nil {
			return ChildRecount{}, nil, fmt.Errorf("posts: recount %s: decode: %w", counter, err)
		}
		return ChildRecount{Stored: stored.Total(), Pending: stored.Pending, Counted: n.N, Capped: n.N >= planCountCap}, shards, nil
	}
	if !write {
		out, _, err := read(ctx, nil)
		return out, err
	}
	var out ChildRecount
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		got, shards, err := read(ctx, tx)
		if err != nil {
			return err
		}
		out = got
		if got.Stored == got.Counted || got.Capped {
			return nil
		}
		out.Written = true
		b := store.NewFirestoreTxBatch(tx)
		stageSetCounter(b, refs[0], shards, field, got.Counted)
		return b.Err()
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ChildRecount{}, ErrNotFound
		}
		return ChildRecount{}, fmt.Errorf("posts: recount %s: %w", counter, err)
	}
	return out, nil
}
