// repo_polls.go is the Firestore implementation of PollRepo (ADR-0029 D3, D6). Collections owned here: pollVotes/{postId}_{uid}
// = {postId, uid, choice, createdAt, expireAt} (the natural-key vote record, TTL on expireAt) and the `pollVotes` array of
// userLikes/{uid} (the viewer's choices, "<postId>:<index>", newest last).
//
// A change (ADR-0029 Amendment 1 A2.3) is ONE more blind batch (ChangeVote) under a LastUpdateTime precondition on the vote doc.
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
	// Changes counts the vote changes (absent = 0) and ChangedAt is the time of the last one (absent = never changed): ADR-0029 Amendment 1
	// A2.6. Written by ChangeVote only (Increment(1) and the clock); small scalars on the automatic indexes. No earlier choice is kept.
	Changes   int       `firestore:"changes,omitempty"`
	ChangedAt time.Time `firestore:"changedAt,omitempty"`
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
func (r *FirestoreRepo) GetVote(ctx context.Context, uid, postID string) (VoteState, bool, error) {
	snap, err := r.pollVoteRef(postID, uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return VoteState{}, false, nil
		}
		return VoteState{}, false, fmt.Errorf("engagement: get poll vote: %w", err)
	}
	var d pollVoteDoc
	if err := snap.DataTo(&d); err != nil {
		return VoteState{}, false, fmt.Errorf("engagement: decode poll vote: %w", err)
	}
	return VoteState{Choice: d.Choice, Changes: d.Changes, UpdateTime: snap.UpdateTime}, true, nil
}

// ChangeVote implements PollRepo: ONE batch, 0 reads, 4 writes (ADR-0029 Amendment 1 A2.3). The hot post document is written by Increment,
// never read. Only the vote doc (LastUpdateTime = the version the caller read) and the post (the Exists precondition of the counter Update)
// carry preconditions; userLikes is two field-level merges (ArrayRemove of the old entry, ArrayUnion of the new one: one write cannot carry two
// transforms on one field), so a missing userLikes doc never fails the commit and "the vote doc did not move" still means "the post is gone".
// Two writes to one document in one commit are accepted by the emulator (TestRepoChangeVote_*).
func (r *FirestoreRepo) ChangeVote(ctx context.Context, p ChangeParams) (ChangeOutcome, error) {
	if r.w.Writer == nil {
		return ChangeStale, errors.New("engagement: repo has no post writer configured")
	}
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	now := r.now().UTC()
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		b.Update(r.pollVoteRef(p.PostID, p.UID), []firestore.Update{
			{Path: "choice", Value: p.To},
			{Path: "changes", Value: firestore.Increment(1)},
			{Path: "changedAt", Value: now},
		}, firestore.LastUpdateTime(p.Version))
		r.w.Writer.StagePollChange(b, p.PostID, p.From, p.To)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"pollVotes": firestore.ArrayRemove(pollEntry(p.PostID, p.From)), "updatedAt": now,
		}, firestore.MergeAll)
		b.Set(r.userLikesRef(p.UID), map[string]any{
			"pollVotes": firestore.ArrayUnion(pollEntry(p.PostID, p.To)), "updatedAt": now,
		}, firestore.MergeAll)
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", res.Attempts)
	switch {
	case err == nil && res.Committed:
		return ChangeWritten, nil
	case err == nil:
		return ChangeStale, nil // NotFound or FailedPrecondition: the vote doc moved or the post is gone
	default:
		return ChangeStale, err
	}
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
