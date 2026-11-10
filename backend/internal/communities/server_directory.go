package communities

import (
	"context"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
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

// ListCommunityMembers is gated by FEATURE_COMMUNITIES. The BANNED and MODERATORS filters are for the owner and moderators
// only (FORBIDDEN reason=not_moderator after the community read); a filter value this server does not know is VALIDATION
// "filter" after the gate. A tampered, expired, foreign or wrong-filter page_token is VALIDATION "page_token"
// before any lookup.
func (s *Server) ListCommunityMembers(ctx context.Context, req *connect.Request[communitiesv1.ListCommunityMembersRequest]) (*connect.Response[communitiesv1.ListCommunityMembersResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListCommunityMembers")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	in := MembersInput{CommunityID: m.GetCommunityId(), PageSize: m.GetPageSize(), PageToken: m.GetPageToken()}
	switch m.GetFilter() {
	case communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_UNSPECIFIED, communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_JOINED:
	case communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED:
		in.Filter = FilterBanned
	case communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_MODERATORS:
		in.Filter = FilterModerators
	default:
		return nil, apierr.Validation("filter", "filter is not a known value")
	}
	page, err := s.svc.ListCommunityMembers(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.ListCommunityMembersResponse{Members: membersToProto(page.Items), NextPageToken: page.NextPageToken}), nil
}

// membersToProto renders member rows (ListCommunityMembers and SearchCommunityMembers alike).
func membersToProto(in []MemberItem) []*communitiesv1.CommunityMember {
	items := make([]graph.ListItem, len(in))
	for i, it := range in {
		items[i] = graph.ListItem{User: it.Profile, Since: it.Since, Relationship: it.Relationship}
	}
	rows := graph.ListItemsToProto(items)
	out := make([]*communitiesv1.CommunityMember, len(rows))
	for i, r := range rows {
		out[i] = &communitiesv1.CommunityMember{User: r, Role: roleToProto(in[i].Role)}
	}
	return out
}

// SearchCommunityMembers is gated by FEATURE_COMMUNITIES (the handler's Guard, first) and then by
// FEATURE_COMMUNITY_MEMBER_SEARCH (the service, before any lookup). filter UNSPECIFIED or JOINED searches the members,
// BANNED the banned users (owner and moderators only); any other value is VALIDATION "filter". No page token.
func (s *Server) SearchCommunityMembers(ctx context.Context, req *connect.Request[communitiesv1.SearchCommunityMembersRequest]) (*connect.Response[communitiesv1.SearchCommunityMembersResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "SearchCommunityMembers")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	in := SearchInput{CommunityID: m.GetCommunityId(), Prefix: m.GetPrefix(), Limit: m.GetLimit()}
	switch m.GetFilter() {
	case communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_UNSPECIFIED, communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_JOINED:
	case communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED:
		in.Filter = FilterBanned
	default:
		in.Filter = MemberFilter(-1) // the service answers VALIDATION "filter" after its flag check
	}
	items, err := s.svc.SearchCommunityMembers(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.SearchCommunityMembersResponse{Members: membersToProto(items)}), nil
}
