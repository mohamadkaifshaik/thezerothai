package ratelimit_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

const procedure = "/test.Service/Method"

// authInject is a tiny interceptor that stands in for authn.IDTokenInterceptor, since ratelimit.Interceptor
// must run after a uid has been attached to the context.
func authInject(uid string) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if uid != "" {
				ctx = authn.WithClaims(ctx, authn.Claims{UID: uid})
			}
			return next(ctx, req)
		}
	})
}

func okHandler(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
	return connect.NewResponse(&commonv1.ErrorDetail{}), nil
}

func newServer(t *testing.T, uid string, cfg ratelimit.Config) *httptest.Server {
	t.Helper()
	h := connect.NewUnaryHandler(procedure, okHandler,
		connect.WithInterceptors(authInject(uid), ratelimit.Interceptor(cfg)),
	)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, xff string) error {
	t.Helper()
	client := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+procedure)
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	if xff != "" {
		req.Header().Set("X-Forwarded-For", xff)
	}
	_, err := client.CallUnary(context.Background(), req)
	return err
}

func TestInterceptor_PerUIDLimit(t *testing.T) {
	srv := newServer(t, "uid-1", ratelimit.Config{Default: ratelimit.NewLimiter(1, time.Minute)})
	if err := call(t, srv, ""); err != nil {
		t.Fatalf("first request should be allowed: %v", err)
	}
	err := call(t, srv, "")
	if err == nil {
		t.Fatal("second immediate request should be rate limited")
	}
	assertResourceExhausted(t, err)
}

func TestInterceptor_PerProcedureOverride(t *testing.T) {
	strict := ratelimit.NewLimiter(1, time.Minute)
	generous := ratelimit.NewLimiter(1000, time.Minute)
	cfg := ratelimit.Config{
		Default:      generous,
		PerProcedure: map[string]*ratelimit.Limiter{procedure: strict},
	}
	srv := newServer(t, "uid-1", cfg)
	if err := call(t, srv, ""); err != nil {
		t.Fatalf("first request should be allowed: %v", err)
	}
	if err := call(t, srv, ""); err == nil {
		t.Fatal("expected the stricter per-procedure limiter to apply, not the generous default")
	}
}

func TestInterceptor_PerIPLimit(t *testing.T) {
	cfg := ratelimit.Config{IP: ratelimit.NewLimiter(1, time.Minute)}
	// No uid in context at all (e.g. before auth) still gets IP-limited.
	srv := newServer(t, "", cfg)
	if err := call(t, srv, "1.2.3.4"); err != nil {
		t.Fatalf("first request should be allowed: %v", err)
	}
	if err := call(t, srv, "1.2.3.4"); err == nil {
		t.Fatal("second request from the same IP should be limited")
	}
	if err := call(t, srv, "5.6.7.8"); err != nil {
		t.Fatalf("a different IP should have its own bucket: %v", err)
	}
}

// TestInterceptor_TrustedProxyHopsAffectsIPBucket: with TrustedProxyHops=2, the interceptor must key the
// per-IP bucket off the second entry from the right, not the rightmost — the concrete behavior change an
// operator gets from raising TRUSTED_PROXY_HOPS once the real hop count is measured in dev.
func TestInterceptor_TrustedProxyHopsAffectsIPBucket(t *testing.T) {
	cfg := ratelimit.Config{IP: ratelimit.NewLimiter(1, time.Minute), TrustedProxyHops: 2}
	srv := newServer(t, "", cfg)

	// Same second-from-right entry ("5.6.7.8") in both calls, different rightmost (Google front-end) hop -
	// with hops=1 these would land in different buckets; with hops=2 they must share one.
	if err := call(t, srv, "1.2.3.4, 5.6.7.8, 9.10.11.12"); err != nil {
		t.Fatalf("first request should be allowed: %v", err)
	}
	if err := call(t, srv, "1.2.3.4, 5.6.7.8, 9.10.11.13"); err == nil {
		t.Fatal("second request sharing the hops=2 client IP should be rate limited")
	}
}

// TestInterceptor_LogsXFFHopCountNotIPs (XFF concern): the debug log must carry a count operators can use
// to calibrate TRUSTED_PROXY_HOPS, and must never carry the IP addresses themselves (PII).
func TestInterceptor_LogsXFFHopCountNotIPs(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	cfg := ratelimit.Config{Log: log}
	srv := newServer(t, "", cfg)

	if err := call(t, srv, "1.2.3.4, 5.6.7.8, 9.10.11.12"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"xff_hops":3`) {
		t.Errorf("log output missing xff_hops=3; got: %s", out)
	}
	for _, leaked := range []string{"1.2.3.4", "5.6.7.8", "9.10.11.12"} {
		if strings.Contains(out, leaked) {
			t.Errorf("log output leaked an IP address (%s), want only the hop count: %s", leaked, out)
		}
	}
}

func assertResourceExhausted(t *testing.T, err error) {
	t.Helper()
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != connect.CodeResourceExhausted {
		t.Fatalf("Code() = %v, want ResourceExhausted", cerr.Code())
	}
}
