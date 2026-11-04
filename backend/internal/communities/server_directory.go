package communities

import (
	"context"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// ListCommunities is gated by FEATURE_COMMUNITIES. The directory is one response of at most 50 ACTIVE communities, most members first;
// page_size is ignored and a non-empty page_token is VALIDATION "page_token" before any lookup.
func (s *Server) ListCommunities(ctx context.Context, req *connect.Request[communitiesv1.ListCommunitiesRequest]) (*connect.Response[communitiesv1.ListCommunitiesResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListCommunities")
	if err != nil {
		return nil, err
	}
	defer cancel()
	views, err := s.svc.ListCommunities(ctx, uid, req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &communitiesv1.ListCommunitiesResponse{Communities: make([]*communitiesv1.Community, len(views))}
	for i, v := range views {
		out.Communities[i] = toProtoCommunity(v)
	}
	return connect.NewResponse(out), nil
}

// ListCommunityMembers is gated by FEATURE_COMMUNITIES. The BANNED filter is for the owner and moderators only (FORBIDDEN
// reason=not_moderator after the community read). A tampered, expired, foreign or wrong-filter page_token is VALIDATION "page_token"
// before any lookup.
func (s *Server) ListCommunityMembers(ctx context.Context, req *connect.Request[communitiesv1.ListCommunityMembersRequest]) (*connect.Response[communitiesv1.ListCommunityMembersResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListCommunityMembers")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	in := MembersInput{CommunityID: m.GetCommunityId(), PageSize: m.GetPageSize(), PageToken: m.GetPageToken()}
	if m.GetFilter() == communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED {
		in.Filter = FilterBanned
	}
	page, err := s.svc.ListCommunityMembers(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	items := make([]graph.ListItem, len(page.Items))
	for i, it := range page.Items {
		items[i] = graph.ListItem{User: it.Profile, Since: it.Since, Relationship: it.Relationship}
	}
	rows := graph.ListItemsToProto(items)
	out := &communitiesv1.ListCommunityMembersResponse{Members: make([]*communitiesv1.CommunityMember, len(rows)), NextPageToken: page.NextPageToken}
	for i, r := range rows {
		out.Members[i] = &communitiesv1.CommunityMember{User: r, Role: roleToProto(page.Items[i].Role)}
	}
	return connect.NewResponse(out), nil
}
