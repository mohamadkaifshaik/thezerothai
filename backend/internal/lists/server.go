package lists

import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one list call (<= 10 s, go-service skill); the transaction itself has 5 s.
const rpcDeadline = 8 * time.Second

// Server is the ListService handler. It mounts every route so the interceptor chain (App Check, ID token, account status,
// rate limits, read budget, degraded mode) covers them, and runs the flag gate (FEATURE_LISTS, ADR-0030 D9) before anything
// else: a caller outside the flag gets FAILED_PRECONDITION FEATURE_DISABLED feature=lists with 0 Firestore reads. Past the
// gate CreateList, UpdateList, DeleteList (W5-4) and AddListMember, RemoveListMember (W5-6) call the Service; the other three are
// still the generated Unimplemented answer until W5-7 (reads) replaces them.
type Server struct {
	listsv1connect.UnimplementedListServiceHandler
	flags FlagChecker
	svc   Service
}

// NewServer builds the handler. svc may be nil (a wiring without the write path): the gated write RPCs then answer
// Unimplemented. Use with listsv1connect.NewListServiceHandler.
func NewServer(fc FlagChecker, svc Service) *Server { return &Server{flags: fc, svc: svc} }

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

// entry is the shared front of the write handlers: the flag gate (0 reads), the wiring check and the RPC deadline.
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

// CreateList is gated by FEATURE_LISTS and creates a private list unless is_private is sent as false (F3).
func (s *Server) CreateList(ctx context.Context, req *connect.Request[listsv1.CreateListRequest]) (*connect.Response[listsv1.CreateListResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "CreateList")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	v, err := s.svc.CreateList(ctx, uid, CreateInput{Key: m.GetIdempotencyKey(), Name: m.GetName(), Description: m.GetDescription(), IsPrivate: m.IsPrivate})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.CreateListResponse{List: toListInfo(v)}), nil
}

// UpdateList is gated by FEATURE_LISTS; only the fields that are set change.
func (s *Server) UpdateList(ctx context.Context, req *connect.Request[listsv1.UpdateListRequest]) (*connect.Response[listsv1.UpdateListResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "UpdateList")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	v, err := s.svc.UpdateList(ctx, uid, UpdateInput{Key: m.GetIdempotencyKey(), ListID: m.GetListId(), Name: m.Name, Description: m.Description, IsPrivate: m.IsPrivate})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.UpdateListResponse{List: toListInfo(v)}), nil
}

// DeleteList is gated by FEATURE_LISTS; a list that is not the caller's, or is gone, is success with no effect.
func (s *Server) DeleteList(ctx context.Context, req *connect.Request[listsv1.DeleteListRequest]) (*connect.Response[listsv1.DeleteListResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "DeleteList")
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := s.svc.DeleteList(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetListId()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.DeleteListResponse{}), nil
}

// toListInfo renders a View. The owner row is the live profile (the AuthorSnapshot thumbnail and lock badge, as graph's rows).
func toListInfo(v View) *listsv1.ListInfo {
	p := v.Owner
	return &listsv1.ListInfo{
		ListId: v.Header.ID,
		Owner: &commonv1.AuthorSnapshot{
			UserId: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarUrl: p.AvatarThumbURL,
			Verified: p.Verified, IsPrivate: p.IsPrivate,
		},
		Name: v.Header.Name, Description: v.Header.Description, IsPrivate: v.Header.IsPrivate,
		MemberCount:    int32(v.Header.MemberCount), //nolint:gosec // bounded by LIST_MAX_MEMBERS (150)
		PinnedByViewer: v.PinnedByViewer,
	}
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

// memberWrite is the shared body of the two member handlers: gate, deadline, the service call, the ListInfo of the answer.
func (s *Server) memberWrite(ctx context.Context, rpc string, call func(ctx context.Context, uid string) (View, error)) (*listsv1.ListInfo, error) {
	ctx, cancel, uid, err := s.entry(ctx, rpc)
	if err != nil {
		return nil, err
	}
	defer cancel()
	v, err := call(ctx, uid)
	if err != nil {
		return nil, err
	}
	return toListInfo(v), nil
}

// AddListMember is gated by FEATURE_LISTS; owner only (W5-6).
//
//nolint:dupl // mirrors RemoveListMember over distinct generated proto types
func (s *Server) AddListMember(ctx context.Context, req *connect.Request[listsv1.AddListMemberRequest]) (*connect.Response[listsv1.AddListMemberResponse], error) {
	m := req.Msg
	info, err := s.memberWrite(ctx, "AddListMember", func(ctx context.Context, uid string) (View, error) {
		return s.svc.AddMember(ctx, uid, m.GetIdempotencyKey(), m.GetListId(), m.GetUserId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.AddListMemberResponse{List: info}), nil
}

// RemoveListMember is gated by FEATURE_LISTS; owner only (W5-6).
//
//nolint:dupl // mirrors AddListMember over distinct generated proto types
func (s *Server) RemoveListMember(ctx context.Context, req *connect.Request[listsv1.RemoveListMemberRequest]) (*connect.Response[listsv1.RemoveListMemberResponse], error) {
	m := req.Msg
	info, err := s.memberWrite(ctx, "RemoveListMember", func(ctx context.Context, uid string) (View, error) {
		return s.svc.RemoveMember(ctx, uid, m.GetIdempotencyKey(), m.GetListId(), m.GetUserId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.RemoveListMemberResponse{List: info}), nil
}

// ListListMembers is gated by FEATURE_LISTS; the read is W5-7.
func (s *Server) ListListMembers(ctx context.Context, req *connect.Request[listsv1.ListListMembersRequest]) (*connect.Response[listsv1.ListListMembersResponse], error) {
	if err := s.gate(ctx); err != nil {
		return nil, err
	}
	return s.UnimplementedListServiceHandler.ListListMembers(ctx, req)
}
