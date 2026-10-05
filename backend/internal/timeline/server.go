// Package timeline owns the home and profile feeds (ADR-0004 algorithm, ADR-0010 slice decisions). It is
// pull-on-read and stores nothing: it reads posts through posts.Reader, the caller's social context through
// graph.Reader and profile status through identity.Directory, and never queries `posts`, `graph` or `users`
// directly (ADR-0004 handoff; imports_test enforces the allowed packages and identifiers).
//
// merge.go is the pure exact-prefix merge, tokens.go the caller/feed-bound token codec, watermark.go the D13
// settle watermark; service.go holds the two RPC bodies.
package timeline

import (
	"context"
	"time"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline is the per-RPC deadline (ADR-0004 decision 9).
const rpcDeadline = 10 * time.Second

// Deps is what the timeline server needs: the flag, the read seams it is allowed to use, and the token
// configuration (cursor key, TIMELINE_TOKEN_TTL, TIMELINE_SETTLE_WINDOW).
type Deps struct {
	Flags     posts.FlagChecker
	Posts     posts.Reader
	Graph     graph.Reader
	Directory identity.Directory

	// CursorKey seals tokens (config.CursorHMACKey).
	CursorKey []byte
	// TokenTTL is config.TimelineTokenTTL (default 720 h).
	TokenTTL time.Duration
	// SettleWindow is config.TimelineSettleWindow (default 15 s, ADR-0010 D13).
	SettleWindow time.Duration
	// Now is the clock; nil means time.Now (tests inject a fake).
	Now func() time.Time
}

// Server adapts the timeline logic to timelinev1connect.TimelineServiceHandler.
type Server struct {
	timelinev1connect.UnimplementedTimelineServiceHandler
	deps   Deps
	codec  codec
	settle time.Duration
	now    func() time.Time
}

// NewServer builds the Connect handler. Use with timelinev1connect.NewTimelineServiceHandler.
func NewServer(d Deps) *Server {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &Server{deps: d, now: now, settle: d.SettleWindow, codec: codec{key: d.CursorKey, ttl: d.TokenTTL, now: now}}
}

var _ timelinev1connect.TimelineServiceHandler = (*Server)(nil)

// GetHomeTimeline returns the caller's chronological home feed (root posts of followees plus the caller).
//
// Budget (ADR-0004, ADR-0010 D17), reads, counting the account-status interceptor's caller `users` read:
// ceiling 2 + C + 2*page where C = ceil((F+1)/30), 269 at F = 5,000 and page 50 (2 = interceptor + caller
// graph; +1 userLikes once engagement ships). Authors covered by a fresh author-recent entry are removed
// before chunking, so the queries are ceil(uncovered/30). Planning: refresh 4 + new posts, older page and cold
// open 30 (F = 60, page 20). Writes 0.
//
//nolint:dupl // mirrors GetUserTimeline over distinct generated proto types
func (s *Server) GetHomeTimeline(ctx context.Context, req *connect.Request[timelinev1.GetHomeTimelineRequest]) (*connect.Response[timelinev1.GetHomeTimelineResponse], error) {
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, 0, "unauthenticated")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := s.home(ctx, uid, req.Msg)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(resp), nil
}

// GetUserTimeline returns one user's posts (Posts tab or Replies tab).
//
// Budget (ADR-0010 D16/D17), reads: 3 + max(page, 20) cold (interceptor + target users + caller graph +
// Limit(max(page, 20)): a cold Posts tab fills the 20-post author-recent entry, so page < 20 still reads 20;
// 53 at page 50; +1 when the caller's blockedBy overflowed), 0 warm for a Posts-tab first page (<= 20) or an
// empty refresh served by a fresh author-recent entry, 4 for a cold refresh with 0 new posts. Planning 11.
// Writes 0.
//
//nolint:dupl // mirrors GetHomeTimeline over distinct generated proto types
func (s *Server) GetUserTimeline(ctx context.Context, req *connect.Request[timelinev1.GetUserTimelineRequest]) (*connect.Response[timelinev1.GetUserTimelineResponse], error) {
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, 0, "unauthenticated")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := s.user(ctx, uid, req.Msg)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(resp), nil
}
