package lists

import (
	"context"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
)

// followsOn is the list_follows flag for the caller. The follow fields of ListInfo (follower_count, followed_by_viewer) are set
// only when it is on, so a caller outside the flag sees the same ListInfo as before.
func (s *Server) followsOn(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, FollowFlagName)
}

// info renders a View as a ListInfo, with the follow fields when the caller has FEATURE_LIST_FOLLOWS.
func (s *Server) info(uid string, v View) *listsv1.ListInfo {
	out := toListInfo(v)
	if s.followsOn(uid) {
		out.FollowerCount = int32(v.Header.FollowerCount) //nolint:gosec // bounded by the follower cap in practice
		out.FollowedByViewer = v.FollowedByViewer
	}
	return out
}

// markFollowed sets FollowedByViewer on views from one batched marker read (called only with the flag on).
func (s *Server) markFollowed(ctx context.Context, uid string, views []View) error {
	if len(views) == 0 {
		return nil
	}
	listIDs := make([]string, len(views))
	for i, v := range views {
		listIDs[i] = v.Header.ID
	}
	followed, err := s.svc.FollowedAmong(ctx, uid, listIDs)
	if err != nil {
		return err
	}
	for i := range views {
		views[i].FollowedByViewer = followed[views[i].Header.ID]
	}
	return nil
}

// followEntry is entry for the follow RPCs: the lists gate, then the sub-feature flag named by flag.
func (s *Server) followEntry(ctx context.Context, rpc, flag string) (context.Context, context.CancelFunc, string, error) {
	ctx, cancel, uid, err := s.entry(ctx, rpc)
	if err != nil {
		return nil, nil, "", err
	}
	if err := GuardFlag(ctx, s.flags, uid, flag); err != nil {
		cancel()
		return nil, nil, "", err
	}
	return ctx, cancel, uid, nil
}

// FollowList is gated by FEATURE_LISTS and FEATURE_LIST_FOLLOWS.
func (s *Server) FollowList(ctx context.Context, req *connect.Request[listsv1.FollowListRequest]) (*connect.Response[listsv1.FollowListResponse], error) {
	ctx, cancel, uid, err := s.followEntry(ctx, "FollowList", FollowFlagName)
	if err != nil {
		return nil, err
	}
	defer cancel()
	v, err := s.svc.FollowList(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetListId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.FollowListResponse{List: s.info(uid, v)}), nil
}

// UnfollowList is gated by FEATURE_LISTS and FEATURE_LIST_FOLLOWS.
func (s *Server) UnfollowList(ctx context.Context, req *connect.Request[listsv1.UnfollowListRequest]) (*connect.Response[listsv1.UnfollowListResponse], error) {
	ctx, cancel, uid, err := s.followEntry(ctx, "UnfollowList", FollowFlagName)
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := s.svc.UnfollowList(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetListId()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&listsv1.UnfollowListResponse{}), nil
}

// ListFollowedLists is gated by FEATURE_LISTS and FEATURE_LIST_FOLLOWS.
func (s *Server) ListFollowedLists(ctx context.Context, req *connect.Request[listsv1.ListFollowedListsRequest]) (*connect.Response[listsv1.ListFollowedListsResponse], error) {
	ctx, cancel, uid, err := s.followEntry(ctx, "ListFollowedLists", FollowFlagName)
	if err != nil {
		return nil, err
	}
	defer cancel()
	page, err := s.svc.ListFollowedLists(ctx, uid, req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &listsv1.ListFollowedListsResponse{NextPageToken: page.NextPageToken}
	for _, v := range page.Views {
		out.Lists = append(out.Lists, s.info(uid, v))
	}
	return connect.NewResponse(out), nil
}

// DiscoverLists is gated by FEATURE_LISTS and FEATURE_LIST_FOLLOWS.
func (s *Server) DiscoverLists(ctx context.Context, req *connect.Request[listsv1.DiscoverListsRequest]) (*connect.Response[listsv1.DiscoverListsResponse], error) {
	ctx, cancel, uid, err := s.followEntry(ctx, "DiscoverLists", FollowFlagName)
	if err != nil {
		return nil, err
	}
	defer cancel()
	page, err := s.svc.DiscoverLists(ctx, uid, req.Msg.GetPageSize(), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &listsv1.DiscoverListsResponse{NextPageToken: page.NextPageToken}
	for _, v := range page.Views {
		out.Lists = append(out.Lists, s.info(uid, v))
	}
	return connect.NewResponse(out), nil
}

// ListSuggestedMembers is gated by FEATURE_LISTS and FEATURE_LIST_SUGGESTIONS; owner only (any other caller: NOT_FOUND).
func (s *Server) ListSuggestedMembers(ctx context.Context, req *connect.Request[listsv1.ListSuggestedMembersRequest]) (*connect.Response[listsv1.ListSuggestedMembersResponse], error) {
	ctx, cancel, uid, err := s.followEntry(ctx, "ListSuggestedMembers", SuggestionsFlagName)
	if err != nil {
		return nil, err
	}
	defer cancel()
	profs, err := s.svc.ListSuggestedMembers(ctx, uid, req.Msg.GetListId(), req.Msg.GetMaxResults())
	if err != nil {
		return nil, err
	}
	out := &listsv1.ListSuggestedMembersResponse{}
	for _, p := range profs {
		out.Users = append(out.Users, &graphv1.UserListItem{
			User: &commonv1.AuthorSnapshot{
				UserId: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarUrl: p.AvatarThumbURL,
				Verified: p.Verified, IsPrivate: p.IsPrivate,
			},
			// Every suggestion is someone the caller follows (ListSuggestedMembers reads RecentFollowing).
			Relationship: &graphv1.Relationship{FollowState: graphv1.FollowState_FOLLOW_STATE_FOLLOWING},
		})
	}
	return connect.NewResponse(out), nil
}
