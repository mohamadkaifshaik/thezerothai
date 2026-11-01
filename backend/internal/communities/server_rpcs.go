package communities

import (
	"context"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// CreateCommunity is gated by FEATURE_COMMUNITIES and needs the caller in COMMUNITY_CREATORS (FORBIDDEN not_creator otherwise).
//
// Firestore (ADR-0031 Cost impact, the account-status interceptor's read included): reads 3 cold / 2 warm (interceptor, idempotency,
// memberships); writes 4 (community, owner member doc, memberships, idempotency) + 1 TTL delete of the idempotency doc 24 h later;
// replay reads 3, writes 0; refused 0 writes.
func (s *Server) CreateCommunity(ctx context.Context, req *connect.Request[communitiesv1.CreateCommunityRequest]) (*connect.Response[communitiesv1.CreateCommunityResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "CreateCommunity")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	v, err := s.svc.CreateCommunity(ctx, uid, CreateInput{
		Key: m.GetIdempotencyKey(), Name: m.GetName(), Description: m.GetDescription(), Rules: rulesFromProto(m.GetRules()),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.CreateCommunityResponse{Community: toProtoCommunity(v), Rules: rulesToProto(v.Community.Rules)}), nil
}

// UpdateCommunity is gated by FEATURE_COMMUNITIES; owner only, and only the fields that are set change.
//
// Firestore (interceptor included): reads 4 cold / 3 warm (interceptor, idempotency, community, owner memberships); writes 2
// (community, idempotency), +1 for the first log entry that names the owner in this community (memberships modlogged), 1 when nothing
// changes, + 1 TTL delete later; replay reads 3, writes 0.
func (s *Server) UpdateCommunity(ctx context.Context, req *connect.Request[communitiesv1.UpdateCommunityRequest]) (*connect.Response[communitiesv1.UpdateCommunityResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "UpdateCommunity")
	if err != nil {
		return nil, err
	}
	defer cancel()
	m := req.Msg
	in := UpdateInput{Key: m.GetIdempotencyKey(), CommunityID: m.GetCommunityId(), Name: m.Name, Description: m.Description}
	if m.GetRules() != nil { // a set CommunityRuleList, even an empty one, replaces every rule
		rs := rulesFromProto(m.GetRules().GetRules())
		in.Rules = &rs
	}
	v, err := s.svc.UpdateCommunity(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.UpdateCommunityResponse{Community: toProtoCommunity(v), Rules: rulesToProto(v.Community.Rules)}), nil
}

// GetCommunity is gated by FEATURE_COMMUNITIES. Any signed-in user reads a community (F6); a SUSPENDED one is NOT_FOUND except to its
// owner.
//
// Firestore (interceptor included): reads 15 cold (interceptor, community, caller member doc, caller graph, owner + <= 10 moderator
// profiles) / 0 warm, planning 4; writes 0.
func (s *Server) GetCommunity(ctx context.Context, req *connect.Request[communitiesv1.GetCommunityRequest]) (*connect.Response[communitiesv1.GetCommunityResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "GetCommunity")
	if err != nil {
		return nil, err
	}
	defer cancel()
	d, err := s.svc.GetCommunity(ctx, uid, req.Msg.GetCommunityId())
	if err != nil {
		return nil, err
	}
	out := &communitiesv1.GetCommunityResponse{Community: toProtoCommunity(d.View), Rules: rulesToProto(d.View.Community.Rules)}
	var items []graph.ListItem
	if d.Owner != nil {
		items = append(items, graph.ListItem{User: d.Owner.Profile, Relationship: d.Owner.Relationship})
	}
	nOwner := len(items)
	for _, p := range d.Moderators {
		items = append(items, graph.ListItem{User: p.Profile, Relationship: p.Relationship})
	}
	rows := graph.ListItemsToProto(items)
	if d.Owner != nil {
		out.Owner = rows[0]
	}
	out.Moderators = rows[nOwner:]
	return connect.NewResponse(out), nil
}

func rulesFromProto(in []*communitiesv1.CommunityRule) []Rule {
	out := make([]Rule, 0, len(in))
	for _, r := range in {
		out = append(out, Rule{Title: r.GetTitle(), Text: r.GetText()})
	}
	return out
}

func rulesToProto(in []Rule) []*communitiesv1.CommunityRule {
	out := make([]*communitiesv1.CommunityRule, len(in))
	for i, r := range in {
		out[i] = &communitiesv1.CommunityRule{Title: r.Title, Text: r.Text}
	}
	return out
}

// toProtoCommunity renders the light header (ADR-0031 N2): the document and the caller's role, 0 extra reads.
func toProtoCommunity(v View) *communitiesv1.Community {
	c := v.Community
	return &communitiesv1.Community{
		CommunityId: c.ID, Name: c.Name, Description: c.Description, MemberCount: c.MemberCount,
		Status: statusToProto(c.Status), Visibility: communitiesv1.CommunityVisibility_COMMUNITY_VISIBILITY_PUBLIC,
		ViewerRole: roleToProto(v.Role), CreatedAt: timestamppb.New(c.CreatedAt),
	}
}

func statusToProto(s Status) communitiesv1.CommunityStatus {
	switch s {
	case StatusActive:
		return communitiesv1.CommunityStatus_COMMUNITY_STATUS_ACTIVE
	case StatusArchived:
		return communitiesv1.CommunityStatus_COMMUNITY_STATUS_ARCHIVED
	case StatusSuspended:
		return communitiesv1.CommunityStatus_COMMUNITY_STATUS_SUSPENDED
	}
	return communitiesv1.CommunityStatus_COMMUNITY_STATUS_UNSPECIFIED
}

func roleToProto(r Role) communitiesv1.CommunityRole {
	switch r {
	case RoleOwner:
		return communitiesv1.CommunityRole_COMMUNITY_ROLE_OWNER
	case RoleModerator:
		return communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR
	case RoleMember:
		return communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER
	case RoleBanned:
		return communitiesv1.CommunityRole_COMMUNITY_ROLE_BANNED
	}
	return communitiesv1.CommunityRole_COMMUNITY_ROLE_NONE
}

// JoinCommunity is gated by FEATURE_COMMUNITIES. A BANNED caller is FORBIDDEN reason=banned; an ARCHIVED community is COMMUNITY_STATE
// reason=community_archived; the 51st joined community is LIMIT_REACHED communities_joined; over the daily quota is QUOTA_EXCEEDED
// community_joins. Already a member (the owner and moderators included) is success and spends no quota. member_count may lag other
// instances by up to 60 s (the transaction never reads the community document).
//
// Firestore (interceptor included): reads 6 cold (interceptor, community via the cache, idempotency, member doc, memberships, quotas) /
// 4 warm; writes 5 (member doc, memberships, memberCount, quotas, idempotency) + 1 TTL delete later; already a member 3 cold reads and
// 1 write; banned, at the cap or over the quota 0 writes; replay 0 writes.
func (s *Server) JoinCommunity(ctx context.Context, req *connect.Request[communitiesv1.JoinCommunityRequest]) (*connect.Response[communitiesv1.JoinCommunityResponse], error) {
	v, err := s.membership(ctx, "JoinCommunity", MembershipInput{Key: req.Msg.GetIdempotencyKey(), CommunityID: req.Msg.GetCommunityId()}, Service.JoinCommunity)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.JoinCommunityResponse{Community: toProtoCommunity(v)}), nil
}

// LeaveCommunity is gated by FEATURE_COMMUNITIES. The owner is COMMUNITY_STATE reason=owner (0 writes); a moderator also leaves
// moderator_ids, logged MODERATOR_LEFT; a non-member (a banned user included, the ban stays) is success with the idempotency document
// only. Allowed in an ARCHIVED community.
//
// Firestore (interceptor included): reads 5 cold (interceptor, community via the cache, idempotency, member doc, memberships) / 3 warm,
// 6 / 4 for a moderator (the community read fresh in the transaction); writes 3 (memberships, community, idempotency) + 1 delete (member
// doc) + 1 TTL delete later; not a member 4 cold reads and 1 write; the owner 0 writes; replay 0 writes.
func (s *Server) LeaveCommunity(ctx context.Context, req *connect.Request[communitiesv1.LeaveCommunityRequest]) (*connect.Response[communitiesv1.LeaveCommunityResponse], error) {
	v, err := s.membership(ctx, "LeaveCommunity", MembershipInput{Key: req.Msg.GetIdempotencyKey(), CommunityID: req.Msg.GetCommunityId()}, Service.LeaveCommunity)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&communitiesv1.LeaveCommunityResponse{Community: toProtoCommunity(v)}), nil
}

// ListMyCommunities is gated by FEATURE_COMMUNITIES. Not paged at Stage 0: page_size is ignored and a non-empty page_token is VALIDATION
// "page_token" with 0 reads beyond the interceptor.
//
// Firestore (interceptor included): reads 52 cold (interceptor, memberships, at most 50 community documents) / 2 warm (interceptor +
// memberships, the documents come from the 60 s cache), planning 4; writes 0.
func (s *Server) ListMyCommunities(ctx context.Context, req *connect.Request[communitiesv1.ListMyCommunitiesRequest]) (*connect.Response[communitiesv1.ListMyCommunitiesResponse], error) {
	ctx, cancel, uid, err := s.entry(ctx, "ListMyCommunities")
	if err != nil {
		return nil, err
	}
	defer cancel()
	l, err := s.svc.ListMyCommunities(ctx, uid, req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &communitiesv1.ListMyCommunitiesResponse{CanCreate: l.CanCreate, Communities: make([]*communitiesv1.Community, len(l.Items))}
	for i, v := range l.Items {
		out.Communities[i] = toProtoCommunity(v)
	}
	return connect.NewResponse(out), nil
}

// membership is the shared body of JoinCommunity and LeaveCommunity: the flag gate, the wiring check and the deadline, then call.
func (s *Server) membership(ctx context.Context, rpc string, in MembershipInput, call func(Service, context.Context, string, MembershipInput) (View, error)) (View, error) {
	ctx, cancel, uid, err := s.entry(ctx, rpc)
	if err != nil {
		return View{}, err
	}
	defer cancel()
	return call(s.svc, ctx, uid, in)
}
