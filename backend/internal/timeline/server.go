// Package timeline owns the home and profile feeds. It is
// pull-on-read and stores nothing: it reads posts through posts.Reader, the caller's social context through
// graph.Reader and profile status through identity.Directory, and never queries `posts`, `graph` or `users`
// directly (handoff; imports_test enforces the allowed packages and identifiers).
//
// merge.go is the pure exact-prefix merge, tokens.go the caller/feed-bound token codec, watermark.go the D13
// settle watermark; service.go holds the Home and profile RPC bodies and service_list.go the list feed (reads lists only through lists.Reader).
package timeline

import (
	"context"
	"time"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline is the per-RPC deadline (decision 9).
const rpcDeadline = 10 * time.Second

// Deps is what the timeline server needs: the flag, the read seams it is allowed to use, and the token
// configuration (cursor key, TIMELINE_TOKEN_TTL, TIMELINE_SETTLE_WINDOW).
type Deps struct {
	Flags     posts.FlagChecker
	Posts     posts.Reader
	Graph     graph.Reader
	Directory identity.Directory
	// Viewer supplies the caller's liked/reposted flags (engagement). Nil, or FEATURE_ENGAGEMENT off
	// for the caller, means every flag is false with no userLikes read.
	Viewer posts.ViewerFlags
	// Removals is the moderation removal log, consulted only by since_token refreshes. Nil disables
	// removed_ids (no reads, no reset): tests and processes that do not wire the log.
	Removals posts.Removals
	// Lists is the only way timeline reads a list (GetListTimeline). Nil leaves GetListTimeline unimplemented behind
	// its flag gate: tests and processes that do not wire lists.
	Lists lists.Reader

	// CursorKey seals tokens (config.CursorHMACKey).
	CursorKey []byte
	// TokenTTL is config.TimelineTokenTTL (default 720 h).
	TokenTTL time.Duration
	// SettleWindow is config.TimelineSettleWindow (default 15 s).
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
	// aud is the visibility predicate (posts.Audience); WithProtectedAuthors gives it the protected set.
	aud *posts.Audience
	// community wires GetCommunityTimeline (service_community.go, set by SetCommunities); nil = Unimplemented.
	community *communityFeedState
	// homeTabs wires SetHomeTabs (home_tabs.go); nil = Unimplemented.
	homeTabs *HomeTabsDeps
}

// NewServer builds the Connect handler. Use with timelinev1connect.NewTimelineServiceHandler.
func NewServer(d Deps, opts ...Option) *Server {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	s := &Server{deps: d, now: now, settle: d.SettleWindow, codec: codec{key: d.CursorKey, ttl: d.TokenTTL, now: now}, aud: posts.NewSnapshotAudience(nil)}
	for _, o := range opts {
		o(s)
	}
	return s
}

var _ timelinev1connect.TimelineServiceHandler = (*Server)(nil)

// GetHomeTimeline returns the caller's chronological home feed (root posts of followees plus the caller).
//
// A since_token refresh also reads the moderation removal log (removed_ids): a warm
// instance cache hit reads nothing, otherwise it refreshes the log once per instance per CACHE_TTL (a full incremental
// page reloads the newest 50). Cold, older and gap calls read nothing from it.
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

// GetUserTimeline returns one user's posts: the Posts, Replies, Media or Reposts tab. `tab`
// UNSPECIFIED (the default and every pre-W3 client) reads include_replies exactly as before; any other tab wins and
// include_replies is ignored with no error. A page_token, gap_page_token or since_token is bound to the caller, the
// target and the EFFECTIVE tab (posts, replies, media or reposts): a token used on another tab is VALIDATION
// field=page_token|since_token, and an unknown `tab` number is VALIDATION field=tab. Media and Reposts
// need FEATURE_PROFILE_TABS on for the caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata feature=profile_tabs);
// Posts and Replies are ungated. The request log carries tab=<effective tab>. The Media and Reposts tabs
// query the hasMedia and kind composite indexes: those must be READY and the backfill run before the flag leaves off.
//
// A since_token refresh also reads the removal log (removed_ids), the same way as GetHomeTimeline.
//
// Protected accounts: for a caller who is neither the target nor a follower of a protected target, every tab
// answers author_protected = true with no posts and no tokens without reading any page, decided before the author-recent cache. In every tab a REPOST of a protected author the caller does
// not follow is dropped and a QUOTE of one gets embed_viewer_state PROTECTED (stripped). A caller's own profile page
// holding a copy of another user's post reads the caller's graph once (cached 60 s). The set is a detached
// instance cache; an unknown set is UNAVAILABLE.
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
