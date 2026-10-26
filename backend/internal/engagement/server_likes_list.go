// server_likes_list.go holds the Connect handler of ListLikedPosts (ADR-0024 D6, ticket W3-4). This file is the flag
// gate and nothing else yet: once it passes, the RPC answers Unimplemented naming the ticket that fills it in (W3-10),
// so no path reads or writes.
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

// LikesListFlagName is the wire name of FEATURE_LIKES_LIST (ADR-0024 D9). ListLikedPosts needs it on for the caller.
// It is independent of FlagName (engagement): the list shows likes made while that flag was on.
const LikesListFlagName = "likes_list"

// guardLikesList is the flag gate of ListLikedPosts, run before any Firestore access: FEATURE_POSTS first (the posts
// guard), then FEATURE_LIKES_LIST on for the caller. FEATURE_ENGAGEMENT is deliberately not required. Disabled is
// FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=likes_list and 0 reads. It returns the caller's uid.
func (s *Server) guardLikesList(ctx context.Context) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if err := flags.Guard(ctx, s.flags.Enabled, uid, LikesListFlagName); err != nil {
		logger.SetRequestField(ctx, "feature", LikesListFlagName)
		return "", flags.DisabledError().WithMeta("feature", LikesListFlagName)
	}
	return uid, nil
}

// ListLikedPosts is the caller's own likes, newest first (ADR-0024 D6; owner-only: the request has no user id). It is
// behind FEATURE_POSTS and FEATURE_LIKES_LIST on for the caller. Worst case (when W3-10 lands) 23 reads cold at page 20
// and 53 at page 50 (interceptor 1, userLikes 1, posts GetMany <= page, caller graph 1), 0 writes; today 0 reads and
// 0 writes (Unimplemented after the flag gate).
func (s *Server) ListLikedPosts(ctx context.Context, _ *connect.Request[engagementv1.ListLikedPostsRequest]) (*connect.Response[engagementv1.ListLikedPostsResponse], error) {
	if _, err := s.guardLikesList(ctx); err != nil {
		return nil, err
	}
	return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("ListLikedPosts is not implemented yet (ticket W3-10)"))
}
