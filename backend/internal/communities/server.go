package communities

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one community call (<= 10 s, go-service skill); the transaction itself has 5 s.
const rpcDeadline = 8 * time.Second

// Server is the CommunityService handler. It mounts every route so the interceptor chain (App Check, ID token, account status, rate
// limits, read budget, degraded mode) covers them, and runs the flag gate (FEATURE_COMMUNITIES, ADR-0031 D10) before anything else: a
// caller outside the flag gets FAILED_PRECONDITION FEATURE_DISABLED feature=communities with 0 Firestore reads. Past the gate
// CreateCommunity, UpdateCommunity and GetCommunity (W5-23) and JoinCommunity, LeaveCommunity and ListMyCommunities (W5-25) call the
// Service; the other six methods are still the generated Unimplemented answer until W5-25b (the directory and member list) and W5-28
// (moderation) replace them one by one. A Server built without a Service answers Unimplemented for the six as well.
type Server struct {
	communitiesv1connect.UnimplementedCommunityServiceHandler
	flags FlagChecker
	svc   Service
}

// NewServer builds the handler. svc may be nil (a wiring without the write path): the gated RPCs then answer Unimplemented. Use with
// communitiesv1connect.NewCommunityServiceHandler.
func NewServer(fc FlagChecker, svc Service) *Server { return &Server{flags: fc, svc: svc} }

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

// entry is the shared front of the implemented handlers: the flag gate (0 reads), the wiring check and the RPC deadline.
func (s *Server) entry(ctx context.Context, rpc string) (context.Context, context.CancelFunc, string, error) {
	if err := s.gate(ctx); err != nil {
		return nil, nil, "", err
	}
	if s.svc == nil {
		return nil, nil, "", connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not wired", rpc))
	}
	uid, _ := authn.UIDFromContext(ctx) // gate proved it is set
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	return ctx, cancel, uid, nil
}

// ListCommunities is gated by FEATURE_COMMUNITIES; the real method arrives with its W5 ticket (see Server).
func (s *Server) ListCommunities(ctx context.Context, req *connect.Request[communitiesv1.ListCommunitiesRequest]) (*connect.Response[communitiesv1.ListCommunitiesResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedCommunityServiceHandler.ListCommunities(ctx, req)
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
