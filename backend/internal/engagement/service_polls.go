// service_polls.go is VotePoll (ADR-0029 D6, ticket W6-7; Amendment 1 A1 and A2, ticket W6-36): one vote per account per poll, changeable until
// the poll closes. The natural key pollVotes/{postId}_{uid} is the idempotency record (D7, the founder's F2 decision, a bend of CLAUDE.md rule 4
// as ADR-0018's likes): no idempotency/* doc is stored, a replay of the same choice is a 0-write success. A different choice is a change only
// when expected_choice names the stored vote (the compare-and-set of A2.2), else ALREADY_VOTED. The voter blocking the author is TARGET_BLOCKED (A1).
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line outcomes and fields of poll_vote (ADR-0029 Observability). Never the choice.
const (
	outcomeVoted       = "voted"
	outcomeChanged     = "changed"
	outcomeChangeLimit = "change_limit"
	outcomeStale       = "stale_expected" // the ALREADY_VOTED row of the A2.2 table (was "already_voted")
	outcomeVoterBlocks = "voter_blocks_author"
	outcomeClosed      = "closed"
	outcomeAuthor      = "author"
	fieldContention    = "contention"
	fieldPostHash      = "post_hash"
	pollVotesDayName   = "poll_votes_daily"
)

// pollMetaChoice is the metadata key ALREADY_VOTED and LIMIT_REACHED carry: the caller's own stored 0-based choice.
const pollMetaChoice = "choice"

// pollChangesLimitName is the LIMIT_REACHED metadata["limit"] value of the per-poll change cap (POLL_VOTE_CHANGES_MAX).
const pollChangesLimitName = "poll_vote_changes"

// pollWriteAttempts bounds one VotePoll's decide-and-write rounds (A2.3 step 3): a round is lost only to a concurrent writer of the same vote
// doc, and the fourth loss is the contention answer.
const pollWriteAttempts = 4

// VotePoll implements Polls.
func (m *Module) VotePoll(ctx context.Context, uid, key, postID string, choiceIndex, expectedChoice int32) (PollVote, error) {
	return m.s.votePoll(ctx, uid, key, postID, choiceIndex, expectedChoice)
}

var _ Polls = (*Module)(nil)

// pollBusyErr is the retryable answer of a vote that kept losing lock races (contention) or ran out of its transaction time.
func pollBusyErr() error { return bookmarkBusyErr() }

// votePoll implements Polls.VotePoll in the order of ADR-0029 D6; every refusal writes nothing.
func (s *service) votePoll(ctx context.Context, uid, key, postID string, choiceIndex, expectedChoice int32) (_ PollVote, err error) {
	logger.SetRequestField(ctx, fieldOp, "poll_vote")
	outcome := ""
	defer func() {
		if err == nil {
			return
		}
		if outcome != "" {
			logger.SetRequestField(ctx, fieldOutcome, outcome)
			return
		}
		noteRejected(ctx, err)
	}()
	// D6 step 3: shape, 0 reads. The message never echoes the value.
	if err := validate(key, postID); err != nil {
		return PollVote{}, err
	}
	// post_hash: HashUID (plain SHA-256, first 8 bytes), the logger's convention for object ids that are not guessable from other ids
	// (message_hash does the same). A post id is public, so no key; it lets an operator count votes and contention per poll.
	logger.SetRequestField(ctx, fieldPostHash, logger.HashPost(postID))
	if choiceIndex < 0 || choiceIndex >= posts.MaxPollChoices {
		return PollVote{}, apierr.Validation("choice_index", "choice_index must be between 0 and 3")
	}
	// expected_choice (A2.2) is 0 or the 1-based choice the caller holds; shape only, 0 reads. A value beyond the poll's options never matches.
	if expectedChoice < 0 || expectedChoice > posts.MaxPollChoices {
		return PollVote{}, apierr.Validation("expected_choice", "expected_choice must be between 0 and 4")
	}
	choice := int(choiceIndex)
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "voting"); err != nil {
		return PollVote{}, err
	}
	// The new-account daily cap (POLL_VOTES_PER_DAY_NEW_ACCOUNT): the ratelimit interceptor counted this call in the shared
	// poll_votes_daily counter but cannot tell account age, so the service compares that same counter with the lower limit.
	// Before any post read, so a refusal is cheap. The profile is cache-first (the account-status interceptor just read it).
	if s.d.PollVoteCap != nil && s.d.NewAccountPollVotesPerDay > 0 {
		prof, perr := s.profile(ctx, uid)
		if perr != nil {
			return PollVote{}, perr
		}
		if s.isNew(prof) && s.d.PollVoteCap.Spent(uid) > s.d.NewAccountPollVotesPerDay {
			return PollVote{}, s.newAccountVoteCapErr(ctx)
		}
	}
	// Step 4: the target as Like resolves it (a REPOST id acts on its original); every refusal is the one NOT_FOUND.
	target, err := s.resolveViewable(ctx, uid, postID)
	if err != nil {
		return PollVote{}, err
	}
	// Step 5: poll checks on the (cached) post, server time. They run after the visibility read, so a refusal tells nothing
	// GetPost does not.
	switch {
	case target.Poll == nil:
		return PollVote{}, apierr.Validation("post_id", "this post has no poll")
	case target.AuthorID == uid:
		outcome = outcomeAuthor
		return PollVote{}, apierr.Validation("post_id", "you cannot vote in your own poll")
	case target.Poll.Closed(s.now()):
		outcome = outcomeClosed
		return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED, "this poll is closed")
	case choice >= len(target.Poll.Options):
		return PollVote{}, apierr.Validation("choice_index", "choice_index is not a choice of this poll")
	}
	// Step 5e (A1): the voter blocks the author. After the closed and range checks, so a blocked voter on a closed poll refreshes to the final
	// results; after Viewable, so an author who blocks the voter has already answered the one NOT_FOUND. 0 reads: the snapshot is the one
	// Viewable just cached. A replay is refused too (A1.1).
	blocked, berr := s.voterBlocksAuthor(ctx, uid, target.AuthorID)
	if berr != nil {
		return PollVote{}, berr
	}
	if blocked {
		outcome = outcomeVoterBlocks
		return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED, "you blocked this author, unblock to vote")
	}
	if s.d.PollRepo == nil {
		return PollVote{}, errors.New("engagement: no poll repo configured")
	}
	return s.decideAndWrite(ctx, uid, target, choice, int(expectedChoice), &outcome)
}

// voterBlocksAuthor reports whether uid blocks authorID, from the caller's own graph snapshot (blocked[], cached 60 s: +0 reads after Viewable).
// It fails closed: no graph wired, or a snapshot error, is an error and never "not blocked".
func (s *service) voterBlocksAuthor(ctx context.Context, uid, authorID string) (bool, error) {
	if s.d.Graph == nil {
		return false, errors.New("engagement: no graph reader configured for VotePoll")
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return false, logger.RedactErr(fmt.Errorf("engagement: poll vote: caller graph: %w", err), uid, authorID)
	}
	return snap.Blocked[authorID], nil
}

// decideAndWrite is steps 6 and 7 of D6 with the A2.2 decision table: up to pollWriteAttempts rounds, each either a blind create (no vote doc known
// to exist) or a decision against the vote doc as just read (replay, change, LIMIT_REACHED, ALREADY_VOTED). A round repeats only when a concurrent
// writer moved the vote doc under it. The batches run on a context that survives the caller leaving (the write may commit anyway, and the cache
// and the response must agree with it); the repo bounds each with txTimeout. outcome is the request-line outcome of a refusal.
func (s *service) decideAndWrite(ctx context.Context, uid string, target *posts.Post, choice, expected int, outcome *string) (PollVote, error) {
	repo := s.d.PollRepo
	wctx := context.WithoutCancel(ctx)
	// e == 0 tries today's blind create first and reads the vote doc only on AlreadyExists; e != 0 reads it first (A2.3 step 1).
	needRead := expected != 0
	var prev time.Time // the UpdateTime of the vote doc a change just failed against
	for attempt := 0; attempt < pollWriteAttempts; attempt++ {
		if attempt > 0 && target.Poll.Closed(s.now()) { // A2.3 step 4: a retried round never commits after close
			*outcome = outcomeClosed
			return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED, "this poll is closed")
		}
		if !needRead {
			res, verr := repo.Vote(wctx, VoteParams{
				UID: uid, PostID: target.ID, Choice: choice, ExpireAt: target.Poll.ClosesAt.Add(s.d.PollVoteTTLAfterClose), ClosesAt: target.Poll.ClosesAt,
			})
			if verr != nil {
				return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, verr)
			}
			switch res {
			case VotePostGone:
				return PollVote{}, notFound() // deleted between the visibility read and the commit: 0 writes
			case VoteWritten:
				logger.SetRequestField(ctx, fieldOutcome, outcomeVoted)
				post := target.Voted(choice)
				if fresh := s.d.Posts.PollVoted(target.ID, choice); fresh != nil {
					post = fresh // the cached copy, composed with any concurrent vote on this instance
				}
				return s.pollVoteView(ctx, uid, post, choice, true), nil
			}
			needRead = true // VoteExists: read the vote doc (D6 step 7)
			continue
		}
		cur, found, gerr := repo.GetVote(ctx, uid, target.ID)
		if gerr != nil {
			return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, gerr)
		}
		if !found {
			if !prev.IsZero() {
				return PollVote{}, notFound() // a change lost its precondition and the vote doc is gone: a deleted post (a TTL cannot run before closesAt)
			}
			if expected == 0 {
				return PollVote{}, pollBusyErr() // the doc existed a moment ago and is gone now: ask the client to retry
			}
			needRead = false // no vote yet: the blind create of a new vote, whatever expected_choice says (A2.2 row 1)
			continue
		}
		switch {
		case cur.Choice == choice: // a replay: the current view, 0 writes
			logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
			return s.pollVoteView(ctx, uid, target, choice, false), nil
		case expected != cur.Choice+1: // a stale or absent expected_choice: today's answer, 0 writes
			*outcome = outcomeStale
			return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED,
				"you already voted in this poll").WithMeta(pollMetaChoice, strconv.Itoa(cur.Choice))
		case cur.Changes >= s.d.PollVoteChangesMax:
			*outcome = outcomeChangeLimit
			return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
				"you can't change your vote again").WithMeta("limit", pollChangesLimitName).WithMeta(pollMetaChoice, strconv.Itoa(cur.Choice))
		}
		if !prev.IsZero() && cur.UpdateTime.Equal(prev) {
			return PollVote{}, notFound() // the precondition failed and the vote doc did not move: the post is gone
		}
		res, cerr := repo.ChangeVote(wctx, ChangeParams{UID: uid, PostID: target.ID, From: cur.Choice, To: choice, Version: cur.UpdateTime, ClosesAt: target.Poll.ClosesAt, ExpireAt: target.Poll.ClosesAt.Add(s.d.PollVoteTTLAfterClose)})
		if cerr != nil {
			return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, cerr)
		}
		if res == ChangeStale {
			prev = cur.UpdateTime // read again next round: moved = decide again, unmoved = the post is gone
			continue
		}
		logger.SetRequestField(ctx, fieldOutcome, outcomeChanged)
		post := target.VoteChanged(cur.Choice, choice)
		if fresh := s.d.Posts.PollVoteChanged(target.ID, cur.Choice, choice); fresh != nil {
			post = fresh // the cached copy, composed with any concurrent vote or change on this instance
		}
		return s.pollVoteView(ctx, uid, post, choice, false), nil
	}
	return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, store.ErrContended) // four lost rounds: a hot vote doc, the contention signal
}

// pollVoteView builds the response of a committed or replayed vote: the viewer's like, repost and bookmark flags from the
// userLikes cache (1 read when cold), with viewer_poll_choice and results_visible from THIS call's vote, never from userLikes
// (D6 step 8), so a replay shows the results even when the userLikes entry was trimmed. The cache is updated from the written
// data; a failed userLikes read degrades to a view without those flags (logged), it never fails a committed vote.
func (s *service) pollVoteView(ctx context.Context, uid string, post *posts.Post, choice int, wrote bool) PollVote {
	var closes time.Time
	if post.Poll != nil {
		closes = post.Poll.ClosesAt
	}
	entry := pollEntry(post.ID, choice, closes)
	var vs posts.ViewerSet
	if st, serr := s.state(ctx, uid); serr != nil {
		slog.WarnContext(ctx, "engagement_poll_vote_viewer_degraded", "error", logger.RedactErr(serr, uid, post.ID).Error())
	} else {
		vs = st.set
	}
	if next := s.cache.updatePollVotes(uid, func(v []string) []string { return withPollVote(v, post.ID, entry) }); next != nil {
		vs = next.set
	}
	vs = vs.WithPollVotes([]string{entry}) // only this post is rendered
	out := PollVote{Post: post, Viewer: vs}
	if s.d.Audience != nil && s.d.Graph != nil {
		// 0 reads: the snapshot is the one the visibility check just cached.
		if snap, err := s.d.Graph.Snapshot(ctx, uid); err == nil {
			out.Hint = RowHint{Protected: s.d.Audience.ProtectedAuthor(ctx, uid, post.AuthorID, snap.Following[post.AuthorID])}
		}
	}
	if wrote {
		s.trimPollVotes(context.WithoutCancel(ctx), uid)
	}
	return out
}

// trimPollVotes is the lazy trim of userLikes.pollVotes (ADR-0029 D3, the TrimLikes pattern A3): a cached list over
// PollViewerVotesKept + slack gets its oldest entries ArrayRemoved down to PollViewerVotesKept (1 write, no read). Best effort: a
// failure is logged and the list stays long until the next vote. The read side never trims.
func (s *service) trimPollVotes(ctx context.Context, uid string) {
	kept := s.d.PollViewerVotesKept
	if kept <= 0 || s.d.PollRepo == nil {
		return
	}
	st, ok := s.cache.get(uid)
	if !ok || len(st.pollVotes) <= kept+trimSlack {
		return
	}
	drop := append([]string(nil), st.pollVotes[:len(st.pollVotes)-kept]...)
	ctx, cancel := context.WithTimeout(ctx, trimTimeout)
	defer cancel()
	if err := s.d.PollRepo.TrimPollVotes(ctx, uid, drop); err != nil {
		slog.WarnContext(ctx, "engagement_poll_trim_failed", "error", logger.RedactErr(err, uid).Error())
		return
	}
	s.cache.updatePollVotes(uid, func(v []string) []string { return withoutIDs(v, drop) })
}

// newAccountVoteCapErr is the interceptor's own rejection shape (RESOURCE_EXHAUSTED, RATE_LIMITED, metadata limit, retry_after
// to IST midnight), so a client cannot tell which of the two caps refused.
func (s *service) newAccountVoteCapErr(ctx context.Context) error {
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.LimitName = pollVotesDayName
	}
	return apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "too many requests, please slow down").
		WithMeta("limit", pollVotesDayName).WithRetryAfter(quota.UntilNextDay(s.now()))
}

// mapVoteErr turns a PollRepo error into the handler's answer. Exhausted contention (Aborted after the store's bounded retry) or
// the transaction's own timeout is a retryable UNAVAILABLE counted as contention=true (the stage-ladder signal that a poll is
// hot, ADR-0029 D6 step 9); a caller that left is a client outcome; anything else is a redacted internal error.
func (s *service) mapVoteErr(ctx context.Context, uid, postID string, err error) error {
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldContention, true)
		logger.SetRequestField(ctx, fieldOutcome, outcomeContention)
		slog.WarnContext(ctx, "poll_vote_contention", "uid_hash", logger.HashUID(uid), "post_hash", logger.HashPost(postID))
		return pollBusyErr()
	}
	return logger.RedactErr(fmt.Errorf("engagement: poll vote: %w", err), uid, postID)
}

// withPollVote returns list with entry as the post's one vote: any earlier entry for postID is dropped and entry goes last (ADR-0029 I-V3: one
// entry per post, replaced on a change, the order Firestore's ArrayRemove + ArrayUnion leaves). The vote doc is the truth, so a replay corrects a
// stale entry too. pollEntry builds the entry; this prefix match is its only reader here (W6-29 changes the entry format in both).
func withPollVote(list []string, postID, entry string) []string {
	prefix := postID + ":"
	out := make([]string, 0, len(list)+1)
	for _, e := range list {
		if len(e) > len(prefix) && e[:len(prefix)] == prefix {
			continue
		}
		out = append(out, e)
	}
	return append(out, entry)
}

// pruneExpiredPollVotes drops the expired userLikes.pollVotes entries (closesAt + POLL_VOTE_TTL_AFTER_CLOSE, poll_retention.go) from
// a freshly loaded document: they are never cached or shown, and one best-effort field-level Update (an Exists precondition, no
// read, 1 write, once per expiry because the removal is persisted) removes them from Firestore. A failed write is logged and
// retried the next time the document is loaded (at most once per CACHE_TTL per instance); DEGRADED_MODE=readonly writes nothing.
// Staleness: a cached copy can show the check mark of an entry that expired inside the last CACHE_TTL (60 s).
func (s *service) pruneExpiredPollVotes(ctx context.Context, uid string, ul UserLikes) UserLikes {
	live, expired := splitPollVotes(ul.PollVotes, s.d.PollVoteTTLAfterClose, s.now())
	if len(expired) == 0 {
		return ul
	}
	ul.PollVotes = live
	if s.d.ReadOnly || s.d.PollRepo == nil {
		return ul
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), trimTimeout)
	defer cancel()
	if err := s.d.PollRepo.TrimPollVotes(wctx, uid, expired); err != nil {
		slog.WarnContext(ctx, "engagement_poll_prune_failed", "error", logger.RedactErr(err, uid).Error())
	}
	return ul
}
