// service_polls.go is VotePoll (ADR-0029 D6, ticket W6-7): one final vote per account per poll. The natural key
// pollVotes/{postId}_{uid} is the idempotency record (D7, the founder's F2 decision, a bend of CLAUDE.md rule 4 as ADR-0018's
// likes): no idempotency/* doc is stored, a replay of the same choice is a 0-write success, a different choice is ALREADY_VOTED.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"

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
	outcomeVoted     = "voted"
	outcomeAlready   = "already_voted"
	outcomeClosed    = "closed"
	outcomeAuthor    = "author"
	fieldContention  = "contention"
	fieldPostHash    = "post_hash"
	pollVotesDayName = "poll_votes_daily"
)

// pollMetaChoice is the metadata key ALREADY_VOTED carries: the caller's own stored 0-based choice.
const pollMetaChoice = "choice"

// VotePoll implements Polls.
func (m *Module) VotePoll(ctx context.Context, uid, key, postID string, choiceIndex int32) (PollVote, error) {
	return m.s.votePoll(ctx, uid, key, postID, choiceIndex)
}

var _ Polls = (*Module)(nil)

// pollEntry is the userLikes.pollVotes entry of a vote: "<postId>:<index>" (ADR-0029 D3).
func pollEntry(postID string, choice int) string { return postID + ":" + strconv.Itoa(choice) }

// pollBusyErr is the retryable answer of a vote that kept losing lock races (contention) or ran out of its transaction time.
func pollBusyErr() error { return bookmarkBusyErr() }

// votePoll implements Polls.VotePoll in the order of ADR-0029 D6; every refusal writes nothing.
func (s *service) votePoll(ctx context.Context, uid, key, postID string, choiceIndex int32) (_ PollVote, err error) {
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
	repo := s.d.PollRepo
	if repo == nil {
		return PollVote{}, errors.New("engagement: no poll repo configured")
	}
	// Step 6: one batch. It runs on a context that survives the caller leaving (the vote may commit anyway, and the cache and
	// the response below must agree with it); the repo bounds it with txTimeout.
	res, verr := repo.Vote(context.WithoutCancel(ctx), VoteParams{
		UID: uid, PostID: target.ID, Choice: choice, ExpireAt: target.Poll.ClosesAt.Add(s.d.PollVoteTTLAfterClose),
	})
	if verr != nil {
		return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, verr)
	}
	post := target
	switch res {
	case VotePostGone:
		return PollVote{}, notFound() // deleted between the visibility read and the commit: 0 writes
	case VoteWritten:
		logger.SetRequestField(ctx, fieldOutcome, outcomeVoted)
		if fresh := s.d.Posts.PollVoted(target.ID, choice); fresh != nil {
			post = fresh // the cached copy, composed with any concurrent vote on this instance
		} else {
			post = target.Voted(choice)
		}
	case VoteExists:
		// Step 7: read the vote doc (+1). The same choice is a replay (0 writes, the current view); another is ALREADY_VOTED.
		stored, found, gerr := repo.GetVote(ctx, uid, target.ID)
		if gerr != nil {
			return PollVote{}, s.mapVoteErr(ctx, uid, target.ID, gerr)
		}
		if !found {
			// The doc existed a moment ago and is gone now (a TTL cannot run before closesAt): ask the client to retry.
			return PollVote{}, pollBusyErr()
		}
		if stored != choice {
			outcome = outcomeAlready
			return PollVote{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED,
				"you already voted in this poll").WithMeta(pollMetaChoice, strconv.Itoa(stored))
		}
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	}
	return s.pollVoteView(ctx, uid, post, choice, res == VoteWritten), nil
}

// pollVoteView builds the response of a committed or replayed vote: the viewer's like, repost and bookmark flags from the
// userLikes cache (1 read when cold), with viewer_poll_choice and results_visible from THIS call's vote, never from userLikes
// (D6 step 8), so a replay shows the results even when the userLikes entry was trimmed. The cache is updated from the written
// data; a failed userLikes read degrades to a view without those flags (logged), it never fails a committed vote.
func (s *service) pollVoteView(ctx context.Context, uid string, post *posts.Post, choice int, wrote bool) PollVote {
	entry := pollEntry(post.ID, choice)
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

// withPollVote appends entry unless the list already holds a vote for postID.
func withPollVote(list []string, postID, entry string) []string {
	prefix := postID + ":"
	for _, e := range list {
		if len(e) > len(prefix) && e[:len(prefix)] == prefix {
			return list
		}
	}
	return append(list, entry)
}
