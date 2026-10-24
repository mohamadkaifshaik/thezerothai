package authn_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"
	"firebase.google.com/go/v4/appcheck"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// jwksServer stands in for Google's App Check key endpoint and counts the requests it gets.
// It is not parallel-safe: appcheck.JWKSUrl is a package variable.
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
