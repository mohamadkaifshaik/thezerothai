package beacons

import (
	"context"
	"errors"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestReportableBeacon_VisibilityMatrix (R17): a caller may report exactly the beacons they may see, every refusal is
// the one ErrNotFound (a community non-member too: a report lookup must not leak membership), and the organiser's own
// beacon is ErrOwnBeacon. The evidence holds the organiser's handle and the beacon's text (R16).
func TestReportableBeacon_VisibilityMatrix(t *testing.T) {
	tests := []struct {
		name   string
		setup  func(e *env, b *Beacon)
		viewer string
		id     string
		want   error // nil = reportable
	}{
		{"public beacon", func(*env, *Beacon) {}, testViewer, testBeaconID, nil},
		{"hidden, other viewer", func(_ *env, b *Beacon) { b.Hidden = true }, testViewer, testBeaconID, ErrNotFound},
		{"viewer blocked by the organiser", func(e *env, _ *Beacon) {
			e.graph.snaps[testViewer] = graph.Snapshot{BlockedBy: map[string]bool{testOrganiser: true}}
		}, testViewer, testBeaconID, ErrNotFound},
		{"viewer blocks the organiser", func(e *env, _ *Beacon) {
			e.graph.snaps[testViewer] = graph.Snapshot{Blocked: map[string]bool{testOrganiser: true}}
		}, testViewer, testBeaconID, ErrNotFound},
		{"community, non-member", func(_ *env, b *Beacon) { b.CommunityID = testCommunity }, testViewer, testBeaconID, ErrNotFound},
		{"community, banned", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleBanned
		}, testViewer, testBeaconID, ErrNotFound},
		{"community, member", func(e *env, b *Beacon) {
			b.CommunityID = testCommunity
			e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
		}, testViewer, testBeaconID, nil},
		{"organiser not ACTIVE", func(e *env, _ *Beacon) {
			p := e.dir.profiles[testOrganiser]
			p.Status = identity.AccountStatusSuspended
			e.dir.profiles[testOrganiser] = p
		}, testViewer, testBeaconID, ErrNotFound},
		{"own public beacon", func(*env, *Beacon) {}, testOrganiser, testBeaconID, ErrOwnBeacon},
		{"own hidden beacon", func(_ *env, b *Beacon) { b.Hidden = true }, testOrganiser, testBeaconID, ErrOwnBeacon},
		{"malformed id", func(*env, *Beacon) {}, testViewer, "abc", ErrNotFound},
		{"missing id", func(*env, *Beacon) {}, testViewer, "0000000000000000099", ErrNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv()
			b := e.openBeacon()
			b.Details = "bring a book"
			tt.setup(e, &b)
			e.repo.docs[testBeaconID] = b
			got, err := e.svc.(BeaconReporter).ReportableBeacon(context.Background(), tt.viewer, tt.id)
			if tt.want != nil {
				if !errors.Is(err, tt.want) {
					t.Fatalf("err = %v, want %v", err, tt.want)
				}
				if got != (ReportedBeacon{}) {
					t.Errorf("a refusal returned evidence: %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.OrganiserUID != testOrganiser || got.OrganiserHandle != testOrganiser || got.Title != "Coffee" || got.Venue != "Hall" || got.Details != "bring a book" || !got.CreatedAt.Equal(e.now) {
				t.Errorf("evidence = %+v", got)
			}
		})
	}
}

// TestValidateBeaconIDExported: the exported check is the same VALIDATION beacon_id the RPCs run.
func TestValidateBeaconIDExported(t *testing.T) {
	assertValidation(t, ValidateBeaconID("12"), "beacon_id")
	if err := ValidateBeaconID(testBeaconID); err != nil {
		t.Fatal(err)
	}
	if NotFoundError().Message != "beacon not found" {
		t.Fatalf("NotFoundError = %q", NotFoundError().Message)
	}
}
