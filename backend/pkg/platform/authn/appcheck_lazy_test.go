package authn_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"
	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/appcheck"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// jwksServer stands in for Google's App Check key endpoint and counts the requests it gets. It also makes ADC
// unresolvable for the test (noADC). It is not parallel-safe: appcheck.JWKSUrl is a package variable.
func jwksServer(t *testing.T, status *atomic.Int32, hits *atomic.Int32) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(int(status.Load()))
		if status.Load() == http.StatusOK {
			_, _ = w.Write([]byte(`{"keys":[]}`))
		}
	}))
	old := appcheck.JWKSUrl
	appcheck.JWKSUrl = srv.URL
	t.Cleanup(func() { appcheck.JWKSUrl = old; srv.Close() })
	noADC(t)
}

// noADC makes Application Default Credentials unresolvable for the rest of the test, so no test can read this
// machine's real credentials and any ADC lookup fails at once, with no network. GOOGLE_APPLICATION_CREDENTIALS points
// at a file that does not exist (the lookup reads it first and errors). The gcloud well-known locations (HOME,
// APPDATA, CLOUDSDK_CONFIG) point at an empty temp dir, and the metadata-server override is cleared.
func noADC(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", filepath.Join(dir, "no-such-adc.json"))
	t.Setenv("HOME", dir)
	t.Setenv("APPDATA", dir)
	t.Setenv("CLOUDSDK_CONFIG", dir)
	t.Setenv("GCE_METADATA_HOST", "")
}

func callWithToken(t *testing.T, v authn.AppCheckVerifier, mode authn.Mode, token string) (reached bool, err error) {
	t.Helper()
	handler := connect.NewUnaryHandler(procedure, func(context.Context, *connect.Request[emptypb.Empty]) (*connect.Response[emptypb.Empty], error) {
		reached = true
		return connect.NewResponse(&emptypb.Empty{}), nil
	}, connect.WithInterceptors(authn.AppCheckInterceptor(v, mode)))
	req := httptest.NewRequest(http.MethodPost, procedure, strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set(authn.AppCheckHeader, token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		return reached, connect.NewError(connect.CodeUnauthenticated, nil)
	}
	return reached, nil
}

// Creating the verifier, and a request without a token, must not touch the network: that is what lets tests that
// build the whole server run offline.
func TestAppCheckVerifier_NoNetworkUntilATokenIsPresented(t *testing.T) {
	var status, hits atomic.Int32
	status.Store(http.StatusOK)
	jwksServer(t, &status, &hits)

	v, err := authn.NewAppCheckVerifier(context.Background(), "demo-project")
	if err != nil {
		t.Fatal(err)
	}
	if reached, _ := callWithToken(t, v, authn.ModeEnforce, ""); reached {
		t.Fatal("a request without a token reached the handler in enforce mode")
	}
	if got := hits.Load(); got != 0 {
		t.Fatalf("%d key fetches before any token was presented, want 0", got)
	}
}

// If the client cannot be built, enforce mode rejects (fail closed); the failure is not cached, so the verifier
// recovers once Google's keys are reachable; and the client is built only once.
func TestAppCheckVerifier_FailsClosedAndRecovers(t *testing.T) {
	var status, hits atomic.Int32
	status.Store(http.StatusInternalServerError)
	jwksServer(t, &status, &hits)

	v, err := authn.NewAppCheckVerifier(context.Background(), "demo-project")
	if err != nil {
		t.Fatal(err)
	}

	if reached, _ := callWithToken(t, v, authn.ModeEnforce, "some-token"); reached {
		t.Fatal("enforce mode let a request through while the App Check client could not be built")
	}
	if hits.Load() == 0 {
		t.Fatal("presenting a token did not attempt to build the client")
	}

	status.Store(http.StatusOK)
	before := hits.Load()
	// The token is not a valid JWT, so it is still rejected, but only after the client was built.
	if reached, _ := callWithToken(t, v, authn.ModeEnforce, "some-token"); reached {
		t.Fatal("an invalid token reached the handler")
	}
	built := hits.Load()
	if built <= before {
		t.Fatal("the failed build was cached: no new key fetch after the endpoint recovered")
	}
	_, _ = callWithToken(t, v, authn.ModeEnforce, "another-token")
	if hits.Load() != built {
		t.Fatalf("client rebuilt on a later call: fetches %d -> %d", built, hits.Load())
	}
}

// CheckAppCheck is the startup self-check: it must fail when the keys cannot be fetched and pass when they can.
func TestCheckAppCheck_FailsFastWhenKeysUnreachable(t *testing.T) {
	var status, hits atomic.Int32
	status.Store(http.StatusInternalServerError)
	jwksServer(t, &status, &hits)

	if err := authn.CheckAppCheck(context.Background(), "demo-project"); err == nil {
		t.Fatal("CheckAppCheck passed although the key endpoint is failing")
	}
	status.Store(http.StatusOK)
	if err := authn.CheckAppCheck(context.Background(), "demo-project"); err != nil {
		t.Fatalf("CheckAppCheck failed with a healthy key endpoint: %v", err)
	}
}

// Since 4.23 the client build has a second step after the key fetch: the SDK's HTTP client. When that step fails,
// enforce mode still rejects, the failure is not cached (each call retries the whole build), and the startup
// self-check fails. The wrapper always adds option.WithoutAuthentication(); a caller API key conflicts with it in
// the options validation, which makes the HTTP-client step fail deterministically with no key material and no ADC.
func TestAppCheckVerifier_FailsClosedWhenClientBuildFails(t *testing.T) {
	var status, hits atomic.Int32
	status.Store(http.StatusOK)
	jwksServer(t, &status, &hits)
	conflicting := option.WithAPIKey("test-only-not-a-key")

	v, err := authn.NewAppCheckVerifier(context.Background(), "demo-project", conflicting)
	if err != nil {
		t.Fatal(err)
	}
	for i := range 2 {
		before := hits.Load()
		if reached, _ := callWithToken(t, v, authn.ModeEnforce, "some-token"); reached {
			t.Fatalf("call %d: enforce mode let a request through while the App Check client could not be built", i)
		}
		if hits.Load() != before+1 {
			t.Fatalf("call %d: key fetches %d -> %d, want one build attempt per call while the build fails", i, before, hits.Load())
		}
	}
	if err := authn.CheckAppCheck(context.Background(), "demo-project", conflicting); err == nil {
		t.Fatal("CheckAppCheck passed although the App Check HTTP client could not be built")
	}
}

// The wrapper never uses credentials (we only call VerifyToken, which verifies locally), so a verifier built with no
// caller options must build where ADC cannot resolve. The first half proves the environment really blocks ADC: the
// bare 4.23 SDK, given no options, fails there. The second half is the production call shape (cmd/api and apiserver
// pass no options): CheckAppCheck and the lazy build both succeed, with one key fetch and no rebuild.
func TestAppCheck_NoCallerOptionsNeedsNoCredentials(t *testing.T) {
	var status, hits atomic.Int32
	status.Store(http.StatusOK)
	jwksServer(t, &status, &hits)

	app, err := firebase.NewApp(context.Background(), &firebase.Config{ProjectID: "demo-project"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := app.AppCheck(context.Background()); err == nil {
		t.Fatal("the bare SDK built an App Check client although ADC cannot resolve: the test environment is not hermetic")
	}

	if err := authn.CheckAppCheck(context.Background(), "demo-project"); err != nil {
		t.Fatalf("CheckAppCheck with no caller options needed credentials: %v", err)
	}
	v, err := authn.NewAppCheckVerifier(context.Background(), "demo-project")
	if err != nil {
		t.Fatal(err)
	}
	before := hits.Load()
	// The token is not a valid JWT, so it is rejected, but only after the client was built (one key fetch).
	if reached, _ := callWithToken(t, v, authn.ModeEnforce, "some-token"); reached {
		t.Fatal("an invalid token reached the handler")
	}
	if got := hits.Load(); got != before+1 {
		t.Fatalf("key fetches %d -> %d, want exactly one successful build", before, got)
	}
	_, _ = callWithToken(t, v, authn.ModeEnforce, "another-token")
	if got := hits.Load(); got != before+1 {
		t.Fatalf("client rebuilt on a later call: fetches %d -> %d", before+1, got)
	}
}
