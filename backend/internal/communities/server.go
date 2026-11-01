package communities

import (
	"context"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// Server is the W5-22 skeleton of the CommunityService handler. It mounts every route so the interceptor chain (App Check, ID
// token, account status, rate limits, read budget, degraded mode) covers them from the first revision that links the generated
// code, and runs the flag gate (FEATURE_COMMUNITIES, ADR-0031 D10) before anything else: a caller outside the flag gets
// FAILED_PRECONDITION FEATURE_DISABLED feature=communities with 0 Firestore reads. Past the gate each method is still the
// generated Unimplemented answer; W5-23 (write path), W5-25 (join and the lists) and W5-28 (moderation) replace the methods one
// by one with the real service.
type Server struct {
	communitiesv1connect.UnimplementedCommunityServiceHandler
	flags FlagChecker
}

// NewServer builds the skeleton handler. Use with communitiesv1connect.NewCommunityServiceHandler.
func NewServer(fc FlagChecker) *Server { return &Server{flags: fc} }

var _ communitiesv1connect.CommunityServiceHandler = (*Server)(nil)

// gate runs the flag check for the authenticated caller. A request that reaches a handler without a uid is a wiring bug (the
// authn interceptor runs first); it is treated as unauthenticated.
func (s *Server) gate(ctx context.Context) error {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return connect.NewError(connect.CodeUnauthenticated, nil)
	}
	return Guard(ctx, s.flags, uid)
}

// CreateCommunity is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) CreateCommunity(ctx context.Context, req *connect.Request[communitiesv1.CreateCommunityRequest]) (*connect.Response[communitiesv1.CreateCommunityResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.CreateCommunity(ctx, req)
}

// UpdateCommunity is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) UpdateCommunity(ctx context.Context, req *connect.Request[communitiesv1.UpdateCommunityRequest]) (*connect.Response[communitiesv1.UpdateCommunityResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.UpdateCommunity(ctx, req)
}

// GetCommunity is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) GetCommunity(ctx context.Context, req *connect.Request[communitiesv1.GetCommunityRequest]) (*connect.Response[communitiesv1.GetCommunityResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.GetCommunity(ctx, req)
}

// ListCommunities is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) ListCommunities(ctx context.Context, req *connect.Request[communitiesv1.ListCommunitiesRequest]) (*connect.Response[communitiesv1.ListCommunitiesResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.ListCommunities(ctx, req)
}

// ListMyCommunities is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) ListMyCommunities(ctx context.Context, req *connect.Request[communitiesv1.ListMyCommunitiesRequest]) (*connect.Response[communitiesv1.ListMyCommunitiesResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.ListMyCommunities(ctx, req)
}

// JoinCommunity is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) JoinCommunity(ctx context.Context, req *connect.Request[communitiesv1.JoinCommunityRequest]) (*connect.Response[communitiesv1.JoinCommunityResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.JoinCommunity(ctx, req)
}

// LeaveCommunity is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) LeaveCommunity(ctx context.Context, req *connect.Request[communitiesv1.LeaveCommunityRequest]) (*connect.Response[communitiesv1.LeaveCommunityResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.LeaveCommunity(ctx, req)
}

// ListCommunityMembers is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) ListCommunityMembers(ctx context.Context, req *connect.Request[communitiesv1.ListCommunityMembersRequest]) (*connect.Response[communitiesv1.ListCommunityMembersResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.ListCommunityMembers(ctx, req)
}

// HideCommunityPost is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) HideCommunityPost(ctx context.Context, req *connect.Request[communitiesv1.HideCommunityPostRequest]) (*connect.Response[communitiesv1.HideCommunityPostResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.HideCommunityPost(ctx, req)
}

// RestoreCommunityPost is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) RestoreCommunityPost(ctx context.Context, req *connect.Request[communitiesv1.RestoreCommunityPostRequest]) (*connect.Response[communitiesv1.RestoreCommunityPostResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.RestoreCommunityPost(ctx, req)
}

// SetMemberRole is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) SetMemberRole(ctx context.Context, req *connect.Request[communitiesv1.SetMemberRoleRequest]) (*connect.Response[communitiesv1.SetMemberRoleResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.SetMemberRole(ctx, req)
}

// ListModerationLog is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) ListModerationLog(ctx context.Context, req *connect.Request[communitiesv1.ListModerationLogRequest]) (*connect.Response[communitiesv1.ListModerationLogResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.ListModerationLog(ctx, req)
}
