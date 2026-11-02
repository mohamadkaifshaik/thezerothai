package communities

import (
	"testing"
	"time"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestServer_ListCommunities(t *testing.T) {
	a, b := sampleView(), sampleView()
	b.Community.ID, b.Role = otherCID, RoleMember
	svc := &fakeService{dirViews: []View{a, b}}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	resp, err := s.ListCommunities(authedCtx("u1"), connect.NewRequest(&communitiesv1.ListCommunitiesRequest{PageSize: 3}))
	if err != nil {
		t.Fatal(err)
	}
	m := resp.Msg
	if len(m.GetCommunities()) != 2 || m.GetCommunities()[1].GetCommunityId() != otherCID ||
		m.GetCommunities()[1].GetViewerRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER || m.GetNextPageToken() != "" || svc.gotUser != "u1" {
		t.Errorf("response = %v by %q", m, svc.gotUser)
	}
}

func TestServer_ListCommunityMembers(t *testing.T) {
	since := time.Now().Truncate(time.Second)
	svc := &fakeService{members: MembersPage{NextPageToken: "tok", Items: []MemberItem{
		{Profile: profile("a", identity.AccountStatusActive), Since: since, Role: RoleModerator},
		{Profile: profile("b", identity.AccountStatusActive), Since: since, Role: RoleBanned},
	}}}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	resp, err := s.ListCommunityMembers(authedCtx("u1"), connect.NewRequest(&communitiesv1.ListCommunityMembersRequest{
		CommunityId: testCID, Filter: communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED, PageSize: 9, PageToken: "t0",
	}))
	if err != nil {
		t.Fatal(err)
	}
	in := svc.membersIn[0]
	if in.CommunityID != testCID || in.Filter != FilterBanned || in.PageSize != 9 || in.PageToken != "t0" {
		t.Errorf("service got %+v", in)
	}
	m := resp.Msg
	if len(m.GetMembers()) != 2 || m.GetNextPageToken() != "tok" || m.GetMembers()[0].GetUser().GetUser().GetUserId() != "a" ||
		m.GetMembers()[0].GetRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR || !m.GetMembers()[1].GetUser().GetSince().AsTime().Equal(since) ||
		m.GetMembers()[1].GetRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_BANNED {
		t.Errorf("response = %v", m)
	}
	for _, f := range []communitiesv1.CommunityMemberFilter{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_UNSPECIFIED, communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_JOINED} {
		if _, err := s.ListCommunityMembers(authedCtx("u1"), connect.NewRequest(&communitiesv1.ListCommunityMembersRequest{Filter: f})); err != nil {
			t.Fatal(err)
		}
		if svc.membersIn[len(svc.membersIn)-1].Filter != FilterJoined {
			t.Errorf("filter %v did not map to JOINED", f)
		}
	}
}
