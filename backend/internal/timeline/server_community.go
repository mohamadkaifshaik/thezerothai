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

// GetCommunityTimeline returns a community's feed (ADR-0031 D6): root posts and quotes listed in the community, newest first, from the
// shared per-community entry (newest 30, 60 s, shared by every viewer) and posts.Reader.ByCommunity, filtered per viewer after the cache
// (service_community.go). Tokens are bound to the caller and the community; a Home, user or list token is VALIDATION with 0 reads.
//
// Order: FEATURE_COMMUNITIES then FEATURE_POSTS (0 reads), community_id shape and tokens (0 reads), then the community (missing or
// SUSPENDED is NOT_FOUND, an ARCHIVED one is readable), the removal check (a since_token older than a dropped removal is VALIDATION
// since_token, before any post is read), the caller's role, the rows, the caller's graph and userLikes.
//
// Budget, reads including the account-status interceptor's caller `users` read (page = page_size, 20 by default, max 50): cold open
// page + 5 = 25 at page 20 and 55 at page 50 (interceptor, community, the caller's member doc, posts <= page, caller graph,
// userLikes; the unit tests, which do not count the interceptor, measure 24 and 54). Every fill of the shared entry reads at most page
// posts. A since refresh with a warm entry is 1 + new posts in the worst case and 0 post reads when nothing is new (planning 3.5 +
// new); an empty refresh reads no graph and no userLikes: 4 cold (interceptor, community, member doc, the one query read). An older
// page is 1 query of <= page rows plus the graph and userLikes. NOT_FOUND costs <= 2. removed_ids costs 0 (the community document is
// held). Writes 0.
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
		// A process that does not wire communities keeps the route's pre-W5-27 answer.
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
