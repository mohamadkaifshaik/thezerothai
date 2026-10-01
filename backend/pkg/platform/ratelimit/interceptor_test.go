package ratelimit_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

const procedure = "/test.Service/Method"

// authInject is a tiny interceptor that stands in for authn.IDTokenInterceptor, since ratelimit.Interceptor
// must run after a uid has been attached to the context.
func authInject(uid string) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if uid != "" {
				ctx = authn.WithClaims(ctx, authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
			}
			return next(ctx, req)
		}
	})
}

// requestInfoInject stands in for mw.Logging's ctx.WithValue setup, since ratelimit.Interceptor writes
// xff_hops/via_hosting onto the same logger.RequestInfo pointer mw.Logging reads from for its one line per
// request (M2) — without this, logger.RequestInfoFromContext(ctx) would be nil inside the interceptor,
// exactly like a real request that reached ratelimit.Interceptor without mw.Logging ever running.
func requestInfoInject(info **logger.RequestInfo) connect.UnaryInterceptorFunc {
	return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			ctx, ri := logger.WithRequestInfo(ctx)
			*info = ri
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

// newServerWithRequestInfo is newServer plus requestInfoInject, for tests that need to inspect what
// ratelimit.Interceptor wrote to logger.RequestInfo (M2). info is populated once the request completes.
func newServerWithRequestInfo(t *testing.T, uid string, cfg ratelimit.Config) (srv *httptest.Server, info **logger.RequestInfo) {
	t.Helper()
	info = new(*logger.RequestInfo)
	h := connect.NewUnaryHandler(procedure, okHandler,
		connect.WithInterceptors(requestInfoInject(info), authInject(uid), ratelimit.Interceptor(cfg)),
	)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, info
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
// operator gets from raising TRUSTED_PROXY_HOPS as an explicit override (ResolveClientIP's doc comment).
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

// TestInterceptor_SetsXFFHopsAndViaHostingOnRequestInfo (M2): the interceptor must surface xff_hops/
// via_hosting on logger.RequestInfo so mw.Logging's one-line-per-request INFO log can carry them — the
// fix for the old defect where this was only ever logged at Debug (dropped in prod, which defaults to
// Info). Never the IP itself: RequestInfo has no field for one, by design.
func TestInterceptor_SetsXFFHopsAndViaHostingOnRequestInfo(t *testing.T) {
	cfg := ratelimit.Config{}
	srv, info := newServerWithRequestInfo(t, "", cfg)

	if err := call(t, srv, "1.2.3.4, 5.6.7.8, 66.249.64.10"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if (*info).XFFHops != 3 {
		t.Errorf("XFFHops = %d, want 3", (*info).XFFHops)
	}
	if !(*info).ViaHosting {
		t.Error("ViaHosting = false, want true: rightmost entry is a recognized Google egress IP")
	}
}

func TestInterceptor_SetsViaHostingFalseOnDirectPath(t *testing.T) {
	cfg := ratelimit.Config{}
	srv, info := newServerWithRequestInfo(t, "", cfg)

	if err := call(t, srv, "203.0.113.7"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if (*info).ViaHosting {
		t.Error("ViaHosting = true, want false: rightmost entry is an ordinary (non-Google) address")
	}
	if (*info).XFFHops != 1 {
		t.Errorf("XFFHops = %d, want 1", (*info).XFFHops)
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
