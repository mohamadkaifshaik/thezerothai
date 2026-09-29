# Code map (backend). One line per reusable item. Keep sorted by area.

Scope note: this file catalogs shared, cross-module code under `backend/pkg/platform` and the module
interfaces under `backend/internal/*/api.go`. Domain internals (service/repo/server implementation
details) are not catalogued here — only what other code should import and reuse.

## Config, wiring, lifecycle

| Item | Location | Use it for |
|---|---|---|
| config.Config / config.Load / config.MustLoad | backend/pkg/platform/config | All env-var configuration: PORT, ENV, DEGRADED_MODE, APP_CHECK_MODE, CURSOR_HMAC_KEY, rate-limit/quota defaults, INTERNAL_OIDC_*, TRUSTED_PROXY_HOPS |
| logger.New / logger.L / logger.WithLogger | backend/pkg/platform/logger | Process-wide slog JSON logger (Cloud Logging shaped: severity/message) |
| logger.TraceFromRequest / TraceFromRequestHeader / WithTrace / TraceFromContext | backend/pkg/platform/logger | Cloud Trace correlation field from `traceparent` / `X-Cloud-Trace-Context` |
| logger.HashUID | backend/pkg/platform/logger | Non-PII per-user log correlation (`uid_hash` field) |
| logger.WithRequestInfo / RequestInfoFromContext | backend/pkg/platform/logger | Mutable per-request pointer (uid, app_check_failed, xff_hops, via_hosting) inner interceptors set so `mw.Logging`'s one log line can see fields set *after* it calls `next` — the fix for "an inner interceptor's ctx.WithValue is invisible to an ancestor holding the original ctx"; don't add a second ad hoc ctx-value flag for a future log field, extend this struct instead |
| httpcors.Wrap | backend/pkg/platform/httpcors | The one browser-CORS middleware for the Connect mux (wraps the whole handler, not a Connect interceptor — preflight OPTIONS never reaches one); no-op when the origin allowlist is empty |
| fsclient.New | backend/pkg/platform/fsclient | The one process-wide `*firestore.Client` (emulator-aware via FIRESTORE_EMULATOR_HOST, standard SDK behavior) |
| health.Handler | backend/pkg/platform/health | `/healthz` — zero-dependency liveness/startup probe |
| pubsubpush.NewVerifier / Middleware / PlaceholderHandler | backend/pkg/platform/pubsubpush | OIDC-verified `/internal/*` handlers for Pub/Sub push + Cloud Scheduler |

## Auth & abuse controls

| Item | Location | Use it for |
|---|---|---|
| authn.NewIDTokenVerifier / IDTokenInterceptor | backend/pkg/platform/authn | Firebase ID token verification (Connect interceptor), attaches authn.Claims to ctx |
| authn.NewAppCheckVerifier / AppCheckInterceptor | backend/pkg/platform/authn | Firebase App Check verification (enforce/monitor modes) |
| authn.AccountStatusInterceptor / AccountStatusProvider / ProfileExemptProcedures | backend/pkg/platform/authn | PROFILE_REQUIRED / SUSPENDED / DELETING enforcement; a module's Service implements AccountStatusProvider via a small adapter (see cmd/api/main.go) |
| authn.UIDFromContext / ClaimsFromContext / WithClaims | backend/pkg/platform/authn | Read the verified caller identity anywhere downstream of the auth interceptors |
| degraded.Interceptor / ProcedureSet / NewProcedureSet | backend/pkg/platform/degraded | DEGRADED_MODE=readonly/nomedia enforcement; readonly is derived from each RPC's proto `idempotency_level`, no hand-maintained list |
| ratelimit.NewLimiter / ratelimit.Interceptor / ratelimit.Config / ResolveClientIP / ClientIP / XFFHopCount | backend/pkg/platform/ratelimit | Per-uid and per-IP in-memory token buckets (post-auth, inside the Connect chain), with per-procedure overrides. `ResolveClientIP(h, hops)` auto-detects a Firebase Hosting egress IP at the rightmost X-Forwarded-For entry (isGoogleEgressIP / googleEgressCIDRs, excludes GCP customer-assignable ranges) and steps one entry left when found; `hops` > 1 is an explicit operator override (config.Config.TrustedProxyHops / env TRUSTED_PROXY_HOPS) that skips detection. Sets xff_hops/via_hosting on logger.RequestInfo for mw.Logging's per-request line — never logs an IP directly |
| ratelimit.PreAuthIPMiddleware | backend/pkg/platform/ratelimit | Plain net/http middleware, coarse per-IP flood backstop *before* the Connect handler chain (before App Check/ID token JWT-verify CPU) — wraps apiserver.Build's whole mux, a separate Limiter from ratelimit.Interceptor's; exempts /health, /healthz |
| quota.Store / quota.CheckAndReserve / quota.Today | backend/pkg/platform/quota | Daily per-user quotas at `quotas/{uid}` (posts/follows/uploads/exports), IST day boundary |

## Errors, requests, pagination

| Item | Location | Use it for |
|---|---|---|
| apierr.Error / apierr.New / apierr.Validation / apierr.ToConnect | backend/pkg/platform/apierr | Every service-layer error: Connect code + `dzeroth.common.v1.ErrorDetail`. Services return `*apierr.Error`; never build a `*connect.Error` by hand in a service/server. |
| mw.Recover / mw.Logging / mw.ErrorMapping | backend/pkg/platform/mw | Cross-cutting Connect interceptors: panic recovery, one-line-per-request logging, final error-to-Connect-code mapping (must be innermost). Wire order is `logging -> recover -> ... -> errorMapping` (Logging outermost, see its package doc comment) — mw.Logging is also the last-resort error shaper + Error-Reporting fallback for any interceptor between it and ErrorMapping that short-circuits without calling next (e.g. authn.AccountStatusInterceptor); don't add a second reportError call anywhere else, extend Logging's existing fallback instead |
| budget.Counter / budget.WithCounter / budget.FromContext | backend/pkg/platform/budget | Per-request Firestore read/write/delete counting for logs (`fs_reads`/`fs_writes`) and integration-test budget assertions |
| cursor.Encode / cursor.Decode / cursor.Cursor / cursor.IsFirstPage | backend/pkg/platform/cursor | Opaque, HMAC-signed `(createdAt, docId)` pagination cursors — use for every list RPC, don't build a second cursor scheme |
| limits.ClampPageSize / limits.DefaultPageSize / limits.MaxPageSize | backend/pkg/platform/limits | page_size clamping (default 20, max 50) for every list RPC |
| limits.MaxRequestBytes | backend/pkg/platform/limits | Request-body size cap (256 KiB) passed to both connect.WithReadMaxBytes (per handler) and http.MaxBytesHandler (wrapping the mux) in apiserver.Build — don't hand-roll a second size constant for a new module's handler |
| idempotency.Store / idempotency.Key / idempotency.HashRequest | backend/pkg/platform/idempotency | The `idempotency/{sha256(uid\|rpc\|key)}` doc mechanism for creates with a Snowflake id (CreatePost, CreateUpload, ...). Natural-key creates (users, follows, likes) don't need this — a `Create()` `AlreadyExists` is enough. |

## Storage primitives

| Item | Location | Use it for |
|---|---|---|
| store.Batch / store.NewFirestoreBatch / store.NewFirestoreTxBatch | backend/pkg/platform/store | The cross-module unit-of-work seam (ADR-0002). Pass `store.Batch` into another module's interface method so it can append writes to your batch/transaction; never build another module's document paths yourself. |
| snowflake.Node / snowflake.NewNode / snowflake.Generate | backend/pkg/platform/snowflake | 64-bit time-ordered IDs (19-digit zero-padded decimal string) for posts/media doc IDs. Not yet wired into main.go — no module needs it until posts/media exist. |
| cache.LRU\[K, V\] / cache.New | backend/pkg/platform/cache | Generic in-process LRU-with-TTL. Every module's instance cache (e.g. `identity.Cache`) wraps this instead of writing a new cache. |

## Scripts

| Item | Location | Use it for |
|---|---|---|
| scripts/dev.sh | scripts/dev.sh | The actual backend+Flutter-web startup logic for `make dev`. Not inlined in the Makefile's `emulators:exec` call (N8): that string runs through the OS default shell (cmd.exe on Windows), which can't parse bash's `trap`/`&`/subshells — `make dev` invokes `bash scripts/dev.sh` instead, a single cmd.exe-safe command line, and the script itself always runs under a real bash. Reads BACKEND_DIR/APP_DIR/PORT from the environment (exported by the Makefile), not Make substitution. |

## Composition root

| Item | Location | Use it for |
|---|---|---|
| apiserver.Build | backend/internal/apiserver | The one `*http.ServeMux` wiring every module's Connect handler + `/health`(z) + `/internal/*` with the full interceptor chain (ADR-0006 §2), wrapped outermost by CORS -> ratelimit.PreAuthIPMiddleware -> http.MaxBytesHandler (M1/hardening, see its doc comment for the full per-request pipeline). `cmd/api/main.go` and `backend/e2e` both call this — a `package main` can't be imported, so the wiring can't live in cmd/api itself. |

## Test helpers (import only from `_test.go` files, like `net/http/httptest`)

| Item | Location | Use it for |
|---|---|---|
| budgettest.Assert / budgettest.Budget | backend/pkg/platform/budget/budgettest | Asserting a `*budget.Counter` from an integration test call stays within an RPC's documented worst-case reads/writes/deletes (testing-strategy skill). Don't hand-roll another `if counter.Reads() > N` block — extend Budget if a new field is ever needed. |
| assertGraphInvariants / graphInvariantViolations / loadGraphState | backend/internal/graph/invariants_integration_test.go | The ADR-0008 D3 graph invariant checker (I1 follows edge <=> following[], I2 counters = edge counts, I3 blocked <=> blockedBy except overflow, I4 no edge across a block, plus S1/S2 structural checks). `newWired` runs it as a t.Cleanup after EVERY graph scenario; call `assertGraphInvariants(t, w.client)` directly mid-test (races) or from T16b / the T25 runbook drill. Ignores `pad-` uids from `padUIDs`. Opt out only with `w.SkipInvariantSweep(reason)`. `graphInvariantViolations` is pure, with negative self-tests. |
| newWired / wiredOption (withFlags, withNewAccountWindow, withQuotas) | backend/internal/graph/fixtures_integration_test.go | Fully wired identity+graph on a fresh emulator project (apiserver.Build wiring minus HTTP) with the invariant sweep registered. Options change flags/quota tiers; `withNewAccountWindow(1)` makes every profile an established account without a clock seam. |
| mustCreateProfile / mustCreateUsers / seedFollow / seedBlock / seedEdge / seedGraphArrays / seedQuota / seedUserField / padUIDs / istDay | backend/internal/graph/fixtures_integration_test.go | THE graph seeding helpers (no second seeding helper for T16b). `seedFollow` and `seedBlock` write invariant-consistent state; `seedEdge` (edge doc only) and `seedGraphArrays` (raw arrays) are raw and need `SkipInvariantSweep` if they break an invariant. `seedQuota` with `istDay(-1)` models the IST-midnight rollover; `padUIDs(n)` reaches a cap (5,000 following / 2,000 blocked / 10,000 blockedBy) without real users. |
| measured / requireAPIError / warmProfiles / quotaUsed / runConcurrently | backend/internal/graph/fixtures_integration_test.go | `measured(t, rpc, budgettest.Budget, fn)` runs one call under a fresh counter, logs `BUDGET <rpc> reads=.. writes=.. deletes=..` (feeds the T21 cost report) and asserts via `budgettest.Assert`; `requireAPIError` asserts Connect code + ErrorReason + metadata; `warmProfiles` measures the warm "typical" budget; `runConcurrently` releases N goroutines together for race tests. |

## Module interfaces (`backend/internal/*/api.go`)

| Item | Location | Use it for |
|---|---|---|
| identity.Service | backend/internal/identity/api.go | CreateProfile, CheckHandleAvailability, GetMe, GetProfile, UpdateProfile, ChangeHandle, AccountStatus. The only thing identity's Connect handler (server.go) depends on. |
| identity.Counters | backend/internal/identity/api.go | Cross-module counter increments on `users/{uid}` (posts/followers/following counts) via `store.Batch` — implemented by identity.FirestoreRepo, used by graph (Follow/Block/Unfollow; `AddCounts` merges both counters on one doc into one write) |
| identity.GraphInitializer | backend/internal/identity/api.go | The one seam identity depends on to create `graph/{uid}` inside CreateProfile's transaction; implemented by graph.FirestoreRepo (backend/internal/graph) until the full GraphService exists |

## Not implemented yet (Phase 0 bootstrap)

`graph` (full GraphService), `posts`, `timeline`, `engagement`, `media`, `notifications`, `search`,
`moderation`, `admin` — no Connect servers registered in `cmd/api/main.go`. `identity.DeleteAccount`,
`RequestAccountExport`, `GetAccountExport` are stubbed `Unimplemented` (need those modules' delete/export
fan-out, ADR-0003). Check here before adding a "temporary" cache, rate limiter, error mapper, or
pagination helper anywhere else — one already exists above.
