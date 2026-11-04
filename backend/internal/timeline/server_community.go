package timeline

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// communityFlags adapts the timeline's posts.FlagChecker (Enabled only) to communities.FlagChecker. communities.Guard calls
// Enabled alone; GloballyOff is the kill-switch question for background jobs, which GetCommunityTimeline is not.
type communityFlags struct{ posts.FlagChecker }

func (communityFlags) GloballyOff(string) bool { return false }

// GetCommunityTimeline returns a community's feed: root posts and quotes listed in the community, newest first, from the
// shared per-community entry (newest 30, 60 s, shared by every viewer) and posts.Reader.ByCommunity, filtered per viewer after the cache
// (service_community.go). Tokens are bound to the caller and the community; a Home, user or list token is VALIDATION.
//
// Order: FEATURE_COMMUNITIES then FEATURE_POSTS, community_id shape and tokens (all before any read), then the community (missing or
// SUSPENDED is NOT_FOUND, an ARCHIVED one is readable), the removal check (a since_token older than a dropped removal is VALIDATION
// since_token, before any post is read), the caller's role, the rows, the caller's graph and userLikes.
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
	if uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, 0, "unauthenticated")
	}
	if s.community == nil {
		// A process that does not wire communities keeps the route's earlier answer.
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("timeline.v1.TimelineService.GetCommunityTimeline is not implemented"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := s.communityTimeline(ctx, uid, req.Msg)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(resp), nil
}
