// repo_delete.go is the DeletePost batch (ADR-0010 D4): the post doc is deleted with an Exists precondition and
// users.postsCount decremented in the same atomic batch, so concurrent deletes of one post decrement exactly once.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Delete's bounded retry on a lost lock race: the postsCount increment is a contended write when one post is
// deleted concurrently. Shared helper: store.CommitWithRetry (full-jitter exponential backoff).
const (
	maxDeleteAttempts  = 4
	deleteRetryBackoff = 25 * time.Millisecond
)

// DeleteOwn implements Repo.
func (r *FirestoreRepo) DeleteOwn(ctx context.Context, id, authorID string) (bool, error) {
	if r.w.Counters == nil {
		return false, errors.New("posts: repo has no Counters configured")
	}
	// A failed Exists precondition (post already gone) is a correct 0-write no-op; a contended retry either wins
	// or sees the post gone.
	res, err := store.CommitWithRetry(ctx,
		func(c *budget.Counter) *store.FirestoreBatch { return store.NewFirestoreBatch(r.client, c) },
		store.RetryConfig{MaxAttempts: maxDeleteAttempts, Backoff: deleteRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff},
		func(b store.Batch) {
			b.Delete(r.ref(id), firestore.Exists)
			r.w.Counters.AddPostsCount(b, authorID, -1)
		})
	noteTxnAttempts(ctx, res.Attempts)
	if err != nil {
		return false, fmt.Errorf("posts: delete post: %w", err)
	}
	return res.Committed, nil
}
