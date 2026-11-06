package beacons

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type rpcCall struct {
	name  string
	write bool // write class: the flag must be on for the caller; read class: only not globally off
	call  func(s *Server, ctx context.Context) error
}

func allCalls() []rpcCall {
	return []rpcCall{
		{"CreateBeacon", true, func(s *Server, ctx context.Context) error {
			_, err := s.CreateBeacon(ctx, connect.NewRequest(&beaconsv1.CreateBeaconRequest{}))
			return err
		}},
		{"UpdateBeacon", true, func(s *Server, ctx context.Context) error {
			_, err := s.UpdateBeacon(ctx, connect.NewRequest(&beaconsv1.UpdateBeaconRequest{}))
			return err
		}},
		{"RequestToJoin", true, func(s *Server, ctx context.Context) error {
			_, err := s.RequestToJoin(ctx, connect.NewRequest(&beaconsv1.RequestToJoinRequest{}))
			return err
		}},
		{"RespondToJoinRequest", true, func(s *Server, ctx context.Context) error {
			_, err := s.RespondToJoinRequest(ctx, connect.NewRequest(&beaconsv1.RespondToJoinRequestRequest{}))
			return err
		}},
		{"CancelBeacon", false, func(s *Server, ctx context.Context) error {
			_, err := s.CancelBeacon(ctx, connect.NewRequest(&beaconsv1.CancelBeaconRequest{}))
			return err
		}},
		{"GetBeacon", false, func(s *Server, ctx context.Context) error {
			_, err := s.GetBeacon(ctx, connect.NewRequest(&beaconsv1.GetBeaconRequest{}))
			return err
		}},
		{"ListBeacons", false, func(s *Server, ctx context.Context) error {
			_, err := s.ListBeacons(ctx, connect.NewRequest(&beaconsv1.ListBeaconsRequest{}))
			return err
		}},
		{"ListMyBeacons", false, func(s *Server, ctx context.Context) error {
			_, err := s.ListMyBeacons(ctx, connect.NewRequest(&beaconsv1.ListMyBeaconsRequest{}))
			return err
		}},
		{"WithdrawJoinRequest", false, func(s *Server, ctx context.Context) error {
			_, err := s.WithdrawJoinRequest(ctx, connect.NewRequest(&beaconsv1.WithdrawJoinRequestRequest{}))
			return err
		}},
		{"LeaveBeacon", false, func(s *Server, ctx context.Context) error {
			_, err := s.LeaveBeacon(ctx, connect.NewRequest(&beaconsv1.LeaveBeaconRequest{}))
			return err
		}},
		{"RemoveParticipant", false, func(s *Server, ctx context.Context) error {
			_, err := s.RemoveParticipant(ctx, connect.NewRequest(&beaconsv1.RemoveParticipantRequest{}))
			return err
		}},
		{"ListParticipants", false, func(s *Server, ctx context.Context) error {
			_, err := s.ListParticipants(ctx, connect.NewRequest(&beaconsv1.ListParticipantsRequest{}))
			return err
		}},
	}
}

// TestServer_FlagGateOnEveryRPC: all twelve BeaconService methods run the FEATURE_BEACONS gate first, in every flag mode,
// by class: the four write-class RPCs need the flag on for the caller, the eight read-class ones only not globally off.
// Past the gate a Server without a service answers Unimplemented; a request with no uid is Unauthenticated.
func TestServer_FlagGateOnEveryRPC(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	modes := []struct {
		name         string
		spec         flags.Spec
		uid          string
		wantOffWrite bool
		wantOffRead  bool
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off, Allowlist: allow}, "in", true, true},
		{"allowlist, listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false, false},
		{"allowlist, unlisted", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true, false},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, "in", true, false},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, "out", false, false},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, "out", false, false},
	}
	if n := len(allCalls()); n != 12 {
		t.Fatalf("matrix covers %d RPCs, want 12", n)
	}
	for _, rpc := range allCalls() {
		for _, m := range modes {
			t.Run(rpc.name+"/"+m.name, func(t *testing.T) {
				s := NewServer(flags.NewRegistry(m.spec), nil)
				ctx := authn.WithClaims(context.Background(), authn.Claims{UID: m.uid})
				err := rpc.call(s, ctx)
				wantOff := m.wantOffRead
				if rpc.write {
					wantOff = m.wantOffWrite
				}
				if wantOff {
					assertDisabled(t, err, FlagName)
					return
				}
				if connect.CodeOf(err) != connect.CodeUnimplemented {
					t.Fatalf("err = %v, want Unimplemented (flag passed, no service)", err)
				}
			})
		}
		t.Run(rpc.name+"/no uid", func(t *testing.T) {
			s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), nil)
			err := rpc.call(s, context.Background())
			var ce *connect.Error
			if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
				t.Fatalf("err = %v, want Unauthenticated", err)
			}
		})
	}
}

// TestServer_ImplementedRPCsReachTheService: with a service wired, the seven PR 2 RPCs forward the request and render
// the answer; the five participation RPCs stay Unimplemented.
func TestServer_ImplementedRPCsReachTheService(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), e.svc)
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: testViewer})
	res, err := s.GetBeacon(ctx, connect.NewRequest(&beaconsv1.GetBeaconRequest{BeaconId: testBeaconID}))
	if err != nil {
		t.Fatalf("GetBeacon: %v", err)
	}
	v := res.Msg.GetView()
	if v.GetBeacon().GetBeaconId() != testBeaconID || v.GetBeacon().GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN ||
		v.GetBeacon().GetActivity() != beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE || v.GetBeacon().GetOrganiser().GetUserId() != testOrganiser ||
		v.GetViewer().GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_NONE || !v.GetViewer().GetCanRequest() {
		t.Fatalf("view = %+v", v)
	}
	if got := v.GetBeacon().GetStartAt().AsTime(); !got.Equal(e.openBeacon().StartAt) {
		t.Fatalf("start_at = %v", got)
	}
	// CreateBeacon converts the enums and the timestamp, and VALIDATION names the field for an UNSPECIFIED enum.
	octx := authn.WithClaims(context.Background(), authn.Claims{UID: testOrganiser})
	_, err = s.CreateBeacon(octx, connect.NewRequest(&beaconsv1.CreateBeaconRequest{
		IdempotencyKey: testKey, Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Title: "Coffee", Venue: "Hall", StartAt: timestamppb.New(e.now.Add(time.Hour)), DurationMinutes: 25, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	assertValidation(t, err, "activity")
	created, err := s.CreateBeacon(octx, connect.NewRequest(&beaconsv1.CreateBeaconRequest{
		IdempotencyKey: testKey, Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_MEAL, Title: "Lunch", Venue: "Hall",
		StartAt: timestamppb.New(e.now.Add(time.Hour)), DurationMinutes: 25, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_SPLIT_EVENLY, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_OPEN_TO_CHAT,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	b := created.Msg.GetView().GetBeacon()
	if b.GetActivity() != beaconsv1.BeaconActivity_BEACON_ACTIVITY_MEAL || b.GetCost() != beaconsv1.BeaconCost_BEACON_COST_SPLIT_EVENLY ||
		b.GetChatPreference() != beaconsv1.ChatPreference_CHAT_PREFERENCE_OPEN_TO_CHAT || b.GetEligibility() != beaconsv1.BeaconEligibility_BEACON_ELIGIBILITY_EVERYONE ||
		created.Msg.GetView().GetViewer().GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_ORGANISER {
		t.Fatalf("created = %+v", b)
	}
	if p := e.repo.createdBy[0]; p.Beacon.Activity != ActivityMeal || p.Beacon.CommunityID != "" {
		t.Fatalf("params = %+v", p.Beacon)
	}
}

// TestServer_ParticipationRPCsReachTheService (PR 3): the seven participation and listing RPCs forward their fields and
// render the answers; the enum filters map to the service's inputs; an UNSPECIFIED response is VALIDATION "response".
func TestServer_ParticipationRPCsReachTheService(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	e.repo.docs[testBeaconID] = b
	e.repo.presult = ParticipantResult{Outcome: Written, Beacon: b, Participant: Participant{BeaconID: testBeaconID, UID: testViewer, State: PStateRequested, Note: "pls", RequestedAt: e.now}}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), e.svc)
	vctx := authn.WithClaims(context.Background(), authn.Claims{UID: testViewer})
	octx := authn.WithClaims(context.Background(), authn.Claims{UID: testOrganiser})

	req, err := s.RequestToJoin(vctx, connect.NewRequest(&beaconsv1.RequestToJoinRequest{IdempotencyKey: testKey, BeaconId: testBeaconID, Note: "pls"}))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if vs := req.Msg.GetViewer(); vs.GetParticipantState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED || !vs.GetCanWithdraw() || vs.GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_NONE {
		t.Fatalf("viewer = %+v", vs)
	}
	if p := e.repo.requestedBy[0]; p.Note != "pls" || p.UID != testViewer {
		t.Fatalf("request params = %+v", p)
	}
	if _, err := s.WithdrawJoinRequest(vctx, connect.NewRequest(&beaconsv1.WithdrawJoinRequestRequest{IdempotencyKey: testKey, BeaconId: testBeaconID})); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if _, err := s.LeaveBeacon(vctx, connect.NewRequest(&beaconsv1.LeaveBeaconRequest{IdempotencyKey: testKey, BeaconId: testBeaconID})); err != nil {
		t.Fatalf("Leave: %v", err)
	}
	_, err = s.RespondToJoinRequest(octx, connect.NewRequest(&beaconsv1.RespondToJoinRequestRequest{IdempotencyKey: testKey, BeaconId: testBeaconID, UserId: testViewer}))
	assertValidation(t, err, "response")
	resp, err := s.RespondToJoinRequest(octx, connect.NewRequest(&beaconsv1.RespondToJoinRequestRequest{IdempotencyKey: testKey, BeaconId: testBeaconID, UserId: testViewer, Response: beaconsv1.JoinResponse_JOIN_RESPONSE_DECLINE}))
	if err != nil || resp.Msg.GetView().GetViewer().GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_ORGANISER {
		t.Fatalf("Respond = %+v, %v", resp, err)
	}
	if p := e.repo.respondedBy[0]; p.Accept || p.TargetUID != testViewer {
		t.Fatalf("respond params = %+v", p)
	}
	if _, err := s.RemoveParticipant(octx, connect.NewRequest(&beaconsv1.RemoveParticipantRequest{IdempotencyKey: testKey, BeaconId: testBeaconID, UserId: testViewer})); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	// ListMyBeacons: role and window enums map to the service input; the page renders views and the token.
	e.repo.memberships = e.membershipsFor(testViewer, RoleRequester, PStateRequested, 2)
	mine, err := s.ListMyBeacons(vctx, connect.NewRequest(&beaconsv1.ListMyBeaconsRequest{Role: beaconsv1.MyBeaconsRole_MY_BEACONS_ROLE_PARTICIPANT, Window: beaconsv1.MyBeaconsWindow_MY_BEACONS_WINDOW_PAST, Limit: 1}))
	if err != nil {
		t.Fatalf("ListMyBeacons: %v", err)
	}
	if q := e.repo.mqueries[0]; fmt.Sprint(q.Roles) != fmt.Sprint([]string{RoleParticipant, RoleRequester}) || !q.Past {
		t.Fatalf("my query = %+v", q)
	}
	if len(mine.Msg.GetViews()) != 1 || mine.Msg.GetNextPageToken() == "" || mine.Msg.GetViews()[0].GetViewer().GetParticipantState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED {
		t.Fatalf("my page = %+v", mine.Msg)
	}

	// ListParticipants: the filter enum maps; rows carry the live user and the state; notes only on REQUESTED rows.
	e.repo.plist = []Participant{{BeaconID: testBeaconID, UID: "req-1", State: PStateRequested, Note: "pls", RequestedAt: e.now}}
	e.dir.profiles["req-1"] = activeProfile("req-1")
	parts, err := s.ListParticipants(octx, connect.NewRequest(&beaconsv1.ListParticipantsRequest{BeaconId: testBeaconID, Filter: beaconsv1.ParticipantFilter_PARTICIPANT_FILTER_REQUESTED}))
	if err != nil {
		t.Fatalf("ListParticipants: %v", err)
	}
	rows := parts.Msg.GetParticipants()
	if len(rows) != 1 || rows[0].GetUser().GetUserId() != "req-1" || rows[0].GetState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED || rows[0].GetNote() != "pls" || !rows[0].GetSince().AsTime().Equal(e.now) {
		t.Fatalf("rows = %+v", rows)
	}
	if q := e.repo.pqueries[0]; q.State != PStateRequested {
		t.Fatalf("participants query = %+v", q)
	}
}

// TestToView_RendersHiddenOnlyForOrganiser: the organiser's own view carries hidden; the converter never invents it.
func TestToView_RendersHiddenOnlyForOrganiser(t *testing.T) {
	b := Beacon{ID: testBeaconID, Hidden: true, Status: StatusFull, StartAt: testNow, EndAt: testNow.Add(time.Hour), CreatedAt: testNow, UpdatedAt: testNow}
	v := toView(View{Beacon: b, Organiser: identity.Profile{UserID: testOrganiser, Handle: "h", AvatarThumbURL: "t"}, Viewer: ViewerState{Role: RoleOrganiser, CanManage: true}})
	if !v.GetBeacon().GetHidden() || v.GetBeacon().GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_FULL || v.GetBeacon().GetOrganiser().GetAvatarUrl() != "t" || !v.GetViewer().GetCanManage() {
		t.Fatalf("view = %+v", v)
	}
}
