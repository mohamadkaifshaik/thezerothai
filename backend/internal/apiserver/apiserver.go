// Package apiserver is the dzeroth monolith's composition root (ADR-0002): it wires every registered
// module's Connect handler, /health (+ /healthz alias) and /internal/* onto one *http.ServeMux with the full interceptor
// chain (ADR-0006 §2). cmd/api/main.go calls Build at startup; backend/e2e also calls it directly to boot
// the exact same handler inside an httptest.Server against the Firebase Emulator Suite.
//
// This package exists only because Go cannot import a `package main` from another package ("is a
// program, not an importable package") — extracting the wiring here is the seam that lets backend/e2e
// exercise the real handler without a second copy of it. cmd/api/main.go is left as a thin
// config-load-and-serve wrapper around Build.
package apiserver

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/fsclient"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/health"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/httpcors"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpush"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// Build wires every module's Connect handler plus /health and /internal/* into one handler (ADR-0002: one
// process, one mux, one cold start). The caller owns closing the returned *firestore.Client (e.g. defer).
//
// The return type is http.Handler, not *http.ServeMux: Firebase Hosting forwards `/api/**` to Cloud Run
// unchanged (firebase.json), so every route below is also mounted under an `/api` prefix (B1) by wrapping
// the base mux a second time with http.StripPrefix — and the whole thing is wrapped once more with the
// CORS middleware (M10). Both wrappers return http.Handler, and cmd/api/main.go / backend/e2e only ever
// need an http.Handler (h2c.NewHandler / httptest.NewServer), so nothing downstream needs ServeMux itself.
func Build(ctx context.Context, cfg config.Config, log *slog.Logger) (http.Handler, *firestore.Client, error) {
	fsClient, err := fsclient.New(ctx, cfg.ProjectID)
	if err != nil {
		return nil, nil, fmt.Errorf("firestore client: %w", err)
	}

	idVerifier, err := authn.NewIDTokenVerifier(ctx, cfg.ProjectID)
	if err != nil {
		return nil, nil, fmt.Errorf("id token verifier: %w", err)
	}
	appCheckVerifier, err := authn.NewAppCheckVerifier(ctx, cfg.ProjectID)
	if err != nil {
		return nil, nil, fmt.Errorf("app check verifier: %w", err)
	}

	// --- modules ---
	// graph.FirestoreRepo is the minimal seam identity depends on to create the empty graph/{uid} doc in
	// the CreateProfile transaction (backend/internal/graph doc comment). The full GraphService is not
	// registered — Phase 0 scope is identity only.
	graphRepo := graph.NewFirestoreRepo(fsClient)
	identityRepo := identity.NewFirestoreRepo(fsClient, graphRepo)
	identityCache := identity.NewCache(cfg.CacheTTL)
	identitySvc := identity.New(identityRepo, identityCache, cfg.HandleChangeCooldown)
	identityServer := identity.NewServer(identitySvc)

	// posts, timeline, engagement, media, notifications, search, moderation, admin, and the full graph
	// module are not implemented in this Phase 0 bootstrap; their Connect servers are not registered.

	// --- interceptors (ADR-0006 §2 order) ---
	accountStatusProvider := accountStatusAdapter{svc: identitySvc}
	profileExempt := authn.ProfileExemptProcedures(
		identityv1connect.IdentityServiceCreateProfileProcedure,
		// CheckHandleAvailability is read-only and must work before a profile exists (sign-up form);
		// see the ADR-0006 deviation note in pkg/platform/authn.ProfileExemptProcedures.
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
	)

	idleBucketTTL := 10 * time.Minute
	rlDefault := ratelimit.NewLimiter(cfg.RateLimit.PerUserPerMinute, idleBucketTTL)
	rlCheckHandle := ratelimit.NewLimiter(cfg.RateLimit.CheckHandlePerUserPerMinute, idleBucketTTL)
	rlIP := ratelimit.NewLimiter(cfg.RateLimit.PerIPPerMinute, idleBucketTTL)

	// M1: rate limit (and degraded mode, also a free in-memory check) now run *before* account status.
	// Previously account status ran first, so a caller who never completes sign-up (no users/{uid}) could
	// call any non-exempt RPC as many times as it wanted — each rejected with PROFILE_REQUIRED — without
	// ever tripping the per-uid/per-IP limiter, because AccountStatusInterceptor returned before
	// ratelimit.Interceptor got a chance to run at all. Moving the free checks first means every call is
	// rate-limited regardless of how it's ultimately rejected, and identity.Cache's ~10s negative "no
	// profile" cache (service.go getProfileCached) keeps the *cost* of the calls that do get through low.
	// N5: logging now runs *before* (outside) recover, not after, so a panicking request still gets its one
	// log line and trace field instead of the panic unwinding past Logging's post-call code entirely.
	// See pkg/platform/mw's package doc comment for the exact final order and the M3 fallback-reporting
	// rationale.
	interceptors := connect.WithInterceptors(
		mw.Logging(log, cfg.ProjectID),
		mw.Recover(log),
		authn.AppCheckInterceptor(appCheckVerifier, authn.Mode(cfg.AppCheck)),
		authn.IDTokenInterceptor(idVerifier),
		ratelimit.Interceptor(ratelimit.Config{
			Default: rlDefault,
			PerProcedure: map[string]*ratelimit.Limiter{
				identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: rlCheckHandle,
			},
			IP:               rlIP,
			TrustedProxyHops: cfg.TrustedProxyHops,
			Log:              log,
		}),
		degraded.Interceptor(cfg.Degraded, degraded.ProcedureSet{} /* no media procedures registered yet */),
		authn.AccountStatusInterceptor(accountStatusProvider, profileExempt),
		mw.ErrorMapping(log),
	)

	mux := http.NewServeMux()
	// /health is the canonical path: Cloud Run's Google front end reserves URL paths ending in "z" on
	// *.run.app, so external requests to /healthz never reach the container. /healthz stays as an alias.
	mux.HandleFunc("/health", health.Handler())
	mux.HandleFunc("/healthz", health.Handler())

	path, handler := identityv1connect.NewIdentityServiceHandler(identityServer, interceptors)
	mux.Handle(path, handler)

	// M8: outside ENV=local, config.Load already refuses to start unless both InternalOIDCAudience and
	// InternalOIDCAllowedEmails are set (fail closed), so /internal/* is only ever unauthenticated here
	// when cfg.Env == "local" — where no real Pub/Sub push subscription exists yet to forge a call from.
	internalHandler := http.Handler(pubsubpush.PlaceholderHandler())
	if cfg.InternalOIDCAudience != "" {
		verifier := pubsubpush.NewVerifier(cfg.InternalOIDCAudience, cfg.InternalOIDCAllowedEmails...)
		internalHandler = verifier.Middleware(internalHandler)
	}
	mux.Handle("/internal/", internalHandler)

	// B1: Firebase Hosting's `/api/**` rewrite (firebase.json) forwards the path unchanged, so every route
	// above must also answer under that prefix. http.StripPrefix delegates to the exact same mux instead of
	// registering every module's handler twice, so this stays correct as new modules are added.
	root := http.NewServeMux()
	root.Handle("/", mux)
	root.Handle("/api/", http.StripPrefix("/api", mux))

	// M10: CORS is off unless cfg.CORSAllowedOrigins is non-empty (local dev by default, or an explicit
	// CORS_ALLOWED_ORIGINS elsewhere) — see pkg/platform/httpcors's doc comment.
	return httpcors.Wrap(cfg.CORSAllowedOrigins, root), fsClient, nil
}

// accountStatusAdapter adapts identity.Service to authn.AccountStatusProvider without either package
// importing the other's concrete types (ADR-0002: modules/platform depend on interfaces only).
type accountStatusAdapter struct {
	svc identity.Service
}

func (a accountStatusAdapter) AccountStatus(ctx context.Context, uid string) (bool, authn.AccountStatus, error) {
	exists, status, err := a.svc.AccountStatus(ctx, uid)
	if err != nil {
		return false, authn.AccountStatusUnknown, err
	}
	switch status {
	case identity.AccountStatusActive:
		return exists, authn.AccountStatusActive, nil
	case identity.AccountStatusSuspended:
		return exists, authn.AccountStatusSuspended, nil
	case identity.AccountStatusDeleting:
		return exists, authn.AccountStatusDeleting, nil
	default:
		return exists, authn.AccountStatusUnknown, nil
	}
}
