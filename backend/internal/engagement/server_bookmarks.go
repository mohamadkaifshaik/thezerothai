// server_bookmarks.go holds the Connect handlers of bookmarks (ADR-0023): AddBookmark, RemoveBookmark and
// ListBookmarks. The flag gate (W2-2) runs first on every RPC; Add and Remove then call the Bookmarks service (W2-3).
// ListBookmarks answers Unimplemented naming its ticket (W2-4) until it lands, so that path reads and writes nothing.
package engagement

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// bookmarkCaller names who the bookmarks flag must be on for.
type bookmarkCaller int

const (
	// callerEnabled needs the flag on for this caller (AddBookmark, which creates new state).
	callerEnabled bookmarkCaller = iota
	// notGloballyOff only needs the flag not switched off for everyone (ListBookmarks, RemoveBookmark), so a user
	// dropped from the allowlist or percent bucket can still see and remove what they saved (ADR-0023 D5).
	notGloballyOff
)

// guardBookmarks is the flag gate of the three RPCs, run before any Firestore access: FEATURE_POSTS first (the posts
// guard), then FEATURE_BOOKMARKS. FEATURE_ENGAGEMENT is deliberately not required (ADR-0023 D5). A checker without
// GloballyOff (posts.GloballyOffChecker) gets the per-caller answer for all three. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=bookmarks and 0 reads. It returns the caller's uid.
func (s *Server) guardBookmarks(ctx context.Context, who bookmarkCaller) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	on := s.flags.Enabled(uid, BookmarksFlagName)
	if g, ok := s.flags.(posts.GloballyOffChecker); ok && who == notGloballyOff {
		on = !g.GloballyOff(BookmarksFlagName)
	}
	if !on {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
		logger.SetRequestField(ctx, "feature", BookmarksFlagName)
		return "", flags.DisabledError().WithMeta("feature", BookmarksFlagName)
	}
	return uid, nil
}

// bookmarkStub runs the flag gate and then answers Unimplemented. The handlers share the gate so it cannot drift
// between them; W2-4 replaces the last Unimplemented answer (ListBookmarks) with the Service call.
func (s *Server) bookmarkStub(ctx context.Context, rpc, ticket string, who bookmarkCaller) error {
	if _, err := s.guardBookmarks(ctx, who); err != nil {
		return err
	}
	return connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not implemented yet (ticket %s)", rpc, ticket))
}

// bookmarkCall is the shared shell of Add and Remove: the flag gate, the RPC deadline, the service call.
func (s *Server) bookmarkCall(ctx context.Context, rpc string, who bookmarkCaller, fn func(context.Context, Bookmarks, string) (BookmarkState, error)) (*engagementv1.BookmarkState, error) {
	uid, err := s.guardBookmarks(ctx, who)
	if err != nil {
		return nil, err
	}
	if s.bookmarks == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not wired", rpc))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	st, err := fn(ctx, s.bookmarks, uid)
	if err != nil {
		return nil, err
	}
	return &engagementv1.BookmarkState{PostId: st.PostID, Bookmarked: st.Bookmarked}, nil
}

// AddBookmark is behind FEATURE_POSTS and FEATURE_BOOKMARKS on for the caller (not FEATURE_ENGAGEMENT); the rules are
// Bookmarks.AddBookmark. Worst case: 7 reads cold (interceptor 1, visibility check 3, idempotency, quotas, userLikes;
// +2 for a REPOST id, +1 on blockedBy overflow), 3 warm; 4 writes (bookmark, idempotency doc, quotas, userLikes) and
// 1 TTL delete later. A replay costs 5 cold / 1 warm reads, 0 writes; an existing bookmark writes 1 (the idempotency doc, so a late retry replays); the cap and the quota
// write 0.
//
//nolint:dupl // mirrors RemoveBookmark over distinct generated proto types
func (s *Server) AddBookmark(ctx context.Context, req *connect.Request[engagementv1.AddBookmarkRequest]) (*connect.Response[engagementv1.AddBookmarkResponse], error) {
	st, err := s.bookmarkCall(ctx, "AddBookmark", callerEnabled, func(ctx context.Context, b Bookmarks, uid string) (BookmarkState, error) {
		return b.AddBookmark(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.AddBookmarkResponse{State: st}), nil
}

// RemoveBookmark is behind FEATURE_POSTS and a FEATURE_BOOKMARKS that is not globally off; the rules are
// Bookmarks.RemoveBookmark. Worst case: 2 reads cold (interceptor 1, idempotency), 1 warm; 2 writes (idempotency doc,
// userLikes) and 1 delete, plus 1 TTL delete later. A missing bookmark writes 1 (the idempotency doc); a replay writes 0.
//
//nolint:dupl // mirrors AddBookmark over distinct generated proto types
func (s *Server) RemoveBookmark(ctx context.Context, req *connect.Request[engagementv1.RemoveBookmarkRequest]) (*connect.Response[engagementv1.RemoveBookmarkResponse], error) {
	st, err := s.bookmarkCall(ctx, "RemoveBookmark", notGloballyOff, func(ctx context.Context, b Bookmarks, uid string) (BookmarkState, error) {
		return b.RemoveBookmark(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId())
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.RemoveBookmarkResponse{State: st}), nil
}

// ListBookmarks is behind FEATURE_POSTS and a FEATURE_BOOKMARKS that is not globally off. Worst case (when W2-4 lands)
// 43 reads cold at page 20 and 103 at page 50; today 0 reads and 0 writes (Unimplemented after the flag gate).
func (s *Server) ListBookmarks(ctx context.Context, _ *connect.Request[engagementv1.ListBookmarksRequest]) (*connect.Response[engagementv1.ListBookmarksResponse], error) {
	return nil, s.bookmarkStub(ctx, "ListBookmarks", "W2-4", notGloballyOff)
}
