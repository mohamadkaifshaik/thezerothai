package beacons

import (
	"context"
	"testing"
	"time"
)

// TestRecentCoParticipants: only plans the caller was in (organiser or ACCEPTED), ended within the window, not cancelled and not
// hidden, contribute; the organiser comes first and the caller is never returned; the caps are clamped.
func TestRecentCoParticipants(t *testing.T) {
	e := newEnv()
	svc := e.svc.(*service)
	ended := testNow.Add(-2 * time.Hour)
	e.repo.memberships = []Membership{
		{BeaconID: "b-ok", Role: RoleParticipant, State: PStateAccepted, EndAt: ended},
		{BeaconID: "b-hidden", Role: RoleOrganiser, State: "open", EndAt: ended},
		{BeaconID: "b-left", Role: RoleParticipant, State: "left", EndAt: ended},
	}
	e.repo.docs["b-ok"] = Beacon{ID: "b-ok", OrganiserID: "org", Activity: "coffee"}
	e.repo.docs["b-hidden"] = Beacon{ID: "b-hidden", OrganiserID: testViewer, Hidden: true}
	e.repo.plist = []Participant{{UID: "org"}, {UID: testViewer}, {UID: "p1"}, {UID: "p2"}}

	got, err := svc.RecentCoParticipants(context.Background(), testViewer, testNow.Add(-30*24*time.Hour), 9, 9)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0].UID != "org" || got[1].UID != "p1" || got[2].UID != "p2" || got[0].Activity != "coffee" {
		t.Fatalf("got %+v", got)
	}
	if q := e.repo.mqueries[0]; !q.Past || q.Limit != maxCoPlans || len(q.Roles) != 2 {
		t.Fatalf("membership query = %+v", q)
	}
	if len(e.repo.pqueries) != 1 || e.repo.pqueries[0].Limit != maxCoPerPlan || e.repo.pqueries[0].State != PStateAccepted {
		t.Fatalf("participant queries = %+v (the hidden plan must not be paged)", e.repo.pqueries)
	}

	// Outside the lookback, and cancelled: nothing.
	e2 := newEnv()
	e2.repo.memberships = []Membership{{BeaconID: "old", Role: RoleOrganiser, EndAt: testNow.Add(-40 * 24 * time.Hour)}, {BeaconID: "gone", Role: RoleOrganiser, EndAt: ended}}
	e2.repo.docs["gone"] = Beacon{ID: "gone", OrganiserID: testViewer, Status: StatusCancelled}
	if got, err := e2.svc.(*service).RecentCoParticipants(context.Background(), testViewer, testNow.Add(-30*24*time.Hour), 2, 4); err != nil || len(got) != 0 {
		t.Fatalf("got %+v, %v", got, err)
	}
}
