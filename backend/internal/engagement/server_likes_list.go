// server_likes_list.go holds the Connect handler of ListLikedPosts (ADR-0024 D6, tickets W3-4 and W3-10): the flag gate
// (W3-4), then LikesList.ListLikedPosts (W3-10), each row rendered with posts.ToView.
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

// ListLikedPosts is the caller's own likes, newest first (ADR-0024 D6; owner-only: the request has no user id, so the
// source is always userLikes/{token uid} and the page token is bound to likes|<uid>). It is behind FEATURE_POSTS and
// FEATURE_LIKES_LIST on for the caller (not FEATURE_ENGAGEMENT); the rules are LikesList.ListLikedPosts. Worst case
// reads cold: 23 at page 20 and 53 at page 50 (interceptor 1, userLikes 1, posts GetMany <= page, caller graph 1), 2
// for an empty array, 20 / 50 warm (posts cached), 0 for a foreign, expired or tampered token past the interceptor;
// 0 writes (no pruning). A client keeps following next_page_token until it is "" because dropped rows shorten a page.
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
			page.Hints[i].Apply(v) // PROTECTED strips a QUOTE's copy; FOLLOWERS for a protected author (ADR-0025 D2, D4)
		}
		v.LikedByViewer = v.LikedByViewer || v.Withheld // a placeholder row is a like by definition
		out.Posts = append(out.Posts, v)
	}
	return connect.NewResponse(out), nil
}
