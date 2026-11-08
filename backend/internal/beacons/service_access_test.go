package beacons

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// The access-policy tests of the 7-11-2026 review (B01-B06, D01): community verdicts on every path that renders a
// community beacon, community status, blockedBy overflow, accept eligibility, the light leave gate, list viewer state
// and the roster's peer blocks.

func assertArchived(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE ||
		ae.Metadata["reason"] != string(communities.StateArchived) {
		t.Fatalf("err = %v, want FAILED_PRECONDITION COMMUNITY_STATE reason=community_archived", err)
	}
}

// communityBeacon stores the default beacon in testCommunity.
func (e *env) communityBeacon() Beacon {
	b := e.openBeacon()
	b.CommunityID = testCommunity
	e.repo.docs[testBeaconID] = b
	return b
}

// TestCommunityStatus (B02): SUSPENDED is the one NOT_FOUND to everyone but the community owner on reads and to everyone
// on writes; ARCHIVED reads but refuses create, request and accept; a restored (ACTIVE) community answers normally; the
// organiser can still cancel in either state.
func TestCommunityStatus(t *testing.T) {
	ctx := context.Background()
	get := func(e *env) error { _, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID); return err }
	request := func(e *env) error {
		_, err := e.svc.RequestToJoin(ctx, testViewer, testKey, testBeaconID, "")
		return err
	}
	create := func(e *env) error {
		in := validCreate()
		in.Public, in.CommunityID = false, testCommunity
		e.flags.on[FlagName] = true
		_, err := e.svc.CreateBeacon(ctx, testViewer, in)
		return err
	}
	list := func(e *env) error {
		_, err := e.svc.ListBeacons(ctx, testViewer, ListInput{CommunityID: testCommunity})
		return err
	}
	for _, tc := range []struct {
		name   string
		status communities.Status
		role   communities.Role
		call   func(*env) error
		want   string // "" ok, "not_found", "archived", "not_member"
	}{
		{"suspended member get", communities.StatusSuspended, communities.RoleMember, get, "not_found"},
		{"suspended moderator get", communities.StatusSuspended, communities.RoleModerator, get, "not_found"},
		{"suspended owner get", communities.StatusSuspended, communities.RoleOwner, get, ""},
		{"suspended member list", communities.StatusSuspended, communities.RoleMember, list, "not_found"},
		{"suspended owner list", communities.StatusSuspended, communities.RoleOwner, list, ""},
		{"suspended non-member get", communities.StatusSuspended, communities.RoleNone, get, "not_found"},
		{"suspended member request", communities.StatusSuspended, communities.RoleMember, request, "not_found"},
		{"suspended owner request", communities.StatusSuspended, communities.RoleOwner, request, "not_found"},
		{"suspended member create", communities.StatusSuspended, communities.RoleMember, create, "not_found"},
		{"archived member get", communities.StatusArchived, communities.RoleMember, get, ""},
		{"archived member list", communities.StatusArchived, communities.RoleMember, list, ""},
		{"archived member request", communities.StatusArchived, communities.RoleMember, request, "archived"},
		{"archived member create", communities.StatusArchived, communities.RoleMember, create, "archived"},
		{"archived non-member get", communities.StatusArchived, communities.RoleNone, get, "not_member"},
		{"restored member request", communities.StatusActive, communities.RoleMember, request, ""},
		{"restored member create", communities.StatusActive, communities.RoleMember, create, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.communityBeacon()
			e.comm.status = map[string]communities.Status{testCommunity: tc.status}
			e.comm.roles[testCommunity+"|"+testViewer] = tc.role
			e.repo.presult = ParticipantResult{Outcome: Written, Beacon: b, Participant: Participant{State: PStateRequested}}
			err := tc.call(e)
			switch tc.want {
			case "":
				if err != nil {
					t.Fatalf("err = %v, want success", err)
				}
			case "not_found":
				assertNotFound(t, err)
			case "archived":
				assertArchived(t, err)
			case "not_member":
				assertForbidden(t, err, "not_member")
			}
			if tc.want != "" && len(e.repo.requestedBy)+len(e.repo.createdBy) != 0 {
				t.Fatal("repository written after a refusal")
			}
		})
	}
	for _, st := range []communities.Status{communities.StatusSuspended, communities.StatusArchived} {
		t.Run(fmt.Sprintf("organiser cancels in %s", st), func(t *testing.T) {
			e := newEnv()
			b := e.communityBeacon()
			e.comm.status = map[string]communities.Status{testCommunity: st}
			e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
			if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatalf("CancelBeacon: %v", err)
			}
			if len(e.repo.cancelledBy) != 1 {
				t.Fatal("cancel not written")
			}
		})
	}
	t.Run("community read failure is not a refusal", func(t *testing.T) {
		e := newEnv()
		e.communityBeacon()
		e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		e.comm.getErr = errors.New("boom")
		_, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID)
		var ae *apierr.Error
		if err == nil || (errors.As(err, &ae) && ae.Code == connect.CodeNotFound) {
			t.Fatalf("err = %v, want an internal error", err)
		}
	})
}

// TestListMyBeacons_CommunityVerdict (B01): a non-organiser row of a community beacon needs the same verdict as
// GetBeacon (JOINED, community not suspended, FEATURE_COMMUNITIES not globally off), computed once per community on the
// page; the organiser's own rows stay so they can cancel; the token comes from the raw rows.
func TestListMyBeacons_CommunityVerdict(t *testing.T) {
	const (
		joined    = "1000000000000000001"
		left      = "1000000000000000002"
		banned    = "1000000000000000003"
		missing   = "1000000000000000004"
		suspended = "1000000000000000005"
	)
	setup := func() (*env, []Membership) {
		e := newEnv()
		rows := e.membershipsFor(testViewer, RoleParticipant, PStateAccepted, 9)
		cids := []string{joined, joined, left, banned, missing, suspended, "", left}
		for i, cid := range cids {
			b := e.repo.docs[rows[i].BeaconID]
			b.CommunityID = cid
			e.repo.docs[b.ID] = b
			rows[i].CommunityID = cid
		}
		// row 7 is the caller's own beacon in the community they left
		ob := e.repo.docs[rows[7].BeaconID]
		ob.OrganiserID = testViewer
		e.repo.docs[ob.ID] = ob
		e.dir.profiles[testViewer] = activeProfile(testViewer)
		rows[7].Role, rows[7].State = RoleOrganiser, string(StatusOpen)
		e.comm.roles[joined+"|"+testViewer] = communities.RoleMember
		e.comm.roles[banned+"|"+testViewer] = communities.RoleBanned
		e.comm.roles[suspended+"|"+testViewer] = communities.RoleMember
		e.comm.missing = map[string]bool{missing: true}
		e.comm.status = map[string]communities.Status{suspended: communities.StatusSuspended}
		e.repo.memberships = rows
		return e, rows
	}
	t.Run("verdict per row", func(t *testing.T) {
		e, rows := setup()
		page, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 8})
		if err != nil {
			t.Fatal(err)
		}
		want := []string{rows[0].BeaconID, rows[1].BeaconID, rows[6].BeaconID, rows[7].BeaconID}
		if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("views = %v, want joined x2, public, own", got)
		}
		if page.NextPageToken == "" {
			t.Fatal("token missing: 9 raw rows for a page of 8")
		}
		if e.comm.gets[joined] != 1 || e.comm.gets[left] > 1 {
			t.Fatalf("community reads = %v, want one per community", e.comm.gets)
		}
		for _, v := range page.Views {
			if v.Beacon.ID == rows[7].BeaconID && v.Viewer.Role != RoleOrganiser {
				t.Fatalf("own row = %+v, want organiser", v.Viewer)
			}
		}
	})
	t.Run("communities globally off", func(t *testing.T) {
		e, rows := setup()
		e.flags.off[communities.FlagName] = true
		page, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 8})
		if err != nil {
			t.Fatal(err)
		}
		want := []string{rows[6].BeaconID, rows[7].BeaconID}
		if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("views = %v, want public and own only", got)
		}
	})
	t.Run("community read failure fails the page", func(t *testing.T) {
		e, _ := setup()
		e.comm.getErr = errors.New("boom")
		if _, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 8}); err == nil {
			t.Fatal("a failed community read rendered rows")
		}
	})
}

// overflowEnv is an env whose viewer's blockedBy overflowed.
func overflowEnv() *env {
	e := newEnv()
	e.graph.snaps[testViewer] = graph.Snapshot{BlockedByOverflow: true}
	return e
}

// TestBlockedByOverflow (B03): when the viewer's blockedBy overflowed, a block the organiser holds is read from the
// organiser's own graph (once per organiser per request); a failing read refuses (fail closed).
func TestBlockedByOverflow(t *testing.T) {
	ctx := context.Background()
	t.Run("get: hidden block", func(t *testing.T) {
		e := overflowEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.graph.snaps[testOrganiser] = graph.Snapshot{Blocked: map[string]bool{testViewer: true}}
		_, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID)
		assertNotFound(t, err)
	})
	t.Run("get: no block", func(t *testing.T) {
		e := overflowEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		if _, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID); err != nil {
			t.Fatal(err)
		}
		if e.graph.readsOf(testOrganiser) != 1 {
			t.Fatalf("organiser graph reads = %d, want 1", e.graph.readsOf(testOrganiser))
		}
	})
	t.Run("get: known block needs no fallback", func(t *testing.T) {
		e := overflowEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.graph.snaps[testViewer] = graph.Snapshot{BlockedByOverflow: true, BlockedBy: map[string]bool{testOrganiser: true}}
		assertNotFound(t, mustErr(e.svc.GetBeacon(ctx, testViewer, testBeaconID)))
		if e.graph.readsOf(testOrganiser) != 0 {
			t.Fatal("organiser graph read although the block was known")
		}
	})
	t.Run("get: failing fallback", func(t *testing.T) {
		e := overflowEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.graph.errs = map[string]error{testOrganiser: errors.New("boom")}
		if _, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID); err == nil {
			t.Fatal("rendered with a failed organiser graph read")
		}
	})
	t.Run("get: no overflow, no fallback", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		if _, err := e.svc.GetBeacon(ctx, testViewer, testBeaconID); err != nil {
			t.Fatal(err)
		}
		if e.graph.readsOf(testOrganiser) != 0 {
			t.Fatal("organiser graph read without overflow")
		}
	})
	t.Run("list beacons", func(t *testing.T) {
		e := overflowEnv()
		rows := e.rowsFrom(3)
		rows[1].OrganiserID = "org-0" // two rows by org-0: one graph read
		e.repo.rows = rows
		e.graph.snaps["org-2"] = graph.Snapshot{Blocked: map[string]bool{testViewer: true}}
		page, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Limit: 3})
		if err != nil {
			t.Fatal(err)
		}
		if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint([]string{rows[0].ID, rows[1].ID}) {
			t.Fatalf("views = %v, want org-2's row dropped", got)
		}
		if e.graph.readsOf("org-0") != 1 {
			t.Fatalf("org-0 graph reads = %d, want 1", e.graph.readsOf("org-0"))
		}
		e.graph.errs = map[string]error{"org-0": errors.New("boom")}
		if _, err := e.svc.ListBeacons(ctx, testViewer, ListInput{Public: true, Limit: 3}); err == nil {
			t.Fatal("list rendered with a failed organiser graph read")
		}
	})
	t.Run("list my beacons", func(t *testing.T) {
		e := overflowEnv()
		rows := e.membershipsFor(testViewer, RoleParticipant, PStateAccepted, 2)
		e.repo.memberships = rows
		e.graph.snaps["org-1"] = graph.Snapshot{Blocked: map[string]bool{testViewer: true}}
		page, err := e.svc.ListMyBeacons(ctx, testViewer, MyBeaconsInput{Limit: 5})
		if err != nil {
			t.Fatal(err)
		}
		if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint([]string{rows[0].BeaconID}) {
			t.Fatalf("views = %v, want org-1's row dropped", got)
		}
		e.graph.errs = map[string]error{"org-0": errors.New("boom")}
		if _, err := e.svc.ListMyBeacons(ctx, testViewer, MyBeaconsInput{Limit: 5}); err == nil {
			t.Fatal("list rendered with a failed organiser graph read")
		}
	})
}

// TestRespondAccept_TargetEligibility (B04): ACCEPT rechecks the target (ACTIVE profile, the community verdict, no block
// either way, overflow-aware) and refuses with not_requested, writing nothing; DECLINE and REMOVE stay unconditional.
func TestRespondAccept_TargetEligibility(t *testing.T) {
	const target = "p1"
	ctx := context.Background()
	for _, tc := range []struct {
		name  string
		setup func(e *env)
		want  string // "" accepted, "not_requested", "archived"
	}{
		{"eligible", func(*env) {}, ""},
		{"target gone", func(e *env) { delete(e.dir.profiles, target) }, "not_requested"},
		{"target suspended", func(e *env) {
			p := activeProfile(target)
			p.Status = identity.AccountStatusSuspended
			e.dir.profiles[target] = p
		}, "not_requested"},
		{"organiser blocks target", func(e *env) {
			e.graph.snaps[testOrganiser] = graph.Snapshot{Blocked: map[string]bool{target: true}}
		}, "not_requested"},
		{"target blocks organiser", func(e *env) {
			e.graph.snaps[testOrganiser] = graph.Snapshot{BlockedBy: map[string]bool{target: true}}
		}, "not_requested"},
		{"target blocks organiser past overflow", func(e *env) {
			e.graph.snaps[testOrganiser] = graph.Snapshot{BlockedByOverflow: true}
			e.graph.snaps[target] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
		}, "not_requested"},
		{"community: target joined", func(e *env) {
			e.communityBeacon()
			e.comm.roles[testCommunity+"|"+target] = communities.RoleMember
		}, ""},
		{"community: target left", func(e *env) { e.communityBeacon() }, "not_requested"},
		{"community: target banned", func(e *env) {
			e.communityBeacon()
			e.comm.roles[testCommunity+"|"+target] = communities.RoleBanned
		}, "not_requested"},
		{"community: archived", func(e *env) {
			e.communityBeacon()
			e.comm.roles[testCommunity+"|"+target] = communities.RoleMember
			e.comm.status = map[string]communities.Status{testCommunity: communities.StatusArchived}
		}, "archived"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.dir.profiles[target] = activeProfile(target)
			tc.setup(e)
			e.repo.presult = ParticipantResult{Outcome: Written, Beacon: e.repo.docs[testBeaconID], Participant: Participant{UID: target, State: PStateAccepted}}
			_, err := e.svc.RespondToJoinRequest(ctx, testOrganiser, testKey, testBeaconID, target, true)
			switch tc.want {
			case "":
				if err != nil || len(e.repo.respondedBy) != 1 {
					t.Fatalf("accept = %v, %d writes, want accepted", err, len(e.repo.respondedBy))
				}
				return
			case "archived":
				assertArchived(t, err)
			default:
				assertPrecondition(t, err, tc.want)
			}
			if len(e.repo.respondedBy) != 0 || len(e.events.accepted) != 0 {
				t.Fatal("an ineligible accept reached the repository")
			}
			// DECLINE and REMOVE are unconditional.
			if _, err := e.svc.RespondToJoinRequest(ctx, testOrganiser, "decline-key-0123456789", testBeaconID, target, false); err != nil {
				t.Fatalf("decline: %v", err)
			}
			if _, err := e.svc.RemoveParticipant(ctx, testOrganiser, "remove-key-0123456789", testBeaconID, target); err != nil {
				t.Fatalf("remove: %v", err)
			}
			if len(e.repo.respondedBy) != 1 || len(e.repo.transitioned) != 1 {
				t.Fatalf("decline/remove writes = %d/%d, want 1/1", len(e.repo.respondedBy), len(e.repo.transitioned))
			}
		})
	}
	t.Run("failing target graph read refuses", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.dir.profiles[target] = activeProfile(target)
		e.graph.snaps[testOrganiser] = graph.Snapshot{BlockedByOverflow: true}
		e.graph.errs = map[string]error{target: errors.New("boom")}
		if _, err := e.svc.RespondToJoinRequest(ctx, testOrganiser, testKey, testBeaconID, target, true); err == nil || len(e.repo.respondedBy) != 0 {
			t.Fatalf("accept = %v, want a refusal without a write", err)
		}
	})
}

// TestSelfTransitions_LightGate (B05): leave and withdraw need only the caller's own row (the repository's verdict, in
// its transaction): a block either way, a hidden beacon, a community the caller left or a gone organiser does not stop
// them, and nothing beyond the repository is read; a missing row is the one NOT_FOUND.
func TestSelfTransitions_LightGate(t *testing.T) {
	ctx := context.Background()
	calls := []struct {
		name string
		call func(e *env) error
	}{
		{"leave", func(e *env) error { return e.svc.LeaveBeacon(ctx, testViewer, testKey, testBeaconID) }},
		{"withdraw", func(e *env) error { return e.svc.WithdrawJoinRequest(ctx, testViewer, testKey, testBeaconID) }},
	}
	for _, tc := range []struct {
		name  string
		setup func(e *env)
	}{
		{"organiser blocks caller", func(e *env) {
			e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}
		}},
		{"caller blocks organiser", func(e *env) {
			e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
		}},
		{"hidden", func(e *env) {
			b := e.repo.docs[testBeaconID]
			b.Hidden = true
			e.repo.docs[testBeaconID] = b
		}},
		{"left community", func(e *env) { e.communityBeacon() }},
		{"communities globally off", func(e *env) {
			e.communityBeacon()
			e.flags.off[communities.FlagName] = true
		}},
		{"organiser gone", func(e *env) { delete(e.dir.profiles, testOrganiser) }},
	} {
		for _, c := range calls {
			t.Run(tc.name+" "+c.name, func(t *testing.T) {
				e := newEnv()
				e.repo.docs[testBeaconID] = e.openBeacon()
				tc.setup(e)
				e.repo.presult = ParticipantResult{Outcome: Written, Beacon: e.repo.docs[testBeaconID]}
				if err := c.call(e); err != nil {
					t.Fatalf("%s: %v", c.name, err)
				}
				if len(e.repo.transitioned) != 1 || e.repo.transitioned[0].TargetUID != testViewer {
					t.Fatalf("transitions = %+v, want the caller's own row", e.repo.transitioned)
				}
				if e.graph.readsOf(testViewer) != 0 || e.comm.calls != 0 || e.dir.calls != 0 {
					t.Fatalf("visibility reads: graph %d comm %d dir %d, want none", e.graph.readsOf(testViewer), e.comm.calls, e.dir.calls)
				}
			})
		}
	}
	for _, c := range calls {
		t.Run("no row is not found "+c.name, func(t *testing.T) {
			e := newEnv()
			e.repo.perr = ErrNotFound
			assertNotFound(t, c.call(e))
		})
	}
}

// TestListBeacons_ViewerState (B06): each row carries the caller's state from one batched read of their participant
// rows (the organiser's own rows need none), the same relationship -> controls rule as GetBeacon.
func TestListBeacons_ViewerState(t *testing.T) {
	e := newEnv()
	rows := e.rowsFrom(4)
	rows[0].OrganiserID = testViewer
	e.dir.profiles[testViewer] = activeProfile(testViewer)
	e.repo.rows = rows
	e.repo.participants = map[string]Participant{
		e.repo.pkey(rows[2].ID, testViewer): {BeaconID: rows[2].ID, UID: testViewer, State: PStateRequested},
		e.repo.pkey(rows[3].ID, testViewer): {BeaconID: rows[3].ID, UID: testViewer, State: PStateAccepted},
	}
	page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: 10})
	if err != nil || len(page.Views) != 4 {
		t.Fatalf("page = %d views, %v", len(page.Views), err)
	}
	want := []ViewerState{
		{Role: RoleOrganiser, CanManage: true},
		{Role: RoleNone, CanRequest: true},
		{Role: RoleNone, ParticipantState: PStateRequested, CanWithdraw: true},
		{Role: RoleParticipant, ParticipantState: PStateAccepted, CanLeave: true},
	}
	for i, v := range page.Views {
		if v.Viewer != want[i] {
			t.Fatalf("row %d viewer = %+v, want %+v", i, v.Viewer, want[i])
		}
	}
	if len(e.repo.participantBatches) != 1 {
		t.Fatalf("participant batches = %d, want 1", len(e.repo.participantBatches))
	}
	if b := e.repo.participantBatches[0]; b.uid != testViewer || fmt.Sprint(b.ids) != fmt.Sprint([]string{rows[1].ID, rows[2].ID, rows[3].ID}) {
		t.Fatalf("batch = %+v, want the caller's rows of the three beacons they do not organise", b)
	}
	// The same rows through GetBeacon answer the same state.
	for i, b := range rows {
		e.repo.docs[b.ID] = b
		v, err := e.svc.GetBeacon(context.Background(), testViewer, b.ID)
		if err != nil || v.Viewer != want[i] {
			t.Fatalf("GetBeacon row %d = %+v, %v, want %+v", i, v.Viewer, err, want[i])
		}
	}
}

// TestListParticipants_PeerBlocks (D01): a participant viewer does not see peers across a block either way (past an
// overflowed blockedBy only peers they follow); the organiser sees everyone; the viewer always sees themselves.
func TestListParticipants_PeerBlocks(t *testing.T) {
	setup := func(viewerSnap graph.Snapshot) *env {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.participants = map[string]Participant{e.repo.pkey(testBeaconID, "acc-1"): {BeaconID: testBeaconID, UID: "acc-1", State: PStateAccepted}}
		for i := 1; i <= 5; i++ {
			uid := fmt.Sprintf("acc-%d", i)
			e.dir.profiles[uid] = activeProfile(uid)
			e.repo.plist = append(e.repo.plist, Participant{BeaconID: testBeaconID, UID: uid, State: PStateAccepted, RespondedAt: e.now})
		}
		e.graph.snaps["acc-1"] = viewerSnap
		return e
	}
	uids := func(p ParticipantsPage) []string {
		out := []string{}
		for _, r := range p.Rows {
			out = append(out, r.User.UserID)
		}
		return out
	}
	blocks := graph.Snapshot{Blocked: map[string]bool{"acc-2": true}, BlockedBy: map[string]bool{"acc-3": true}}
	t.Run("participant", func(t *testing.T) {
		e := setup(blocks)
		page, err := e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID})
		if err != nil || fmt.Sprint(uids(page)) != fmt.Sprint([]string{"acc-1", "acc-4", "acc-5"}) {
			t.Fatalf("rows = %v, %v, want acc-1 acc-4 acc-5", uids(page), err)
		}
	})
	t.Run("participant past overflow", func(t *testing.T) {
		e := setup(graph.Snapshot{BlockedByOverflow: true, Following: map[string]bool{"acc-5": true}})
		page, err := e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID})
		if err != nil || fmt.Sprint(uids(page)) != fmt.Sprint([]string{"acc-1", "acc-5"}) {
			t.Fatalf("rows = %v, %v, want acc-1 acc-5", uids(page), err)
		}
	})
	t.Run("organiser sees everyone", func(t *testing.T) {
		e := setup(blocks)
		e.graph.snaps[testOrganiser] = graph.Snapshot{BlockedByOverflow: true}
		page, err := e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID})
		if err != nil || len(page.Rows) != 5 {
			t.Fatalf("rows = %v, %v, want all five", uids(page), err)
		}
	})
}
