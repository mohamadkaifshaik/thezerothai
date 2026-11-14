// repo_recount.go serves `opsctl recount-replies` and `opsctl recount-quotes`: a post's stored replyCount or
// quoteCount compared with a count() of the posts that reply to or quote it.
//
//	Q-RC posts where replyToId == X  (count, LIMIT planCountCap)  -> automatic single-field index
//	Q-QC posts where quoteOfId == X  (count, LIMIT planCountCap)  -> automatic single-field index
//
// Every existing reply/quote doc counts, whatever its moderation state: moderation keeps the counters so a restore is
// exact, and the recount matches what the live counters hold.
package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
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
	Stored  int64
	Counted int64
	Written bool
}

// ChildRecounter is the repair behind the recount commands (*FirestoreRepo).
type ChildRecounter interface {
	// RecountChildren compares the stored counter with the count of the posts referencing postID. With write and a
	// difference, it sets the counter in one transaction (the post read and the count inside it, so a concurrent reply
	// or quote conflicts and the transaction retries). A missing post is ErrNotFound.
	RecountChildren(ctx context.Context, postID string, which ChildCount, write bool) (ChildRecount, error)
}

var _ ChildRecounter = (*FirestoreRepo)(nil)

// RecountChildren implements ChildRecounter. Reads: the post and one aggregation; at most one write.
func (r *FirestoreRepo) RecountChildren(ctx context.Context, postID string, which ChildCount, write bool) (ChildRecount, error) {
	if !ids.ValidPostID(postID) {
		return ChildRecount{}, ErrInvalidID
	}
	counter, ref, err := which.fields()
	if err != nil {
		return ChildRecount{}, err
	}
	q := r.client.Collection(postsCollection).Where(ref, "==", postID).Limit(planCountCap)
	agg := q.NewAggregationQuery().WithCount("n")
	read := func(ctx context.Context, tx *firestore.Transaction) (ChildRecount, error) {
		var snap *firestore.DocumentSnapshot
		var res firestore.AggregationResult
		var err error
		if tx != nil {
			snap, err = tx.Get(r.ref(postID))
		} else {
			snap, err = r.ref(postID).Get(ctx)
		}
		if status.Code(err) == codes.NotFound {
			return ChildRecount{}, ErrNotFound
		}
		if err != nil {
			return ChildRecount{}, fmt.Errorf("posts: recount %s: read: %w", counter, err)
		}
		if tx != nil {
			res, err = agg.Transaction(tx).Get(ctx)
		} else {
			res, err = agg.Get(ctx)
		}
		if err != nil {
			return ChildRecount{}, fmt.Errorf("posts: recount %s: count: %w", counter, err)
		}
		var n struct {
			N int64 `firestore:"n"`
		}
		if err := res.DataTo(&n); err != nil {
			return ChildRecount{}, fmt.Errorf("posts: recount %s: decode: %w", counter, err)
		}
		var stored int64
		if v, err := snap.DataAt(counter); err == nil {
			stored, _ = v.(int64) // absent: 0
		}
		return ChildRecount{Stored: stored, Counted: n.N}, nil
	}
	if !write {
		return read(ctx, nil)
	}
	var out ChildRecount
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		got, err := read(ctx, tx)
		if err != nil {
			return err
		}
		out = got
		if got.Stored == got.Counted {
			return nil
		}
		out.Written = true
		return tx.Update(r.ref(postID), []firestore.Update{{Path: counter, Value: got.Counted}})
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ChildRecount{}, ErrNotFound
		}
		return ChildRecount{}, fmt.Errorf("posts: recount %s: %w", counter, err)
	}
	return out, nil
}
