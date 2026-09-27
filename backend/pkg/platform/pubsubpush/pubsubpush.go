// Package pubsubpush verifies the Google-signed OIDC tokens Pub/Sub push subscriptions and Cloud
// Scheduler attach to requests against /internal/* (ADR-0002, ADR-0006 §5). These endpoints are never
// reachable through the public Connect handlers; they're plain http.Handlers behind this middleware.
package pubsubpush

import (
	"fmt"
	"net/http"
	"strings"

	"google.golang.org/api/idtoken"
)

// Verifier checks that an incoming request carries a valid OIDC token whose audience matches this
// service's URL and whose `email` claim is one of the allowed push/scheduler service accounts.
type Verifier struct {
	audience      string
	allowedEmails map[string]struct{}
}

// NewVerifier builds a Verifier. audience is normally the Cloud Run service URL (the value configured
// on the Pub/Sub push subscription / Scheduler job's OIDC token audience).
func NewVerifier(audience string, allowedEmails ...string) *Verifier {
	set := make(map[string]struct{}, len(allowedEmails))
	for _, e := range allowedEmails {
		set[e] = struct{}{}
	}
	return &Verifier{audience: audience, allowedEmails: set}
}

// Middleware wraps an internal handler, rejecting any request without a valid, authorized OIDC token.
func (v *Verifier) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authz := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(authz, prefix) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		token := strings.TrimPrefix(authz, prefix)
		payload, err := idtoken.Validate(r.Context(), token, v.audience)
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		email, _ := payload.Claims["email"].(string)
		if _, ok := v.allowedEmails[email]; !ok {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// PlaceholderHandler answers 202 Accepted with no body. Wired at /internal/ until real Pub/Sub push
// topics (post-delete, account-delete, profile-snapshot-refresh, ...) are implemented by their owning
// modules; keeps the route present (and OIDC-checked) from day one.
func PlaceholderHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = fmt.Fprintf(w, "no handler registered for %s yet\n", r.URL.Path)
	})
}
