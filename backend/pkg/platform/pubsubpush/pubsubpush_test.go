package pubsubpush

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPlaceholderHandler_Accepted(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/internal/some-topic", nil)
	rec := httptest.NewRecorder()

	PlaceholderHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusAccepted {
		t.Errorf("status = %d, want 202", rec.Code)
	}
}

func TestMiddleware_RejectsMissingAuthorization(t *testing.T) {
	v := NewVerifier("https://api.example.com", "push@x.iam.gserviceaccount.com")
	handler := v.Middleware(PlaceholderHandler())

	req := httptest.NewRequest(http.MethodPost, "/internal/some-topic", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestMiddleware_RejectsInvalidBearerToken(t *testing.T) {
	v := NewVerifier("https://api.example.com", "push@x.iam.gserviceaccount.com")
	handler := v.Middleware(PlaceholderHandler())

	req := httptest.NewRequest(http.MethodPost, "/internal/some-topic", nil)
	req.Header.Set("Authorization", "Bearer not-a-real-oidc-token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestNewVerifier_BuildsAllowedEmailSet(t *testing.T) {
	v := NewVerifier("aud", "a@x.iam.gserviceaccount.com", "b@x.iam.gserviceaccount.com")
	if len(v.allowedEmails) != 2 {
		t.Fatalf("allowedEmails = %v, want 2 entries", v.allowedEmails)
	}
	if v.audience != "aud" {
		t.Errorf("audience = %q, want aud", v.audience)
	}
}
