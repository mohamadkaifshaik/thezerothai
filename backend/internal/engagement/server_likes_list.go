// server_likes_list.go holds the Connect handler of ListLikedPosts: the flag gate,
// then LikesList.ListLikedPosts, each row rendered with posts.ToView.
package engagement

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// LikesListFlagName is the wire name of FEATURE_LIKES_LIST. ListLikedPosts needs it on for the caller.
// It is independent of FlagName (engagement): the list shows likes made while that flag was on.
const LikesListFlagName = "likes_list"

// guardLikesList is the flag gate of ListLikedPosts, run before any Firestore access: FEATURE_POSTS first (the posts
// guard), then FEATURE_LIKES_LIST on for the caller. FEATURE_ENGAGEMENT is deliberately not required. Disabled is
// FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=likes_list, before any Firestore access. It returns the caller's uid.
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

// ListLikedPosts is the caller's own likes, newest first (owner-only: the request has no user id, so the
// source is always userLikes/{token uid} and the page token is bound to likes|<uid>). It is behind FEATURE_POSTS and
// FEATURE_LIKES_LIST on for the caller (not FEATURE_ENGAGEMENT); the rules are LikesList.ListLikedPosts. It reads
// userLikes, posts through GetMany (only the misses of the post cache) and the caller graph; a foreign, expired or
// tampered token is rejected before any lookup. It writes nothing (no pruning). A client keeps following next_page_token until it is "" because dropped rows shorten a page.
func (s *Server) ListLikedPosts(ctx context.Context, req *connect.Request[engagementv1.ListLikedPostsRequest]) (*connect.Response[engagementv1.ListLikedPostsResponse], error) {
	uid, err := s.guardLikesList(ctx)
	if err != nil {
		return nil, err
	}
	if s.likes == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("ListLikedPosts is not wired"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	page, err := s.likes.ListLikedPosts(ctx, uid, req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &engagementv1.ListLikedPostsResponse{NextPageToken: page.NextPageToken, Posts: make([]*postsv1.PostView, 0, len(page.Posts))}
	for i, p := range page.Posts {
		v := posts.ToView(p, page.Viewer, uid)
		if i < len(page.Hints) {
			page.Hints[i].Apply(v) // PROTECTED strips a QUOTE's copy; FOLLOWERS for a protected author
			posts.ApplyPublicViews(v, p, page.Hints[i].Protected)
		}
		v.LikedByViewer = v.LikedByViewer || v.Withheld // a placeholder row is a like by definition
		out.Posts = append(out.Posts, v)
	}
	return connect.NewResponse(out), nil
}
