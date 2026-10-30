package lists

import (
	"context"

	"connectrpc.com/connect"

	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// Server is the W5-3 skeleton of the ListService handler. It mounts every route so the interceptor chain (App Check, ID token,
// account status, rate limits, read budget) covers them from the first revision that links the generated code, and runs the
// flag gate (FEATURE_LISTS, ADR-0030 D9) before anything else: a caller outside the flag gets FAILED_PRECONDITION
// FEATURE_DISABLED feature=lists with 0 Firestore reads. Past the gate each method is still the generated Unimplemented
// answer; W5-4 (write path), W5-6 (members) and W5-7 (reads) replace the methods one by one with the real service.
type Server struct {
	listsv1connect.UnimplementedListServiceHandler
	flags FlagChecker
}

// NewServer builds the skeleton handler. Use with listsv1connect.NewListServiceHandler.
func NewServer(fc FlagChecker) *Server { return &Server{flags: fc} }

var _ listsv1connect.ListServiceHandler = (*Server)(nil)

// gate runs the flag check for the authenticated caller. A request that reaches a handler without a uid is a wiring bug (the
// authn interceptor runs first); it is treated as unauthenticated.
func (s *Server) gate(ctx context.Context) error {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return connect.NewError(connect.CodeUnauthenticated, nil)
	}
	return Guard(ctx, s.flags, uid)
}

// CreateList is gated by FEATURE_LISTS; the write path is W5-4.
func (s *Server) CreateList(ctx context.Context, req *connect.Request[listsv1.CreateListRequest]) (*connect.Response[listsv1.CreateListResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.CreateList(ctx, req)
}

// UpdateList is gated by FEATURE_LISTS; the write path is W5-4.
func (s *Server) UpdateList(ctx context.Context, req *connect.Request[listsv1.UpdateListRequest]) (*connect.Response[listsv1.UpdateListResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.UpdateList(ctx, req)
}

// DeleteList is gated by FEATURE_LISTS; the write path is W5-4.
func (s *Server) DeleteList(ctx context.Context, req *connect.Request[listsv1.DeleteListRequest]) (*connect.Response[listsv1.DeleteListResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.DeleteList(ctx, req)
}

// GetList is gated by FEATURE_LISTS; the read is W5-7.
func (s *Server) GetList(ctx context.Context, req *connect.Request[listsv1.GetListRequest]) (*connect.Response[listsv1.GetListResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.GetList(ctx, req)
}

// ListUserLists is gated by FEATURE_LISTS; the read is W5-7.
func (s *Server) ListUserLists(ctx context.Context, req *connect.Request[listsv1.ListUserListsRequest]) (*connect.Response[listsv1.ListUserListsResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.ListUserLists(ctx, req)
}

// AddListMember is gated by FEATURE_LISTS; the member write is W5-6.
func (s *Server) AddListMember(ctx context.Context, req *connect.Request[listsv1.AddListMemberRequest]) (*connect.Response[listsv1.AddListMemberResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.AddListMember(ctx, req)
}

// RemoveListMember is gated by FEATURE_LISTS; the member write is W5-6.
func (s *Server) RemoveListMember(ctx context.Context, req *connect.Request[listsv1.RemoveListMemberRequest]) (*connect.Response[listsv1.RemoveListMemberResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.RemoveListMember(ctx, req)
}

// ListListMembers is gated by FEATURE_LISTS; the read is W5-7.
func (s *Server) ListListMembers(ctx context.Context, req *connect.Request[listsv1.ListListMembersRequest]) (*connect.Response[listsv1.ListListMembersResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.ListListMembers(ctx, req)
}
