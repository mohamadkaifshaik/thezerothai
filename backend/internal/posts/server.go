// server.go is the thin Connect handler for PostService: extract the caller's uid, check the FEATURE_POSTS
// flag, call Service, map the result. No business logic and no Firestore here (CLAUDE.md: handlers stay thin;
// errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping).
//
// T5 registers the service with every RPC behind the flag guard and otherwise Unimplemented; T8 (CreatePost)
// and T9 (DeletePost, GetPost) replace the bodies, GetThread stays Unimplemented until the replies slice (P3).
package posts

import (
	"context"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagChecker is the minimal seam posts and timeline need from pkg/platform/flags.Registry (ADR-0002: depend
// on interfaces, not the concrete platform type). *flags.Registry satisfies it.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// GuardFeature is the ADR-0010 D1 flag check shared by PostService and TimelineService: it runs before any
// Firestore access and returns FAILED_PRECONDITION + FEATURE_DISABLED (0 reads from this code) when the posts
// flag is off for the caller. A rejected call logs feature_disabled=true and outcome=rejected:feature_disabled.
// A missing caller identity is UNAUTHENTICATED (unreachable: authn.IDTokenInterceptor runs first).
func GuardFeature(ctx context.Context, fc FlagChecker) error {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	if fc == nil || !fc.Enabled(uid, FlagName) {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
		return flags.DisabledError()
	}
	return nil
}

// Server adapts Service to postsv1connect.PostServiceHandler.
type Server struct {
	postsv1connect.UnimplementedPostServiceHandler
	svc   Service
	flags FlagChecker
}

// NewServer builds the Connect handler. Use with postsv1connect.NewPostServiceHandler.
func NewServer(svc Service, fc FlagChecker) *Server {
	return &Server{svc: svc, flags: fc}
}

var _ postsv1connect.PostServiceHandler = (*Server)(nil)

// CreatePost is behind the flag and Unimplemented until T8.
func (s *Server) CreatePost(ctx context.Context, req *connect.Request[postsv1.CreatePostRequest]) (*connect.Response[postsv1.CreatePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	return s.UnimplementedPostServiceHandler.CreatePost(ctx, req)
}

// DeletePost is behind the flag and Unimplemented until T9.
func (s *Server) DeletePost(ctx context.Context, req *connect.Request[postsv1.DeletePostRequest]) (*connect.Response[postsv1.DeletePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	return s.UnimplementedPostServiceHandler.DeletePost(ctx, req)
}

// GetPost is behind the flag and Unimplemented until T9.
func (s *Server) GetPost(ctx context.Context, req *connect.Request[postsv1.GetPostRequest]) (*connect.Response[postsv1.GetPostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	return s.UnimplementedPostServiceHandler.GetPost(ctx, req)
}

// GetThread is behind the flag and Unimplemented until the replies slice (P3).
func (s *Server) GetThread(ctx context.Context, req *connect.Request[postsv1.GetThreadRequest]) (*connect.Response[postsv1.GetThreadResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	return s.UnimplementedPostServiceHandler.GetThread(ctx, req)
}
