//go:build integration

package e2e

// Key directory E2E smoke (E2EE plan 2, Task 8). Boots the real handler via newTestServerCfg with FEATURE_E2EE_DM in
// allowlist mode (the uids are minted first so the allowlist can name them) and FEATURE_MESSAGING on, over the Firestore
// and Auth emulators. Skips when FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST are not set. The deletion test
// also needs the Pub/Sub and Storage emulators (like account_smoke_test.go) and skips without them.
//
// Scenario: A and B follow each other. A registers a device and uploads 3 key packages plus a last-resort package; B
// registers. B claims A (one package, not last-resort, A's key; A's pool is then 2), B looks A up (counts zeroed, no
// timestamps). A blocks B: B's claim and B's lookup answer CANNOT_MESSAGE, identical on the wire (raw HTTP: status, body
// bytes, content type) to each other, to the answers for an unknown user and to those for a SUSPENDED user.
// A caller without the flag (not in the allowlist, flag not globally off) gets FEATURE_DISABLED on the three gated RPCs
// and can still list, remove and look up (an empty success without a shared encrypted conversation). No credentials
// answer 401 on all six procedures. Account deletion erases users/{A}/keyDevices and users/{A}/keyDeviceRemovals (a
// mark left by a REMOTE removal, whose id is then refused with DEVICE_REMOVED, and an orphan mark).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"connectrpc.com/connect"
	"google.golang.org/api/option"
	pubsub "google.golang.org/api/pubsub/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func keysKey(op string) string { return fmt.Sprintf("e2e-keys-%s-%d", op, rand.Int63()) }

func keysRandBytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rand.Intn(256))
	}
	return b
}

// keysDeviceID is a valid device id (16-64 of [A-Za-z0-9_-]), unique per call.
func keysDeviceID(label string) string { return fmt.Sprintf("e2e-%s-%016x", label, rand.Int63()) }

// keysErrDetail returns the dzeroth.common.v1.ErrorDetail of a Connect error plus a deterministic wire form of the
// code, message and every detail, for byte-for-byte comparison of refusals.
func keysErrDetail(t *testing.T, err error, code connect.Code) (*commonv1.ErrorDetail, string) {
	t.Helper()
	assertCode(t, err, code)
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	var detail *commonv1.ErrorDetail
	var wire strings.Builder
	fmt.Fprintf(&wire, "%v|%s|", ce.Code(), ce.Message())
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			t.Fatalf("error detail: %v", verr)
		}
		raw, merr := proto.MarshalOptions{Deterministic: true}.Marshal(v)
		if merr != nil {
			t.Fatalf("marshal error detail: %v", merr)
		}
		wire.Write(raw)
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			detail = ed
		}
	}
	if detail == nil {
		t.Fatalf("error %v carries no ErrorDetail", err)
	}
	return detail, wire.String()
}

func keysWantReason(t *testing.T, err error, reason commonv1.ErrorReason, metaKey, metaVal string) string {
	t.Helper()
	d, wire := keysErrDetail(t, err, connect.CodeFailedPrecondition)
	if d.GetReason() != reason {
		t.Errorf("reason = %v, want %v", d.GetReason(), reason)
	}
	if metaKey != "" && d.GetMetadata()[metaKey] != metaVal {
		t.Errorf("metadata[%s] = %q, want %q (all: %v)", metaKey, d.GetMetadata()[metaKey], metaVal, d.GetMetadata())
	}
	return wire
}

// keysWire is one raw HTTP answer as a client sees it: the status code, the Content-Type header and the body bytes.
type keysWire struct {
	status int
	ctype  string
	body   []byte
}

// keysRawPost calls a KeyService procedure the way any client would, without the Connect client: a Connect unary JSON
// POST with the caller's bearer token, so the comparison below sees exactly the bytes on the wire.
func keysRawPost(t *testing.T, baseURL, proc, token string, msg proto.Message) keysWire {
	t.Helper()
	body, err := protojson.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal %s request: %v", proc, err)
	}
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, baseURL+proc, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", proc, err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read %s response: %v", proc, err)
	}
	return keysWire{status: resp.StatusCode, ctype: resp.Header.Get("Content-Type"), body: raw}
}

type keysSmokeUser struct{ token, uid string }

func (u keysSmokeUser) withProfile(t *testing.T, ident identityv1connect.IdentityServiceClient, label string) keysSmokeUser {
	t.Helper()
	if _, err := ident.CreateProfile(context.Background(), authedRequest(u.token, &identityv1.CreateProfileRequest{
		IdempotencyKey: keysKey("create-" + label),
		Handle:         uniqueHandle("k8" + label),
		DisplayName:    "Keys Smoke " + label,
	})); err != nil {
		t.Fatalf("CreateProfile(%s): %v", label, err)
	}
	return u
}

func TestE2E_KeysSmoke_RegisterClaimBlockFlag(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()

	// Mint first so the allowlist can name A and B; C stays off it (the flag is not globally off: C is "dropped").
	tokA, uidA := newAnonymousIDToken(t)
	tokB, uidB := newAnonymousIDToken(t)
	tokC, uidC := newAnonymousIDToken(t)
	allow := map[string]struct{}{uidA: {}, uidB: {}}
	ident, baseURL := newTestServerCfg(t, func(c *config.Config) {
		c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.On}
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allow}
		c.RateLimit.PreAuthIPPerMinute = 100000
	})
	a := keysSmokeUser{tokA, uidA}.withProfile(t, ident, "a")
	b := keysSmokeUser{tokB, uidB}.withProfile(t, ident, "b")
	c := keysSmokeUser{tokC, uidC}.withProfile(t, ident, "c")
	graph := graphv1connect.NewGraphServiceClient(http.DefaultClient, baseURL)
	keys := keysv1connect.NewKeyServiceClient(http.DefaultClient, baseURL)

	for _, f := range []struct{ who, target keysSmokeUser }{{a, b}, {b, a}} {
		if _, err := graph.Follow(ctx, authedRequest(f.who.token, &graphv1.FollowRequest{IdempotencyKey: keysKey("follow"), UserId: f.target.uid})); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	}

	// A registers a device and uploads 3 packages plus a last-resort; B registers its own device.
	devA, devB := keysDeviceID("a"), keysDeviceID("b")
	sigA, sigB := keysRandBytes(32), keysRandBytes(32)
	if _, err := keys.RegisterKeyDevice(ctx, authedRequest(a.token, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg-a"), DeviceId: devA, SignaturePublicKey: sigA})); err != nil {
		t.Fatalf("RegisterKeyDevice(A): %v", err)
	}
	pkgs := [][]byte{keysRandBytes(64), keysRandBytes(65), keysRandBytes(66)}
	lastResort := keysRandBytes(70)
	up, err := keys.UploadKeyPackages(ctx, authedRequest(a.token, &keysv1.UploadKeyPackagesRequest{
		IdempotencyKey: keysKey("up-a"), DeviceId: devA, KeyPackages: pkgs, LastResortKeyPackage: lastResort,
	}))
	if err != nil || up.Msg.GetKeyPackageCount() != 3 || !up.Msg.GetHasLastResort() {
		t.Fatalf("UploadKeyPackages(A) = %v, %v; want 3 packages and a last-resort", up, err)
	}
	if _, err := keys.RegisterKeyDevice(ctx, authedRequest(b.token, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg-b"), DeviceId: devB, SignaturePublicKey: sigB})); err != nil {
		t.Fatalf("RegisterKeyDevice(B): %v", err)
	}

	// B claims A: exactly one package for A's device, one of the three, with A's key.
	claim, err := keys.ClaimKeyPackages(ctx, authedRequest(b.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("claim"), UserId: a.uid}))
	if err != nil {
		t.Fatalf("ClaimKeyPackages(B->A): %v", err)
	}
	got := claim.Msg.GetKeyPackages()
	if len(got) != 1 {
		t.Fatalf("claimed %d devices, want 1: %v", len(got), got)
	}
	one := got[0]
	isUploaded := false
	for _, p := range pkgs {
		isUploaded = isUploaded || bytes.Equal(p, one.GetKeyPackage())
	}
	if one.GetDeviceId() != devA || !one.GetHasKeyPackage() || one.GetLastResort() || !isUploaded || !bytes.Equal(one.GetSignaturePublicKey(), sigA) {
		t.Fatalf("claimed = device %q has %v last_resort %v uploaded %v key-match %v", one.GetDeviceId(), one.GetHasKeyPackage(), one.GetLastResort(), isUploaded, bytes.Equal(one.GetSignaturePublicKey(), sigA))
	}
	mine, err := keys.ListMyKeyDevices(ctx, authedRequest(a.token, &keysv1.ListMyKeyDevicesRequest{}))
	if err != nil || len(mine.Msg.GetDevices()) != 1 || mine.Msg.GetDevices()[0].GetKeyPackageCount() != 2 || !mine.Msg.GetDevices()[0].GetHasLastResort() {
		t.Fatalf("ListMyKeyDevices(A) after one claim = %v, %v; want one device with key_package_count 2 and a last-resort", mine, err)
	}

	// B looks A up: A's device, counts zeroed.
	look, err := keys.GetKeyDevices(ctx, authedRequest(b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{a.uid}}))
	if err != nil {
		t.Fatalf("GetKeyDevices(B->A): %v", err)
	}
	users := look.Msg.GetUsers()
	if len(users) != 1 || users[0].GetUserId() != a.uid || len(users[0].GetDevices()) != 1 {
		t.Fatalf("GetKeyDevices = %v, want A with one device", users)
	}
	if d := users[0].GetDevices()[0]; d.GetDeviceId() != devA || !bytes.Equal(d.GetSignaturePublicKey(), sigA) || d.GetKeyPackageCount() != 0 || d.GetHasLastResort() {
		t.Fatalf("A's device as seen by B = %v, want id %s, A's key, counts zeroed", d, devA)
	}
	// Another user's device carries no timestamps; the owner's own list keeps them.
	if d := users[0].GetDevices()[0]; d.GetCreatedAt() != nil || d.GetLastSeenAt() != nil {
		t.Fatalf("A's device as seen by B carries created_at %v / last_seen_at %v, want both absent", d.GetCreatedAt(), d.GetLastSeenAt())
	}
	if d := mine.Msg.GetDevices()[0]; d.GetCreatedAt() == nil || d.GetLastSeenAt() == nil {
		t.Fatalf("A's own device lost its timestamps: %v", d)
	}

	// A blocks B (the real graph service): B's claim and lookup refuse, byte-identical to each other and to an unknown user.
	if _, err := graph.Block(ctx, authedRequest(a.token, &graphv1.BlockRequest{IdempotencyKey: keysKey("block"), UserId: b.uid})); err != nil {
		t.Fatalf("Block(A->B): %v", err)
	}
	_, claimErr := keys.ClaimKeyPackages(ctx, authedRequest(b.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("claim-blocked"), UserId: a.uid}))
	claimWire := keysWantReason(t, claimErr, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
	_, lookErr := keys.GetKeyDevices(ctx, authedRequest(b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{a.uid}}))
	lookWire := keysWantReason(t, lookErr, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
	// A well-formed id that names nobody (28 chars, like a Firebase uid).
	_, unkErr := keys.GetKeyDevices(ctx, authedRequest(b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{"NoSuchUserAnywhere0000000000"}}))
	unkWire := keysWantReason(t, unkErr, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
	if claimWire != lookWire || lookWire != unkWire {
		t.Fatalf("the refusals differ on the wire:\n  blocked claim  %q\n  blocked lookup %q\n  unknown lookup %q", claimWire, lookWire, unkWire)
	}

	// The same comparison on the raw HTTP answer (status, body bytes, content type), adding an unknown-user claim and a
	// SUSPENDED target. D's profile is created on a second instance and suspended in Firestore, so this instance never
	// cached D as ACTIVE.
	tokD, uidD := newAnonymousIDToken(t)
	identD, _ := newTestServerCfg(t, func(c *config.Config) {
		c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.On}
		c.RateLimit.PreAuthIPPerMinute = 100000
	})
	keysSmokeUser{tokD, uidD}.withProfile(t, identD, "d")
	fsCfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	fs, err := firestore.NewClient(ctx, fsCfg.ProjectID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fs.Close() })
	if _, err := fs.Doc("users/"+uidD).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatalf("suspend D: %v", err)
	}
	const unknownUID = "NoSuchUserAnywhere0000000000"
	claimProc, lookProc := keysv1connect.KeyServiceClaimKeyPackagesProcedure, keysv1connect.KeyServiceGetKeyDevicesProcedure
	raw := []struct {
		name string
		got  keysWire
	}{
		{"blocked claim", keysRawPost(t, baseURL, claimProc, b.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("raw-claim-blocked"), UserId: a.uid})},
		{"blocked lookup", keysRawPost(t, baseURL, lookProc, b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{a.uid}})},
		{"unknown-user lookup", keysRawPost(t, baseURL, lookProc, b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{unknownUID}})},
		{"unknown-user claim", keysRawPost(t, baseURL, claimProc, b.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("raw-claim-unknown"), UserId: unknownUID})},
		{"suspended-user claim", keysRawPost(t, baseURL, claimProc, b.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("raw-claim-suspended"), UserId: uidD})},
		{"suspended-user lookup", keysRawPost(t, baseURL, lookProc, b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{uidD}})},
	}
	want := raw[0].got
	if want.status == http.StatusOK || len(want.body) == 0 || !strings.Contains(string(want.body), "failed_precondition") {
		t.Fatalf("blocked claim on the wire = HTTP %d %q %s, want a failed_precondition error", want.status, want.ctype, want.body)
	}
	for _, r := range raw[1:] {
		if r.got.status != want.status || r.got.ctype != want.ctype || !bytes.Equal(r.got.body, want.body) {
			t.Errorf("%s differs on the wire from the blocked claim:\n  got  HTTP %d %q %s\n  want HTTP %d %q %s",
				r.name, r.got.status, r.got.ctype, r.got.body, want.status, want.ctype, want.body)
		}
	}

	// Flag off for the caller (C is not on the allowlist): the three gated RPCs answer FEATURE_DISABLED / e2ee_dm before any lookup.
	for name, call := range map[string]func() error{
		"RegisterKeyDevice": func() error {
			_, err := keys.RegisterKeyDevice(ctx, authedRequest(c.token, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg-c"), DeviceId: keysDeviceID("c"), SignaturePublicKey: keysRandBytes(32)}))
			return err
		},
		"UploadKeyPackages": func() error {
			_, err := keys.UploadKeyPackages(ctx, authedRequest(c.token, &keysv1.UploadKeyPackagesRequest{IdempotencyKey: keysKey("up-c"), DeviceId: keysDeviceID("c"), KeyPackages: [][]byte{{1}}}))
			return err
		},
		"ClaimKeyPackages": func() error {
			_, err := keys.ClaimKeyPackages(ctx, authedRequest(c.token, &keysv1.ClaimKeyPackagesRequest{IdempotencyKey: keysKey("claim-c"), UserId: a.uid}))
			return err
		},
	} {
		t.Run("flag off for the caller: "+name, func(t *testing.T) {
			keysWantReason(t, call(), commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")
		})
	}
	// GetKeyDevices also needs only "not globally off": C has no encrypted conversation with A, so the lookup is an empty
	// success (A's device stays hidden), never FEATURE_DISABLED.
	if res, err := keys.GetKeyDevices(ctx, authedRequest(c.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{a.uid}})); err != nil ||
		len(res.Msg.GetUsers()) != 1 || len(res.Msg.GetUsers()[0].GetDevices()) != 0 {
		t.Errorf("GetKeyDevices without the flag = %v, %v; want an empty success", res, err)
	}
	// ListMyKeyDevices and RemoveKeyDevice need only "not globally off": a user off the allowlist still works. (A user who
	// had a device and was then dropped cannot be expressed here: the allowlist is fixed when the server is built.)
	if res, err := keys.ListMyKeyDevices(ctx, authedRequest(c.token, &keysv1.ListMyKeyDevicesRequest{})); err != nil || len(res.Msg.GetDevices()) != 0 {
		t.Errorf("ListMyKeyDevices without the flag = %v, %v; want an empty success", res, err)
	}
	if _, err := keys.RemoveKeyDevice(ctx, authedRequest(c.token, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: keysKey("rm-c"), DeviceId: keysDeviceID("c")})); err != nil {
		t.Errorf("RemoveKeyDevice without the flag (missing device = success): %v", err)
	}

	// No credentials: 401 on every one of the six procedures.
	for _, proc := range []string{
		keysv1connect.KeyServiceRegisterKeyDeviceProcedure,
		keysv1connect.KeyServiceListMyKeyDevicesProcedure,
		keysv1connect.KeyServiceRemoveKeyDeviceProcedure,
		keysv1connect.KeyServiceUploadKeyPackagesProcedure,
		keysv1connect.KeyServiceGetKeyDevicesProcedure,
		keysv1connect.KeyServiceClaimKeyPackagesProcedure,
	} {
		resp, err := http.Post(baseURL+proc, "application/json", strings.NewReader(`{}`))
		if err != nil {
			t.Fatalf("POST %s: %v", proc, err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("POST %s without credentials: HTTP %d, want 401", proc, resp.StatusCode)
		}
	}
}

// TestE2E_KeysSmoke_AccountDeletionErasesKeyDevices deletes A through the real lifecycle (DeleteAccount, the jobs chain
// played over the Pub/Sub emulator, as account_smoke_test.go) and reads Firestore directly: before the deletion the device,
// its two pool documents and a pool under a device that no longer exists are present (a positive control, so a wrong path
// cannot pass vacuously); after it nothing is left under users/{A}/keyDevices, including the orphan pool.
func TestE2E_KeysSmoke_AccountDeletionErasesKeyDevices(t *testing.T) {
	skipIfNoEmulators(t)
	if os.Getenv("PUBSUB_EMULATOR_HOST") == "" || os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("PUBSUB_EMULATOR_HOST/STORAGE_EMULATOR_HOST not set; run via the emulator suite")
	}
	ctx := context.Background()
	suffix := rand.Int63()
	topic, bucketName := fmt.Sprintf("jobs-e2e-keys-%d", suffix), fmt.Sprintf("demo-e2e-keys-exports-%d", suffix)

	tokA, uidA := newAnonymousIDToken(t)
	allow := map[string]struct{}{uidA: {}}
	identClient, baseURL := newTestServerCfg(t, func(c *config.Config) {
		c.FeatureMessaging = flags.Spec{Name: "messaging", Mode: flags.On}
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allow}
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic, c.ExportBucket = topic, bucketName
		c.RateLimit.PreAuthIPPerMinute = 100000
	})
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	e := &accountSmokeEnv{identity: identClient, baseURL: baseURL, cfg: cfg, tokenA: tokA, uidA: uidA}
	e.fs, err = firestore.NewClient(ctx, cfg.ProjectID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.fs.Close() })
	e.ps, err = pubsub.NewService(ctx, option.WithEndpoint("http://"+os.Getenv("PUBSUB_EMULATOR_HOST")+"/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	topicName := fmt.Sprintf("projects/%s/topics/%s", cfg.ProjectID, topic)
	e.sub = fmt.Sprintf("projects/%s/subscriptions/sub-%d", cfg.ProjectID, suffix)
	if _, err := e.ps.Projects.Topics.Create(topicName, &pubsub.Topic{}).Context(ctx).Do(); err != nil {
		t.Fatalf("create topic: %v", err)
	}
	if _, err := e.ps.Projects.Subscriptions.Create(e.sub, &pubsub.Subscription{Topic: topicName, AckDeadlineSeconds: 60}).Context(ctx).Do(); err != nil {
		t.Fatalf("create subscription: %v", err)
	}
	sc, err := storage.NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sc.Close() })
	e.bucket = sc.Bucket(bucketName)

	keysSmokeUser{tokA, uidA}.withProfile(t, identClient, "d")
	keys := keysv1connect.NewKeyServiceClient(http.DefaultClient, baseURL)

	dev := keysDeviceID("del")
	if _, err := keys.RegisterKeyDevice(ctx, authedRequest(tokA, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg"), DeviceId: dev, SignaturePublicKey: keysRandBytes(32)})); err != nil {
		t.Fatalf("RegisterKeyDevice: %v", err)
	}
	if _, err := keys.UploadKeyPackages(ctx, authedRequest(tokA, &keysv1.UploadKeyPackagesRequest{
		IdempotencyKey: keysKey("up"), DeviceId: dev, KeyPackages: [][]byte{keysRandBytes(40), keysRandBytes(41)}, LastResortKeyPackage: keysRandBytes(42),
	})); err != nil {
		t.Fatalf("UploadKeyPackages: %v", err)
	}
	// A second device removed from "another device" (REMOTE, with the token's fresh sign-in): it leaves a removed mark, and
	// the same id is then refused with DEVICE_REMOVED through the real handler.
	lost := keysDeviceID("lost")
	if _, err := keys.RegisterKeyDevice(ctx, authedRequest(tokA, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg-lost"), DeviceId: lost, SignaturePublicKey: keysRandBytes(32)})); err != nil {
		t.Fatalf("RegisterKeyDevice (lost): %v", err)
	}
	if _, err := keys.RemoveKeyDevice(ctx, authedRequest(tokA, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: keysKey("rm-lost"), DeviceId: lost, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE})); err != nil {
		t.Fatalf("RemoveKeyDevice REMOTE: %v", err)
	}
	_, err = keys.RegisterKeyDevice(ctx, authedRequest(tokA, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: keysKey("reg-lost2"), DeviceId: lost, SignaturePublicKey: keysRandBytes(32)}))
	keysWantReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED, "", "")
	// A mark with no device document behind it (a REMOTE removal of an id that was never registered).
	orphanMark := keysDeviceID("orphanmark")
	if _, err := e.fs.Doc("users/"+uidA+"/keyDeviceRemovals/"+orphanMark).Set(ctx, map[string]any{"removedAt": time.Now(), "expireAt": time.Now().Add(90 * 24 * time.Hour)}); err != nil {
		t.Fatalf("seed orphan mark: %v", err)
	}
	markPaths := []string{"users/" + uidA + "/keyDeviceRemovals/" + lost, "users/" + uidA + "/keyDeviceRemovals/" + orphanMark}
	for _, path := range markPaths {
		if snap, err := e.fs.Doc(path).Get(ctx); err != nil || !snap.Exists() {
			t.Fatalf("before the deletion: %s missing (the positive control): %v", path, err)
		}
	}
	// A pool under a device document that does not exist (what a concurrent remove can leave behind).
	ghost := keysDeviceID("ghost")
	if _, err := e.fs.Doc("users/"+uidA+"/keyDevices/"+ghost+"/keyPackages/orphan1").Set(ctx, map[string]any{"data": keysRandBytes(8)}); err != nil {
		t.Fatalf("seed orphan pool: %v", err)
	}

	// Everything under users/{A}/keyDevices, found by path: device docs (existing or only a parent of a pool) and pool docs.
	residue := func() (devices, pools int) {
		refs, err := e.fs.Collection("users/" + uidA + "/keyDevices").DocumentRefs(ctx).GetAll()
		if err != nil {
			t.Fatalf("list keyDevices refs: %v", err)
		}
		for _, ref := range refs {
			if snap, err := ref.Get(ctx); err == nil && snap.Exists() {
				devices++
			}
			docs, err := ref.Collection("keyPackages").Limit(200).Documents(ctx).GetAll()
			if err != nil {
				t.Fatalf("list %s pool: %v", ref.Path, err)
			}
			pools += len(docs)
		}
		return devices, pools
	}
	if d, p := residue(); d != 1 || p != 3 { // the device, its 2 packages + the orphan; the last-resort lives on the device doc
		t.Fatalf("before the deletion: %d device docs and %d pool docs under users/%s/keyDevices, want 1 and 3 (the positive control)", d, p, uidA)
	}
	if refs, _ := e.fs.Collection("users/" + uidA + "/keyDevices").DocumentRefs(ctx).GetAll(); len(refs) != 2 {
		t.Fatalf("DocumentRefs listed %d refs, want 2 (the device and the orphan's missing parent)", len(refs))
	}

	if _, err := identClient.DeleteAccount(ctx, authedRequest(tokA, &identityv1.DeleteAccountRequest{IdempotencyKey: keysKey("delete")})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	if _, err := e.fs.Doc("users/"+uidA).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	e.runJobs(t)

	if snap, err := e.fs.Doc("users/" + uidA).Get(ctx); err == nil && snap.Exists() {
		t.Fatal("users/{uid} survived the deletion (the lifecycle did not finish, so the key check below would prove nothing)")
	}
	if d, p := residue(); d != 0 || p != 0 {
		t.Errorf("after the deletion: %d device docs and %d pool docs remain under users/%s/keyDevices, want 0 and 0", d, p, uidA)
	}
	for _, path := range append([]string{"users/" + uidA + "/keyDevices/" + dev, "users/" + uidA + "/keyDevices/" + ghost + "/keyPackages/orphan1"}, markPaths...) {
		if snap, err := e.fs.Doc(path).Get(ctx); err == nil && snap.Exists() {
			t.Errorf("%s survived the deletion", path)
		}
	}
	if refs, err := e.fs.Collection("users/" + uidA + "/keyDeviceRemovals").DocumentRefs(ctx).GetAll(); err != nil || len(refs) != 0 {
		t.Errorf("after the deletion: %d refs under users/%s/keyDeviceRemovals (%v), want 0", len(refs), uidA, err)
	}
}
