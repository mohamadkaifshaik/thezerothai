package timeline

import (
	"context"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// communityFlags adapts the timeline's posts.FlagChecker (Enabled only) to communities.FlagChecker. communities.Guard calls
// Enabled alone; GloballyOff is the kill-switch question for background jobs, which GetCommunityTimeline is not.
type communityFlags struct{ posts.FlagChecker }

func (communityFlags) GloballyOff(string) bool { return false }

// GetCommunityTimeline is the W5-22 stub of the community feed (ADR-0031 D3, D6; W5-27 implements it). It mounts the route so the
// interceptor chain covers it and runs the gates in the order the real method keeps: FEATURE_COMMUNITIES first, then FEATURE_POSTS,
// both with 0 reads (FAILED_PRECONDITION FEATURE_DISABLED, feature=communities or posts); past them it is still the generated
// Unimplemented answer. The rate-limit bucket (12/min) and the read budget apply from the interceptor chain already.
//
// Budget: 0 reads and 0 writes beyond the account-status interceptor's cached caller read.
func (s *Server) GetCommunityTimeline(ctx context.Context, req *connect.Request[timelinev1.GetCommunityTimelineRequest]) (*connect.Response[timelinev1.GetCommunityTimelineResponse], error) {
	uid, _ := authn.UIDFromContext(ctx)
	var fc communities.FlagChecker // nil = off for everyone
	if s.deps.Flags != nil {
		fc = communityFlags{s.deps.Flags}
	}
	if err := communities.Guard(ctx, fc, uid); err != nil {
		return nil, err
	}
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	return s.UnimplementedTimelineServiceHandler.GetCommunityTimeline(ctx, req)
}
