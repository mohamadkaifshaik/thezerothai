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
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

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
// Exists), retried on contention. AlreadyExists is ShareExists, a missing post SharePostGone; both wrote nothing.
func (r *FirestoreRepo) CreateShare(ctx context.Context, uid, postID string) (ShareOutcome, error) {
	if r.w.Writer == nil {
		return 0, fmt.Errorf("engagement: repo has no posts writer configured")
	}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Create(r.shareRef(postID, uid), likeDoc{PostID: postID, UID: uid, CreatedAt: r.now().UTC()})
		r.w.Writer.StageShareCount(b, postID, 1)
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
