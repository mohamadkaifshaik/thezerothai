package httpcors_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/httpcors"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
}

func TestWrap_EmptyOriginsIsNoOp(t *testing.T) {
	h := httpcors.Wrap(nil, okHandler())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	req.Header.Set("Origin", "http://localhost:12345")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want empty (CORS off)", got)
	}
}

func TestWrap_AllowsMatchingLocalhostWildcard(t *testing.T) {
	h := httpcors.Wrap([]string{"http://localhost:*"}, okHandler())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	req.Header.Set("Origin", "http://localhost:54321")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "http://localhost:54321" {
		t.Errorf("Access-Control-Allow-Origin = %q, want http://localhost:54321", got)
	}
}

func TestWrap_RejectsUnknownOrigin(t *testing.T) {
	h := httpcors.Wrap([]string{"https://app.example.com"}, okHandler())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	req.Header.Set("Origin", "https://evil.example.com")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want empty for an unlisted origin", got)
	}
}

func TestWrap_PreflightAllowsAuthorizationAndAppCheckHeaders(t *testing.T) {
	h := httpcors.Wrap([]string{"https://app.example.com"}, okHandler())
	req := httptest.NewRequest(http.MethodOptions, "/dzeroth.identity.v1.IdentityService/GetMe", nil)
	req.Header.Set("Origin", "https://app.example.com")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	// Browsers send this list normalized to lowercase and sorted lexicographically (Fetch spec) before the
	// server ever sees it; rs/cors validates that ordering, so the test must replicate it.
	req.Header.Set("Access-Control-Request-Headers", "authorization,content-type,x-firebase-appcheck")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK && rec.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d, want 200/204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Headers"); got == "" {
		t.Error("expected Access-Control-Allow-Headers to be set on the preflight response")
	}
}
