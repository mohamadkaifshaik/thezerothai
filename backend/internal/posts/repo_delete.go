// repo_delete.go is the DeletePost batch (ADR-0010 D4): the post doc is deleted with an Exists precondition and
// users.postsCount decremented in the same atomic batch, so concurrent deletes of one post decrement exactly once.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// maxDeleteAttempts bounds the retries of a batch that lost a lock race (Aborted) on the author's users doc: the
// postsCount increment is a contended write when one post is deleted concurrently.
const maxDeleteAttempts = 4

// DeleteOwn implements Repo.
func (r *FirestoreRepo) DeleteOwn(ctx context.Context, id, authorID string) (bool, error) {
	if r.w.Counters == nil {
		return false, errors.New("posts: repo has no Counters configured")
	}
	var err error
	for attempt := 0; attempt < maxDeleteAttempts; attempt++ {
		// Writes are counted on a scratch counter and merged only on success, so a lost race reports 0 writes.
		scratch := &budget.Counter{}
		b := store.NewFirestoreBatch(r.client, scratch)
		b.Delete(r.ref(id), firestore.Exists)
		r.w.Counters.AddPostsCount(b, authorID, -1)
		if err = b.Commit(ctx); err == nil {
			c := budget.FromContext(ctx)
			c.AddWrites(scratch.Writes())
			c.AddDeletes(scratch.Deletes())
			return true, nil
		}
		if isFailedPrecondition(err) {
			return false, nil
		}
		if !isAborted(err) {
			break
		}
		// Lock contention: the retry either wins or sees the post gone (Exists fails => no-op).
		select {
		case <-ctx.Done():
			return false, fmt.Errorf("posts: delete post: %w", ctx.Err())
		case <-time.After(time.Duration(attempt+1) * 25 * time.Millisecond):
		}
	}
	return false, fmt.Errorf("posts: delete post: %w", err)
}

func isAborted(err error) bool {
	for e := err; e != nil; e = errors.Unwrap(e) {
		if status.Code(e) == codes.Aborted {
			return true
		}
	}
	return false
}

// isFailedPrecondition reports a lost Exists precondition. Firestore answers NotFound for a missing document
// under an Exists precondition (the emulator and production both); FailedPrecondition is accepted too.
func isFailedPrecondition(err error) bool {
	for e := err; e != nil; e = errors.Unwrap(e) {
		if c := status.Code(e); c == codes.FailedPrecondition || c == codes.NotFound {
			return true
		}
	}
	return false
}
