package keys

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
)

// The app version floor (plan 6 section 3.1, Task 3.B) in the KeyService handler. Below the floor the RPCs that take
// part in messaging answer FAILED_PRECONDITION + FEATURE_DISABLED, feature=messaging (not e2ee_dm: the client hides
// messaging as a whole), update_required=true, after the caller check and before the flag class, the wiring and any
// lookup. Listing and removing the caller's own devices pass the floor (review M1): removal is a safety action.

func floorCtx(uid, header string) context.Context {
	return clientinfo.WithClient(srvCtx(uid), clientinfo.Parse(header))
}

// keyFloorGated classifies every KeyService RPC: true = refused below the floor, false = exempt (works on any build).
// A new RPC must be added here or TestServer_KeyFloorClassesCoverEveryKeyRPC fails.
var keyFloorGated = map[string]bool{
	"RegisterKeyDevice": true,
	"UploadKeyPackages": true,
	"ClaimKeyPackages":  true,
	"GetKeyDevices":     true,
	"ListMyKeyDevices":  false,
	"RemoveKeyDevice":   false,
}

// TestServer_KeyFloorClassesCoverEveryKeyRPC: the floor classification and the srvRPCs table the floor tests drive both
// name exactly the KeyService RPCs.
func TestServer_KeyFloorClassesCoverEveryKeyRPC(t *testing.T) {
	iface := reflect.TypeOf((*keysv1connect.KeyServiceHandler)(nil)).Elem()
	if iface.NumMethod() != len(srvRPCs) || iface.NumMethod() != len(keyFloorGated) {
		t.Fatalf("KeyServiceHandler has %d methods, srvRPCs drives %d, keyFloorGated classifies %d: classify the new RPC",
			iface.NumMethod(), len(srvRPCs), len(keyFloorGated))
	}
	for i := range iface.NumMethod() {
		if _, ok := keyFloorGated[iface.Method(i).Name]; !ok {
			t.Errorf("%s is not classified in keyFloorGated", iface.Method(i).Name)
		}
	}
	for _, r := range srvRPCs {
		if _, ok := iface.MethodByName(r.name); !ok {
			t.Errorf("srvRPCs names %s, which is not a KeyService RPC", r.name)
		}
	}
}

// TestServer_AKeyRPCBelowTheFloorAnswersFeatureDisabledWithUpdateRequired is the plan's "a messaging RPC below the floor
// answers FEATURE_DISABLED with update_required" for the key directory: each gated RPC, flag on, off or nil (the answer
// does not depend on flags or on any other user), never reaching the service. The exempt RPCs (listing and removing the
// caller's own devices) never get the floor's answer: with the flag on they reach the service, otherwise they answer
// exactly what their flag class says.
func TestServer_AKeyRPCBelowTheFloorAnswersFeatureDisabledWithUpdateRequired(t *testing.T) {
	floors := clientinfo.Floors{Android: 1, Web: 1, IOS: 1}
	// states[0] is the flag on for the caller: there an exempt RPC must reach the service.
	states := []FlagChecker{fakeFlags{on: map[string]bool{srvCaller: true}}, fakeFlags{on: map[string]bool{srvOther: true}}, fakeFlags{off: true}, nil}
	for si, fc := range states {
		for _, header := range []string{"android/0", "ios/0", "other/0", "", "web/1/2"} {
			for _, rpc := range srvRPCs {
				name := fmt.Sprintf("%v %q %s", fc, header, rpc.name)
				svc := &fakeService{byUser: map[string][]Device{}}
				err := rpc.run(floorCtx(srvCaller, header), NewServer(fc, svc, WithClientFloor(floors)), srvKey)
				var ae *apierr.Error
				if !keyFloorGated[rpc.name] {
					if errors.As(err, &ae) && ae.Metadata["update_required"] != "" {
						t.Errorf("%s: exempt RPC got the floor's answer %v", name, err)
					}
					// Same answer and service calls as with no floor wired.
					base := &fakeService{byUser: map[string][]Device{}}
					baseErr := rpc.run(srvCtx(srvCaller), NewServer(fc, base), srvKey)
					if fmt.Sprint(connect.CodeOf(err)) != fmt.Sprint(connect.CodeOf(baseErr)) || len(svc.calls) != len(base.calls) {
						t.Errorf("%s: exempt RPC = %v (calls %v), want %v (calls %v) as with no floor", name, err, svc.calls, baseErr, base.calls)
					}
					if si == 0 && (err != nil || len(svc.calls) != 1) {
						t.Errorf("%s: exempt RPC below the floor must reach the service: err %v calls %v", name, err, svc.calls)
					}
					continue
				}
				if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
					t.Fatalf("%s: %v, want FAILED_PRECONDITION FEATURE_DISABLED", name, err)
				}
				if len(ae.Metadata) != 2 || ae.Metadata["feature"] != "messaging" || ae.Metadata["update_required"] != "true" {
					t.Errorf("%s: metadata %v, want {feature: messaging, update_required: true}", name, ae.Metadata)
				}
				if len(svc.calls) != 0 {
					t.Errorf("%s: a refused call reached the service: %v", name, svc.calls)
				}
			}
		}
	}
	// No identity stays UNAUTHENTICATED; at the floor the call runs.
	for _, rpc := range srvRPCs {
		if err := rpc.run(clientinfo.WithClient(context.Background(), clientinfo.Parse("android/0")), NewServer(nil, &fakeService{}, WithClientFloor(floors)), srvKey); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Errorf("%s with no caller: %v, want UNAUTHENTICATED", rpc.name, err)
		}
		svc := &fakeService{byUser: map[string][]Device{}}
		if err := rpc.run(floorCtx(srvCaller, "android/1"), NewServer(fakeFlags{on: map[string]bool{srvCaller: true}}, svc, WithClientFloor(floors)), srvKey); err != nil || len(svc.calls) != 1 {
			t.Errorf("%s at the floor: err %v calls %v, want the service called once", rpc.name, err, svc.calls)
		}
	}
}

// TestServer_KeysFloor0ChangesNothing is the plan's "floor 0 changes nothing" for the key directory: every RPC, every flag
// state and header, answers exactly as with no floor wired.
func TestServer_KeysFloor0ChangesNothing(t *testing.T) {
	answer := func(err error) string {
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return fmt.Sprintf("%v %v %v", ae.Code, ae.Reason, ae.Metadata)
		}
		return fmt.Sprintf("%v", connect.CodeOf(err))
	}
	for _, fc := range []FlagChecker{fakeFlags{on: map[string]bool{srvCaller: true}}, fakeFlags{on: map[string]bool{srvOther: true}}, fakeFlags{off: true}, nil} {
		for _, rpc := range srvRPCs {
			baseSvc := &fakeService{byUser: map[string][]Device{}}
			want := answer(rpc.run(srvCtx(srvCaller), NewServer(fc, baseSvc), srvKey))
			for _, header := range []string{"", "android/0", "ios/0", "other/0", "web/1"} {
				svc := &fakeService{byUser: map[string][]Device{}}
				got := answer(rpc.run(floorCtx(srvCaller, header), NewServer(fc, svc, WithClientFloor(clientinfo.Floors{})), srvKey))
				if got != want || len(svc.calls) != len(baseSvc.calls) {
					t.Errorf("%v %q %s: %s (calls %v), want %s (calls %v)", fc, header, rpc.name, got, svc.calls, want, baseSvc.calls)
				}
			}
		}
	}
}
