// Package httpcors provides the browser CORS wrapper for the Connect mux (M10). CORS is plain net/http
// middleware around the whole mux, not a Connect interceptor: preflight OPTIONS requests never carry a
// Connect procedure and would never reach a Connect handler or its interceptor chain.
//
// CLAUDE.md / ADR-0007: Firebase Hosting's `/api/**` rewrite means dev/prod web traffic to the API is
// always same-origin, so CORS is off by default outside local dev — this package only ever does anything
// when config.Config.CORSAllowedOrigins is non-empty (local dev's Flutter web client, or an explicit
// CORS_ALLOWED_ORIGINS override for the rare case web needs to call the Cloud Run URL directly).
package httpcors

import (
	"net/http"

	connectcors "connectrpc.com/cors"
	"github.com/rs/cors"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// maxAgeSeconds bounds how long a browser caches a preflight response (2h): long enough to avoid a
// preflight round trip on every call, short enough that a Terraform origin-allowlist change takes effect
// quickly.
const maxAgeSeconds = 2 * 60 * 60

// Wrap returns next unchanged if origins is empty (CORS off, the default outside local — see the package
// doc comment); otherwise it wraps next with a CORS handler allowing exactly those origins for Connect's
// unary protocols (Connect JSON/binary, gRPC-web).
func Wrap(origins []string, next http.Handler) http.Handler {
	if len(origins) == 0 {
		return next
	}
	c := cors.New(cors.Options{
		AllowedOrigins: origins,
		AllowedMethods: connectcors.AllowedMethods(),
		AllowedHeaders: append(connectcors.AllowedHeaders(), "Authorization", authn.AppCheckHeader),
		ExposedHeaders: connectcors.ExposedHeaders(),
		MaxAge:         maxAgeSeconds,
		// No cookies/credentials are used for auth (Firebase ID tokens go in the Authorization header), so
		// AllowCredentials stays false — the safer default, and it lets AllowedOrigins keep using "*"
		// wildcards (e.g. "http://localhost:*"), which CORS forbids once credentials are allowed.
		AllowCredentials: false,
	})
	return c.Handler(next)
}
