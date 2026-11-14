// server_polls.go holds the Connect handler of VotePoll: the flag gate, then the vote
// through the Polls seam. No business logic here.
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

// PollsFlagName is the wire name of FEATURE_POLLS. CreatePost with a poll needs it on for the caller
// (posts); VotePoll needs FEATURE_ENGAGEMENT on for the caller and this flag NOT globally off.
const PollsFlagName = posts.PollsFlagName

// guardPoll is the flag gate of VotePoll, run before any Firestore access: FEATURE_POSTS first (the
// posts guard), then FEATURE_ENGAGEMENT on for the caller (feature=engagement), then FEATURE_POLLS not globally off
// (feature=polls; Registry.GloballyOff: a viewer outside a polls allowlist may still vote in an
// existing poll). A checker without GloballyOff gets the per-caller answer. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED, before any Firestore access. It returns the caller's uid.
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

// VotePoll records the caller's vote in a poll, or changes it until the poll closes; the rules are
// Polls.VotePoll. It is behind FEATURE_POSTS, FEATURE_ENGAGEMENT on for the caller and FEATURE_POLLS not globally off. Once the gate
// passes:
//   - a new vote: the visibility check (post, author users, caller graph) and userLikes are read, and one batch writes
//     the vote doc, the post's poll counters and userLikes.pollVotes; the vote doc is removed later by its TTL;
//   - a change (expected_choice names the stored vote): the vote doc is read first, and one batch writes it (under a
//     LastUpdateTime precondition), the post's two counters, and userLikes ArrayRemove and ArrayUnion; a lost round
//     reads the vote doc again;
//   - a replay, ALREADY_VOTED (a stale or absent expected_choice) and LIMIT_REACHED (the change cap): nothing is written;
//   - TARGET_BLOCKED (the voter blocks the author), closed, author, no poll, choice range: nothing is written, and the
//     block check adds no read;
//   - a flag, shape or rate-bucket refusal does no Firestore access.
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
	posts.ApplyPublicViews(v, res.Post, res.Hint.Protected)
	return connect.NewResponse(&engagementv1.VotePollResponse{Post: v}), nil
}
