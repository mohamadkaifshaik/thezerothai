package beacons

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const testPeer = "peer-1"

// sharedBeacon stores beacon number n (an hour apart, organised by org) and returns the viewer's membership row for it.
func (e *env) sharedBeacon(n int, org string) Membership {
	b := e.openBeacon()
	b.ID = fmt.Sprintf("%019d", 300+n)
	b.OrganiserID = org
	b.StartAt = e.now.Add(time.Duration(n+1) * time.Hour)
	b.EndAt = b.StartAt.Add(25 * time.Minute)
	e.repo.docs[b.ID] = b
	e.dir.profiles[org] = activeProfile(org)
	e.dir.profiles[testPeer] = activeProfile(testPeer)
	role, state := RoleParticipant, PStateAccepted
	if org == testViewer {
		role, state = RoleOrganiser, string(StatusOpen)
	}
	return Membership{BeaconID: b.ID, Role: role, State: state, StartAt: b.StartAt, EndAt: b.EndAt}
}

// peerIn puts the peer in beacon m as an accepted participant.
func (e *env) peerIn(m Membership) {
	if e.repo.theirs == nil {
		e.repo.theirs = map[string]Membership{}
	}
	e.repo.theirs[testPeer+"|"+m.BeaconID] = Membership{BeaconID: m.BeaconID, Role: RoleParticipant, State: PStateAccepted, StartAt: m.StartAt, EndAt: m.EndAt}
}

func (e *env) shared(in SharedInput) (Page, error) {
	if in.PeerUID == "" {
		in.PeerUID = testPeer
	}
	return e.svc.ListShared(context.Background(), testViewer, in)
}

func TestListShared_ReturnsOnlyBothInPlansSoonestFirst(t *testing.T) {
	e := newEnv()
	a := e.sharedBeacon(0, testOrganiser)  // both accepted
	b := e.sharedBeacon(1, testViewer)     // viewer organises, peer accepted
	c := e.sharedBeacon(2, testOrganiser)  // viewer only
	d := e.sharedBeacon(3, testOrganiser)  // peer only (viewer has no row)
	r := e.sharedBeacon(4, testOrganiser)  // viewer accepted, peer only REQUESTED
	rq := e.sharedBeacon(5, testOrganiser) // viewer only REQUESTED
	rq.Role, rq.State = RoleRequester, PStateRequested
	e.repo.memberships = []Membership{a, b, c, r, rq}
	e.peerIn(a)
	e.peerIn(b)
	e.peerIn(d)
	e.repo.theirs[testPeer+"|"+r.BeaconID] = Membership{BeaconID: r.BeaconID, Role: RoleRequester, State: PStateRequested}
	page, err := e.shared(SharedInput{})
	if err != nil {
		t.Fatal(err)
	}
	if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint([]string{a.BeaconID, b.BeaconID}) {
		t.Fatalf("views = %v, want [%s %s]", got, a.BeaconID, b.BeaconID)
	}
	if v := page.Views[0].Viewer; v.Role != RoleParticipant || v.ParticipantState != PStateAccepted || !v.CanLeave {
		t.Fatalf("participant view state = %+v", v)
	}
	if v := page.Views[1].Viewer; v.Role != RoleOrganiser || !v.CanManage {
		t.Fatalf("organiser view state = %+v", v)
	}
	if page.NextPageToken != "" {
		t.Fatal("unexpected token")
	}
	// The read bound: one membership query (scan + 1, organiser and participant roles, upcoming), one peer batch over the
	// viewer's in-plan beacons only (the requester row is not asked for), one beacon batch over the shared ones.
	if len(e.repo.mqueries) != 1 {
		t.Fatalf("membership queries = %d", len(e.repo.mqueries))
	}
	q := e.repo.mqueries[0]
	if q.UID != testViewer || q.Limit != sharedScanRows+1 || q.Past || fmt.Sprint(q.Roles) != fmt.Sprint([]string{RoleOrganiser, RoleParticipant}) {
		t.Fatalf("query = %+v", q)
	}
	if len(e.repo.mgets) != 1 || e.repo.mgets[0].uid != testPeer || fmt.Sprint(e.repo.mgets[0].ids) != fmt.Sprint([]string{a.BeaconID, b.BeaconID, c.BeaconID, r.BeaconID}) {
		t.Fatalf("peer batches = %+v", e.repo.mgets)
	}
	if len(e.repo.beaconBatches) != 1 || fmt.Sprint(e.repo.beaconBatches[0]) != fmt.Sprint([]string{a.BeaconID, b.BeaconID}) {
		t.Fatalf("beacon batches = %v", e.repo.beaconBatches)
	}
}

func TestListShared_Validation(t *testing.T) {
	for _, tc := range []struct{ name, peer string }{
		{"empty", ""}, {"self", testViewer}, {"bad id", "not a uid!"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			_, err := e.svc.ListShared(context.Background(), testViewer, SharedInput{PeerUID: tc.peer})
			assertValidation(t, err, "peer_user_id")
			if e.repo.calls() != 0 {
				t.Fatal("validation must come before any read")
			}
		})
	}
	e := newEnv()
	_, err := e.shared(SharedInput{PageToken: "garbage"})
	assertValidation(t, err, "page_token")
}

func TestListShared_EmptyWithoutLeakingWhy(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(e *env)
	}{
		{"viewer blocked the peer", func(e *env) { e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testPeer: true}} }},
		{"peer blocked the viewer", func(e *env) { e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testPeer: true}} }},
		{"peer is gone", func(e *env) { delete(e.dir.profiles, testPeer) }},
		{"peer is suspended", func(e *env) {
			p := activeProfile(testPeer)
			p.Status = identity.AccountStatusSuspended
			e.dir.profiles[testPeer] = p
		}},
		{"no shared plan", func(e *env) {}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			m := e.sharedBeacon(0, testOrganiser)
			e.repo.memberships = []Membership{m}
			e.peerIn(m)
			if tc.name == "no shared plan" {
				e.repo.theirs = nil
			}
			tc.setup(e)
			page, err := e.shared(SharedInput{})
			if err != nil || len(page.Views) != 0 || page.NextPageToken != "" {
				t.Fatalf("page = %+v, %v; want empty and no error", page, err)
			}
			if tc.name != "no shared plan" && e.repo.calls() != 0 {
				t.Fatalf("a block or a gone peer must stop before any membership read, calls = %d", e.repo.calls())
			}
		})
	}
}

func TestListShared_RowRules(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(e *env, b *Beacon)
		graph  graph.Snapshot
		want   bool
	}{
		{"open shows", func(*env, *Beacon) {}, graph.Snapshot{}, true},
		{"full shows", func(_ *env, b *Beacon) { b.Status = StatusFull }, graph.Snapshot{}, true},
		{"cancelled drops", func(_ *env, b *Beacon) { b.Status = StatusCancelled }, graph.Snapshot{}, false},
		{"ended drops", func(e *env, b *Beacon) { b.EndAt = e.now.Add(-time.Minute) }, graph.Snapshot{}, false},
		{"hidden drops", func(_ *env, b *Beacon) { b.Hidden = true }, graph.Snapshot{}, false},
		{"organiser blocked by viewer drops", func(*env, *Beacon) {}, graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}, false},
		{"organiser blocks viewer drops", func(*env, *Beacon) {}, graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			m := e.sharedBeacon(0, testOrganiser)
			b := e.repo.docs[m.BeaconID]
			tc.mutate(e, &b)
			e.repo.docs[m.BeaconID] = b
			e.graph.snaps[testViewer] = tc.graph
			e.repo.memberships = []Membership{m}
			e.peerIn(m)
			page, err := e.shared(SharedInput{})
			if err != nil {
				t.Fatal(err)
			}
			if got := len(page.Views) == 1; got != tc.want {
				t.Fatalf("shown = %v, want %v (views %v)", got, tc.want, viewIDs(page.Views))
			}
		})
	}
	t.Run("organiser account suspended drops", func(t *testing.T) {
		e := newEnv()
		m := e.sharedBeacon(0, testOrganiser)
		p := activeProfile(testOrganiser)
		p.Status = identity.AccountStatusSuspended
		e.dir.profiles[testOrganiser] = p
		e.repo.memberships = []Membership{m}
		e.peerIn(m)
		page, err := e.shared(SharedInput{})
		if err != nil || len(page.Views) != 0 {
			t.Fatalf("page = %+v, %v", page, err)
		}
	})
}

// TestListShared_CommunityNeedsBothSides: a community beacon shows only while BOTH users are still JOINED members.
func TestListShared_CommunityNeedsBothSides(t *testing.T) {
	for _, tc := range []struct {
		name       string
		viewerRole communities.Role
		peerRole   communities.Role
		off        bool
		missing    bool
		want       bool
	}{
		{"both members", communities.RoleMember, communities.RoleMember, false, false, true},
		{"owner and moderator", communities.RoleOwner, communities.RoleModerator, false, false, true},
		{"viewer left", communities.RoleNone, communities.RoleMember, false, false, false},
		{"peer left", communities.RoleMember, communities.RoleNone, false, false, false},
		{"peer banned", communities.RoleMember, communities.RoleBanned, false, false, false},
		{"communities flag globally off", communities.RoleMember, communities.RoleMember, true, false, false},
		{"community gone", communities.RoleMember, communities.RoleMember, false, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			m := e.sharedBeacon(0, testOrganiser)
			b := e.repo.docs[m.BeaconID]
			b.CommunityID = testCommunity
			e.repo.docs[m.BeaconID] = b
			e.comm.roles = map[string]communities.Role{testCommunity + "|" + testViewer: tc.viewerRole, testCommunity + "|" + testPeer: tc.peerRole}
			if tc.missing {
				e.comm.missing = map[string]bool{testCommunity: true}
			}
			e.flags.off[communities.FlagName] = tc.off
			e.repo.memberships = []Membership{m}
			e.peerIn(m)
			page, err := e.shared(SharedInput{})
			if err != nil {
				t.Fatal(err)
			}
			if got := len(page.Views) == 1; got != tc.want {
				t.Fatalf("shown = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestListShared_LimitAndPaging: limit 0 = 3 and above 10 = 10; a cut page carries a token that resumes after the last
// returned row; a full scan window carries one even when nothing in it is shared; a token is bound to the peer.
func TestListShared_LimitAndPaging(t *testing.T) {
	e := newEnv()
	var rows []Membership
	for i := range 5 {
		m := e.sharedBeacon(i, testOrganiser)
		e.peerIn(m)
		rows = append(rows, m)
	}
	e.repo.memberships = rows
	page, err := e.shared(SharedInput{})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Views) != 3 || page.NextPageToken == "" {
		t.Fatalf("default page = %d views, token %q; want 3 and a token", len(page.Views), page.NextPageToken)
	}
	if _, err := e.shared(SharedInput{PageToken: page.NextPageToken}); err != nil {
		t.Fatal(err)
	}
	q := e.repo.mqueries[1]
	if q.AfterID != rows[2].BeaconID || !q.AfterEndAt.Equal(rows[2].EndAt) {
		t.Fatalf("resume query = after %s %v, want after the third row %s", q.AfterID, q.AfterEndAt, rows[2].BeaconID)
	}
	if _, err := e.shared(SharedInput{PeerUID: "peer-2", PageToken: page.NextPageToken}); err == nil {
		t.Fatal("a token for another peer must not open")
	} else {
		assertValidation(t, err, "page_token")
	}
	if page, err = e.shared(SharedInput{Limit: 100}); err != nil || len(page.Views) != 5 || page.NextPageToken != "" {
		t.Fatalf("limit 100: %d views, token %q, %v; want all 5 and no token", len(page.Views), page.NextPageToken, err)
	}
	if page, err = e.shared(SharedInput{Limit: 2}); err != nil || len(page.Views) != 2 {
		t.Fatalf("limit 2: %d views, %v", len(page.Views), err)
	}

	// 11 viewer rows, none shared: one empty page that still resumes.
	e2 := newEnv()
	var many []Membership
	for i := range sharedScanRows + 1 {
		many = append(many, e2.sharedBeacon(i, testOrganiser))
	}
	e2.repo.memberships = many
	page, err = e2.shared(SharedInput{})
	if err != nil || len(page.Views) != 0 || page.NextPageToken == "" {
		t.Fatalf("empty window: %d views, token %q, %v; want none and a token", len(page.Views), page.NextPageToken, err)
	}
	if len(e2.repo.mgets) != 1 || len(e2.repo.mgets[0].ids) != sharedScanRows {
		t.Fatalf("peer batch = %+v, want one batch of the %d scanned rows", e2.repo.mgets, sharedScanRows)
	}
}

func TestListShared_RepoErrorsFailClosed(t *testing.T) {
	e := newEnv()
	m := e.sharedBeacon(0, testOrganiser)
	e.repo.memberships = []Membership{m}
	e.peerIn(m)
	e.repo.err = errors.New("boom")
	if _, err := e.shared(SharedInput{}); err == nil {
		t.Fatal("a failed read must fail the call, not answer an empty page")
	}
	e2 := newEnv()
	e2.graph.err = errors.New("graph down")
	if _, err := e2.shared(SharedInput{}); err == nil {
		t.Fatal("a failed graph read must fail closed")
	}
}

// TestServer_ListSharedBeacons_FlagModes: FEATURE_BEACONS not globally off, then FEATURE_CHAT_SHARED_PLANS on for the
// caller, before any service call; with both on the request reaches the service and renders.
func TestServer_ListSharedBeacons_FlagModes(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	on := flags.Spec{Mode: flags.On}
	off := flags.Spec{Mode: flags.Off, Allowlist: allow}
	listed := flags.Spec{Mode: flags.Allowlist, Allowlist: allow}
	spec := func(name string, s flags.Spec) flags.Spec { s.Name = name; return s }
	for _, tc := range []struct {
		name    string
		beacons flags.Spec
		chat    flags.Spec
		uid     string
		wantOff string // feature in FEATURE_DISABLED, "" = passes
	}{
		{"both on", on, on, "in", ""},
		{"chat off", on, off, "in", SharedPlansFlagName},
		{"chat allowlist, listed", on, listed, "in", ""},
		{"chat allowlist, unlisted", on, listed, "out", SharedPlansFlagName},
		{"beacons off", off, on, "in", FlagName},
		{"beacons allowlist, unlisted still passes the read class", listed, on, "out", ""},
		{"both off names beacons first", off, off, "in", FlagName},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			m := e.sharedBeacon(0, testOrganiser)
			e.repo.memberships = []Membership{m}
			e.peerIn(m)
			s := NewServer(flags.NewRegistry(spec(FlagName, tc.beacons), spec(SharedPlansFlagName, tc.chat)), e.svc)
			ctx := authn.WithClaims(context.Background(), authn.Claims{UID: tc.uid})
			res, err := s.ListSharedBeacons(ctx, connect.NewRequest(&beaconsv1.ListSharedBeaconsRequest{PeerUserId: testPeer}))
			if tc.wantOff != "" {
				assertDisabled(t, err, tc.wantOff)
				if e.repo.calls() != 0 {
					t.Fatal("a disabled flag must do no Firestore work")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			_ = res
		})
	}
	t.Run("renders", func(t *testing.T) {
		e := newEnv()
		m := e.sharedBeacon(0, testOrganiser)
		e.repo.memberships = []Membership{m}
		e.peerIn(m)
		s := NewServer(flags.NewRegistry(spec(FlagName, on), spec(SharedPlansFlagName, on)), e.svc)
		ctx := authn.WithClaims(context.Background(), authn.Claims{UID: testViewer})
		res, err := s.ListSharedBeacons(ctx, connect.NewRequest(&beaconsv1.ListSharedBeaconsRequest{PeerUserId: testPeer}))
		if err != nil {
			t.Fatal(err)
		}
		if vs := res.Msg.GetViews(); len(vs) != 1 || vs[0].GetBeacon().GetBeaconId() != m.BeaconID || vs[0].GetViewer().GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_PARTICIPANT {
			t.Fatalf("views = %+v", vs)
		}
	})
	t.Run("no uid", func(t *testing.T) {
		s := NewServer(flags.NewRegistry(spec(FlagName, on), spec(SharedPlansFlagName, on)), nil)
		_, err := s.ListSharedBeacons(context.Background(), connect.NewRequest(&beaconsv1.ListSharedBeaconsRequest{}))
		if connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("err = %v, want Unauthenticated", err)
		}
	})
}
