package apiserver

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// TestUpdateProfile_ClearIsRefusedInReadonlyMode (ADR-0024 Amendment 1 A2): clears are exempt from the profile_extras
// gate, not from DEGRADED_MODE=readonly. A clear is a write like any other, so the platform interceptor refuses it
// before the handler runs; this follows UpdateProfile's proto idempotency_level (mutating), no list to go stale. The
// service is built with a nil repo and no flags: if the interceptor let the call through the test would fail on the
// handler, not pass.
func TestUpdateProfile_ClearIsRefusedInReadonlyMode(t *testing.T) {
	svc := identity.New(nil, identity.NewCache(time.Minute), 0)
	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: "uid-ro", SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(setUID, degraded.Interceptor(config.DegradedReadonly, degraded.ProcedureSet{}), mw.ErrorMapping(slog.Default()))
	mux := http.NewServeMux()
	p, h := identityv1connect.NewIdentityServiceHandler(identity.NewServer(svc), opts)
	mux.Handle(p, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	client := identityv1connect.NewIdentityServiceClient(srv.Client(), srv.URL)

	empty := ""
	tests := map[string]*identityv1.UpdateProfileRequest{
		"clear the website":        {IdempotencyKey: "readonly-clear-0000001", Website: &empty},
		"clear the pin":            {IdempotencyKey: "readonly-clear-0000002", PinnedPostId: &empty},
		"clear all four":           {IdempotencyKey: "readonly-clear-0000003", BannerMediaId: &empty, Location: &empty, Website: &empty, PinnedPostId: &empty},
		"a bio edit (the control)": {IdempotencyKey: "readonly-clear-0000004", Bio: strPtr("hello")},
	}
	for name, req := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := client.UpdateProfile(context.Background(), connect.NewRequest(req))
			if got := connect.CodeOf(err); got != connect.CodeUnavailable {
				t.Fatalf("code = %v (err %v), want Unavailable: DEGRADED_MODE=readonly refuses every write, clears included", got, err)
			}
		})
	}
}

func strPtr(s string) *string { return &s }
