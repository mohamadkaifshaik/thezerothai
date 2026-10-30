// server_polls.go holds the Connect handler of VotePoll (ADR-0029 D6, tickets W6-4 and W6-7): the flag gate (W6-4); the
// vote itself (W6-7) replaces the Unimplemented answer after the gate.
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

// VotePoll records the caller's one, final vote in a poll (ADR-0029 D6). The W6-4 skeleton is the flag gate only: it
// answers FEATURE_DISABLED per the gate above and Unimplemented to a caller it lets through, with 0 Firestore reads and 0
// writes (the interceptor's account-status read apart). Worst case once W6-7 lands (ADR-0029 Cost impact): 8 reads cold
// (interceptor 1, post 1, author users 1, caller graph 1, +2 for a REPOST id, +1 on blockedBy overflow, userLikes 1) and 3
// writes (vote doc, post counters, userLikes.pollVotes) for a new vote; a replay or ALREADY_VOTED 9 reads, 0 writes; a
// refusal at most 7 reads, 0 writes.
func (s *Server) VotePoll(ctx context.Context, _ *connect.Request[engagementv1.VotePollRequest]) (*connect.Response[engagementv1.VotePollResponse], error) {
	if _, err := s.guardPoll(ctx); err != nil {
		return nil, err
	}
	return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("VotePoll is not wired"))
}
