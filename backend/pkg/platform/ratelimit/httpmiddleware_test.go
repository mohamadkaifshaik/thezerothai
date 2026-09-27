package ratelimit_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

func newProtectedHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
}

func doGet(t *testing.T, h http.Handler, path, xff string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestPreAuthIPMiddleware_BlocksFloodByIP(t *testing.T) {
	limiter := ratelimit.NewLimiter(1, time.Minute)
	h := ratelimit.PreAuthIPMiddleware(limiter, 1, nil)(newProtectedHandler())

	if rec := doGet(t, h, "/rpc", "1.2.3.4"); rec.Code != http.StatusOK {
		t.Fatalf("first request status = %d, want 200", rec.Code)
	}
	rec := doGet(t, h, "/rpc", "1.2.3.4")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request status = %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("expected a Retry-After header on the 429 response")
	}
}

func TestPreAuthIPMiddleware_IndependentPerIP(t *testing.T) {
	limiter := ratelimit.NewLimiter(1, time.Minute)
	h := ratelimit.PreAuthIPMiddleware(limiter, 1, nil)(newProtectedHandler())

	if rec := doGet(t, h, "/rpc", "1.2.3.4"); rec.Code != http.StatusOK {
		t.Fatalf("ip1 first request status = %d, want 200", rec.Code)
	}
	if rec := doGet(t, h, "/rpc", "5.6.7.8"); rec.Code != http.StatusOK {
		t.Fatalf("a different IP should have its own bucket, got status %d", rec.Code)
	}
}

// TestPreAuthIPMiddleware_ExemptsHealthPath (M1 ticket: "exempt /health"): Cloud Run's own startup/liveness
// probe must never be throttled, no matter how many times it fires from the same source.
func TestPreAuthIPMiddleware_ExemptsHealthPath(t *testing.T) {
	limiter := ratelimit.NewLimiter(1, time.Minute)
	exempt := map[string]struct{}{"/health": {}, "/healthz": {}}
	h := ratelimit.PreAuthIPMiddleware(limiter, 1, exempt)(newProtectedHandler())

	for i := 0; i < 5; i++ {
		if rec := doGet(t, h, "/health", "9.9.9.9"); rec.Code != http.StatusOK {
			t.Fatalf("request %d to /health status = %d, want 200 (exempt)", i, rec.Code)
		}
	}
	// Confirm the same IP is still fresh (never consumed a token) against a non-exempt path.
	if rec := doGet(t, h, "/rpc", "9.9.9.9"); rec.Code != http.StatusOK {
		t.Fatalf("/rpc after only exempt-path traffic status = %d, want 200", rec.Code)
	}
}

func TestPreAuthIPMiddleware_NilLimiterIsNoop(t *testing.T) {
	h := ratelimit.PreAuthIPMiddleware(nil, 1, nil)(newProtectedHandler())
	for i := 0; i < 3; i++ {
		if rec := doGet(t, h, "/rpc", "1.2.3.4"); rec.Code != http.StatusOK {
			t.Fatalf("request %d status = %d, want 200 with a nil limiter", i, rec.Code)
		}
	}
}

// TestPreAuthIPMiddleware_NoXFFLetsThrough matches ratelimit.Interceptor's existing behavior: a request
// with no resolvable IP (no X-Forwarded-For — never happens behind Cloud Run, but does in local dev/tests
// with nothing in front) is let through unmetered rather than blocked or panicking.
func TestPreAuthIPMiddleware_NoXFFLetsThrough(t *testing.T) {
	limiter := ratelimit.NewLimiter(1, time.Minute)
	h := ratelimit.PreAuthIPMiddleware(limiter, 1, nil)(newProtectedHandler())
	for i := 0; i < 3; i++ {
		if rec := doGet(t, h, "/rpc", ""); rec.Code != http.StatusOK {
			t.Fatalf("request %d status = %d, want 200 with no X-Forwarded-For", i, rec.Code)
		}
	}
}
