// server_bookmarks.go holds the Connect handlers of bookmarks (ADR-0023): AddBookmark, RemoveBookmark and
// ListBookmarks. This file is the flag gate and nothing else yet (W2-2): once it passes, every RPC answers
// Unimplemented naming the ticket that fills it in (W2-3 Add and Remove, W2-4 List), so no path reads or writes.
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

// bookmarkStub runs the flag gate and then answers Unimplemented. The three handlers share it so the gate cannot drift
// between them; W2-3 and W2-4 replace the Unimplemented answer with the Service call, one handler at a time.
func (s *Server) bookmarkStub(ctx context.Context, rpc, ticket string, who bookmarkCaller) error {
	if _, err := s.guardBookmarks(ctx, who); err != nil {
		return err
	}
	return connect.NewError(connect.CodeUnimplemented, fmt.Errorf("%s is not implemented yet (ticket %s)", rpc, ticket))
}

// AddBookmark is behind FEATURE_POSTS and FEATURE_BOOKMARKS on for the caller. Worst case (when W2-3 lands) 7 reads
// cold, 4 writes; today 0 reads and 0 writes (Unimplemented after the flag gate).
func (s *Server) AddBookmark(ctx context.Context, _ *connect.Request[engagementv1.AddBookmarkRequest]) (*connect.Response[engagementv1.AddBookmarkResponse], error) {
	return nil, s.bookmarkStub(ctx, "AddBookmark", "W2-3", callerEnabled)
}

// RemoveBookmark is behind FEATURE_POSTS and a FEATURE_BOOKMARKS that is not globally off. Worst case (when W2-3 lands)
// 2 reads cold, 2 writes and 1 delete; today 0 reads and 0 writes (Unimplemented after the flag gate).
func (s *Server) RemoveBookmark(ctx context.Context, _ *connect.Request[engagementv1.RemoveBookmarkRequest]) (*connect.Response[engagementv1.RemoveBookmarkResponse], error) {
	return nil, s.bookmarkStub(ctx, "RemoveBookmark", "W2-3", notGloballyOff)
}

// ListBookmarks is behind FEATURE_POSTS and a FEATURE_BOOKMARKS that is not globally off. Worst case (when W2-4 lands)
// 43 reads cold at page 20 and 103 at page 50; today 0 reads and 0 writes (Unimplemented after the flag gate).
func (s *Server) ListBookmarks(ctx context.Context, _ *connect.Request[engagementv1.ListBookmarksRequest]) (*connect.Response[engagementv1.ListBookmarksResponse], error) {
	return nil, s.bookmarkStub(ctx, "ListBookmarks", "W2-4", notGloballyOff)
}
