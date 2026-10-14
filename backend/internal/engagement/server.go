// server.go is the thin Connect handler for EngagementService: caller uid, the FEATURE_POSTS and
// FEATURE_ENGAGEMENT flags, Service, response mapping. No business logic and no Firestore here (CLAUDE.md).
package engagement

import (
	"context"
	"time"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// rpcDeadline bounds one engagement call (<= 10 s, go-service skill); the transaction itself has 5 s.
const rpcDeadline = 8 * time.Second

// Server adapts Service to engagementv1connect.EngagementServiceHandler.
type Server struct {
	engagementv1connect.UnimplementedEngagementServiceHandler
	svc   Service
	flags posts.FlagChecker
}

// NewServer builds the Connect handler. Use with engagementv1connect.NewEngagementServiceHandler.
func NewServer(svc Service, fc posts.FlagChecker) *Server { return &Server{svc: svc, flags: fc} }

var _ engagementv1connect.EngagementServiceHandler = (*Server)(nil)

// guard runs FEATURE_POSTS (the posts guard) and FEATURE_ENGAGEMENT, in that order, with 0 reads from this code,
// and returns the caller's uid with a deadline-bound context.
func (s *Server) guard(ctx context.Context) (context.Context, context.CancelFunc, string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return nil, nil, "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if err := flags.Guard(ctx, s.flags.Enabled, uid, FlagName); err != nil {
		return nil, nil, "", err
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	return ctx, cancel, uid, nil
}

func toProto(r Result) *engagementv1.PostEngagement {
	return &engagementv1.PostEngagement{
		PostId: r.PostID, LikeCount: r.LikeCount, RepostCount: r.RepostCount,
		LikedByViewer: r.LikedByViewer, RepostedByViewer: r.RepostedByViewer,
	}
}

// LikePost implements the RPC; the rules are Service.Like.
func (s *Server) LikePost(ctx context.Context, req *connect.Request[engagementv1.LikePostRequest]) (*connect.Response[engagementv1.LikePostResponse], error) {
	ctx, cancel, uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	r, err := s.svc.Like(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.LikePostResponse{Engagement: toProto(r)}), nil
}

// UnlikePost implements the RPC; the rules are Service.Unlike.
func (s *Server) UnlikePost(ctx context.Context, req *connect.Request[engagementv1.UnlikePostRequest]) (*connect.Response[engagementv1.UnlikePostResponse], error) {
	ctx, cancel, uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	r, err := s.svc.Unlike(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.UnlikePostResponse{Engagement: toProto(r)}), nil
}

// RepostPost implements the RPC; the rules are Service.Repost.
func (s *Server) RepostPost(ctx context.Context, req *connect.Request[engagementv1.RepostPostRequest]) (*connect.Response[engagementv1.RepostPostResponse], error) {
	ctx, cancel, uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	r, err := s.svc.Repost(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.RepostPostResponse{Engagement: toProto(r), RepostPostId: r.RepostPostID}), nil
}

// UndoRepost implements the RPC; the rules are Service.UndoRepost.
func (s *Server) UndoRepost(ctx context.Context, req *connect.Request[engagementv1.UndoRepostRequest]) (*connect.Response[engagementv1.UndoRepostResponse], error) {
	ctx, cancel, uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	r, err := s.svc.UndoRepost(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.UndoRepostResponse{Engagement: toProto(r)}), nil
}
