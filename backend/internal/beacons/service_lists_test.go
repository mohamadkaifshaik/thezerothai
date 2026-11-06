package beacons

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// membershipsFor builds n membership rows for uid on distinct beacons (and the beacons themselves, organised by
// org-<i>), each ending an hour apart.
func (e *env) membershipsFor(uid, role, state string, n int) []Membership {
	out := make([]Membership, 0, n)
	for i := range n {
		b := e.openBeacon()
		b.ID = fmt.Sprintf("%019d", 200+i)
		b.OrganiserID = fmt.Sprintf("org-%d", i)
		if role == RoleOrganiser {
			b.OrganiserID = uid
		}
		b.StartAt = e.now.Add(time.Duration(i+1) * time.Hour)
		b.EndAt = b.StartAt.Add(25 * time.Minute)
		e.repo.docs[b.ID] = b
		e.dir.profiles[b.OrganiserID] = activeProfile(b.OrganiserID)
		out = append(out, Membership{BeaconID: b.ID, Role: role, State: state, StartAt: b.StartAt, EndAt: b.EndAt})
	}
	return out
}

func TestListMyBeacons_RoleWindowAndQuery(t *testing.T) {
	for _, tc := range []struct {
		role  string
		roles []string
	}{
		{"", nil},
		{RoleOrganiser, []string{RoleOrganiser}},
		{RoleParticipant, []string{RoleParticipant, RoleRequester}},
	} {
		t.Run("role "+tc.role, func(t *testing.T) {
			e := newEnv()
			if _, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Role: tc.role, Past: true, Limit: 5}); err != nil {
				t.Fatal(err)
			}
			q := e.repo.mqueries[0]
			if fmt.Sprint(q.Roles) != fmt.Sprint(tc.roles) || !q.Past || q.UID != testViewer || q.Limit != 6 || !q.Now.Equal(e.now) {
				t.Fatalf("query = %+v, want roles %v past limit 6", q, tc.roles)
			}
		})
	}
	e := newEnv()
	assertValidation(t, mustErrPage(e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Role: "bogus"})), "role")
	if _, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 0}); err != nil {
		t.Fatal(err)
	}
	if q := e.repo.mqueries[0]; q.Limit != 21 || q.Past {
		t.Fatalf("default query = %+v, want limit 21 upcoming", q)
	}
}

// TestListMyBeacons_DropsDanglingAndHiddenKeepsToken: rows whose beacon is gone (R3) or hidden are dropped; the token is
// computed from the raw rows; the viewer state comes from the membership row.
func TestListMyBeacons_DropsDanglingAndHiddenKeepsToken(t *testing.T) {
	e := newEnv()
	rows := e.membershipsFor(testViewer, RoleRequester, PStateRequested, 4)
	rows[0].State, rows[0].Role = PStateAccepted, RoleParticipant
	delete(e.repo.docs, rows[1].BeaconID) // dangling
	hidden := e.repo.docs[rows[2].BeaconID]
	hidden.Hidden = true
	e.repo.docs[rows[2].BeaconID] = hidden
	e.repo.memberships = rows
	page, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 3})
	if err != nil {
		t.Fatal(err)
	}
	if page.NextPageToken == "" {
		t.Fatal("token missing: 4 rows for a page of 3")
	}
	if len(page.Views) != 1 || page.Views[0].Beacon.ID != rows[0].BeaconID {
		t.Fatalf("views = %d (%v), want only the accepted row's beacon", len(page.Views), viewIDs(page.Views))
	}
	v := page.Views[0]
	if v.Viewer.Role != RoleParticipant || v.Viewer.ParticipantState != PStateAccepted || !v.Viewer.CanLeave || v.Organiser.UserID != "org-0" {
		t.Fatalf("view = %+v", v.Viewer)
	}
	if len(e.repo.beaconBatches) != 1 || len(e.repo.beaconBatches[0]) != 3 {
		t.Fatalf("beacon batches = %v, want one batch of the 3 raw rows", e.repo.beaconBatches)
	}
	// Organised rows render the organiser's own view.
	e2 := newEnv()
	e2.repo.memberships = e2.membershipsFor(testOrganiser, RoleOrganiser, string(StatusOpen), 1)
	page, err = e2.svc.ListMyBeacons(context.Background(), testOrganiser, MyBeaconsInput{Role: RoleOrganiser})
	if err != nil || len(page.Views) != 1 || page.Views[0].Viewer.Role != RoleOrganiser || !page.Views[0].Viewer.CanManage {
		t.Fatalf("organised page = %+v, %v", page.Views, err)
	}
}

// TestListMyBeacons_DropsBlockedAndTerminalRows (review): a row whose organiser blocks the caller or whom the caller
// blocks is dropped; declined, withdrawn, left and removed rows are history and are dropped; requested, accepted and
// organised rows stay; the token is still computed from the raw rows.
func TestListMyBeacons_DropsBlockedAndTerminalRows(t *testing.T) {
	e := newEnv()
	rows := e.membershipsFor(testViewer, RoleRequester, PStateRequested, 6)
	rows[1].Role, rows[1].State = RoleParticipant, PStateAccepted // blocked below
	rows[2].State = PStateDeclined
	rows[3].State = PStateWithdrawn
	rows[4].Role, rows[4].State = RoleParticipant, PStateLeft
	rows[5].Role, rows[5].State = RoleParticipant, PStateRemoved
	e.repo.memberships = rows
	e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{"org-1": true}}
	page, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 5})
	if err != nil {
		t.Fatal(err)
	}
	if got := viewIDs(page.Views); fmt.Sprint(got) != fmt.Sprint([]string{rows[0].BeaconID}) {
		t.Fatalf("views = %v, want only the requested row's beacon", got)
	}
	if page.NextPageToken == "" {
		t.Fatal("token missing: 6 raw rows for a page of 5")
	}
	e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{"org-1": true}}
	page, err = e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 5})
	if err != nil || len(page.Views) != 1 {
		t.Fatalf("caller blocks the organiser: views = %v, %v", viewIDs(page.Views), err)
	}
}

func viewIDs(vs []View) []string {
	out := make([]string, 0, len(vs))
	for _, v := range vs {
		out = append(out, v.Beacon.ID)
	}
	return out
}

func TestListMyBeacons_TokenBinding(t *testing.T) {
	e := newEnv()
	e.repo.memberships = e.membershipsFor(testViewer, RoleRequester, PStateRequested, 3)
	page, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 2})
	if err != nil || page.NextPageToken == "" {
		t.Fatalf("page = %+v, %v", page, err)
	}
	token := page.NextPageToken
	assertValidation(t, mustErrPage(e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 2, Past: true, PageToken: token})), "page_token")
	assertValidation(t, mustErrPage(e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 2, Role: RoleOrganiser, PageToken: token})), "page_token")
	assertValidation(t, mustErrPage(e.svc.ListMyBeacons(context.Background(), "someone-else", MyBeaconsInput{Limit: 2, PageToken: token})), "page_token")
	if _, err := e.svc.ListMyBeacons(context.Background(), testViewer, MyBeaconsInput{Limit: 2, PageToken: token}); err != nil {
		t.Fatalf("same uid, role and window: %v", err)
	}
	q := e.repo.mqueries[len(e.repo.mqueries)-1]
	if q.AfterID != e.repo.memberships[1].BeaconID || !q.AfterEndAt.Equal(e.repo.memberships[1].EndAt) {
		t.Fatalf("resume query = %+v, want after row 1", q)
	}
}

// TestListParticipants_Visibility: ACCEPTED rows are visible to the organiser and accepted participants; REQUESTED rows
// (with notes) to the organiser only; anyone else gets NOT_FOUND / not_organiser; non-ACTIVE users are dropped.
func TestListParticipants_Visibility(t *testing.T) {
	setup := func() *env {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.participants = map[string]Participant{
			e.repo.pkey(testBeaconID, "acc-1"): {BeaconID: testBeaconID, UID: "acc-1", State: PStateAccepted},
			e.repo.pkey(testBeaconID, "req-1"): {BeaconID: testBeaconID, UID: "req-1", State: PStateRequested, Note: "pls"},
		}
		e.repo.plist = []Participant{
			{BeaconID: testBeaconID, UID: "acc-1", State: PStateAccepted, Note: "secret", RespondedAt: e.now},
			{BeaconID: testBeaconID, UID: "gone", State: PStateAccepted, RespondedAt: e.now.Add(time.Minute)},
		}
		e.dir.profiles["acc-1"] = activeProfile("acc-1")
		e.dir.profiles["req-1"] = activeProfile("req-1")
		gone := activeProfile("gone")
		gone.Status = identity.AccountStatusSuspended
		e.dir.profiles["gone"] = gone
		return e
	}
	t.Run("organiser lists accepted without notes", func(t *testing.T) {
		e := setup()
		page, err := e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID, Limit: 10})
		if err != nil || len(page.Rows) != 1 || page.Rows[0].User.UserID != "acc-1" || page.Rows[0].Participant.Note != "" {
			t.Fatalf("page = %+v, %v", page.Rows, err)
		}
		if q := e.repo.pqueries[0]; q.State != PStateAccepted || q.Limit != 11 {
			t.Fatalf("query = %+v", q)
		}
	})
	t.Run("organiser lists requested with notes", func(t *testing.T) {
		e := setup()
		e.repo.plist = []Participant{{BeaconID: testBeaconID, UID: "req-1", State: PStateRequested, Note: "pls", RequestedAt: e.now}}
		page, err := e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID, Requested: true})
		if err != nil || len(page.Rows) != 1 || page.Rows[0].Participant.Note != "pls" {
			t.Fatalf("page = %+v, %v", page.Rows, err)
		}
		if q := e.repo.pqueries[0]; q.State != PStateRequested {
			t.Fatalf("query = %+v", q)
		}
	})
	t.Run("accepted participant lists accepted, not requested", func(t *testing.T) {
		e := setup()
		if _, err := e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID}); err != nil {
			t.Fatalf("accepted participant: %v", err)
		}
		_, err := e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID, Requested: true})
		assertForbidden(t, err, "not_organiser")
	})
	t.Run("requester and stranger get not found", func(t *testing.T) {
		e := setup()
		_, err := e.svc.ListParticipants(context.Background(), "req-1", ListParticipantsInput{BeaconID: testBeaconID})
		assertNotFound(t, err)
		_, err = e.svc.ListParticipants(context.Background(), testViewer, ListParticipantsInput{BeaconID: testBeaconID})
		assertNotFound(t, err)
		if len(e.repo.pqueries) != 0 {
			t.Fatal("query ran for a viewer who may not list")
		}
	})
	t.Run("token binding and paging", func(t *testing.T) {
		e := setup()
		e.repo.plist = []Participant{
			{BeaconID: testBeaconID, UID: "acc-1", State: PStateAccepted, RespondedAt: e.now},
			{BeaconID: testBeaconID, UID: "acc-2", State: PStateAccepted, RespondedAt: e.now.Add(time.Minute)},
			{BeaconID: testBeaconID, UID: "acc-3", State: PStateAccepted, RespondedAt: e.now.Add(2 * time.Minute)},
		}
		e.dir.profiles["acc-2"] = activeProfile("acc-2")
		page, err := e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID, Limit: 2})
		if err != nil || len(page.Rows) != 2 || page.NextPageToken == "" {
			t.Fatalf("page = %d rows, token %q, %v", len(page.Rows), page.NextPageToken, err)
		}
		token := page.NextPageToken
		assertValidation(t, mustErrParticipants(e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID, Requested: true, PageToken: token})), "page_token")
		assertValidation(t, mustErrParticipants(e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID, PageToken: token})), "page_token")
		if _, err := e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: testBeaconID, Limit: 2, PageToken: token}); err != nil {
			t.Fatal(err)
		}
		q := e.repo.pqueries[len(e.repo.pqueries)-1]
		if q.AfterUID != "acc-2" || !q.AfterAt.Equal(e.now.Add(time.Minute)) {
			t.Fatalf("resume query = %+v, want after acc-2", q)
		}
	})
	t.Run("beacon_id is validated and visibility applies", func(t *testing.T) {
		e := setup()
		assertValidation(t, mustErrParticipants(e.svc.ListParticipants(context.Background(), testOrganiser, ListParticipantsInput{BeaconID: "x"})), "beacon_id")
		b := e.repo.docs[testBeaconID]
		b.Hidden = true
		e.repo.docs[testBeaconID] = b
		_, err := e.svc.ListParticipants(context.Background(), "acc-1", ListParticipantsInput{BeaconID: testBeaconID})
		assertNotFound(t, err)
	})
}

func mustErrParticipants(_ ParticipantsPage, err error) error { return err }
