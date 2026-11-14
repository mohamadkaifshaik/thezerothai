// repo_polls.go is the Firestore implementation of PollRepo. Collections owned here: pollVotes/{postId}_{uid}
// = {postId, uid, choice, createdAt, expireAt} (the natural-key vote record, TTL on expireAt) and the `pollVotes` array of
// userLikes/{uid} (the viewer's choices, "<postId>:<index>", newest last).
//
// A change is ONE more blind batch (ChangeVote) under a LastUpdateTime precondition on the vote doc.
//
// The vote is ONE batch with no read: Create of the vote doc, the posts counter Update (posts.EngagementWriter.StagePollVote, an
// implicit Exists precondition) and a field-level Set with MergeAll of userLikes.pollVotes. Every userLikes write is field-level
// (a known class of bug: a whole-document Set would empty the other lists).
//
// Hot posts (the poll total the service read is at or above HOT_COUNTER_THRESHOLD, posts.EngagementWriter.Hot): the counter
// write goes to the post's shards, which carry no precondition on the post, so a blind batch could no longer tell a deleted
// post. The vote and the change then run the SAME writes as a transaction that first reads the post (GuardHot: a read, not a
// precondition, so on a change the vote doc's LastUpdateTime stays the only precondition). A post that is gone answers
// VotePostGone / ChangeStale with nothing written, exactly as the cold batch's failed Exists does.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
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
	// Changes counts the vote changes (absent = 0) and ChangedAt is the time of the last one (absent = never changed).
	// Written by ChangeVote only (Increment(1) and the clock); small scalars on the automatic indexes. No earlier choice is kept.
	Changes   int       `firestore:"changes,omitempty"`
	ChangedAt time.Time `firestore:"changedAt,omitempty"`
}

func (r *FirestoreRepo) pollVoteRef(postID, uid string) *firestore.DocumentRef {
	return r.client.Collection(pollVotesCollection).Doc(docID(postID, uid))
}

// Vote implements PollRepo: one batch with no reads (vote doc, the post's counters, userLikes.pollVotes). It retries lock-race
// aborts a bounded number of times (store.CommitWithRetry); exhausted, the error wraps store.ErrContended.
// A hot post (p.Known) takes voteHot instead.
func (r *FirestoreRepo) Vote(ctx context.Context, p VoteParams) (VoteOutcome, error) {
	if r.w.Writer == nil {
		return VoteWritten, errors.New("engagement: repo has no post writer configured")
	}
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	now := r.now().UTC()
	if r.w.Writer.Hot(p.Known) {
		return r.voteHot(ctx, p, now)
	}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		r.stageVote(b, p, now)
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

// stageVote appends the writes of one vote (the same on the cold batch and the hot transaction) and returns the counter's
// committed hook (a no-op when cold).
func (r *FirestoreRepo) stageVote(b store.Batch, p VoteParams, now time.Time) func() {
	b.Create(r.pollVoteRef(p.PostID, p.UID), pollVoteDoc{
		PostID: p.PostID, UID: p.UID, Choice: p.Choice, CreatedAt: now, ExpireAt: p.ExpireAt.UTC(),
	})
	committed := r.w.Writer.StagePollVote(b, p.PostID, p.Choice, p.Known)
	b.Set(r.userLikesRef(p.UID), map[string]any{
		"pollVotes": firestore.ArrayUnion(pollEntry(p.PostID, p.Choice, p.ClosesAt)), "updatedAt": now,
		// The expiry day of this entry, for the daily sweep (poll_retention.go); ArrayUnion, so no vote loses another one day.
		"pollVotesDueDays": firestore.ArrayUnion(pollDueDay(p.ExpireAt)),
	}, firestore.MergeAll)
	return committed
}

// voteHot is Vote on a hot post: the vote's writes in a transaction that reads the post first (GuardHot; no lock under the
// database's optimistic concurrency, and hot voters never write the post, so they do not conflict with each other on it).
// A missing post is VotePostGone, an existing vote doc VoteExists; nothing is written in either case.
func (r *FirestoreRepo) voteHot(ctx context.Context, p VoteParams, now time.Time) (VoteOutcome, error) {
	err := r.runHotPollTx(ctx, p.PostID, p.Known, func(b store.Batch) func() { return r.stageVote(b, p, now) })
	switch {
	case err == nil:
		return VoteWritten, nil
	case errors.Is(err, posts.ErrNotFound):
		return VotePostGone, nil
	case status.Code(err) == codes.AlreadyExists:
		return VoteExists, nil
	default:
		return VoteWritten, err
	}
}

// runHotPollTx runs stage in a transaction behind GuardHot (posts.ErrNotFound when the post is gone) and calls the staged
// counter's committed hook once the transaction committed. Exhausted contention wraps store.ErrContended (mapVoteErr's
// contention answer); every other error is returned as Firestore gave it, so the caller can read its code.
func (r *FirestoreRepo) runHotPollTx(ctx context.Context, postID string, known int64, stage func(store.Batch) func()) error {
	var committed func()
	attempts, err := r.runTx(ctx, func(_ context.Context, tx *firestore.Transaction) error {
		committed = nil
		if err := r.w.Writer.GuardHot(tx, postID, known); err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		done := stage(b)
		if err := b.Err(); err != nil {
			return err
		}
		committed = done
		return nil
	})
	store.NoteTxnAttempts(ctx, "engagement_txn_contention", attempts)
	switch {
	case err == nil:
		committed()
		return nil
	case store.IsContention(err):
		return fmt.Errorf("engagement: poll vote: %w", errors.Join(store.ErrContended, err))
	}
	return err
}

// GetVote implements PollRepo: reads pollVotes/{postId}_{uid}.
func (r *FirestoreRepo) GetVote(ctx context.Context, uid, postID string) (VoteState, bool, error) {
	snap, err := r.pollVoteRef(postID, uid).Get(ctx)
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

// ChangeVote implements PollRepo: ONE batch, no reads. The hot post document is written by Increment,
// never read. Only the vote doc (LastUpdateTime = the version the caller read) and the post (the Exists precondition of the counter Update)
// carry preconditions; userLikes is two field-level merges (ArrayRemove of the old entry, ArrayUnion of the new one: one write cannot carry two
// transforms on one field), so a missing userLikes doc never fails the commit and "the vote doc did not move" still means "the post is gone".
// Two writes to one document in one commit are accepted by the emulator (TestRepoChangeVote_*).
// A hot post (p.Known) takes changeVoteHot instead.
func (r *FirestoreRepo) ChangeVote(ctx context.Context, p ChangeParams) (ChangeOutcome, error) {
	if r.w.Writer == nil {
		return ChangeStale, errors.New("engagement: repo has no post writer configured")
	}
	ctx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()
	now := r.now().UTC()
	if r.w.Writer.Hot(p.Known) {
		return r.changeVoteHot(ctx, p, now)
	}
	res, err := store.CommitWithRetry(ctx, r.newBatch, r.retryConfig(), func(b store.Batch) {
		r.stageChange(b, p, now)
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

// stageChange appends the writes of one vote change (the same on the cold batch and the hot transaction) and returns the
// counter's committed hook (a no-op when cold).
func (r *FirestoreRepo) stageChange(b store.Batch, p ChangeParams, now time.Time) func() {
	b.Update(r.pollVoteRef(p.PostID, p.UID), []firestore.Update{
		{Path: "choice", Value: p.To},
		{Path: "changes", Value: firestore.Increment(1)},
		{Path: "changedAt", Value: now},
	}, firestore.LastUpdateTime(p.Version))
	committed := r.w.Writer.StagePollChange(b, p.PostID, p.From, p.To, p.Known)
	b.Set(r.userLikesRef(p.UID), map[string]any{
		// Both forms of the old entry: the three-part one and a two-part one written before it (dev only).
		"pollVotes": firestore.ArrayRemove(pollEntry(p.PostID, p.From, p.ClosesAt), pollEntry(p.PostID, p.From, time.Time{})), "updatedAt": now,
	}, firestore.MergeAll)
	b.Set(r.userLikesRef(p.UID), map[string]any{
		"pollVotes": firestore.ArrayUnion(pollEntry(p.PostID, p.To, p.ClosesAt)), "updatedAt": now,
		// A no-op when the day is already there (the same post, the same closesAt); it adds the day when a legacy entry is replaced.
		"pollVotesDueDays": firestore.ArrayUnion(pollDueDay(p.ExpireAt)),
	}, firestore.MergeAll)
	return committed
}

// changeVoteHot is ChangeVote on a hot post: the change's writes (the shard -1 on From and +1 on To in one shard write)
// in a transaction behind GuardHot. The vote doc's LastUpdateTime is still the one precondition, checked at commit; a
// post that is gone (the guard's read) and a moved vote doc are both ChangeStale with nothing written, and the service's
// re-read tells them apart as it does for the cold batch (unmoved = the post is gone).
func (r *FirestoreRepo) changeVoteHot(ctx context.Context, p ChangeParams, now time.Time) (ChangeOutcome, error) {
	err := r.runHotPollTx(ctx, p.PostID, p.Known, func(b store.Batch) func() { return r.stageChange(b, p, now) })
	switch {
	case err == nil:
		return ChangeWritten, nil
	case errors.Is(err, posts.ErrNotFound), store.IsPreconditionFailed(err):
		return ChangeStale, nil
	default:
		return ChangeStale, err
	}
}

// TrimPollVotes implements PollRepo: one field-level Update (an Exists precondition), no read. It never creates the document: a
// trim or prune that races the account-deletion eraser must not bring a userLikes document back. A missing document is
// success.
func (r *FirestoreRepo) TrimPollVotes(ctx context.Context, uid string, drop []string) error {
	if len(drop) == 0 {
		return nil
	}
	_, err := r.userLikesRef(uid).Update(ctx, []firestore.Update{
		{Path: "pollVotes", Value: firestore.ArrayRemove(toAny(drop)...)},
		{Path: "updatedAt", Value: r.now().UTC()},
	})
	if err != nil && status.Code(err) != codes.NotFound {
		return fmt.Errorf("engagement: trim userLikes pollVotes: %w", err)
	}
	return nil
}
