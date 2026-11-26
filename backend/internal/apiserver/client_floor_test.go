package apiserver

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// The app version floor's stamp (plan 6 section 3.1, Task 3.B: "an apiserver chain test that the stamp runs before the
// handlers and adds no Firestore read"). Through the real chainInterceptors: every handler sees the parsed x-dz-client
// header in its context, and a request with the header costs exactly the provider lookups (the only Firestore-backed
// seams of the chain: the session cut and the account status) of the same request without it.

// countingActive is an AccountStatusProvider that counts its lookups (each would be a cached profile read).
type countingActive struct{ calls atomic.Int64 }

func (c *countingActive) AccountStatus(context.Context, string) (bool, authn.AccountStatus, error) {
	c.calls.Add(1)
	return true, authn.AccountStatusActive, nil
}

func TestChain_TheClientStampRunsBeforeTheHandlersAndAddsNoRead(t *testing.T) {
	const uid = "uid-chain-floor"
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 1_000_000
	cfg.RateLimit.PerIPPerMinute = 1_000_000
	cuts := &chainCuts{cut: map[string]time.Time{}}
	status := &countingActive{}
	ics := chainInterceptors(chainDeps{
		log: slog.New(slog.NewTextHandler(io.Discard, nil)), projectID: "demo-dzeroth-local",
		appCheck: chainAppCheck{}, appCheckMode: authn.ModeMonitor,
		idVerifier: chainIDVerifier{
			"tok": {UID: uid, SignInProvider: authn.SignInProviderGoogle, EmailVerified: true, AuthTime: time.Now()},
		},
		profileExempt: profileExemptProcedures(),
		sessionCuts:   cuts, sessionCutOn: func() bool { return true },
		rateLimit: RateLimitConfig(cfg), degradedMode: config.DegradedMode(""), media: degraded.ProcedureSet{},
		accountStatus: status, publicIDs: passThrough,
	})
	var seen atomic.Value
	mux := http.NewServeMux()
	procs := []string{
		messagingv1connect.MessagingServiceListConversationsProcedure,
		identityv1connect.IdentityServiceGetMeProcedure,
	}
	for _, proc := range procs {
		mux.Handle(proc, connect.NewUnaryHandler(proc,
			func(ctx context.Context, _ *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				seen.Store(clientinfo.FromContext(ctx))
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, connect.WithInterceptors(ics...)))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	// call returns the lookups the request cost (session cut + account status).
	call := func(proc, header string) (clientinfo.Client, int64) {
		t.Helper()
		before := cuts.calls.Load() + status.calls.Load()
		seen.Store(clientinfo.Client{Platform: "unset", Level: -1})
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("Authorization", "Bearer tok")
		if header != "" {
			req.Header().Set("x-dz-client", header)
		}
		if _, err := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc).CallUnary(context.Background(), req); err != nil {
			t.Fatalf("%s %q: %v", proc, header, err)
		}
		c, _ := seen.Load().(clientinfo.Client)
		return c, cuts.calls.Load() + status.calls.Load() - before
	}
	for _, proc := range procs {
		_, baseline := call(proc, "")
		for header, want := range map[string]clientinfo.Client{
			"":          {},
			"web/1":     {Platform: clientinfo.PlatformWeb, Level: 1},
			"android/1": {Platform: clientinfo.PlatformAndroid, Level: 1},
			"ios/0":     {Platform: clientinfo.PlatformIOS, Level: 0},
			"other/0":   {},
			"garbage":   {},
		} {
			got, lookups := call(proc, header)
			if got != want {
				t.Errorf("%s %q: the handler saw %+v, want %+v (the stamp must run before the handler)", proc, header, got, want)
			}
			if lookups != baseline {
				t.Errorf("%s %q: %d provider lookups, want %d as without the header (the stamp reads nothing)", proc, header, lookups, baseline)
			}
		}
	}
}

// TestNewKeysModule_PassesTheClientFloor: the floor Build hands newKeysModule reaches the KeyService handler (a build
// below it gets FEATURE_DISABLED update_required before the flag class, here a nil checker that would say e2ee_dm).
func TestNewKeysModule_PassesTheClientFloor(t *testing.T) {
	lookup := keysLookupCap(4, 3, func(string) bool { return false })
	mod, err := newKeysModule(unusedKeysRepo{}, nil, stubMessagingPermission{}, messaging.ConversationID, ratelimit.NewDailyCap(2), lookup, testKeysReauth, stubCutter{}, stubPush{}, nil,
		keys.WithClientFloor(clientinfo.Floors{Android: 1}))
	if err != nil {
		t.Fatalf("newKeysModule: %v", err)
	}
	ctx := clientinfo.WithClient(authn.WithClaims(context.Background(), authn.Claims{UID: "uid-a"}), clientinfo.Parse("android/0"))
	_, err = mod.server.GetKeyDevices(ctx, connect.NewRequest(&keysv1.GetKeyDevicesRequest{UserIds: []string{"uid-b"}}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["update_required"] != "true" || ae.Metadata["feature"] != "messaging" {
		t.Fatalf("GetKeyDevices below the floor = %v, want FEATURE_DISABLED feature=messaging update_required=true", err)
	}
	// Listing the caller's own devices passes the floor (removal is a safety action): here the nil flag checker answers.
	_, err = mod.server.ListMyKeyDevices(ctx, connect.NewRequest(&keysv1.ListMyKeyDevicesRequest{}))
	if errors.As(err, &ae) && ae.Metadata["update_required"] != "" {
		t.Fatalf("ListMyKeyDevices below the floor = %v, want it exempt from the floor", err)
	}
}

// TestClientFloors: the config ints become the floors every module reads.
func TestClientFloors(t *testing.T) {
	got := clientFloors(config.Config{ClientFloors: config.ClientFloorsConfig{Android: 1, Web: 2, IOS: 3}})
	if want := (clientinfo.Floors{Android: 1, Web: 2, IOS: 3}); got != want {
		t.Errorf("clientFloors = %+v, want %+v", got, want)
	}
	if clientFloors(config.Config{}).Raised() {
		t.Error("the default config must raise no floor")
	}
}
