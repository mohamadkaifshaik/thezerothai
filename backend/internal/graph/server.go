// server.go is the thin Connect handler: extract the caller's uid, do proto<->domain conversion, call
// Service, convert the result back. No business logic and no Firestore here (CLAUDE.md: handlers stay
// thin; errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping).
package graph

import (
	"context"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// Server adapts Service to graphv1connect.GraphServiceHandler.
type Server struct {
	svc Service
}

// NewServer builds the Connect handler. Use with graphv1connect.NewGraphServiceHandler.
func NewServer(svc Service) *Server {
	return &Server{svc: svc}
}

var _ graphv1connect.GraphServiceHandler = (*Server)(nil)

func callerUID(ctx context.Context) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		// Should be unreachable: authn.IDTokenInterceptor runs before every handler.
		return "", apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	return uid, nil
}

func toProtoFollowState(s FollowState) graphv1.FollowState {
	switch s {
	case FollowStateNone:
		return graphv1.FollowState_FOLLOW_STATE_NONE
	case FollowStateFollowing:
		return graphv1.FollowState_FOLLOW_STATE_FOLLOWING
	case FollowStateRequested:
		return graphv1.FollowState_FOLLOW_STATE_REQUESTED
	default:
		return graphv1.FollowState_FOLLOW_STATE_UNSPECIFIED
	}
}

func toProtoRelationship(r Relationship) *graphv1.Relationship {
	return &graphv1.Relationship{
		UserId:      r.UserID,
		FollowState: toProtoFollowState(r.FollowState),
		Blocking:    r.Blocking,
		Muting:      r.Muting,
	}
}

func toProtoRelationships(rs []Relationship) []*graphv1.Relationship {
	out := make([]*graphv1.Relationship, len(rs))
	for i, r := range rs {
		out[i] = toProtoRelationship(r)
	}
	return out
}

func toProtoAuthorSnapshot(p identity.Profile) *commonv1.AuthorSnapshot {
	return &commonv1.AuthorSnapshot{
		UserId:      p.UserID,
		Handle:      p.Handle,
		DisplayName: p.DisplayName,
		// AuthorSnapshot.avatar_url is documented as the 96px thumbnail (common.proto).
		AvatarUrl: p.AvatarThumbURL,
		Verified:  p.Verified,
	}
}

func toProtoListItem(item ListItem) *graphv1.UserListItem {
	out := &graphv1.UserListItem{
		User:         toProtoAuthorSnapshot(item.User),
		Relationship: toProtoRelationship(item.Relationship),
	}
	if !item.Since.IsZero() {
		out.Since = timestamppb.New(item.Since)
	}
	return out
}

func toProtoListItems(items []ListItem) []*graphv1.UserListItem {
	out := make([]*graphv1.UserListItem, len(items))
	for i, it := range items {
		out[i] = toProtoListItem(it)
	}
	return out
}

func (s *Server) Follow(ctx context.Context, req *connect.Request[graphv1.FollowRequest]) (*connect.Response[graphv1.FollowResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Follow(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.FollowResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) Unfollow(ctx context.Context, req *connect.Request[graphv1.UnfollowRequest]) (*connect.Response[graphv1.UnfollowResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Unfollow(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.UnfollowResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) Block(ctx context.Context, req *connect.Request[graphv1.BlockRequest]) (*connect.Response[graphv1.BlockResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Block(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.BlockResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) Unblock(ctx context.Context, req *connect.Request[graphv1.UnblockRequest]) (*connect.Response[graphv1.UnblockResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Unblock(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.UnblockResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) Mute(ctx context.Context, req *connect.Request[graphv1.MuteRequest]) (*connect.Response[graphv1.MuteResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Mute(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.MuteResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) Unmute(ctx context.Context, req *connect.Request[graphv1.UnmuteRequest]) (*connect.Response[graphv1.UnmuteResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rel, err := s.svc.Unmute(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetUserId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.UnmuteResponse{Relationship: toProtoRelationship(rel)}), nil
}

func (s *Server) GetRelationships(ctx context.Context, req *connect.Request[graphv1.GetRelationshipsRequest]) (*connect.Response[graphv1.GetRelationshipsResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	rels, err := s.svc.GetRelationships(ctx, uid, req.Msg.GetUserIds())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.GetRelationshipsResponse{Relationships: toProtoRelationships(rels)}), nil
}

func (s *Server) ListFollowers(ctx context.Context, req *connect.Request[graphv1.ListFollowersRequest]) (*connect.Response[graphv1.ListFollowersResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	page, err := s.svc.ListFollowers(ctx, uid, req.Msg.GetUserId(), req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.ListFollowersResponse{Users: toProtoListItems(page.Items), NextPageToken: page.NextPageToken}), nil
}

func (s *Server) ListFollowing(ctx context.Context, req *connect.Request[graphv1.ListFollowingRequest]) (*connect.Response[graphv1.ListFollowingResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	page, err := s.svc.ListFollowing(ctx, uid, req.Msg.GetUserId(), req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.ListFollowingResponse{Users: toProtoListItems(page.Items), NextPageToken: page.NextPageToken}), nil
}

func (s *Server) ListBlockedUsers(ctx context.Context, req *connect.Request[graphv1.ListBlockedUsersRequest]) (*connect.Response[graphv1.ListBlockedUsersResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	page, err := s.svc.ListBlockedUsers(ctx, uid, req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.ListBlockedUsersResponse{Users: toProtoListItems(page.Items), NextPageToken: page.NextPageToken}), nil
}

func (s *Server) ListMutedUsers(ctx context.Context, req *connect.Request[graphv1.ListMutedUsersRequest]) (*connect.Response[graphv1.ListMutedUsersResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	page, err := s.svc.ListMutedUsers(ctx, uid, req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&graphv1.ListMutedUsersResponse{Users: toProtoListItems(page.Items), NextPageToken: page.NextPageToken}), nil
}

// ListFollowRequests and RespondToFollowRequest stay Unimplemented-shaped-as-FEATURE_DISABLED regardless of
// the flag (ADR-0008 D1): private accounts and follow requests are deferred. 0 reads.
func (s *Server) ListFollowRequests(ctx context.Context, _ *connect.Request[graphv1.ListFollowRequestsRequest]) (*connect.Response[graphv1.ListFollowRequestsResponse], error) {
	if _, err := callerUID(ctx); err != nil {
		return nil, err
	}
	return nil, apierr.ToConnect(featureDisabledErr())
}

func (s *Server) RespondToFollowRequest(ctx context.Context, _ *connect.Request[graphv1.RespondToFollowRequestRequest]) (*connect.Response[graphv1.RespondToFollowRequestResponse], error) {
	if _, err := callerUID(ctx); err != nil {
		return nil, err
	}
	return nil, apierr.ToConnect(featureDisabledErr())
}
