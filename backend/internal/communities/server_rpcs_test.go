package communities

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeService records what the handlers pass down and answers canned values.
type fakeService struct {
	create  []CreateInput
	update  []UpdateInput
	get     []string
	view    View
	detail  Detail
	err     error
	gotUser string
}

func (s *fakeService) CreateCommunity(_ context.Context, uid string, in CreateInput) (View, error) {
	s.create, s.gotUser = append(s.create, in), uid
	return s.view, s.err
}

func (s *fakeService) UpdateCommunity(_ context.Context, uid string, in UpdateInput) (View, error) {
	s.update, s.gotUser = append(s.update, in), uid
	return s.view, s.err
}

func (s *fakeService) GetCommunity(_ context.Context, uid, id string) (Detail, error) {
	s.get, s.gotUser = append(s.get, id), uid
	return s.detail, s.err
}

func authedCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

func sampleView() View {
	return View{Role: RoleOwner, Community: Community{
		ID: testCID, Name: "Go", Description: "about", MemberCount: 4, Status: StatusActive, CreatedAt: testNow,
		Rules: []Rule{{Title: "Be kind", Text: "always"}},
	}}
}

// TestServer_ImplementedRPCsRunTheGateBeforeTheService: in every flag mode, a caller outside the flag never reaches the service (0 reads,
// FEATURE_DISABLED), and a caller inside does.
func TestServer_ImplementedRPCsRunTheGateBeforeTheService(t *testing.T) {
	calls := map[string]func(*Server, context.Context) error{
		"CreateCommunity": call((*Server).CreateCommunity),
		"UpdateCommunity": call((*Server).UpdateCommunity),
		"GetCommunity":    call((*Server).GetCommunity),
	}
	for rpc, c := range calls {
		for _, m := range flagModes() {
			t.Run(rpc+"/"+m.name, func(t *testing.T) {
				svc := &fakeService{view: sampleView()}
				s := NewServer(flags.NewRegistry(m.spec), svc)
				err := c(s, authedCtx(m.uid))
				touched := len(svc.create)+len(svc.update)+len(svc.get) > 0
				if m.wantOff {
					assertDisabled(t, err)
					if touched {
						t.Error("the service ran for a caller outside the flag")
					}
					return
				}
				if err != nil || !touched {
					t.Errorf("err = %v, touched = %v, want the service to run", err, touched)
				}
			})
		}
	}
}

func TestServer_CreateCommunity(t *testing.T) {
	svc := &fakeService{view: sampleView()}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	resp, err := s.CreateCommunity(authedCtx("u1"), connect.NewRequest(&communitiesv1.CreateCommunityRequest{
		IdempotencyKey: goodKey, Name: "Go", Description: "about", Rules: []*communitiesv1.CommunityRule{{Title: "Be kind", Text: "always"}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	in := svc.create[0]
	if svc.gotUser != "u1" || in.Key != goodKey || in.Name != "Go" || in.Description != "about" || len(in.Rules) != 1 || in.Rules[0].Title != "Be kind" {
		t.Errorf("service got %q %+v", svc.gotUser, in)
	}
	c := resp.Msg.GetCommunity()
	if c.GetCommunityId() != testCID || c.GetMemberCount() != 4 || c.GetStatus() != communitiesv1.CommunityStatus_COMMUNITY_STATUS_ACTIVE ||
		c.GetVisibility() != communitiesv1.CommunityVisibility_COMMUNITY_VISIBILITY_PUBLIC || c.GetViewerRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_OWNER ||
		!c.GetCreatedAt().AsTime().Equal(testNow) {
		t.Errorf("header = %v", c)
	}
	if r := resp.Msg.GetRules(); len(r) != 1 || r[0].GetTitle() != "Be kind" || r[0].GetText() != "always" {
		t.Errorf("rules = %v", r)
	}
	// the service's error comes back untouched
	svc.err = Forbidden(ReasonNotCreator)
	if _, err := s.CreateCommunity(authedCtx("u1"), connect.NewRequest(&communitiesv1.CreateCommunityRequest{})); !errors.Is(err, svc.err) {
		t.Errorf("err = %v", err)
	}
}

func TestServer_UpdateCommunity_RulesUnsetIsNotEmpty(t *testing.T) {
	svc := &fakeService{view: sampleView()}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	name := "New"
	for _, tt := range []struct {
		name      string
		rules     *communitiesv1.CommunityRuleList
		wantRules bool
		wantLen   int
	}{
		{"unset", nil, false, 0},
		{"set and empty removes every rule", &communitiesv1.CommunityRuleList{}, true, 0},
		{"set replaces", &communitiesv1.CommunityRuleList{Rules: []*communitiesv1.CommunityRule{{Title: "a"}, {Title: "b"}}}, true, 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			svc.update = nil
			_, err := s.UpdateCommunity(authedCtx("u1"), connect.NewRequest(&communitiesv1.UpdateCommunityRequest{
				IdempotencyKey: goodKey, CommunityId: testCID, Name: &name, Rules: tt.rules,
			}))
			if err != nil {
				t.Fatal(err)
			}
			in := svc.update[0]
			if (in.Rules != nil) != tt.wantRules || (in.Rules != nil && len(*in.Rules) != tt.wantLen) {
				t.Errorf("rules = %v", in.Rules)
			}
			if in.Name == nil || *in.Name != "New" || in.Description != nil || in.CommunityID != testCID {
				t.Errorf("input = %+v", in)
			}
		})
	}
}

func TestServer_GetCommunity(t *testing.T) {
	v := sampleView()
	v.Role = RoleNone
	svc := &fakeService{detail: Detail{
		View:       v,
		Owner:      &Person{Profile: identity.Profile{UserID: "o", Handle: "own", Status: identity.AccountStatusActive}, Relationship: graph.Relationship{UserID: "o", FollowState: graph.FollowStateFollowing}},
		Moderators: []Person{{Profile: identity.Profile{UserID: "m1", Handle: "mod1"}}, {Profile: identity.Profile{UserID: "m2", Handle: "mod2"}}},
	}}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	resp, err := s.GetCommunity(authedCtx("u1"), connect.NewRequest(&communitiesv1.GetCommunityRequest{CommunityId: testCID}))
	if err != nil {
		t.Fatal(err)
	}
	m := resp.Msg
	if svc.get[0] != testCID || svc.gotUser != "u1" {
		t.Errorf("service got %q %q", svc.gotUser, svc.get)
	}
	if m.GetCommunity().GetViewerRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_NONE || m.GetOwner().GetUser().GetHandle() != "own" ||
		m.GetOwner().GetRelationship().GetFollowState() == 0 || len(m.GetModerators()) != 2 || m.GetModerators()[1].GetUser().GetHandle() != "mod2" {
		t.Errorf("response = %v", m)
	}
	if m.GetOwner().GetSince() != nil || m.GetModerators()[0].GetSince() != nil {
		t.Error("since is set on a role holder row")
	}
	// no owner (ARCHIVED, F12): the field is unset and the moderators stay in order
	svc.detail.Owner = nil
	resp, err = s.GetCommunity(authedCtx("u1"), connect.NewRequest(&communitiesv1.GetCommunityRequest{CommunityId: testCID}))
	if err != nil || resp.Msg.GetOwner() != nil || len(resp.Msg.GetModerators()) != 2 || resp.Msg.GetModerators()[0].GetUser().GetHandle() != "mod1" {
		t.Errorf("no owner: %v, %v", resp, err)
	}
}

func TestProtoMapping(t *testing.T) {
	for s, want := range map[Status]communitiesv1.CommunityStatus{
		StatusActive: communitiesv1.CommunityStatus_COMMUNITY_STATUS_ACTIVE, StatusArchived: communitiesv1.CommunityStatus_COMMUNITY_STATUS_ARCHIVED,
		StatusSuspended: communitiesv1.CommunityStatus_COMMUNITY_STATUS_SUSPENDED, "": communitiesv1.CommunityStatus_COMMUNITY_STATUS_UNSPECIFIED,
	} {
		if got := statusToProto(s); got != want {
			t.Errorf("status %q -> %v, want %v", s, got, want)
		}
	}
	for r, want := range map[Role]communitiesv1.CommunityRole{
		RoleOwner: communitiesv1.CommunityRole_COMMUNITY_ROLE_OWNER, RoleModerator: communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR,
		RoleMember: communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER, RoleBanned: communitiesv1.CommunityRole_COMMUNITY_ROLE_BANNED,
		RoleNone: communitiesv1.CommunityRole_COMMUNITY_ROLE_NONE,
	} {
		if got := roleToProto(r); got != want {
			t.Errorf("role %v -> %v, want %v", r, got, want)
		}
	}
}

func TestNewWithoutCreatorsRefusesEveryone(t *testing.T) {
	_, err := New(Deps{Repo: newFakeRepo()}).CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go"})
	wantAPIErr(t, err, connect.CodePermissionDenied, 21, map[string]string{"reason": "not_creator"})
}
