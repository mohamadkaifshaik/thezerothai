package beacons

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// F28b: an UpdateBeacon audience only widens (community < public).

const otherCommunity = "9876543210987654321"

func assertAudienceRefused(t *testing.T, err error, reason string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION ||
		ae.Metadata["field"] != "audience" || ae.Metadata["reason"] != reason {
		t.Fatalf("err = %v, want INVALID_ARGUMENT VALIDATION audience reason=%s", err, reason)
	}
}

// TestAudienceMove is the whole widening matrix: every stored audience against every requested one.
func TestAudienceMove(t *testing.T) {
	for _, tc := range []struct {
		name     string
		from, to string
		want     AudienceMove
		wantErr  error
	}{
		{"public to public", "", "", AudienceSame, nil},
		{"public to a community", "", testCommunity, AudienceNarrow, ErrAudienceNarrowing},
		{"community to public", testCommunity, "", AudienceWiden, nil},
		{"community to the same community", testCommunity, testCommunity, AudienceSame, nil},
		{"community to another community", testCommunity, otherCommunity, AudienceIncompatible, ErrAudienceIncompatible},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := audienceMove(tc.from, tc.to)
			if got != tc.want {
				t.Fatalf("audienceMove(%q, %q) = %v, want %v", tc.from, tc.to, got, tc.want)
			}
			err := got.err()
			if tc.wantErr == nil && err != nil || tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
		})
	}
}

// TestUpdateBeacon_AudienceMatrix runs every from -> to pair through the service to the wire answer. Every move reaches
// the repository with the requested communityId and a hash covering it; the repository (the fake applies the same
// audienceMove on the stored doc) refuses narrowing and incompatible moves after its idempotency lookup.
func TestUpdateBeacon_AudienceMatrix(t *testing.T) {
	public := &AudienceInput{Public: true}
	inCommunity := &AudienceInput{CommunityID: testCommunity}
	inOther := &AudienceInput{CommunityID: otherCommunity}
	for _, tc := range []struct {
		name    string
		stored  string
		req     *AudienceInput
		refused string // the reason; "" = reaches the repository
	}{
		{"public -> public (no-op)", "", public, ""},
		{"public -> community (narrowing)", "", inCommunity, reasonAudienceNarrowing},
		{"community -> public (widen)", testCommunity, public, ""},
		{"community -> same community (no-op)", testCommunity, inCommunity, ""},
		{"community -> another community", testCommunity, inOther, reasonAudienceIncompatible},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.openBeacon()
			b.CommunityID = tc.stored
			e.repo.docs[testBeaconID] = b
			e.comm.roles[testCommunity+"|"+testOrganiser] = communities.RoleMember
			e.repo.update = UpdateResult{Outcome: Unchanged, Beacon: b}
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: tc.req})
			if tc.refused != "" {
				assertAudienceRefused(t, err, tc.refused)
			} else if err != nil {
				t.Fatalf("UpdateBeacon: %v", err)
			}
			p := e.repo.updatedBy[0]
			if p.AudienceCommunityID == nil || *p.AudienceCommunityID != tc.req.CommunityID {
				t.Fatalf("AudienceCommunityID = %v, want %q", p.AudienceCommunityID, tc.req.CommunityID)
			}
			if p.RequestHash != updateHash(testBeaconID, nil, nil, nil, nil, schedule{}, &tc.req.CommunityID, nil) {
				t.Fatal("request hash does not cover the audience")
			}
		})
	}
}

// TestUpdateBeacon_AudienceRepoRefusalsMap: the repository decides again on the fresh doc; its sentinels answer the same
// wire refusal as the service's precheck.
func TestUpdateBeacon_AudienceRepoRefusalsMap(t *testing.T) {
	for _, tc := range []struct {
		repoErr error
		reason  string
	}{{ErrAudienceNarrowing, reasonAudienceNarrowing}, {ErrAudienceIncompatible, reasonAudienceIncompatible}} {
		t.Run(tc.reason, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.err = tc.repoErr
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{Public: true}})
			assertAudienceRefused(t, err, tc.reason)
		})
	}
}

// TestUpdateBeacon_AudienceOrganiserOnly: anyone but the organiser is FORBIDDEN not_organiser, even a JOINED member of
// the beacon's community, and nothing is written.
func TestUpdateBeacon_AudienceOrganiserOnly(t *testing.T) {
	e := newEnv()
	e.communityBeacon()
	e.comm.roles[testCommunity+"|"+testViewer] = communities.RoleMember
	_, err := e.svc.UpdateBeacon(context.Background(), testViewer, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{Public: true}})
	assertForbidden(t, err, "not_organiser")
	if len(e.repo.updatedBy) != 0 {
		t.Fatal("repository Update called")
	}
}

// TestUpdateBeacon_AudienceValidation: public = false and a malformed community id stop before any lookup.
func TestUpdateBeacon_AudienceValidation(t *testing.T) {
	for _, tc := range []struct {
		name  string
		in    *AudienceInput
		field string
	}{
		{"public false", &AudienceInput{}, "audience"},
		{"bad community id", &AudienceInput{CommunityID: "12"}, "community_id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: tc.in})
			assertValidation(t, err, tc.field)
			if e.repo.calls() != 0 {
				t.Fatal("repository called for an invalid audience")
			}
		})
	}
}

// TestUpdateBeacon_WidenCommunityGate: widening runs the community write gate on the organiser (resolve lets the
// organiser past it): a suspended community is NOT_FOUND, an archived one COMMUNITY_STATE, an organiser who was banned is
// not_member, the communities kill switch refuses; an ACTIVE community the organiser is in passes.
func TestUpdateBeacon_WidenCommunityGate(t *testing.T) {
	ok := func(t *testing.T, err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("err = %v", err)
		}
	}
	notMember := func(t *testing.T, err error) { t.Helper(); assertForbidden(t, err, "not_member") }
	disabled := func(t *testing.T, err error) {
		t.Helper()
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Fatalf("err = %v, want FEATURE_DISABLED", err)
		}
	}
	for _, tc := range []struct {
		name   string
		role   communities.Role
		status communities.Status
		off    bool
		check  func(t *testing.T, err error)
	}{
		{"member of an active community", communities.RoleMember, communities.StatusActive, false, ok},
		{"suspended, even for the community owner", communities.RoleOwner, communities.StatusSuspended, false, assertNotFound},
		{"archived", communities.RoleMember, communities.StatusArchived, false, assertArchived},
		{"organiser banned", communities.RoleBanned, communities.StatusActive, false, notMember},
		{"organiser left", communities.RoleNone, communities.StatusActive, false, notMember},
		{"communities globally off", communities.RoleMember, communities.StatusActive, true, disabled},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.communityBeacon()
			e.comm.roles[testCommunity+"|"+testOrganiser] = tc.role
			e.comm.status = map[string]communities.Status{testCommunity: tc.status}
			if tc.off {
				e.flags.off[communities.FlagName] = true
			}
			b.CommunityID = ""
			e.repo.update = UpdateResult{Outcome: Written, Beacon: b, Widened: true}
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{Public: true}})
			tc.check(t, err)
			if (err == nil) != (len(e.repo.updatedBy) == 1) {
				t.Fatalf("repository calls = %d with err %v", len(e.repo.updatedBy), err)
			}
		})
	}
}

// TestUpdateBeacon_WidenSendsNoNotice: a widening alone is not announced (nobody loses access, nothing about the plan
// changes); one combined with a reschedule is announced once, for the reschedule.
func TestUpdateBeacon_WidenSendsNoNotice(t *testing.T) {
	for _, tc := range []struct {
		name string
		res  UpdateResult
		want int
	}{
		{"widen only", UpdateResult{Outcome: Written, Widened: true}, 0},
		{"widen and reschedule", UpdateResult{Outcome: Written, Widened: true, Rescheduled: true, Accepted: []string{"p1"}}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			b := e.communityBeacon()
			e.comm.roles[testCommunity+"|"+testOrganiser] = communities.RoleMember
			b.CommunityID = ""
			tc.res.Beacon = b
			e.repo.update = tc.res
			if _, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{Public: true}}); err != nil {
				t.Fatal(err)
			}
			if len(e.events.updated) != tc.want {
				t.Fatalf("Updated events = %d, want %d", len(e.events.updated), tc.want)
			}
		})
	}
}

// TestUpdateBeacon_WidenReplay: a retry of a committed widening finds the beacon public already (the stored audience
// resent), so the community gate does not run again, and the repository gets the same key and hash to replay the stored
// outcome. A since-banned organiser's retry still answers the stored success.
func TestUpdateBeacon_WidenReplay(t *testing.T) {
	e := newEnv()
	b := e.openBeacon() // public: the widening committed
	e.repo.docs[testBeaconID] = b
	e.comm.roles[testCommunity+"|"+testOrganiser] = communities.RoleBanned
	e.repo.update = UpdateResult{Outcome: Replayed, Beacon: b}
	v, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{Public: true}})
	if err != nil || v.Beacon.CommunityID != "" {
		t.Fatalf("replay = %+v, %v", v.Beacon, err)
	}
	p := e.repo.updatedBy[0]
	public := ""
	if p.IdemKey != idempotency.Key(testOrganiser, rpcUpdateBeacon, testKey) || p.RequestHash != updateHash(testBeaconID, nil, nil, nil, nil, schedule{}, &public, nil) {
		t.Fatalf("params = %+v", p)
	}
	if e.comm.calls != 0 {
		t.Fatal("the community gate ran on a replay")
	}
}

// TestUpdateBeacon_ReplayAfterWidening: K1 resent the stored community (committed Unchanged), K2 then widened the plan;
// a retry of K1 finds the beacon public, which would read as a narrowing, yet it must replay K1's stored answer: the
// service does not refuse it before the repository's idempotency lookup, and no community gate runs.
func TestUpdateBeacon_ReplayAfterWidening(t *testing.T) {
	e := newEnv()
	b := e.openBeacon() // public since K2
	e.repo.docs[testBeaconID] = b
	e.repo.update = UpdateResult{Outcome: Replayed, Beacon: b}
	_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Audience: &AudienceInput{CommunityID: testCommunity}})
	if err != nil {
		t.Fatalf("retry of K1 = %v, want its stored success", err)
	}
	if len(e.repo.updatedBy) != 1 || e.comm.calls != 0 {
		t.Fatalf("repository calls = %d, community calls = %d", len(e.repo.updatedBy), e.comm.calls)
	}
}

// TestUpdateHash_Audience: without an audience the hash is the pre-F28b one; each audience hashes apart.
func TestUpdateHash_Audience(t *testing.T) {
	title := "T"
	legacy := updateHash("b", &title, nil, nil, nil, schedule{}, nil, nil)
	if legacy != idempotency.HashRequest(`beacon_id=b|title="T"|details=unset|venue=unset|open_spots=unset`) {
		t.Fatal("hash without an audience changed")
	}
	public, c1, c2 := "", testCommunity, otherCommunity
	seen := map[string]bool{legacy: true}
	for _, a := range []*string{&public, &c1, &c2} {
		h := updateHash("b", &title, nil, nil, nil, schedule{}, a, nil)
		if seen[h] {
			t.Fatalf("audience %q hashes like another request", *a)
		}
		seen[h] = true
	}
}

func TestUpdateInputFromProto_Audience(t *testing.T) {
	in, err := updateInputFromProto(&beaconsv1.UpdateBeaconRequest{Audience: &beaconsv1.UpdateBeaconRequest_Public{Public: true}})
	if err != nil || in.Audience == nil || !in.Audience.Public || in.Audience.CommunityID != "" {
		t.Fatalf("public = %+v, %v", in.Audience, err)
	}
	in, err = updateInputFromProto(&beaconsv1.UpdateBeaconRequest{Audience: &beaconsv1.UpdateBeaconRequest_CommunityId{CommunityId: testCommunity}})
	if err != nil || in.Audience == nil || in.Audience.Public || in.Audience.CommunityID != testCommunity {
		t.Fatalf("community = %+v, %v", in.Audience, err)
	}
	in, err = updateInputFromProto(&beaconsv1.UpdateBeaconRequest{})
	if err != nil || in.Audience != nil {
		t.Fatalf("unset = %+v, %v; want nil", in.Audience, err)
	}
}
