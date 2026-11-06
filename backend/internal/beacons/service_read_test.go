package beacons

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func TestGetBeacon_HiddenToOthersIsNotFoundOrganiserSeesIt(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	b.Hidden = true
	e.repo.docs[testBeaconID] = b
	_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
	assertNotFound(t, err)
	v, err := e.svc.GetBeacon(context.Background(), testOrganiser, testBeaconID)
	if err != nil || !v.Beacon.Hidden || v.Viewer.Role != RoleOrganiser {
		t.Fatalf("organiser view = %+v, %v", v, err)
	}
	_, err = e.svc.GetBeacon(context.Background(), testViewer, "0000000000000000099")
	assertNotFound(t, err)
	assertValidation(t, mustErr(e.svc.GetBeacon(context.Background(), testViewer, "nope")), "beacon_id")
}

func mustErr(_ View, err error) error { return err }

func TestGetBeacon_BlockEitherWayIsNotFound(t *testing.T) {
	for _, tc := range []struct {
		name string
		snap graph.Snapshot
	}{
		{"viewer is blocked by the organiser", graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}},
		{"viewer blocks the organiser", graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.graph.snaps[testViewer] = tc.snap
			_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
			assertNotFound(t, err)
		})
	}
	t.Run("no block", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		v, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		if err != nil || v.Viewer.Role != RoleNone || !v.Viewer.CanRequest || v.Viewer.CanManage {
			t.Fatalf("view = %+v, %v", v, err)
		}
	})
}

func TestGetBeacon_EndedDerived(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	e.repo.docs[testBeaconID] = b
	e.now = b.EndAt
	v, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
	if err != nil || v.Beacon.Status != StatusEnded || v.Viewer.CanRequest {
		t.Fatalf("at end: view = %+v, %v, want ended and no request", v, err)
	}
	o, err := e.svc.GetBeacon(context.Background(), testOrganiser, testBeaconID)
	if err != nil || o.Viewer.CanManage {
		t.Fatalf("organiser at end: view = %+v, %v, want no manage", o, err)
	}
}

func TestGetBeacon_CommunityRules(t *testing.T) {
	community := func(e *env) {
		b := e.openBeacon()
		b.CommunityID = testCommunity
		e.repo.docs[testBeaconID] = b
	}
	t.Run("not a member", func(t *testing.T) {
		e := newEnv()
		community(e)
		_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		assertForbidden(t, err, "not_member")
		if e.dir.calls != 0 {
			t.Fatal("profile read before the membership check")
		}
	})
	t.Run("banned", func(t *testing.T) {
		e := newEnv()
		community(e)
		e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleBanned
		_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		assertForbidden(t, err, "not_member")
	})
	t.Run("member", func(t *testing.T) {
		e := newEnv()
		community(e)
		e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		if _, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("communities globally off", func(t *testing.T) {
		e := newEnv()
		community(e)
		e.flags.off[communities.FlagName] = true
		e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
		assertDisabled(t, err, communities.FlagName)
	})
	t.Run("communities allowlist without the viewer still reads", func(t *testing.T) {
		e := newEnv()
		community(e)
		e.flags.on[communities.FlagName] = false // not on for the caller, but not globally off
		e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		if _, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID); err != nil {
			t.Fatal(err)
		}
	})
}

func TestGetBeacon_OrganiserGoneIsNotFound(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	p := e.dir.profiles[testOrganiser]
	p.Status = identity.AccountStatusSuspended
	e.dir.profiles[testOrganiser] = p
	_, err := e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
	assertNotFound(t, err)
	delete(e.dir.profiles, testOrganiser)
	_, err = e.svc.GetBeacon(context.Background(), testViewer, testBeaconID)
	assertNotFound(t, err)
}

// rowsFrom builds n public open beacons by distinct organisers, an hour apart.
func (e *env) rowsFrom(n int) []Beacon {
	out := make([]Beacon, 0, n)
	for i := range n {
		b := e.openBeacon()
		b.ID = fmt.Sprintf("%019d", 100+i)
		b.OrganiserID = fmt.Sprintf("org-%d", i)
		b.StartAt = e.now.Add(time.Duration(i+1) * time.Hour)
		b.EndAt = b.StartAt.Add(25 * time.Minute)
		e.dir.profiles[b.OrganiserID] = activeProfile(b.OrganiserID)
		out = append(out, b)
	}
	return out
}

func TestListBeacons_TokenBoundToAudienceAndViewer(t *testing.T) {
	e := newEnv()
	e.repo.rows = e.rowsFrom(3)
	page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: 2})
	if err != nil || len(page.Views) != 2 || page.NextPageToken == "" {
		t.Fatalf("page 1 = %d views, token %q, %v", len(page.Views), page.NextPageToken, err)
	}
	token := page.NextPageToken
	if _, err := e.svc.ListBeacons(context.Background(), "someone-else", ListInput{Public: true, Limit: 2, PageToken: token}); err == nil {
		t.Fatal("token opened for another viewer")
	} else {
		assertValidation(t, err, "page_token")
	}
	e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
	if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{CommunityID: testCommunity, Limit: 2, PageToken: token}); err == nil {
		t.Fatal("token opened for another audience")
	} else {
		assertValidation(t, err, "page_token")
	}
	if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: 2, PageToken: token}); err != nil {
		t.Fatalf("same viewer and audience: %v", err)
	}
	q := e.repo.queries[len(e.repo.queries)-1]
	if q.AfterID != e.repo.rows[1].ID || !q.AfterStartAt.Equal(e.repo.rows[1].StartAt) {
		t.Fatalf("resume query = %+v, want after row 1", q)
	}
	assertValidation(t, mustErrPage(e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, PageToken: "garbage"})), "page_token")
}

func mustErrPage(_ Page, err error) error { return err }

func TestListBeacons_DropsBlockedAndHiddenKeepsToken(t *testing.T) {
	e := newEnv()
	rows := e.rowsFrom(4)
	rows[2].Hidden = true
	e.repo.rows = rows
	e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{"org-0": true}, BlockedBy: map[string]bool{"org-1": true}}
	page, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: 3})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Views) != 0 || page.NextPageToken == "" {
		t.Fatalf("page = %d views (want 0: two blocked, one hidden), token %q (want set)", len(page.Views), page.NextPageToken)
	}
	e.graph.snaps[testViewer] = graph.Snapshot{}
	page, err = e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: 3})
	if err != nil || len(page.Views) != 2 || page.Views[0].Organiser.UserID != "org-0" || page.Views[1].Organiser.UserID != "org-1" {
		t.Fatalf("page without blocks = %+v, %v, want org-0 and org-1 (hidden dropped)", page.Views, err)
	}
}

func TestListBeacons_LimitClampAndFromDefault(t *testing.T) {
	e := newEnv()
	for _, tc := range []struct {
		limit int32
		want  int
	}{{0, 21}, {5, 6}, {99, 51}} {
		if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, Limit: tc.limit}); err != nil {
			t.Fatal(err)
		}
		q := e.repo.queries[len(e.repo.queries)-1]
		if q.Limit != tc.want || !q.From.Equal(e.now) || q.CommunityID != "" {
			t.Fatalf("limit %d: query = %+v, want limit %d from now public", tc.limit, q, tc.want)
		}
	}
	from := e.now.Add(2 * time.Hour)
	if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{Public: true, From: from}); err != nil {
		t.Fatal(err)
	}
	if q := e.repo.queries[len(e.repo.queries)-1]; !q.From.Equal(from) {
		t.Fatalf("explicit from: query = %+v", q)
	}
}

func TestListBeacons_CommunityNeedsMembership(t *testing.T) {
	e := newEnv()
	_, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{CommunityID: testCommunity})
	assertForbidden(t, err, "not_member")
	if len(e.repo.queries) != 0 {
		t.Fatal("query ran for a non-member")
	}
	assertValidation(t, mustErrPage(e.svc.ListBeacons(context.Background(), testViewer, ListInput{})), "audience")
	e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
	if _, err := e.svc.ListBeacons(context.Background(), testViewer, ListInput{CommunityID: testCommunity}); err != nil {
		t.Fatal(err)
	}
	if q := e.repo.queries[0]; q.CommunityID != testCommunity {
		t.Fatalf("query = %+v", q)
	}
}
