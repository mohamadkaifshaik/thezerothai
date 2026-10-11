// server.go is the thin Connect handler for PostService: extract the caller's uid, check the FEATURE_POSTS
// flag, call Service, map the result. No business logic and no Firestore here (CLAUDE.md: handlers stay thin;
// errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping).
//
// T5 registers the service with every RPC behind the flag guard and otherwise Unimplemented; T8 (CreatePost)
// and T9 (DeletePost, GetPost) replace the bodies, GetThread stays Unimplemented until the replies slice (P3).
package posts

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
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
	if fc == nil {
		return flags.Guard(ctx, nil, uid, FlagName)
	}
	return flags.Guard(ctx, fc.Enabled, uid, FlagName)
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

// createDeadline bounds one CreatePost call (<= 10 s, go-service skill); the transaction itself has 5 s.
const createDeadline = 8 * time.Second

// CreatePost is behind the flag; everything else (validation order, mentions, the transaction) is
// Service.Create (T8).
func (s *Server) CreatePost(ctx context.Context, req *connect.Request[postsv1.CreatePostRequest]) (*connect.Response[postsv1.CreatePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	ctx, cancel := context.WithTimeout(ctx, createDeadline)
	defer cancel()
	m := req.Msg
	post, err := s.svc.Create(ctx, uid, CreateInput{
		IdempotencyKey: m.GetIdempotencyKey(),
		Text:           m.GetText(),
		MediaIDs:       m.GetMediaIds(),
		MediaAltTexts:  m.GetMediaAltTexts(),
		ReplyToPostID:  m.GetReplyToPostId(),
		QuoteOfPostID:  m.GetQuoteOfPostId(),
		MediaEnabled:   s.mediaEnabled(uid),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.CreatePostResponse{Post: &postsv1.PostView{Post: ToProto(post)}}), nil
}

// mediaFlagName is the wire name of FEATURE_MEDIA (media.FlagName; posts does not import media).
const mediaFlagName = "media"

// mediaEnabled reports FEATURE_MEDIA for uid; a nil checker means off (fail closed).
func (s *Server) mediaEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, mediaFlagName)
}

// readDeadline bounds DeletePost and GetPost (<= 10 s, go-service skill).
const readDeadline = 5 * time.Second

// DeletePost is behind the flag; the rules (ownership, no-op cases, the batch) are Service.Delete (T9).
func (s *Server) DeletePost(ctx context.Context, req *connect.Request[postsv1.DeletePostRequest]) (*connect.Response[postsv1.DeletePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	if err := s.svc.Delete(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.DeletePostResponse{}), nil
}

// GetPost is behind the flag; the visibility rules are Service.GetForViewer (T9). Viewer flags stay false until
// engagement ships (ADR-0010 D3).
func (s *Server) GetPost(ctx context.Context, req *connect.Request[postsv1.GetPostRequest]) (*connect.Response[postsv1.GetPostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx)
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	post, err := s.svc.GetForViewer(ctx, uid, req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.GetPostResponse{Post: &postsv1.PostView{Post: ToProto(post)}}), nil
}

// GetThread is behind the flag and Unimplemented until the replies slice (P3).
func (s *Server) GetThread(ctx context.Context, req *connect.Request[postsv1.GetThreadRequest]) (*connect.Response[postsv1.GetThreadResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	return s.UnimplementedPostServiceHandler.GetThread(ctx, req)
}
