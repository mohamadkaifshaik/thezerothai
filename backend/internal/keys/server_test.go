package keys

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const (
	srvCaller = "uid-caller"
	srvOther  = "uid-other"
	srvThird  = "uid-third"
	srvKey    = "key-0123456789abcdef"
	srvDevice = "device-0123456789ab"
)

// fakeService records every call's arguments and answers from its fields.
type fakeService struct {
	calls []string
	// the last arguments
	uid, deviceID, target, exclude string
	sigKey, lastResort             []byte
	packages                       [][]byte
	userIDs                        []string

	device   Device
	devices  []Device
	byUser   map[string][]Device
	claimed  []Claimed
	convID   string // the conversation id Claim answers
	pool     int
	hasLR    bool
	err      error
	deadline time.Duration // the remaining deadline the service saw
}

func (f *fakeService) note(ctx context.Context, op, uid string) {
	f.calls = append(f.calls, op)
	f.uid = uid
	if d, ok := ctx.Deadline(); ok {
		f.deadline = time.Until(d)
	}
}

func (f *fakeService) Register(ctx context.Context, uid, deviceID string, signatureKey []byte) (Device, error) {
	f.note(ctx, "register", uid)
	f.deviceID, f.sigKey = deviceID, signatureKey
	return f.device, f.err
}

func (f *fakeService) ListMine(ctx context.Context, uid string) ([]Device, error) {
	f.note(ctx, "list", uid)
	return f.devices, f.err
}

func (f *fakeService) Remove(ctx context.Context, uid, deviceID string) error {
	f.note(ctx, "remove", uid)
	f.deviceID = deviceID
	return f.err
}

func (f *fakeService) Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte) (int, bool, error) {
	f.note(ctx, "upload", uid)
	f.deviceID, f.packages, f.lastResort = deviceID, packages, lastResort
	return f.pool, f.hasLR, f.err
}

func (f *fakeService) GetDevices(ctx context.Context, uid string, userIDs []string) (map[string][]Device, error) {
	f.note(ctx, "get_devices", uid)
	f.userIDs = userIDs
	return f.byUser, f.err
}

func (f *fakeService) Claim(ctx context.Context, uid, targetUID, excludeDeviceID string) ([]Claimed, string, error) {
	f.note(ctx, "claim", uid)
	f.target, f.exclude = targetUID, excludeDeviceID
	return f.claimed, f.convID, f.err
}

var _ Service = (*fakeService)(nil)

func srvCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

// srvRPC is one KeyService RPC driven through the handler with a well-formed request (key is the idempotency key).
type srvRPC struct {
	name     string
	mutating bool
	// notOff: the RPC needs the flag only not globally off (ListMyKeyDevices, RemoveKeyDevice); else on for the caller.
	notOff bool
	run    func(ctx context.Context, s *Server, key string) error
}

var srvRPCs = []srvRPC{
	{"RegisterKeyDevice", true, false, func(ctx context.Context, s *Server, key string) error {
		_, err := s.RegisterKeyDevice(ctx, connect.NewRequest(&keysv1.RegisterKeyDeviceRequest{IdempotencyKey: key, DeviceId: srvDevice, SignaturePublicKey: make([]byte, 32)}))
		return err
	}},
	{"ListMyKeyDevices", false, true, func(ctx context.Context, s *Server, _ string) error {
		_, err := s.ListMyKeyDevices(ctx, connect.NewRequest(&keysv1.ListMyKeyDevicesRequest{}))
		return err
	}},
	{"RemoveKeyDevice", true, true, func(ctx context.Context, s *Server, key string) error {
		_, err := s.RemoveKeyDevice(ctx, connect.NewRequest(&keysv1.RemoveKeyDeviceRequest{IdempotencyKey: key, DeviceId: srvDevice}))
		return err
	}},
	{"UploadKeyPackages", true, false, func(ctx context.Context, s *Server, key string) error {
		_, err := s.UploadKeyPackages(ctx, connect.NewRequest(&keysv1.UploadKeyPackagesRequest{IdempotencyKey: key, DeviceId: srvDevice, KeyPackages: [][]byte{{1}}}))
		return err
	}},
	{"GetKeyDevices", false, true, func(ctx context.Context, s *Server, _ string) error {
		_, err := s.GetKeyDevices(ctx, connect.NewRequest(&keysv1.GetKeyDevicesRequest{UserIds: []string{srvOther}}))
		return err
	}},
	{"ClaimKeyPackages", true, false, func(ctx context.Context, s *Server, key string) error {
		_, err := s.ClaimKeyPackages(ctx, connect.NewRequest(&keysv1.ClaimKeyPackagesRequest{IdempotencyKey: key, UserId: srvOther}))
		return err
	}},
}

func wantFeatureDisabled(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagName {
		t.Fatalf("want FAILED_PRECONDITION FEATURE_DISABLED feature=%s, got %v", FlagName, err)
	}
}

// TestServer_FlagClasses: every RPC in every flag state. On for the caller: all six run. Off for the caller but not
// globally off (dropped from an allowlist): only ListMyKeyDevices, RemoveKeyDevice and GetKeyDevices run. Globally off (and a nil
// checker): none. A refused call is FEATURE_DISABLED feature=e2ee_dm and never reaches the service.
func TestServer_FlagClasses(t *testing.T) {
	states := []struct {
		name string
		fc   FlagChecker
		// runs reports whether rpc reaches the service in this state.
		runs func(rpc srvRPC) bool
	}{
		{"on for the caller", fakeFlags{on: map[string]bool{srvCaller: true}}, func(srvRPC) bool { return true }},
		{"dropped from the allowlist", fakeFlags{on: map[string]bool{srvOther: true}}, func(r srvRPC) bool { return r.notOff }},
		{"globally off", fakeFlags{off: true, on: map[string]bool{srvCaller: true}}, func(srvRPC) bool { return false }},
		{"nil checker", nil, func(srvRPC) bool { return false }},
	}
	for _, st := range states {
		for _, rpc := range srvRPCs {
			t.Run(st.name+"/"+rpc.name, func(t *testing.T) {
				svc := &fakeService{byUser: map[string][]Device{}}
				err := rpc.run(srvCtx(srvCaller), NewServer(st.fc, svc), srvKey)
				if st.runs(rpc) {
					if err != nil || len(svc.calls) != 1 {
						t.Fatalf("want the service called once, got calls=%v err=%v", svc.calls, err)
					}
					return
				}
				wantFeatureDisabled(t, err)
				if len(svc.calls) != 0 {
					t.Fatalf("a disabled call reached the service: %v", svc.calls)
				}
			})
		}
	}
}

// TestServer_UnauthenticatedAndUnwired: no uid is UNAUTHENTICATED before the flag; a server without a service is
// UNIMPLEMENTED after the flag.
func TestServer_UnauthenticatedAndUnwired(t *testing.T) {
	on := fakeFlags{on: map[string]bool{srvCaller: true}}
	for _, rpc := range srvRPCs {
		svc := &fakeService{}
		if err := rpc.run(context.Background(), NewServer(on, svc), srvKey); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Errorf("%s without a uid: %v", rpc.name, err)
		}
		if err := rpc.run(srvCtx(""), NewServer(on, svc), srvKey); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Errorf("%s with an empty uid: %v", rpc.name, err)
		}
		if err := rpc.run(context.Background(), NewServer(fakeFlags{off: true}, svc), srvKey); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Errorf("%s without a uid, flag off: %v (want UNAUTHENTICATED first)", rpc.name, err)
		}
		if len(svc.calls) != 0 {
			t.Errorf("%s: an unauthenticated call reached the service", rpc.name)
		}
		if err := rpc.run(srvCtx(srvCaller), NewServer(on, nil), srvKey); connect.CodeOf(err) != connect.CodeUnimplemented {
			t.Errorf("%s unwired: %v", rpc.name, err)
		}
	}
}

// TestServer_IdempotencyKey: the four mutating RPCs refuse a malformed or missing key with VALIDATION idempotency_key
// before the service; FEATURE_DISABLED wins over a bad key; the reads take no key.
func TestServer_IdempotencyKey(t *testing.T) {
	on := fakeFlags{on: map[string]bool{srvCaller: true}}
	for _, rpc := range srvRPCs {
		if !rpc.mutating {
			continue
		}
		for _, bad := range []string{"", "short", "has space in it 0123", string(bytes.Repeat([]byte("a"), 65))} {
			svc := &fakeService{}
			wantValidation(t, rpc.run(srvCtx(srvCaller), NewServer(on, svc), bad), "idempotency_key")
			if len(svc.calls) != 0 {
				t.Fatalf("%s with key %q reached the service", rpc.name, bad)
			}
		}
		wantFeatureDisabled(t, rpc.run(srvCtx(srvCaller), NewServer(fakeFlags{off: true}, &fakeService{}), "bad"))
	}
}

// TestServer_Deadline: the service runs under the handler's 8 s deadline.
func TestServer_Deadline(t *testing.T) {
	for _, rpc := range srvRPCs {
		svc := &fakeService{byUser: map[string][]Device{}}
		if err := rpc.run(srvCtx(srvCaller), NewServer(fakeFlags{on: map[string]bool{srvCaller: true}}, svc), srvKey); err != nil {
			t.Fatal(err)
		}
		if svc.deadline <= 0 || svc.deadline > rpcDeadline {
			t.Errorf("%s: the service saw a deadline of %v, want (0, %v]", rpc.name, svc.deadline, rpcDeadline)
		}
	}
}

// TestServer_ServiceErrorPassesThrough: the handler returns the service's error as is.
func TestServer_ServiceErrorPassesThrough(t *testing.T) {
	want := apierr.Validation("device_id", "bad")
	for _, rpc := range srvRPCs {
		svc := &fakeService{err: want}
		if err := rpc.run(srvCtx(srvCaller), NewServer(fakeFlags{on: map[string]bool{srvCaller: true}}, svc), srvKey); !errors.Is(err, want) {
			t.Errorf("%s: %v, want the service's error", rpc.name, err)
		}
	}
}

var t1 = t0.Add(time.Hour)

func srvDev(id string, pool int, lr bool) Device {
	return Device{ID: id, SignatureKey: bytes.Repeat([]byte{7}, 32), CreatedAt: t0, LastSeenAt: t1, PoolCount: pool, HasLastResort: lr}
}

// wireTimeIs: a zero service time is an absent wire timestamp, anything else the same instant.
func wireTimeIs(got *timestamppb.Timestamp, want time.Time) bool {
	if want.IsZero() {
		return got == nil
	}
	return got != nil && got.AsTime().Equal(want)
}

func checkWireDevice(t *testing.T, got *keysv1.KeyDevice, want Device) {
	t.Helper()
	if got.GetDeviceId() != want.ID || !bytes.Equal(got.GetSignaturePublicKey(), want.SignatureKey) ||
		!wireTimeIs(got.GetCreatedAt(), want.CreatedAt) || !wireTimeIs(got.GetLastSeenAt(), want.LastSeenAt) ||
		int(got.GetKeyPackageCount()) != want.PoolCount || got.GetHasLastResort() != want.HasLastResort || got.GetInactive() != want.Inactive {
		t.Fatalf("wire device %v, want %+v", got, want)
	}
}

// TestServer_Mapping: each RPC hands the service the caller's uid and the request's fields, and renders its answer.
func TestServer_Mapping(t *testing.T) {
	on := fakeFlags{on: map[string]bool{srvCaller: true}}
	ctx := srvCtx(srvCaller)

	t.Run("RegisterKeyDevice", func(t *testing.T) {
		key := bytes.Repeat([]byte{9}, 32)
		svc := &fakeService{device: srvDev(srvDevice, 3, true)}
		res, err := NewServer(on, svc).RegisterKeyDevice(ctx, connect.NewRequest(&keysv1.RegisterKeyDeviceRequest{IdempotencyKey: srvKey, DeviceId: srvDevice, SignaturePublicKey: key}))
		if err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || svc.deviceID != srvDevice || !bytes.Equal(svc.sigKey, key) {
			t.Fatalf("service got uid=%s device=%s key=%x", svc.uid, svc.deviceID, svc.sigKey)
		}
		checkWireDevice(t, res.Msg.GetDevice(), svc.device)
	})

	t.Run("ListMyKeyDevices", func(t *testing.T) {
		svc := &fakeService{devices: []Device{srvDev("device-aaaaaaaaaaaaaa", 100, true), srvDev("device-bbbbbbbbbbbbbb", 0, false)}}
		res, err := NewServer(on, svc).ListMyKeyDevices(ctx, connect.NewRequest(&keysv1.ListMyKeyDevicesRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || len(res.Msg.GetDevices()) != 2 {
			t.Fatalf("uid=%s devices=%v", svc.uid, res.Msg.GetDevices())
		}
		for i, d := range svc.devices {
			checkWireDevice(t, res.Msg.GetDevices()[i], d)
		}
		empty, err := NewServer(on, &fakeService{}).ListMyKeyDevices(ctx, connect.NewRequest(&keysv1.ListMyKeyDevicesRequest{}))
		if err != nil || len(empty.Msg.GetDevices()) != 0 {
			t.Fatalf("empty list = %v, %v", empty.Msg.GetDevices(), err)
		}
	})

	t.Run("RemoveKeyDevice", func(t *testing.T) {
		svc := &fakeService{}
		if _, err := NewServer(on, svc).RemoveKeyDevice(ctx, connect.NewRequest(&keysv1.RemoveKeyDeviceRequest{IdempotencyKey: srvKey, DeviceId: srvDevice})); err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || svc.deviceID != srvDevice {
			t.Fatalf("uid=%s device=%s", svc.uid, svc.deviceID)
		}
	})

	t.Run("UploadKeyPackages", func(t *testing.T) {
		pkgs := [][]byte{{1, 2}, {3}}
		lr := []byte{4, 5, 6}
		svc := &fakeService{pool: 42, hasLR: true}
		res, err := NewServer(on, svc).UploadKeyPackages(ctx, connect.NewRequest(&keysv1.UploadKeyPackagesRequest{
			IdempotencyKey: srvKey, DeviceId: srvDevice, KeyPackages: pkgs, LastResortKeyPackage: lr}))
		if err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || svc.deviceID != srvDevice || len(svc.packages) != 2 || !bytes.Equal(svc.packages[0], pkgs[0]) ||
			!bytes.Equal(svc.packages[1], pkgs[1]) || !bytes.Equal(svc.lastResort, lr) {
			t.Fatalf("service got uid=%s device=%s packages=%v lr=%v", svc.uid, svc.deviceID, svc.packages, svc.lastResort)
		}
		if res.Msg.GetKeyPackageCount() != 42 || !res.Msg.GetHasLastResort() {
			t.Fatalf("response = %v", res.Msg)
		}
	})

	t.Run("GetKeyDevices keeps the request order and every id", func(t *testing.T) {
		mine := srvDev("device-mine00000000000", 7, true)
		theirs := srvDev("device-theirs000000000", 0, false)
		theirs.CreatedAt, theirs.LastSeenAt = time.Time{}, time.Time{} // as the service returns another user's device
		// The service answers a map; the handler must answer in request order, with an entry for every id (an empty
		// list for one the map has no devices for, or no key at all).
		svc := &fakeService{byUser: map[string][]Device{srvThird: {theirs}, srvCaller: {mine}, srvOther: {}}}
		ids := []string{srvThird, srvOther, srvCaller, "uid-absent"}
		res, err := NewServer(on, svc).GetKeyDevices(ctx, connect.NewRequest(&keysv1.GetKeyDevicesRequest{UserIds: ids}))
		if err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || len(svc.userIDs) != len(ids) {
			t.Fatalf("service got uid=%s ids=%v", svc.uid, svc.userIDs)
		}
		users := res.Msg.GetUsers()
		if len(users) != len(ids) {
			t.Fatalf("users = %v, want %d entries", users, len(ids))
		}
		for i, id := range ids {
			if users[i].GetUserId() != id {
				t.Fatalf("users[%d] = %s, want %s (request order)", i, users[i].GetUserId(), id)
			}
		}
		if len(users[0].GetDevices()) != 1 || len(users[1].GetDevices()) != 0 || len(users[2].GetDevices()) != 1 || len(users[3].GetDevices()) != 0 {
			t.Fatalf("device lists = %v", users)
		}
		checkWireDevice(t, users[0].GetDevices()[0], theirs) // zeroed counts as the service returned them
		if d := users[0].GetDevices()[0]; d.GetCreatedAt() != nil || d.GetLastSeenAt() != nil {
			t.Fatalf("another user's device carries timestamps on the wire: %v", d)
		}
		if d := users[2].GetDevices()[0]; d.GetCreatedAt() == nil || d.GetLastSeenAt() == nil {
			t.Fatalf("the caller's own device lost its timestamps on the wire: %v", d)
		}
		checkWireDevice(t, users[2].GetDevices()[0], mine)
	})

	t.Run("ClaimKeyPackages", func(t *testing.T) {
		claimed := []Claimed{
			{DeviceID: "device-one000000000000", SignatureKey: bytes.Repeat([]byte{1}, 32), KeyPackage: []byte{8, 8}, HasKeyPackage: true},
			{DeviceID: "device-two000000000000", SignatureKey: bytes.Repeat([]byte{2}, 32), KeyPackage: []byte{9}, HasKeyPackage: true, LastResort: true},
			{DeviceID: "device-three0000000000", SignatureKey: bytes.Repeat([]byte{3}, 32)},
		}
		svc := &fakeService{claimed: claimed}
		res, err := NewServer(on, svc).ClaimKeyPackages(ctx, connect.NewRequest(&keysv1.ClaimKeyPackagesRequest{IdempotencyKey: srvKey, UserId: srvOther, ExcludeDeviceId: srvDevice}))
		if err != nil {
			t.Fatal(err)
		}
		if svc.uid != srvCaller || svc.target != srvOther || svc.exclude != srvDevice {
			t.Fatalf("service got uid=%s target=%s exclude=%s", svc.uid, svc.target, svc.exclude)
		}
		got := res.Msg.GetKeyPackages()
		if len(got) != len(claimed) {
			t.Fatalf("key packages = %v", got)
		}
		for i, c := range claimed {
			g := got[i]
			if g.GetDeviceId() != c.DeviceID || !bytes.Equal(g.GetSignaturePublicKey(), c.SignatureKey) || !bytes.Equal(g.GetKeyPackage(), c.KeyPackage) ||
				g.GetHasKeyPackage() != c.HasKeyPackage || g.GetLastResort() != c.LastResort {
				t.Fatalf("key_packages[%d] = %v, want %+v", i, g, c)
			}
		}
		if res.Msg.GetConversationId() != "" {
			t.Fatalf("conversation_id = %q, want the service's (empty) answer", res.Msg.GetConversationId())
		}
		empty, err := NewServer(on, &fakeService{claimed: []Claimed{}, convID: "conv-x"}).ClaimKeyPackages(ctx, connect.NewRequest(&keysv1.ClaimKeyPackagesRequest{IdempotencyKey: srvKey, UserId: srvOther}))
		if err != nil || len(empty.Msg.GetKeyPackages()) != 0 || empty.Msg.GetConversationId() != "conv-x" {
			t.Fatalf("empty claim = %v, %v, conversation_id %q", empty.Msg.GetKeyPackages(), err, empty.Msg.GetConversationId())
		}
	})
}

// TestGetKeyDevices_GateClass: GetKeyDevices needs the flag only not globally off (K1): a caller dropped from the
// allowlist reaches the service (which answers an empty success without a shared conversation); globally off is
// FEATURE_DISABLED feature=e2ee_dm and never reaches it.
func TestGetKeyDevices_GateClass(t *testing.T) {
	get := func(s *Server) error {
		_, err := s.GetKeyDevices(srvCtx(srvCaller), connect.NewRequest(&keysv1.GetKeyDevicesRequest{UserIds: []string{srvOther}}))
		return err
	}
	svc := &fakeService{byUser: map[string][]Device{}}
	if err := get(NewServer(fakeFlags{on: map[string]bool{srvOther: true}}, svc)); err != nil || len(svc.calls) != 1 {
		t.Fatalf("caller flag off, not globally off: calls=%v err=%v, want the service reached", svc.calls, err)
	}
	svc = &fakeService{byUser: map[string][]Device{}}
	wantFeatureDisabled(t, get(NewServer(fakeFlags{off: true, on: map[string]bool{srvCaller: true}}, svc)))
	if len(svc.calls) != 0 {
		t.Fatalf("a globally off call reached the service: %v", svc.calls)
	}
}

// TestKeyDevices_InactiveMarker: ListMyKeyDevices and GetKeyDevices put the service's Inactive on the wire (K5) for the
// caller's own list and for another user's lookup alike.
func TestKeyDevices_InactiveMarker(t *testing.T) {
	on := fakeFlags{on: map[string]bool{srvCaller: true}}
	stale, fresh := srvDev("device-stale000000000", 0, false), srvDev("device-fresh000000000", 0, false)
	stale.Inactive = true
	svc := &fakeService{devices: []Device{stale, fresh}, byUser: map[string][]Device{srvOther: {stale, fresh}}}
	res, err := NewServer(on, svc).ListMyKeyDevices(srvCtx(srvCaller), connect.NewRequest(&keysv1.ListMyKeyDevicesRequest{}))
	if err != nil || len(res.Msg.GetDevices()) != 2 || !res.Msg.GetDevices()[0].GetInactive() || res.Msg.GetDevices()[1].GetInactive() {
		t.Fatalf("ListMyKeyDevices = %v, %v; want [inactive, active]", res, err)
	}
	got, err := NewServer(on, svc).GetKeyDevices(srvCtx(srvCaller), connect.NewRequest(&keysv1.GetKeyDevicesRequest{UserIds: []string{srvOther}}))
	if err != nil || len(got.Msg.GetUsers()) != 1 || len(got.Msg.GetUsers()[0].GetDevices()) != 2 ||
		!got.Msg.GetUsers()[0].GetDevices()[0].GetInactive() || got.Msg.GetUsers()[0].GetDevices()[1].GetInactive() {
		t.Fatalf("GetKeyDevices = %v, %v; want [inactive, active]", got, err)
	}
}

// TestContract_K2K5Fields pins the two additive wire fields of addendum 1: KeyDevice.inactive (K5) and
// ClaimKeyPackagesResponse.conversation_id (K2).
func TestContract_K2K5Fields(t *testing.T) {
	if !(&keysv1.KeyDevice{Inactive: true}).GetInactive() {
		t.Fatal("KeyDevice.inactive")
	}
	if (&keysv1.ClaimKeyPackagesResponse{ConversationId: "x"}).GetConversationId() != "x" {
		t.Fatal("conversation_id")
	}
}
