// server_polls.go holds the Connect handler of VotePoll (ADR-0029 D6, tickets W6-4 and W6-7): the flag gate (W6-4), then the vote
// (W6-7) through the Polls seam. No business logic here.
package engagement

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// PollsFlagName is the wire name of FEATURE_POLLS (ADR-0029 D12). CreatePost with a poll needs it on for the caller
// (posts); VotePoll needs FEATURE_ENGAGEMENT on for the caller and this flag NOT globally off.
const PollsFlagName = posts.PollsFlagName

// guardPoll is the flag gate of VotePoll, run before any Firestore access (ADR-0029 D6 step 2): FEATURE_POSTS first (the
// posts guard), then FEATURE_ENGAGEMENT on for the caller (feature=engagement), then FEATURE_POLLS not globally off
// (feature=polls; Registry.GloballyOff, the ADR-0021 L-A pattern: a viewer outside a polls allowlist may still vote in an
// existing poll). A checker without GloballyOff gets the per-caller answer. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED and 0 reads. It returns the caller's uid.
func (s *Server) guardPoll(ctx context.Context) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if err := flags.Guard(ctx, s.flags.Enabled, uid, FlagName); err != nil {
		logger.SetRequestField(ctx, "feature", FlagName)
		return "", flags.DisabledError().WithMeta("feature", FlagName)
	}
	on := s.flags.Enabled(uid, PollsFlagName)
	if g, ok := s.flags.(posts.GloballyOffChecker); ok {
		on = !g.GloballyOff(PollsFlagName)
	}
	if !on {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
		logger.SetRequestField(ctx, "feature", PollsFlagName)
		return "", flags.DisabledError().WithMeta("feature", PollsFlagName)
	}
	return uid, nil
}

// VotePoll records the caller's vote in a poll, or changes it until the poll closes (ADR-0029 D6, Amendment 1 A1 and A2); the rules are
// Polls.VotePoll. It is behind FEATURE_POSTS, FEATURE_ENGAGEMENT on for the caller and FEATURE_POLLS not globally off. Worst case once the gate
// passes (ADR-0029 Cost impact):
//   - a new vote: 8 reads cold (interceptor 1, post 1, author users 1, caller graph 1, +2 for a REPOST id, +1 on blockedBy overflow, userLikes 1)
//     and 3 writes in one batch (vote doc, the post's poll counters, userLikes.pollVotes) + 1 TTL delete later; planning 3 reads;
//   - a change (expected_choice names the stored vote): 9 reads worst (the 8 + the vote doc), 4 typical, 4 writes in one batch (vote doc under a
//     LastUpdateTime precondition, the post's two counters, userLikes ArrayRemove and ArrayUnion), +1 read per lost round (at most 3 more);
//   - a replay, ALREADY_VOTED (a stale or absent expected_choice) and LIMIT_REACHED (the change cap): 9 worst, 0 writes;
//   - TARGET_BLOCKED (the voter blocks the author), closed, author, no poll, choice range: at most 7 reads, 0 writes (the block check adds none);
//   - a flag, shape, rate-bucket or cap refusal costs the interceptor's 1 read. The new-account daily cap is applied in the service.
func (s *Server) VotePoll(ctx context.Context, req *connect.Request[engagementv1.VotePollRequest]) (*connect.Response[engagementv1.VotePollResponse], error) {
	uid, err := s.guardPoll(ctx)
	if err != nil {
		return nil, err
	}
	if s.polls == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("VotePoll is not wired"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	res, err := s.polls.VotePoll(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId(), req.Msg.GetChoiceIndex(), req.Msg.GetExpectedChoice())
	if err != nil {
		return nil, err
	}
	v := posts.ToView(res.Post, res.Viewer, uid) // the one converter: results visible for this voter, viewer_poll_choice from this call's vote
	res.Hint.Apply(v)
	return connect.NewResponse(&engagementv1.VotePollResponse{Post: v}), nil
}
