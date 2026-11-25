package messaging_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// The app version floor (plan 6 section 3.1, Task 3.B) in the MessagingService handler: below the floor every RPC
// answers FAILED_PRECONDITION + FEATURE_DISABLED, feature=messaging, update_required=true, before the flag check and the
// service; floors of 0 change nothing.

// unreachable is a messaging.Service with no implementation: a refused call that reached it would panic.
type unreachable struct{ messaging.Service }

// noStamp is a header value meaning "no apiserver chain in front": the context is never stamped (reads as no header).
const noStamp = "\x00none"

// everyRPC calls each MessagingServiceHandler method of srv (found by reflection, so a new RPC is covered without
// editing this test) with an empty request, and returns the error per method name.
func everyRPC(t *testing.T, ctx context.Context, srv *messaging.Server) map[string]error {
	t.Helper()
	iface := reflect.TypeOf((*messagingv1connect.MessagingServiceHandler)(nil)).Elem()
	v := reflect.ValueOf(srv)
	out := make(map[string]error, iface.NumMethod())
	for i := range iface.NumMethod() {
		m := iface.Method(i)
		reqType := m.Type.In(1).Elem() // connect.Request[T]
		req := reflect.New(reqType)
		msg := req.Elem().FieldByName("Msg")
		msg.Set(reflect.New(msg.Type().Elem()))
		res := v.MethodByName(m.Name).Call([]reflect.Value{reflect.ValueOf(ctx), req})
		err, _ := res[1].Interface().(error)
		out[m.Name] = err
	}
	if len(out) < 14 {
		t.Fatalf("found %d MessagingService RPCs, want at least 14", len(out))
	}
	return out
}

func authed(header string) context.Context {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: inList, SignInProvider: authn.SignInProviderGoogle})
	if header == noStamp {
		return ctx
	}
	return clientinfo.WithClient(ctx, clientinfo.Parse(header))
}

func wantUpdateRequired(t *testing.T, name string, err error) {
	t.Helper()
	ce := apierr.ToConnect(err)
	if ce == nil || ce.Code() != connect.CodeFailedPrecondition {
		t.Fatalf("%s: err = %v, want FAILED_PRECONDITION", name, err)
	}
	reason, meta := reasonOf(t, ce)
	if reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != "messaging" || meta["update_required"] != "true" || len(meta) != 2 {
		t.Errorf("%s: reason %v metadata %v, want FEATURE_DISABLED {feature: messaging, update_required: true}", name, reason, meta)
	}
}

// TestServer_AMessagingRPCBelowTheFloorAnswersFeatureDisabledWithUpdateRequired is the plan's "a messaging RPC below the
// floor answers FEATURE_DISABLED with update_required": every RPC, for every too-old header, without reaching the
// service (so no read, and an answer that depends on nothing but the caller's own header and the config).
func TestServer_AMessagingRPCBelowTheFloorAnswersFeatureDisabledWithUpdateRequired(t *testing.T) {
	floors := clientinfo.Floors{Android: 1, Web: 1, IOS: 1}
	for _, header := range []string{"android/0", "web/0", "ios/0", "other/0", "", "garbage", "android/-1", noStamp} {
		srv := messaging.NewServer(unreachable{}, messaging.WithClientFloor(floors))
		for name, err := range everyRPC(t, authed(header), srv) {
			wantUpdateRequired(t, fmt.Sprintf("%q %s", header, name), err)
		}
	}
	// No identity is still UNAUTHENTICATED, never the floor's answer.
	srv := messaging.NewServer(unreachable{}, messaging.WithClientFloor(floors))
	for name, err := range everyRPC(t, clientinfo.WithClient(context.Background(), clientinfo.Parse("android/0")), srv) {
		if connect.CodeOf(apierr.ToConnect(err)) != connect.CodeUnauthenticated {
			t.Errorf("%s with no caller: %v, want UNAUTHENTICATED", name, err)
		}
	}
}

// TestServer_FloorUpdateRequiredOverTheWire: the detail the client reads (Task 3.C), stamped by clientinfo.Interceptor and
// shaped by the error middleware; a build at the floor reaches the service.
func TestServer_FloorUpdateRequiredOverTheWire(t *testing.T) {
	caller := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: inList, SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	mux := http.NewServeMux()
	srv := messaging.NewServer(messaging.New(registry(flags.On, 0), messaging.Deps{}), messaging.WithClientFloor(clientinfo.Floors{Android: 1}))
	mux.Handle(messagingv1connect.NewMessagingServiceHandler(srv, connect.WithInterceptors(clientinfo.Interceptor(), caller, mw.ErrorMapping(slog.New(slog.NewTextHandler(io.Discard, nil))))))
	hs := httptest.NewServer(mux)
	t.Cleanup(hs.Close)
	client := messagingv1connect.NewMessagingServiceClient(hs.Client(), hs.URL)
	send := func(header string) error {
		req := connect.NewRequest(&messagingv1.SendMessageRequest{})
		req.Header().Set("x-dz-client", header)
		_, err := client.SendMessage(context.Background(), req)
		return err
	}
	err := send("android/0")
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("android/0: %v, want FAILED_PRECONDITION", err)
	}
	reason, meta := reasonOf(t, err)
	if reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != "messaging" || meta["update_required"] != "true" {
		t.Errorf("android/0: %v %v, want FEATURE_DISABLED feature=messaging update_required=true", reason, meta)
	}
	// At the floor: the service's own validation of the empty request.
	if err := send("android/1"); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("android/1 at the floor: %v, want the service's INVALID_ARGUMENT", err)
	}
}

// TestServer_Floor0ChangesNothing is the plan's "floor 0 changes nothing": with every floor 0 every RPC answers exactly
// what it answers with no floor wired, for every header and flag mode.
func TestServer_Floor0ChangesNothing(t *testing.T) {
	for _, mode := range []flags.Mode{flags.On, flags.Off, flags.Allowlist} {
		baseline := everyRPC(t, authed(noStamp), messaging.NewServer(messaging.New(registry(mode, 0), messaging.Deps{})))
		for _, header := range []string{noStamp, "", "android/0", "ios/0", "other/0", "web/1", "web/1/2"} {
			srv := messaging.NewServer(messaging.New(registry(mode, 0), messaging.Deps{}), messaging.WithClientFloor(clientinfo.Floors{}))
			for name, err := range everyRPC(t, authed(header), srv) {
				if got, want := describe(err), describe(baseline[name]); got != want {
					t.Errorf("%s %q %s: %s, want %s (as with no floor)", mode, header, name, got, want)
				}
			}
		}
	}
}

// describe is the wire answer of err: code, reason and metadata (fmt prints a map with sorted keys).
func describe(err error) string {
	if err == nil {
		return "ok"
	}
	ce := apierr.ToConnect(err)
	s := ce.Code().String()
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				s += fmt.Sprintf(" %v %v", ed.GetReason(), ed.GetMetadata())
			}
		}
	}
	return s
}
