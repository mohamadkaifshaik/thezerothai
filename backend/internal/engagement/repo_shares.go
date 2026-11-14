// repo_shares.go is the Firestore side of shares (shares design 2026-11-13 §3): postShares/{postId}_{uid}
// {postId, uid, createdAt}, one marker per account per post, whatever the channel. No channel, conversation or recipient is
// ever stored. The marker backs the invariant posts/{id}.shareCount == count(postShares where postId == id), like likes.
//
//	Q-S1 postShares where uid == X LIMIT 100              -> automatic single-field index (erasure)
//	Q-S2 postShares where uid == X ORDER BY __name__      -> automatic single-field index (export, pages of 500)
//	Q-S3 postShares where postId == X LIMIT 100           -> automatic single-field index (post_delete clean-up)
//	Q-S4 count() of postShares where postId == X          -> automatic single-field index (opsctl recount-shares)
//
// createdAt is exempt from indexing (firebase/firestore.indexes.json): it is never queried.
package engagement

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const postSharesCollection = "postShares"

var _ ShareRepo = (*FirestoreRepo)(nil)

func (r *FirestoreRepo) shareRef(postID, uid string) *firestore.DocumentRef {
	return r.client.Collection(postSharesCollection).Doc(docID(postID, uid))
}

// HasShare implements ShareRepo: one read.
func (r *FirestoreRepo) HasShare(ctx context.Context, uid, postID string) (bool, error) {
	_, err := r.shareRef(postID, uid).Get(ctx)
	switch status.Code(err) {
	case codes.OK:
		return true, nil
	case codes.NotFound:
		return false, nil
	default:
		return false, fmt.Errorf("engagement: get share marker: %w", err)
	}
}

// CreateShare implements ShareRepo: one blind batch (the marker's Create precondition and the counter Update's implicit
// Exists), retried on contention. AlreadyExists is ShareExists, a missing post SharePostGone; both wrote nothing. A hot
// post (known) takes createHotShare instead.
func (r *FirestoreRepo) CreateShare(ctx context.Context, uid, postID string, known int64) (ShareOutcome, error) {
	if r.w.Writer == nil {
		return 0, fmt.Errorf("engagement: repo has no posts writer configured")
	}
	if r.w.Writer.Hot(known) {
		return r.createHotShare(ctx, uid, postID, known)
	}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Create(r.shareRef(postID, uid), likeDoc{PostID: postID, UID: uid, CreatedAt: r.now().UTC()})
		r.w.Writer.StageShareCount(b, postID, 1, known)
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
	switch {
	case status.Code(err) == codes.AlreadyExists:
		return ShareExists, nil
	case err != nil:
		return 0, fmt.Errorf("engagement: create share marker: %w", err)
	case !res.Committed:
		return SharePostGone, nil
	}
	return ShareCreated, nil
}

// createHotShare is CreateShare on a hot post: the shareCount +1 goes to the post's shards, which carry no precondition,
// so it runs as a transaction that reads the post first (GuardHot: no lock under the database's optimistic concurrency,
// and concurrent sharers never write the post, so they do not conflict on it) and keeps the batch's answers: a missing
// post is SharePostGone, an existing marker ShareExists, nothing written in either case.
func (r *FirestoreRepo) createHotShare(ctx context.Context, uid, postID string, known int64) (ShareOutcome, error) {
	var committed func()
	attempts, err := r.runTx(ctx, func(_ context.Context, tx *firestore.Transaction) error {
		committed = nil
		if err := r.w.Writer.GuardHot(tx, postID, known); err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Create(r.shareRef(postID, uid), likeDoc{PostID: postID, UID: uid, CreatedAt: r.now().UTC()})
		done := r.w.Writer.StageShareCount(b, postID, 1, known)
		if err := b.Err(); err != nil {
			return err
		}
		committed = done
		return nil
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	switch {
	case errors.Is(err, posts.ErrNotFound):
		return SharePostGone, nil
	case status.Code(err) == codes.AlreadyExists:
		return ShareExists, nil
	case store.IsContention(err):
		return 0, fmt.Errorf("engagement: create share marker: %w", errors.Join(store.ErrContended, err))
	case err != nil:
		return 0, fmt.Errorf("engagement: create share marker: %w", err)
	}
	committed()
	return ShareCreated, nil
}

// deleteSharesOf deletes up to limit markers of postID (Q-S3), blind, in one batch: the post_delete job's step (the counter
// died with the post). full reports whether the page was full. Reads len(page), minimum 1.
func (r *FirestoreRepo) deleteSharesOf(ctx context.Context, postID string, limit int) (n int, full bool, err error) {
	return r.deleteByPost(ctx, postSharesCollection, postID, limit)
}

// CountShares returns count() of postShares where postId == X (Q-S4): one aggregation query, billed as one read per
// 1,000 index entries. It is the opsctl recount-shares side of the invariant.
func (r *FirestoreRepo) CountShares(ctx context.Context, postID string) (int64, error) {
	q := r.client.Collection(postSharesCollection).Where("postId", "==", postID)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("engagement: count shares: %w", err)
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("engagement: decode share count: %w", err)
	}
	return out.Count, nil
}
