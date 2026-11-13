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
// follow lookup runs only for an empty note under the flag (one call for the organiser), never with the flag off, and
// the organiser's whole graph doc is never read.
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
					wantLookups := 0
					if quick && n.empty {
						wantLookups = 1
					}
					if got := e.graph.lookupCount(); got != wantLookups {
						t.Fatalf("follow lookups = %d, want %d", got, wantLookups)
					}
					if wantLookups == 1 && (len(e.graph.lookups[0]) != 1 || e.graph.lookups[0][0] != testOrganiser) {
						t.Fatalf("lookup candidates = %v, want the organiser", e.graph.lookups[0])
					}
					if got := e.graph.readsOf(testOrganiser); got != 0 {
						t.Fatalf("organiser graph doc reads = %d, want 0", got)
					}
					if vs.QuickJoinAllowed {
						t.Fatal("quick_join_allowed must stay false in the RequestToJoin answer")
					}
				})
			}
		}
	}
}

// TestRequestToJoin_QuickJoinEdges: a pending follow request is not a follow; a failed follow lookup refuses the
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
	t.Run("lookup failure fails closed", func(t *testing.T) {
		e := quickJoinEnv(true, true)
		e.graph.lookupErr = errors.New("boom")
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
// beacon the viewer may request and an organiser who follows the viewer; the follow lookup runs only when the rest
// holds (one call), and a failed lookup is false, not an error.
func TestGetBeacon_QuickJoinAllowed(t *testing.T) {
	for _, tc := range []struct {
		name        string
		quick       bool
		follows     bool
		setup       func(e *env)
		viewer      string
		want        bool
		wantLookups int
	}{
		{name: "followed", quick: true, follows: true, want: true, wantLookups: 1},
		{name: "not followed", quick: true, wantLookups: 1},
		{name: "flag off", follows: true},
		{name: "beacons off for the caller", quick: true, follows: true, setup: func(e *env) { e.flags.on[FlagName] = false }},
		{name: "no lookup wired", quick: true, follows: true, setup: func(e *env) { e.svc = e.rebuild(func(d *Deps) { d.Follows = nil }) }},
		{name: "pending follow request", quick: true, wantLookups: 1, setup: func(e *env) {
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
		{name: "declined may request again", quick: true, follows: true, want: true, wantLookups: 1, setup: func(e *env) {
			e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, testViewer): {State: PStateDeclined}}
		}},
		{name: "organiser", quick: true, viewer: testOrganiser},
		{name: "lookup failure is false", quick: true, follows: true, wantLookups: 1, setup: func(e *env) {
			e.graph.lookupErr = errors.New("boom")
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
			if got := e.graph.lookupCount(); got != tc.wantLookups {
				t.Fatalf("follow lookups = %d, want %d", got, tc.wantLookups)
			}
			if pb := toViewerState(v.Viewer); pb.GetQuickJoinAllowed() != tc.want {
				t.Fatalf("proto quick_join_allowed = %v", pb.GetQuickJoinAllowed())
			}
		})
	}
}

// listPage seeds a ListBeacons page for testViewer over several organisers: org-1 follows the viewer (two plans, one
// FULL), org-2 does not, org-3 follows the viewer but the viewer already requested its plan, and one plan is the
// viewer's own. Every organiser is ACTIVE.
func listPage(e *env) {
	mk := func(id, org string, status Status) Beacon {
		b := e.openBeacon()
		b.ID, b.OrganiserID, b.Status = id, org, status
		return b
	}
	for _, u := range []string{"org-2", "org-3"} {
		e.dir.profiles[u] = activeProfile(u)
	}
	e.graph.snaps[testOrganiser] = graph.Snapshot{Following: map[string]bool{testViewer: true}}
	e.graph.snaps["org-3"] = graph.Snapshot{Following: map[string]bool{testViewer: true}}
	e.repo.rows = []Beacon{
		mk("0000000000000000101", testOrganiser, StatusOpen),
		mk("0000000000000000102", testOrganiser, StatusFull),
		mk("0000000000000000103", "org-2", StatusOpen),
		mk("0000000000000000104", "org-3", StatusOpen),
		mk("0000000000000000105", testViewer, StatusOpen),
	}
	e.repo.participants = map[string]Participant{e.repo.pkey("0000000000000000104", testViewer): {State: PStateRequested}}
}

// TestListBeacons_QuickJoinBatched: one follow lookup per page, holding only the distinct organisers of the rows the
// viewer may request (never the viewer, never a FULL-only or already-requested organiser); each row is marked from it.
// Flag off, beacons off for the caller, or no lookup wired: zero lookups and every row false. A failed lookup: every row
// false, the page still answers.
func TestListBeacons_QuickJoinBatched(t *testing.T) {
	for _, tc := range []struct {
		name        string
		setup       func(e *env)
		wantLookups int
		wantTrue    map[string]bool
	}{
		{name: "mixed organisers", wantLookups: 1, wantTrue: map[string]bool{"0000000000000000101": true}},
		{name: "flag off", setup: func(e *env) { e.flags.on[QuickJoinFlagName] = false }},
		{name: "beacons off for the caller", setup: func(e *env) { e.flags.on[FlagName] = false }},
		{name: "no lookup wired", setup: func(e *env) { e.svc = e.rebuild(func(d *Deps) { d.Follows = nil }) }},
		{name: "lookup failure", wantLookups: 1, setup: func(e *env) { e.graph.lookupErr = errors.New("boom") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := quickJoinEnv(true, false)
			listPage(e)
			if tc.setup != nil {
				tc.setup(e)
			}
			page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true})
			if err != nil {
				t.Fatalf("ListBeacons: %v", err)
			}
			if len(page.Views) != 5 {
				t.Fatalf("views = %d, want 5", len(page.Views))
			}
			for _, v := range page.Views {
				if v.Viewer.QuickJoinAllowed != tc.wantTrue[v.Beacon.ID] {
					t.Errorf("%s (organiser %s) quick_join_allowed = %v", v.Beacon.ID, v.Beacon.OrganiserID, v.Viewer.QuickJoinAllowed)
				}
			}
			if got := e.graph.lookupCount(); got != tc.wantLookups {
				t.Fatalf("follow lookups = %d, want %d", got, tc.wantLookups)
			}
			if tc.wantLookups == 1 {
				got := e.graph.lookups[0]
				if len(got) != 2 || got[0] != testOrganiser || got[1] != "org-2" {
					t.Fatalf("lookup candidates = %v, want [org-1 org-2]", got)
				}
			}
			for _, u := range []string{testOrganiser, "org-2", "org-3"} {
				if e.graph.readsOf(u) != 0 {
					t.Fatalf("graph doc of %s read", u)
				}
			}
		})
	}
}

// TestMarkQuickJoin_NoRequestableRow: rows the viewer cannot request (organised, accepted, requested: the shape of
// ListMyBeacons and ListSharedBeacons pages) cost no lookup and stay false.
func TestMarkQuickJoin_NoRequestableRow(t *testing.T) {
	e := quickJoinEnv(true, true)
	s := e.svc.(*service)
	b := e.openBeacon()
	views := []View{
		{Beacon: b, Viewer: ViewerState{Role: RoleParticipant, ParticipantState: PStateAccepted, CanLeave: true}},
		{Beacon: b, Viewer: ViewerState{Role: RoleNone, ParticipantState: PStateRequested, CanWithdraw: true}},
		{Beacon: Beacon{ID: "0000000000000000201", OrganiserID: testViewer}, Viewer: ViewerState{Role: RoleOrganiser, CanManage: true}},
	}
	s.markQuickJoin(context.Background(), testViewer, views)
	for _, v := range views {
		if v.Viewer.QuickJoinAllowed {
			t.Fatalf("row marked: %+v", v.Viewer)
		}
	}
	if got := e.graph.lookupCount(); got != 0 {
		t.Fatalf("follow lookups = %d, want 0", got)
	}
}
