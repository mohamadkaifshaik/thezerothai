package beacons

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

func assertForbidden(t *testing.T, err error, reason string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Code != connect.CodePermissionDenied || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FORBIDDEN || ae.Metadata["reason"] != reason {
		t.Fatalf("err = code %v reason %v meta %v, want PERMISSION_DENIED FORBIDDEN reason=%s", ae.Code, ae.Reason, ae.Metadata, reason)
	}
}

func assertPrecondition(t *testing.T, err error, reason string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeFailedPrecondition || ae.Metadata["reason"] != reason {
		t.Fatalf("err = code %v meta %v, want FAILED_PRECONDITION reason=%s", ae.Code, ae.Metadata, reason)
	}
}

func assertNotFound(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound || ae.Message != "beacon not found" {
		t.Fatalf("err = %v, want NOT_FOUND \"beacon not found\"", err)
	}
}

// TestCreateBeacon_ValidationBeforeAnyRead: every field rule is applied before the repository, the directory or the
// community reader is touched, naming the field.
func TestCreateBeacon_ValidationBeforeAnyRead(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*CreateInput)
		field  string
	}{
		{"key", func(in *CreateInput) { in.Key = "short" }, "idempotency_key"},
		{"title empty", func(in *CreateInput) { in.Title = "" }, "title"},
		{"details long", func(in *CreateInput) { in.Details = strings.Repeat("d", 301) }, "details"},
		{"venue empty", func(in *CreateInput) { in.Venue = "" }, "venue"},
		{"start too soon", func(in *CreateInput) { in.StartAt = testNow.Add(time.Minute) }, "start_at"},
		{"duration short", func(in *CreateInput) { in.DurationMin = 5 }, "duration_minutes"},
		{"open_spots zero", func(in *CreateInput) { in.OpenSpots = 0 }, "open_spots"},
		{"both audiences", func(in *CreateInput) { in.CommunityID = testCommunity }, "audience"},
		{"bad community id", func(in *CreateInput) { in.Public = false; in.CommunityID = "x" }, "community_id"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			in := validCreate()
			tc.mutate(&in)
			_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
			assertValidation(t, err, tc.field)
			if e.repo.calls() != 0 || e.dir.calls != 0 || e.comm.calls != 0 {
				t.Fatalf("reads before validation: repo %d dir %d comm %d", e.repo.calls(), e.dir.calls, e.comm.calls)
			}
		})
	}
	t.Run("open_spots above the cap is LIMIT_REACHED beacon_participants", func(t *testing.T) {
		e := newEnv()
		in := validCreate()
		in.OpenSpots = 21
		_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED || ae.Metadata["limit"] != "beacon_participants" {
			t.Fatalf("err = %v, want LIMIT_REACHED limit=beacon_participants", err)
		}
		if e.repo.calls() != 0 {
			t.Fatal("repository called")
		}
	})
}

// TestCreateBeacon_CommunityNeedsMembership: a community audience needs the caller JOINED (owner, moderator or member);
// none or banned is FORBIDDEN not_member before any profile read.
func TestCreateBeacon_CommunityNeedsMembership(t *testing.T) {
	for _, tc := range []struct {
		name string
		role communities.Role
		ok   bool
	}{
		{"none", communities.RoleNone, false},
		{"banned", communities.RoleBanned, false},
		{"member", communities.RoleMember, true},
		{"moderator", communities.RoleModerator, true},
		{"owner", communities.RoleOwner, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.comm.roles[testCommunity+"|"+testOrganiser] = tc.role
			in := validCreate()
			in.Public, in.CommunityID = false, testCommunity
			_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
			if !tc.ok {
				assertForbidden(t, err, "not_member")
				if e.repo.calls() != 0 || e.dir.calls != 0 {
					t.Fatalf("reads after refusal: repo %d dir %d", e.repo.calls(), e.dir.calls)
				}
				return
			}
			if err != nil {
				t.Fatalf("CreateBeacon: %v", err)
			}
			if len(e.repo.createdBy) != 1 || e.repo.createdBy[0].Beacon.CommunityID != testCommunity {
				t.Fatalf("createdBy = %+v", e.repo.createdBy)
			}
		})
	}
}

// TestCreateBeacon_CommunityFlagOff: a community audience needs FEATURE_COMMUNITIES on for the caller.
func TestCreateBeacon_CommunityFlagOff(t *testing.T) {
	e := newEnv()
	e.flags.on[communities.FlagName] = false
	e.comm.roles[testCommunity+"|"+testOrganiser] = communities.RoleMember
	in := validCreate()
	in.Public, in.CommunityID = false, testCommunity
	_, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
	assertDisabled(t, err, communities.FlagName)
	if e.repo.calls() != 0 || e.comm.calls != 0 {
		t.Fatal("reads after a disabled flag")
	}
}

// TestCreateBeacon_PassesParamsAndHashesRequest: the repository gets the normalised beacon, the derived end and expiry
// inputs, the cap and a request hash that is stable per body; the answer carries the organiser's live row and state.
func TestCreateBeacon_PassesParamsAndHashesRequest(t *testing.T) {
	e := newEnv()
	in := validCreate()
	in.Title = "  Coffee at 4  "
	v, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in)
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	p := e.repo.createdBy[0]
	if p.UID != testOrganiser || p.ID != testBeaconID || p.MaxOpenPerUser != 5 || p.IdemKey != idempotency.Key(testOrganiser, rpcCreateBeacon, testKey) {
		t.Fatalf("params = %+v", p)
	}
	if p.Beacon.Title != "Coffee at 4" || !p.Beacon.EndAt.Equal(in.StartAt.Add(25*time.Minute)) || p.Beacon.CommunityID != "" {
		t.Fatalf("beacon = %+v", p.Beacon)
	}
	if v.Organiser.UserID != testOrganiser || v.Viewer.Role != RoleOrganiser || !v.Viewer.CanManage || v.Viewer.CanRequest {
		t.Fatalf("view = %+v", v)
	}
	if v.Beacon.Status != StatusOpen {
		t.Fatalf("status = %q, want open", v.Beacon.Status)
	}
	// Same body, same hash; a different title, a different hash.
	if _, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in); err != nil {
		t.Fatal(err)
	}
	in2 := in
	in2.Title = "Tea"
	if _, err := e.svc.CreateBeacon(context.Background(), testOrganiser, in2); err != nil {
		t.Fatal(err)
	}
	h := e.repo.createdBy
	if h[0].RequestHash != h[1].RequestHash || h[1].RequestHash == h[2].RequestHash {
		t.Fatalf("hashes = %q %q %q", h[0].RequestHash, h[1].RequestHash, h[2].RequestHash)
	}
}

// TestUpdateBeacon_Rules: visibility is proved first (another organiser's beacon is FORBIDDEN not_organiser, a hidden
// one NOT_FOUND), then the repository's verdicts map to FAILED_PRECONDITION with a reason.
func TestUpdateBeacon_Rules(t *testing.T) {
	title := "New"
	t.Run("not the organiser", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		_, err := e.svc.UpdateBeacon(context.Background(), testViewer, UpdateInput{Key: testKey, BeaconID: testBeaconID, Title: &title})
		assertForbidden(t, err, "not_organiser")
		if len(e.repo.updatedBy) != 0 {
			t.Fatal("repository Update called")
		}
	})
	t.Run("hidden to another is not found", func(t *testing.T) {
		e := newEnv()
		b := e.openBeacon()
		b.Hidden = true
		e.repo.docs[testBeaconID] = b
		_, err := e.svc.UpdateBeacon(context.Background(), testViewer, UpdateInput{Key: testKey, BeaconID: testBeaconID, Title: &title})
		assertNotFound(t, err)
	})
	for _, tc := range []struct {
		name   string
		repoE  error
		reason string
	}{
		{"ended", ErrEnded, "ended"},
		{"cancelled", ErrCancelled, "cancelled"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.err = tc.repoE
			_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Title: &title})
			assertPrecondition(t, err, tc.reason)
		})
	}
	t.Run("title is normalised and Now is the clock", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.update = UpdateResult{Outcome: Written, Beacon: e.openBeacon()}
		padded := "  New  "
		if _, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Title: &padded}); err != nil {
			t.Fatal(err)
		}
		p := e.repo.updatedBy[0]
		if p.Title == nil || *p.Title != "New" || !p.Now.Equal(e.now) || p.IdemKey != idempotency.Key(testOrganiser, rpcUpdateBeacon, testKey) {
			t.Fatalf("params = %+v", p)
		}
	})
}

// TestCancelBeacon_PassesParams: the organiser's cancel reaches the repository with the clock and the key; a replay is a
// success.
func TestCancelBeacon_PassesParams(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	e.repo.cancel = CancelResult{Outcome: Replayed, Beacon: e.openBeacon()}
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	p := e.repo.cancelledBy[0]
	if p.UID != testOrganiser || p.BeaconID != testBeaconID || !p.Now.Equal(e.now) || p.IdemKey != idempotency.Key(testOrganiser, rpcCancelBeacon, testKey) {
		t.Fatalf("params = %+v", p)
	}
	if err := e.svc.CancelBeacon(context.Background(), testViewer, testKey, testBeaconID); err == nil {
		t.Fatal("another caller could cancel")
	} else {
		assertForbidden(t, err, "not_organiser")
	}
}
