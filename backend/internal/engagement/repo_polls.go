// repo_polls.go is the Firestore implementation of PollRepo (ADR-0029 D3, D6). Collections owned here: pollVotes/{postId}_{uid}
// = {postId, uid, choice, createdAt, expireAt} (the natural-key vote record, TTL on expireAt) and the `pollVotes` array of
// userLikes/{uid} (the viewer's choices, "<postId>:<index>", newest last).
//
// The vote is ONE batch with no read: Create of the vote doc, the posts counter Update (posts.EngagementWriter.StagePollVote, an
// implicit Exists precondition) and a field-level Set with MergeAll of userLikes.pollVotes. Every userLikes write is field-level
// (the ADR-0021 I-3 class of bug: a whole-document Set would empty the other lists).
package engagement

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

const pollVotesCollection = "pollVotes"

var _ PollRepo = (*FirestoreRepo)(nil)

// pollVoteDoc is pollVotes/{postId}_{uid}. expireAt is the TTL field (Terraform `poll_votes_expire_at`): closesAt + 30 d.
type pollVoteDoc struct {
	PostID    string    `firestore:"postId"`
	UID       string    `firestore:"uid"`
	Choice    int       `firestore:"choice"`
	CreatedAt time.Time `firestore:"createdAt"`
	ExpireAt  time.Time `firestore:"expireAt"`
}

func (r *FirestoreRepo) pollVoteRef(postID, uid string) *firestore.DocumentRef {
	return r.client.Collection(pollVotesCollection).Doc(docID(postID, uid))
}

// Vote implements PollRepo: one batch, 0 reads, 3 writes (vote doc, the post's counters, userLikes.pollVotes). It retries lock-race
// aborts a bounded number of times (store.CommitWithRetry); exhausted, the error wraps store.ErrContended.
func (r *FirestoreRepo) Vote(ctx context.Context, p VoteParams) (VoteOutcome, error) {
	if r.w.Writer == nil {
		return VoteWritten, errors.New("engagement: repo has no post writer configured")
	}
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	now := r.now().UTC()
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Create(r.pollVoteRef(p.PostID, p.UID), pollVoteDoc{
			PostID: p.PostID, UID: p.UID, Choice: p.Choice, CreatedAt: now, ExpireAt: p.ExpireAt.UTC(),
		})
		r.w.Writer.StagePollVote(b, p.PostID, p.Choice)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"pollVotes": firestore.ArrayUnion(pollEntry(p.PostID, p.Choice)), "updatedAt": now,
		}, firestore.MergeAll)
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
	switch {
	case err == nil && res.Committed:
		return VoteWritten, nil
	case err == nil:
		// CommitWithRetry maps NotFound and FailedPrecondition to "precondition failed": the posts Update found no document.
		return VotePostGone, nil
	case status.Code(err) == codes.AlreadyExists:
		return VoteExists, nil
	default:
		return VoteWritten, err
	}
}

// GetVote implements PollRepo: 1 read of pollVotes/{postId}_{uid}.
func (r *FirestoreRepo) GetVote(ctx context.Context, uid, postID string) (int, bool, error) {
	snap, err := r.pollVoteRef(postID, uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return 0, false, nil
		}
		return 0, false, fmt.Errorf("engagement: get poll vote: %w", err)
	}
	var d pollVoteDoc
	if err := snap.DataTo(&d); err != nil {
		return 0, false, fmt.Errorf("engagement: decode poll vote: %w", err)
	}
	return d.Choice, true, nil
}

// TrimPollVotes implements PollRepo: one field-level write, no read.
func (r *FirestoreRepo) TrimPollVotes(ctx context.Context, uid string, drop []string) error {
	if len(drop) == 0 {
		return nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	b.Set(r.userLikesRef(uid), map[string]any{
		"pollVotes": firestore.ArrayRemove(toAny(drop)...), "updatedAt": r.now().UTC(),
	}, firestore.MergeAll)
	if err := b.Commit(ctx); err != nil {
		return fmt.Errorf("engagement: trim userLikes pollVotes: %w", err)
	}
	return nil
}
