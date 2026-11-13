package beacons

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// quickJoinEnv is newEnv with an OPEN public beacon by testOrganiser, a Written request result and FEATURE_BEACONS on.
// quick sets FEATURE_BEACON_QUICK_JOIN; follows puts testViewer in the organiser's following set.
func quickJoinEnv(quick, follows bool) *env {
	e := newEnv()
	b := e.openBeacon()
	e.repo.docs[testBeaconID] = b
	e.repo.presult = ParticipantResult{Outcome: Written, Beacon: b, Participant: Participant{BeaconID: testBeaconID, UID: testViewer, State: PStateRequested}}
	e.flags.on[FlagName] = true
	e.flags.on[QuickJoinFlagName] = quick
	if follows {
		e.graph.snaps[testOrganiser] = graph.Snapshot{Following: map[string]bool{testViewer: true}}
	}
	return e
}

// TestRequestToJoin_QuickJoinMatrix: flag on/off x organiser follows or not x empty, whitespace-only or real note. Only
// flag on + not followed + empty (after trim) is refused, FAILED_PRECONDITION note_required, with nothing written; the
// organiser's graph is read only for an empty note under the flag (one read), never with the flag off.
func TestRequestToJoin_QuickJoinMatrix(t *testing.T) {
	notes := []struct {
		name, note string
		empty      bool
	}{
		{"empty", "", true},
		{"spaces", "   ", true},
		{"nbsp and spaces", "   ", true},
		{"note", "  count me in  ", false},
	}
	for _, quick := range []bool{false, true} {
		for _, follows := range []bool{false, true} {
			for _, n := range notes {
				name := fmt.Sprintf("flag=%v/follows=%v/%s", quick, follows, n.name)
				t.Run(name, func(t *testing.T) {
					e := quickJoinEnv(quick, follows)
					vs, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, n.note)
					wantRefused := quick && !follows && n.empty
					if wantRefused {
						assertPrecondition(t, err, "note_required")
						var ae *apierr.Error
						if errors.As(err, &ae) && ae.Code != connect.CodeFailedPrecondition {
							t.Fatalf("code = %v", ae.Code)
						}
						if len(e.repo.requestedBy) != 0 || len(e.events.requested) != 0 {
							t.Fatalf("refused request was written (%d) or notified (%d)", len(e.repo.requestedBy), len(e.events.requested))
						}
					} else {
						if err != nil {
							t.Fatalf("RequestToJoin: %v", err)
						}
						if len(e.repo.requestedBy) != 1 || vs.ParticipantState != PStateRequested {
							t.Fatalf("writes = %d, viewer = %+v", len(e.repo.requestedBy), vs)
						}
						if n.empty && e.repo.requestedBy[0].Note != "" {
							t.Fatalf("note = %q, want empty", e.repo.requestedBy[0].Note)
						}
					}
					wantReads := 0
					if quick && n.empty {
						wantReads = 1
					}
					if got := e.graph.readsOf(testOrganiser); got != wantReads {
						t.Fatalf("organiser graph reads = %d, want %d", got, wantReads)
					}
					if vs.QuickJoinAllowed {
						t.Fatal("quick_join_allowed must stay false in the RequestToJoin answer")
					}
				})
			}
		}
	}
}

// TestRequestToJoin_QuickJoinEdges: a pending follow request is not a follow; a failed organiser graph read refuses the
// write (fail closed, not note_required); the repository's state verdicts keep their reasons over note_required; and a
// same-key retry of a committed one-tap join replays after the organiser unfollowed, without the follow check.
func TestRequestToJoin_QuickJoinEdges(t *testing.T) {
	t.Run("pending follow request is not a follow", func(t *testing.T) {
		e := quickJoinEnv(true, false)
		e.graph.snaps[testOrganiser] = graph.Snapshot{Requested: map[string]bool{testViewer: true}}
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		assertPrecondition(t, err, "note_required")
	})
	t.Run("viewer following the organiser is not enough", func(t *testing.T) {
		e := quickJoinEnv(true, false)
		e.graph.snaps[testViewer] = graph.Snapshot{Following: map[string]bool{testOrganiser: true}}
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		assertPrecondition(t, err, "note_required")
	})
	t.Run("graph read failure fails closed", func(t *testing.T) {
		e := quickJoinEnv(true, true)
		e.graph.errs = map[string]error{testOrganiser: errors.New("boom")}
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		var ae *apierr.Error
		if err == nil || (errors.As(err, &ae) && ae.Metadata["reason"] == "note_required") {
			t.Fatalf("err = %v, want an internal error", err)
		}
		if len(e.repo.requestedBy) != 0 {
			t.Fatal("written after a failed follow check")
		}
	})
	for _, tc := range []struct {
		repoE  error
		reason string
	}{{ErrFull, "full"}, {ErrAlreadyRequested, "already_requested"}, {ErrCancelled, "cancelled"}} {
		t.Run("state verdict "+tc.reason+" wins", func(t *testing.T) {
			e := quickJoinEnv(true, false)
			e.repo.perr = tc.repoE
			_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
			assertPrecondition(t, err, tc.reason)
			if e.repo.prechecks != 0 {
				t.Fatal("follow check ran before the state verdict")
			}
		})
	}
	t.Run("replay after unfollow", func(t *testing.T) {
		e := quickJoinEnv(true, true)
		if _, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, ""); err != nil {
			t.Fatalf("first: %v", err)
		}
		e.graph.snaps[testOrganiser] = graph.Snapshot{}
		vs, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, " ")
		if err != nil {
			t.Fatalf("replay: %v", err)
		}
		if vs.ParticipantState != PStateRequested || e.repo.prechecks != 1 {
			t.Fatalf("viewer = %+v, prechecks = %d, want a replay without a second check", vs, e.repo.prechecks)
		}
		// A new key is a new request: the follow is checked again and is gone.
		_, err = e.svc.RequestToJoin(context.Background(), testViewer, "fedcba9876543210fedc", testBeaconID, "")
		assertPrecondition(t, err, "note_required")
	})
}

// TestGetBeacon_QuickJoinAllowed: true only with FEATURE_BEACONS and FEATURE_BEACON_QUICK_JOIN on for the viewer, a
// beacon the viewer may request and an organiser who follows the viewer; the organiser's graph is read only when the
// rest holds, and a failed read is false, not an error.
func TestGetBeacon_QuickJoinAllowed(t *testing.T) {
	for _, tc := range []struct {
		name      string
		quick     bool
		follows   bool
		setup     func(e *env)
		viewer    string
		want      bool
		wantReads int
	}{
		{name: "followed", quick: true, follows: true, want: true, wantReads: 1},
		{name: "not followed", quick: true, wantReads: 1},
		{name: "flag off", follows: true},
		{name: "beacons off for the caller", quick: true, follows: true, setup: func(e *env) { e.flags.on[FlagName] = false }},
		{name: "pending follow request", quick: true, wantReads: 1, setup: func(e *env) {
			e.graph.snaps[testOrganiser] = graph.Snapshot{Requested: map[string]bool{testViewer: true}}
		}},
		{name: "full", quick: true, follows: true, setup: func(e *env) {
			b := e.openBeacon()
			b.Status = StatusFull
			e.repo.docs[testBeaconID] = b
		}},
		{name: "already requested", quick: true, follows: true, setup: func(e *env) {
			e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateRequested}}
		}},
		{name: "accepted", quick: true, follows: true, setup: func(e *env) {
			e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateAccepted}}
		}},
		{name: "declined may request again", quick: true, follows: true, want: true, wantReads: 1, setup: func(e *env) {
			e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateDeclined}}
		}},
		{name: "organiser", quick: true, viewer: testOrganiser},
		{name: "graph failure is false", quick: true, follows: true, wantReads: 1, setup: func(e *env) {
			e.graph.errs = map[string]error{testOrganiser: errors.New("boom")}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := quickJoinEnv(tc.quick, tc.follows)
			if tc.setup != nil {
				tc.setup(e)
			}
			viewer := tc.viewer
			if viewer == "" {
				viewer = testViewer
			}
			v, err := e.svc.GetBeacon(context.Background(), viewer, testBeaconID)
			if err != nil {
				t.Fatalf("GetBeacon: %v", err)
			}
			if v.Viewer.QuickJoinAllowed != tc.want {
				t.Fatalf("quick_join_allowed = %v, want %v (viewer %+v)", v.Viewer.QuickJoinAllowed, tc.want, v.Viewer)
			}
			if viewer != testOrganiser {
				if got := e.graph.readsOf(testOrganiser); got != tc.wantReads {
					t.Fatalf("organiser graph reads = %d, want %d", got, tc.wantReads)
				}
			}
			if pb := toViewerState(v.Viewer); pb.GetQuickJoinAllowed() != tc.want {
				t.Fatalf("proto quick_join_allowed = %v", pb.GetQuickJoinAllowed())
			}
		})
	}
}

// TestListBeacons_QuickJoinStaysFalse: list rows never compute the field (no per-row organiser graph read).
func TestListBeacons_QuickJoinStaysFalse(t *testing.T) {
	e := quickJoinEnv(true, true)
	e.repo.rows = []Beacon{e.repo.docs[testBeaconID]}
	page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true})
	if err != nil {
		t.Fatalf("ListBeacons: %v", err)
	}
	if len(page.Views) != 1 {
		t.Fatalf("views = %d", len(page.Views))
	}
	if page.Views[0].Viewer.QuickJoinAllowed || !page.Views[0].Viewer.CanRequest {
		t.Fatalf("viewer = %+v, want can_request without quick_join_allowed", page.Views[0].Viewer)
	}
	if got := e.graph.readsOf(testOrganiser); got != 0 {
		t.Fatalf("organiser graph reads = %d, want 0", got)
	}
}
