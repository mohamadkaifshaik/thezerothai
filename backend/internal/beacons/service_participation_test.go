package beacons

import (
	"context"
	"errors"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// TestParticipation_ValidationBeforeReads: key, beacon_id, note and user_id are checked before any read, per RPC.
func TestParticipation_ValidationBeforeReads(t *testing.T) {
	long := strings.Repeat("n", 141)
	cases := []struct {
		name  string
		call  func(e *env) error
		field string
	}{
		{"request key", func(e *env) error {
			_, err := e.svc.RequestToJoin(context.Background(), testViewer, "short", testBeaconID, "")
			return err
		}, "idempotency_key"},
		{"request id", func(e *env) error {
			_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, "x", "")
			return err
		}, "beacon_id"},
		{"request note", func(e *env) error {
			_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, long)
			return err
		}, "note"},
		{"withdraw id", func(e *env) error { return e.svc.WithdrawJoinRequest(context.Background(), testViewer, testKey, "x") }, "beacon_id"},
		{"respond user", func(e *env) error {
			_, err := e.svc.RespondToJoinRequest(context.Background(), testOrganiser, testKey, testBeaconID, "", true)
			return err
		}, "user_id"},
		{"leave key", func(e *env) error { return e.svc.LeaveBeacon(context.Background(), testViewer, "short", testBeaconID) }, "idempotency_key"},
		{"remove user", func(e *env) error {
			_, err := e.svc.RemoveParticipant(context.Background(), testOrganiser, testKey, testBeaconID, "bad id")
			return err
		}, "user_id"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			assertValidation(t, tc.call(e), tc.field)
			if e.repo.calls() != 0 || e.dir.calls != 0 || e.comm.calls != 0 {
				t.Fatalf("reads before validation: repo %d dir %d comm %d", e.repo.calls(), e.dir.calls, e.comm.calls)
			}
		})
	}
}

// TestRequestToJoin_RulesAndState: visibility first (hidden/blocked NOT_FOUND, non-member FORBIDDEN), the organiser is
// refused before the repository, the repository gets the normalised note, the cap and the clock, and the answer is the
// caller's new viewer state.
func TestRequestToJoin_RulesAndState(t *testing.T) {
	t.Run("hidden is not found", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		b.Hidden = true
		e.repo.docs[testBeaconID] = b
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		assertNotFound(t, err)
	})
	t.Run("blocked is not found", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		assertNotFound(t, err)
	})
	t.Run("community non-member is forbidden", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		b.CommunityID = testCommunity
		e.repo.docs[testBeaconID] = b
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		assertForbidden(t, err, "not_member")
		if e.repo.calls() != 0 {
			t.Fatal("repository called for a non-member")
		}
	})
	t.Run("organiser cannot join", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		_, err := e.svc.RequestToJoin(context.Background(), testOrganiser, testKey, testBeaconID, "")
		assertPrecondition(t, err, "organiser")
		if len(e.repo.requestedBy) != 0 {
			t.Fatal("repository Request called for the organiser")
		}
	})
	t.Run("params and state", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		e.repo.docs[testBeaconID] = b
		e.repo.presult = ParticipantResult{Outcome: Written, Beacon: b, Participant: Participant{BeaconID: testBeaconID, UID: testViewer, State: PStateRequested}}
		vs, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "  hi  ")
		if err != nil {
			t.Fatalf("RequestToJoin: %v", err)
		}
		p := e.repo.requestedBy[0]
		if p.UID != testViewer || p.BeaconID != testBeaconID || p.Note != "hi" || p.MaxPending != 10 || !p.Now.Equal(e.now) || p.IdemKey != idempotency.Key(testViewer, rpcRequestToJoin, testKey) {
			t.Fatalf("params = %+v", p)
		}
		if vs.Role != RoleNone || vs.ParticipantState != PStateRequested || !vs.CanWithdraw || vs.CanRequest || vs.CanLeave {
			t.Fatalf("viewer state = %+v", vs)
		}
	})
	for _, tc := range []struct {
		name   string
		repoE  error
		reason string
	}{
		{"full", ErrFull, "full"},
		{"already requested", ErrAlreadyRequested, "already_requested"},
		{"ended", ErrEnded, "ended"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.perr = tc.repoE
			_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
			assertPrecondition(t, err, tc.reason)
		})
	}
	t.Run("pending cap is LIMIT_REACHED", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.perr = ErrPendingLimit
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED || ae.Metadata["limit"] != "beacon_requests_pending" {
			t.Fatalf("err = %v, want LIMIT_REACHED limit=beacon_requests_pending", err)
		}
	})
}

// TestWithdrawAndLeave_PassParams: the caller acts on their own row; the repository's verdicts map to reasons.
func TestWithdrawAndLeave_PassParams(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	e.repo.presult = ParticipantResult{Outcome: Written, Beacon: e.openBeacon()}
	if err := e.svc.WithdrawJoinRequest(context.Background(), testViewer, testKey, testBeaconID); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if err := e.svc.LeaveBeacon(context.Background(), testViewer, testKey, testBeaconID); err != nil {
		t.Fatalf("Leave: %v", err)
	}
	w, l := e.repo.transitioned[0], e.repo.transitioned[1]
	if w.UID != testViewer || w.TargetUID != testViewer || w.IdemKey != idempotency.Key(testViewer, rpcWithdrawJoinRequest, testKey) || !w.Now.Equal(e.now) {
		t.Fatalf("withdraw params = %+v", w)
	}
	if l.TargetUID != testViewer || l.IdemKey != idempotency.Key(testViewer, rpcLeaveBeacon, testKey) {
		t.Fatalf("leave params = %+v", l)
	}
	e.repo.perr = ErrNotRequested
	assertPrecondition(t, e.svc.WithdrawJoinRequest(context.Background(), testViewer, testKey, testBeaconID), "not_requested")
	e.repo.perr = ErrNotParticipant
	assertPrecondition(t, e.svc.LeaveBeacon(context.Background(), testViewer, testKey, testBeaconID), "not_participant")
	e.repo.perr = nil
	e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
	assertNotFound(t, e.svc.LeaveBeacon(context.Background(), testViewer, testKey, testBeaconID))
}

// TestRespondAndRemove_OrganiserOnly: visibility and the organiser check come first; the organiser's answer is the view
// with the updated beacon.
func TestRespondAndRemove_OrganiserOnly(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	if _, err := e.svc.RespondToJoinRequest(context.Background(), testViewer, testKey, testBeaconID, "p1", true); err == nil {
		t.Fatal("a stranger could respond")
	} else {
		assertForbidden(t, err, "not_organiser")
	}
	if _, err := e.svc.RemoveParticipant(context.Background(), testViewer, testKey, testBeaconID, "p1"); err == nil {
		t.Fatal("a stranger could remove")
	} else {
		assertForbidden(t, err, "not_organiser")
	}
	if len(e.repo.respondedBy)+len(e.repo.transitioned) != 0 {
		t.Fatal("repository called for a stranger")
	}
	full := e.openBeacon()
	full.AcceptedCount, full.Status = 3, StatusFull
	e.repo.presult = ParticipantResult{Outcome: Written, Beacon: full, Participant: Participant{UID: "p1", State: PStateAccepted}}
	v, err := e.svc.RespondToJoinRequest(context.Background(), testOrganiser, testKey, testBeaconID, "p1", true)
	if err != nil {
		t.Fatalf("Respond: %v", err)
	}
	r := e.repo.respondedBy[0]
	if r.UID != testOrganiser || r.TargetUID != "p1" || !r.Accept || r.IdemKey != idempotency.Key(testOrganiser, rpcRespondToJoinRequest, testKey) || !r.Now.Equal(e.now) {
		t.Fatalf("respond params = %+v", r)
	}
	if v.Beacon.Status != StatusFull || v.Beacon.AcceptedCount != 3 || v.Viewer.Role != RoleOrganiser || v.Organiser.UserID != testOrganiser {
		t.Fatalf("view = %+v", v)
	}
	if _, err := e.svc.RemoveParticipant(context.Background(), testOrganiser, testKey, testBeaconID, "p1"); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	rm := e.repo.transitioned[0]
	if rm.UID != testOrganiser || rm.TargetUID != "p1" || rm.IdemKey != idempotency.Key(testOrganiser, rpcRemoveParticipant, testKey) {
		t.Fatalf("remove params = %+v", rm)
	}
	e.repo.perr = ErrNotRequested
	if _, err := e.svc.RespondToJoinRequest(context.Background(), testOrganiser, testKey, testBeaconID, "p1", false); err == nil {
		t.Fatal("not_requested not mapped")
	} else {
		assertPrecondition(t, err, "not_requested")
	}
}

// TestGetBeacon_ViewerStateFromParticipantRow: a non-organiser's row decides the state and the actions.
func TestGetBeacon_ViewerStateFromParticipantRow(t *testing.T) {
	for _, tc := range []struct {
		state string
		want  ViewerState
	}{
		{PStateAccepted, ViewerState{Role: RoleParticipant, ParticipantState: PStateAccepted, CanLeave: true}},
		{PStateRequested, ViewerState{Role: RoleNone, ParticipantState: PStateRequested, CanWithdraw: true}},
		{PStateDeclined, ViewerState{Role: RoleNone, ParticipantState: PStateDeclined, CanRequest: true}},
		{PStateLeft, ViewerState{Role: RoleNone, ParticipantState: PStateLeft, CanRequest: true}},
	} {
		t.Run(tc.state, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {BeaconID: testBeaconID, UID: testViewer, State: tc.state}}
			v, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
			if err != nil {
				t.Fatal(err)
			}
			if v.Viewer != tc.want {
				t.Fatalf("viewer = %+v, want %+v", v.Viewer, tc.want)
			}
		})
	}
	t.Run("requested on an ended beacon can still withdraw", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		e.repo.docs[testBeaconID] = b
		e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateRequested}}
		e.now = b.EndAt
		v, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		if err != nil || !v.Viewer.CanWithdraw || v.Viewer.CanRequest {
			t.Fatalf("viewer = %+v, %v, want can_withdraw on an ended beacon", v.Viewer, err)
		}
	})
	t.Run("accepted on an ended beacon cannot leave", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		e.repo.docs[testBeaconID] = b
		e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateAccepted}}
		e.now = b.EndAt
		v, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		if err != nil || v.Viewer.CanLeave || v.Viewer.Role != RoleParticipant {
			t.Fatalf("viewer = %+v, %v", v.Viewer, err)
		}
	})
}

// TestResolve_BlockBeforeMembership (R15): a blocked viewer of a community beacon gets NOT_FOUND without a role lookup.
func TestResolve_BlockBeforeMembership(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	b.CommunityID = testCommunity
	e.repo.docs[testBeaconID] = b
	e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleNone
	e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}
	_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
	assertNotFound(t, err)
	if e.comm.calls != 0 {
		t.Fatalf("role looked up %d times for a blocked viewer", e.comm.calls)
	}
}
