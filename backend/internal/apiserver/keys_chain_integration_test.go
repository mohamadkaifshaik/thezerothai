//go:build integration

package apiserver

// The key directory over the real Build chain (Firestore and Auth emulators): the KeyService handler mounted behind
// FEATURE_E2EE_DM, the one keys repository, and the messaging send rules reached through messaging.Permission and the
// apiserver adapter. A stranger may look up and claim (a first message would be a request, which is allowed); a user the
// owner blocked, and an unknown user, get the same CANNOT_MESSAGE; a target with the flag off is an empty success; a
// caller dropped from the allowlist can still list and remove their devices but not look anyone up.

import (
	"bytes"
	"context"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestKeysChain_LookupClaimAndRefusals(t *testing.T) {
	ctx := context.Background()
	skipIfNoEmulators(t)
	// The users are minted first so the allowlist can name them: owner, stranger and blocked have the flag; flagOff does
	// not (the flag is not globally off, so it is "dropped from the allowlist").
	mint := func() dmUser { tok, uid := mintToken(t, ""); return dmUser{tok, uid} }
	owner, stranger, blocked, flagOff := mint(), mint(), mint(), mint()
	allow := map[string]struct{}{owner.uid: {}, stranger.uid: {}, blocked.uid: {}}
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allow}
	})
	for _, u := range []dmUser{owner, stranger, blocked, flagOff} {
		e.createProfile(t, u.token)
	}
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	// owner blocks `blocked` before anyone looks anything up (no cached graph to age out).
	if _, err := e.graph.Block(ctx, authed(owner.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("keys-block"), UserId: blocked.uid})); err != nil {
		t.Fatalf("Block: %v", err)
	}

	const device = "keys-chain-device-0001"
	sig := bytes.Repeat([]byte{5}, 32)
	if _, err := keysClient.RegisterKeyDevice(ctx, authed(owner.token, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("keys-reg"), DeviceId: device, SignaturePublicKey: sig})); err != nil {
		t.Fatalf("RegisterKeyDevice: %v", err)
	}
	up, err := keysClient.UploadKeyPackages(ctx, authed(owner.token, &keysv1.UploadKeyPackagesRequest{
		IdempotencyKey: contractKey("keys-up"), DeviceId: device, KeyPackages: [][]byte{[]byte("one"), []byte("two")}, LastResortKeyPackage: []byte("last"),
	}))
	if err != nil || up.Msg.GetKeyPackageCount() != 2 || !up.Msg.GetHasLastResort() {
		t.Fatalf("UploadKeyPackages = %v, %v", up, err)
	}

	t.Run("a stranger looks up in request order, with the counts zeroed", func(t *testing.T) {
		res, err := keysClient.GetKeyDevices(ctx, authed(stranger.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{stranger.uid, flagOff.uid, owner.uid}}))
		if err != nil {
			t.Fatalf("GetKeyDevices: %v", err)
		}
		users := res.Msg.GetUsers()
		if len(users) != 3 || users[0].GetUserId() != stranger.uid || users[1].GetUserId() != flagOff.uid || users[2].GetUserId() != owner.uid {
			t.Fatalf("users = %v, want request order", users)
		}
		if len(users[0].GetDevices()) != 0 || len(users[1].GetDevices()) != 0 {
			t.Fatalf("stranger (no device) and flag-off user (empty success) = %v", users)
		}
		d := users[2].GetDevices()
		if len(d) != 1 || d[0].GetDeviceId() != device || !bytes.Equal(d[0].GetSignaturePublicKey(), sig) || d[0].GetKeyPackageCount() != 0 || d[0].GetHasLastResort() {
			t.Fatalf("owner's devices = %v, want one with zeroed counts", d)
		}
	})

	t.Run("a stranger claims one one-time package", func(t *testing.T) {
		res, err := keysClient.ClaimKeyPackages(ctx, authed(stranger.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: contractKey("keys-claim"), UserId: owner.uid}))
		if err != nil {
			t.Fatalf("ClaimKeyPackages: %v", err)
		}
		got := res.Msg.GetKeyPackages()
		if len(got) != 1 || got[0].GetDeviceId() != device || !got[0].GetHasKeyPackage() || got[0].GetLastResort() ||
			(!bytes.Equal(got[0].GetKeyPackage(), []byte("one")) && !bytes.Equal(got[0].GetKeyPackage(), []byte("two"))) {
			t.Fatalf("claimed = %v", got)
		}
		mine, err := keysClient.ListMyKeyDevices(ctx, authed(owner.token, &keysv1.ListMyKeyDevicesRequest{}))
		if err != nil || len(mine.Msg.GetDevices()) != 1 || mine.Msg.GetDevices()[0].GetKeyPackageCount() != 1 {
			t.Fatalf("owner's pool after one claim = %v, %v", mine, err)
		}
	})

	t.Run("blocked and unknown users get the one CANNOT_MESSAGE", func(t *testing.T) {
		_, gerr := keysClient.GetKeyDevices(ctx, authed(blocked.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{owner.uid}}))
		wantReason(t, gerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
		_, cerr := keysClient.ClaimKeyPackages(ctx, authed(blocked.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: contractKey("keys-claim-b"), UserId: owner.uid}))
		wantReason(t, cerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
		_, uerr := keysClient.GetKeyDevices(ctx, authed(stranger.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{"NoSuchUserAnywhere0000000000"}}))
		wantReason(t, uerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
		if wireBytes(t, gerr) != wireBytes(t, uerr) || wireBytes(t, gerr) != wireBytes(t, cerr) {
			t.Fatalf("the refusals differ on the wire:\n  blocked lookup %s\n  blocked claim  %s\n  unknown lookup %s", wireBytes(t, gerr), wireBytes(t, cerr), wireBytes(t, uerr))
		}
	})

	t.Run("a caller without the flag can list, remove and look up (empty without a shared conversation)", func(t *testing.T) {
		if _, err := keysClient.ListMyKeyDevices(ctx, authed(flagOff.token, &keysv1.ListMyKeyDevicesRequest{})); err != nil {
			t.Fatalf("ListMyKeyDevices without the flag (not globally off): %v", err)
		}
		if _, err := keysClient.RemoveKeyDevice(ctx, authed(flagOff.token, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("keys-rm-off"), DeviceId: device})); err != nil {
			t.Fatalf("RemoveKeyDevice without the flag (not globally off): %v", err)
		}
		// Not globally off, so the lookup runs: the send rules allow it, there is no shared encrypted conversation, so it is
		// an empty success, never FEATURE_DISABLED.
		res, err := keysClient.GetKeyDevices(ctx, authed(flagOff.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{owner.uid}}))
		if err != nil {
			t.Fatalf("GetKeyDevices without the flag (not globally off): %v", err)
		}
		if users := res.Msg.GetUsers(); len(users) != 1 || users[0].GetUserId() != owner.uid || len(users[0].GetDevices()) != 0 {
			t.Fatalf("flag-off caller's lookup = %v, want one user with no devices", users)
		}
	})
}
