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

	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/fsclient"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/health"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/httpcors"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpush"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// healthPaths is exempt from PreAuthIPMiddleware (M1): Cloud Run's startup/liveness probe hits /health
// (and its legacy /healthz alias) constantly and must never be throttled. Checked against the path *after*
// any Firebase Hosting `/api/**` StripPrefix (see the wrapping order below), so both routes exempt with
// just these two bare entries.
var healthPaths = map[string]struct{}{"/health": {}, "/healthz": {}}

// Build wires every module's Connect handler plus /health and /internal/* into one handler (ADR-0002: one
// process, one mux, one cold start). The caller owns closing the returned *firestore.Client (e.g. defer).
//
// The return type is http.Handler, not *http.ServeMux: Firebase Hosting forwards `/api/**` to Cloud Run
// unchanged (firebase.json), so every route below is also mounted under an `/api` prefix (B1) by wrapping
// the base mux a second time with http.StripPrefix. That doubly-mounted mux is then wrapped, outermost
// first: CORS (M10) -> PreAuthIPMiddleware (M1) -> http.MaxBytesHandler (hardening). All of these return
// http.Handler, and cmd/api/main.go / backend/e2e only ever need an http.Handler (net/http's native h2c
// support / httptest.NewServer), so nothing downstream needs ServeMux itself.
//
// Full per-request pipeline, outermost to innermost (document any change here in the PR body — it's the
// ADR-0006 §2 order plus the plain-net/http layers M1/hardening added in front of it):
//
//	CORS -> PreAuthIPMiddleware (M1: coarse per-IP flood backstop, pre-auth) -> MaxBytesHandler (hardening)
//	  -> [mux dispatch: /health | /internal/* | a module's Connect handler, each connect.WithReadMaxBytes'd]
//	    -> logging -> recover -> App Check -> ID token -> rate limit (fine-grained, per-uid/IP, post-auth)
//	       -> degraded mode -> account status -> errorMapping -> handler
//
// M1 (docs/reviews/security-audit-v0.1.0.md — distinct from ADR-0006 §2's own "Phase 0 review M1"
// amendment, coincidentally the same finding ID and date): the ADR-0006 §2 rate-limit interceptor still
// sits *after* App Check/ID token verification, so on its own it can't stop an unauthenticated flood from
// paying JWT-verify CPU. PreAuthIPMiddleware is a second, independent Limiter (never the same
// bucket/instance as the one ratelimit.Interceptor uses below) that rejects by IP before any of that
// verification work runs at all.
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

	// --- feature flags (ADR-0008 D6) ---
	featureFlags := flags.NewRegistry(cfg.FeatureGraph)
	log.Info("feature_flags", "flags", featureFlags.StartupLogValues())

	// --- modules ---
	// graph.FirestoreRepo backs both identity.GraphInitializer (creating the empty graph/{uid} doc inside
	// CreateProfile's transaction, unchanged since the Phase 0 bootstrap) and the full GraphService
	// (ADR-0008). graph depends on identity.Directory/Counters directly; identity depends on graph only
	// through the consumer-side identity.BlockChecker interface it declares itself (identity/api.go) — no
	// import cycle. graph.Service needs identity.Directory (implemented by identitySvc) and identitySvc
	// needs graph.Service as its BlockChecker: SetDirectory breaks that construction-order cycle (see
	// graph.service's doc comment) — safe because it runs once, synchronously, before ListenAndServe.
	graphRepo := graph.NewFirestoreRepo(fsClient)
	identityRepo := identity.NewFirestoreRepo(fsClient, graphRepo)
	identityCache := identity.NewCache(cfg.CacheTTL)
	graphCache := graph.NewCache(cfg.CacheTTL)

	graphSvc := graph.New(graph.Deps{
		Repo:                    graphRepo,
		Cache:                   graphCache,
		Counters:                identityRepo,
		Flags:                   featureFlags,
		FollowsPerDay:           int64(cfg.Quota.FollowsPerDay),
		NewAccountFollowsPerDay: int64(cfg.Quota.NewAccountFollowsPerDay),
		BlocksPerDay:            int64(cfg.Quota.BlocksPerDay),
		NewAccountBlocksPerDay:  int64(cfg.Quota.NewAccountBlocksPerDay),
		NewAccountWindow:        cfg.Quota.NewAccountWindow,
	})
	identitySvc := identity.New(identityRepo, identityCache, cfg.HandleChangeCooldown,
		identity.WithFeatureFlags(featureFlags),
		identity.WithBlockChecker(graphSvc),
	)
	// identitySvc's concrete type also implements identity.Directory (GetProfiles/Forget); asserted here
	// since identity.Service itself only exposes the Connect-handler-facing RPC methods.
	graphSvc.SetDirectory(identitySvc.(identity.Directory))

	identityServer := identity.NewServer(identitySvc)
	graphServer := graph.NewServer(graphSvc)

	// posts, timeline, engagement, media, notifications, search, moderation, admin are not implemented in
	// this bootstrap; their Connect servers are not registered.

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

	// ADR-0008 D7: Follow/Unfollow 30/min, Block/Unblock/Mute/Unmute 20/min, lists 20/min; GetRelationships
	// uses rlDefault (the 60/min default). A shared DailyCap (not a second limiter) backs the per-uid daily
	// list cap (T4), logged as limit_name "graph_list_daily".
	rlGraphFollow := ratelimit.NewLimiter(cfg.RateLimit.GraphFollowPerMinute, idleBucketTTL)
	rlGraphBlock := ratelimit.NewLimiter(cfg.RateLimit.GraphBlockPerMinute, idleBucketTTL)
	rlGraphList := ratelimit.NewLimiter(cfg.RateLimit.GraphListPerMinute, idleBucketTTL)
	graphListDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphListCallsPerDay, 24*time.Hour)

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
				graphv1connect.GraphServiceFollowProcedure:                        rlGraphFollow,
				graphv1connect.GraphServiceUnfollowProcedure:                      rlGraphFollow,
				graphv1connect.GraphServiceBlockProcedure:                         rlGraphBlock,
				graphv1connect.GraphServiceUnblockProcedure:                       rlGraphBlock,
				graphv1connect.GraphServiceMuteProcedure:                          rlGraphBlock,
				graphv1connect.GraphServiceUnmuteProcedure:                        rlGraphBlock,
				graphv1connect.GraphServiceListFollowersProcedure:                 rlGraphList,
				graphv1connect.GraphServiceListFollowingProcedure:                 rlGraphList,
				graphv1connect.GraphServiceListBlockedUsersProcedure:              rlGraphList,
				graphv1connect.GraphServiceListMutedUsersProcedure:                rlGraphList,
			},
			DailyCaps: map[string]ratelimit.NamedDailyCap{
				graphv1connect.GraphServiceListFollowersProcedure:    {Name: "graph_list_daily", Cap: graphListDailyCap},
				graphv1connect.GraphServiceListFollowingProcedure:    {Name: "graph_list_daily", Cap: graphListDailyCap},
				graphv1connect.GraphServiceListBlockedUsersProcedure: {Name: "graph_list_daily", Cap: graphListDailyCap},
				graphv1connect.GraphServiceListMutedUsersProcedure:   {Name: "graph_list_daily", Cap: graphListDailyCap},
			},
			IP:               rlIP,
			TrustedProxyHops: cfg.TrustedProxyHops,
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

	// Hardening (2026-09-27 security audit, informational finding): connect.WithReadMaxBytes caps the
	// *decompressed* body size at the Connect codec layer (a gzip-bomb guard — see limits.MaxRequestBytes's
	// doc comment); http.MaxBytesHandler below caps the raw bytes read off the socket before that.
	path, handler := identityv1connect.NewIdentityServiceHandler(identityServer, interceptors, connect.WithReadMaxBytes(limits.MaxRequestBytes))
	mux.Handle(path, handler)

	graphPath, graphHandler := graphv1connect.NewGraphServiceHandler(graphServer, interceptors, connect.WithReadMaxBytes(limits.MaxRequestBytes))
	mux.Handle(graphPath, graphHandler)

	// M8: outside ENV=local, config.Load already refuses to start unless both InternalOIDCAudience and
	// InternalOIDCAllowedEmails are set (fail closed), so /internal/* is only ever unauthenticated here
	// when cfg.Env == "local" — where no real Pub/Sub push subscription exists yet to forge a call from.
	internalHandler := http.Handler(pubsubpush.PlaceholderHandler())
	if cfg.InternalOIDCAudience != "" {
		verifier := pubsubpush.NewVerifier(cfg.InternalOIDCAudience, cfg.InternalOIDCAllowedEmails...)
		internalHandler = verifier.Middleware(internalHandler)
	}
	mux.Handle("/internal/", internalHandler)

	// M1 (docs/reviews/security-audit-v0.1.0.md): a coarse, pre-auth per-IP token bucket wraps the whole mux — /health,
	// /internal/* and every module's Connect handler — as plain net/http middleware, so an unauthenticated
	// flood is rejected before it costs any App Check / ID token JWT-verify CPU (that verification happens
	// only once a request reaches a Connect handler's own interceptor chain inside mux, below this layer).
	// This is a *different* Limiter instance from the one ratelimit.Interceptor uses above (rlIP): a
	// request is never double-charged against the same bucket for the two layers.
	//
	// Hardening: http.MaxBytesHandler caps the raw request-body bytes read off the socket (before any
	// decompression) for every route on mux, using the same limits.MaxRequestBytes as
	// connect.WithReadMaxBytes above.
	//
	// Both wrap mux itself, *before* it is mounted twice below — so exemptPaths (healthPaths) and every
	// route see the same normalized path regardless of whether the request arrived at "/health" directly or
	// "/api/health" via Firebase Hosting's rewrite (http.StripPrefix runs first on that path, then this
	// same wrapped handler runs against the already-stripped "/health").
	preAuthIPLimiter := ratelimit.NewLimiter(cfg.RateLimit.PreAuthIPPerMinute, idleBucketTTL)
	protectedMux := ratelimit.PreAuthIPMiddleware(preAuthIPLimiter, cfg.TrustedProxyHops, healthPaths)(
		http.MaxBytesHandler(mux, limits.MaxRequestBytes),
	)

	// B1: Firebase Hosting's `/api/**` rewrite (firebase.json) forwards the path unchanged, so every route
	// above must also answer under that prefix. http.StripPrefix delegates to the exact same (protected) mux
	// instead of registering every module's handler twice, so this stays correct as new modules are added.
	root := http.NewServeMux()
	root.Handle("/", protectedMux)
	root.Handle("/api/", http.StripPrefix("/api", protectedMux))

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
