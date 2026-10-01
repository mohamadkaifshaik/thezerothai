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
| ratelimit.NewLimiter / ratelimit.Interceptor / ratelimit.Config / ResolveClientIP / ClientIP / XFFHopCount | backend/pkg/platform/ratelimit | Per-uid and per-IP in-memory token buckets (post-auth, inside the Connect chain), with per-procedure overrides. `ratelimit.DailyCap` / `NewDailyCap(limit)` (+ `Config.DailyCaps`, `NamedDailyCap`) is the per-uid daily counter that resets only at IST midnight (`quota.TodayAt`, no idle TTL); apiserver wires four: `graph_list_daily` (list RPCs), `graph_mutation_daily` (all six graph mutations, `GRAPH_MUTATIONS_PER_DAY`, default 500), `check_handle_daily` (CheckHandleAvailability) and `account_ops_daily` (DeleteAccount, RequestAccountExport, GetAccountExport). `ResolveClientIP(h, hops)` auto-detects a Firebase Hosting egress IP at the rightmost X-Forwarded-For entry (isGoogleEgressIP / googleEgressCIDRs, excludes GCP customer-assignable ranges) and steps one entry left when found; `hops` > 1 is an explicit operator override (config.Config.TrustedProxyHops / env TRUSTED_PROXY_HOPS) that skips detection. Sets xff_hops/via_hosting on logger.RequestInfo for mw.Logging's per-request line — never logs an IP directly. ADR-0010 D5 / T3 (as amended A1-A10): the same `DailyCap` also counts units: `Reserve(key)` / `Release(key, n)` / `Charge(key, n)` / `Spent` / `Inflight` (`Allow` = Reserve + Charge(1)), `WithMaxCallReads(M)` arms the A1 in-flight hold (admit only while `count + (inflight+1)*M <= cap`; M = `config.ReadBudgetMaxCallReads` 269 for the uid key, `config.IPReadBudgetMaxCallReads` 2 for the IP key), `WithClock` for fake-clock tests. `Config.ReadBudget` (per uid, every procedure; `READ_BUDGET_PER_UID_PER_DAY`) and `Config.ReadBudgetIP` (`READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY`) are charged with `budget.FromContext(ctx).Reads()` after the call. IP key = `ratelimit.IPBudgetKey(ip) (key, ok)` (canonical IPv4 or IPv6 /64, never raw input), used by `PreAuthIPMiddleware`, `Config.IP` and `ReadBudgetIP`; since A8 it never rejects: `Config.ReadBudgetIPEnforce` is empty (the guard test asserts it, and Enforce ∪ ChargeOnly == the profile-exempt set with no overlap) and `Config.ReadBudgetIPChargeOnly` is CheckHandleAvailability and CreateProfile. A marked profile-less uid's non-exempt calls get a charge-only IP key with `viaMark` (A3: `logger.RequestInfo.ProfileRequired`, set by `authn.AccountStatusInterceptor`, plus a per-instance `cache.LRU` mark, TTL `ProfileLessMarkTTL`); A9: when such a call finds a profile (`logger.RequestInfo.ProfileFound`, set by the same interceptor on `exists`) the IP key is charged 0 and not logged and the mark is deleted. `apiserver.RateLimitConfig` is the exported builder tests use to run the shipped config. `Config.ReadBudgetChargeOnly` (DeleteAccount, RequestAccountExport, GetAccountExport; A6) is charged, never rejected, bounded by the `account_ops_daily` DailyCap (`ACCOUNT_OPS_CALLS_PER_DAY`, default 20). Rejections: `limit_name`/`metadata.limit` `read_budget_daily` (retry to `quota.UntilNextDay`) or `read_budget_inflight` (retry 1 s); `Config.ReadBudgetCovers(proc)` is what the guard test asserts for every NO_SIDE_EFFECTS procedure. Log fields: `read_budget_spent` (uid), `read_budget_ip_spent`, `read_budget_key`, `read_budget_inflight`, `profile_required`, WARN `read_budget_over_max`. `CHECK_HANDLE_CALLS_PER_DAY` (default 100) is the `check_handle_daily` DailyCap. `ResolveClientIP` falls back to the rightmost entry when the chosen one is not an IP (A5) |
| authn.VerifiedIdentityInterceptor(emailGated, allowAnonymous) / Claims.IdentityGate(allowAnonymous) / authn.GatePass, GateEmailUnverified, GateProviderNotAllow / authn.SignInProvider* | backend/pkg/platform/authn | ADR-0010 D5 A2/A10 gate, right after `IDTokenInterceptor`: a sign-in-provider allowlist that fails closed (`google.com`, `apple.com`, `password` with `email_verified`, `anonymous` only when `config.AuthEmulator`). Anything else gets FAILED_PRECONDITION `EMAIL_NOT_VERIFIED` (profile-exempt procedures) or `PROFILE_REQUIRED` (all others) from the token claims alone, 0 reads, before the rate limiter; logs `gate=email_unverified` or `gate=provider_not_allowed` + `gate_provider` (32 bytes). `identity.requireVerifiedIdentity` (`identity.WithAllowAnonymous`) uses the same `IdentityGate` as defence in depth. `config.Load` refuses `FIREBASE_AUTH_EMULATOR_HOST` when ENV is dev or prod |
| config.Config.FeaturePosts (`FEATURE_POSTS`, `_ALLOWLIST`, `_PERCENT`) / RateLimitConfig.UserTimelinePerMinute, PostCreatePerMinute, PostDeletePerMinute | backend/pkg/platform/config | ADR-0010 D1/T4: the posts+timeline flag (wire name `posts`, registered next to `graph` in `flags.NewRegistry`, so `GetMe.enabled_features` lists it at 0 reads) and the per-procedure buckets wired in `apiserver.RateLimitConfig`: GetHomeTimeline `RATE_LIMIT_TIMELINE_PER_MIN` 6, GetUserTimeline `RATE_LIMIT_USER_TIMELINE_PER_MIN` 30, CreatePost `RATE_LIMIT_POST_CREATE_PER_MIN` 10, DeletePost `RATE_LIMIT_POST_DELETE_PER_MIN` 20, GetPost the default 60. All must be > 0. No extra daily call cap: writes are bounded by `quota.Posts`, reads by the D5 read budget |
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
| cache.LRU\[K, V\] / cache.New | backend/pkg/platform/cache | Generic in-process LRU-with-TTL. Every module's instance cache (e.g. `identity.Cache`) wraps this instead of writing a new cache. `GetOrSet(key, mk)` is the atomic get-or-create (one winner under concurrent first access; used by `ratelimit.DailyCap.lock` and `Limiter.Allow`), never a Get-miss-then-Set. |

## Scripts

| Item | Location | Use it for |
|---|---|---|
| scripts/dev.sh | scripts/dev.sh | The actual backend+Flutter-web startup logic for `make dev`. Not inlined in the Makefile's `emulators:exec` call (N8): that string runs through the OS default shell (cmd.exe on Windows), which can't parse bash's `trap`/`&`/subshells — `make dev` invokes `bash scripts/dev.sh` instead, a single cmd.exe-safe command line, and the script itself always runs under a real bash. Reads BACKEND_DIR/APP_DIR/PORT from the environment (exported by the Makefile), not Make substitution. |

## Composition root

| Item | Location | Use it for |
|---|---|---|
| apiserver.Build | backend/internal/apiserver | The one `*http.ServeMux` wiring every module's Connect handler + `/health`(z) + `/internal/*` with the full interceptor chain (ADR-0006 §2), wrapped outermost by CORS -> ratelimit.PreAuthIPMiddleware -> http.MaxBytesHandler (M1/hardening, see its doc comment for the full per-request pipeline). `cmd/api/main.go` and `backend/e2e` both call this — a `package main` can't be imported, so the wiring can't live in cmd/api itself. |
| apiserver.RateLimitConfig / profileExemptProcedures | backend/internal/apiserver/ratelimit_config.go | The one place `ratelimit.Config` is assembled (per-minute buckets, daily caps, read budget, IP sets); `profileExemptProcedures()` is the one profile-exempt set shared by `Build` (gate + account status) and the guard test; `Build` calls it and `guard_test.go` (T3.5) inspects it, failing CI if any linked NO_SIDE_EFFECTS procedure is not covered by the read budget |
| identity.Cache GetHandleFree / SetHandleFree / InvalidateHandleFree | backend/internal/identity/cache.go | 10 s negative handle cache (`notFoundTTL`, ADR-0010 D5): a handle that `ResolveHandle` reported NotFound; used by CheckHandleAvailability and GetProfile-by-handle (and T7 `ResolveHandles`). Cleared by `SetProfile`; only a hint, CreateProfile/ChangeHandle stay transactional |
| quota.UntilNextDay | backend/pkg/platform/quota | Duration until the next IST midnight (retry_after of daily-counter rejections) |

## Test helpers (import only from `_test.go` files, like `net/http/httptest`)

| Item | Location | Use it for |
|---|---|---|
| budgettest.Assert / budgettest.Budget | backend/pkg/platform/budget/budgettest | Asserting a `*budget.Counter` from an integration test call stays within an RPC's documented worst-case reads/writes/deletes (testing-strategy skill). Don't hand-roll another `if counter.Reads() > N` block — extend Budget if a new field is ever needed. |
| assertGraphInvariants / graphInvariantViolations / loadGraphState | backend/internal/graph/invariants_integration_test.go | The ADR-0008 D3 graph invariant checker (I1 follows edge <=> following[], I2 counters = edge counts, I3 blocked <=> blockedBy except overflow, I4 no edge across a block, plus S1/S2 structural checks). `newWired` runs it as a t.Cleanup after EVERY graph scenario; call `assertGraphInvariants(t, w.client)` directly mid-test (races) or from T16b / the T25 runbook drill. Ignores `pad-` uids from `padUIDs`. Opt out only with `w.SkipInvariantSweep(reason)`. `graphInvariantViolations` is pure, with negative self-tests. |
| newRig / newRigWithMutationCap / rig.errorLines | backend/internal/graph/wire_t16b_integration_test.go | Real Connect handlers over the wired services (httptest): wire-byte assertions, per-call budget counter (`lastOps`), optional list/mutation daily caps, and a capture of what `mw.ErrorMapping` logs at ERROR (`errorLines`). |
| newWired / wiredOption (withFlags, withNewAccountWindow, withQuotas) | backend/internal/graph/fixtures_integration_test.go | Fully wired identity+graph on a fresh emulator project (apiserver.Build wiring minus HTTP) with the invariant sweep registered. Options change flags/quota tiers; `withNewAccountWindow(1)` makes every profile an established account without a clock seam. |
| mustCreateProfile / mustCreateUsers / seedFollow / seedBlock / seedEdge / seedGraphArrays / seedQuota / seedUserField / padUIDs / istDay | backend/internal/graph/fixtures_integration_test.go | THE graph seeding helpers (no second seeding helper for T16b). `seedFollow` and `seedBlock` write invariant-consistent state; `seedEdge` (edge doc only) and `seedGraphArrays` (raw arrays) are raw and need `SkipInvariantSweep` if they break an invariant. `seedQuota` with `istDay(-1)` models the IST-midnight rollover; `padUIDs(n)` reaches a cap (5,000 following / 2,000 blocked / 10,000 blockedBy) without real users. |
| measured / requireAPIError / warmProfiles / quotaUsed / runConcurrently | backend/internal/graph/fixtures_integration_test.go | `measured(t, rpc, budgettest.Budget, fn)` runs one call under a fresh counter, logs `BUDGET <rpc> reads=.. writes=.. deletes=..` (feeds the T21 cost report) and asserts via `budgettest.Assert`; `requireAPIError` asserts Connect code + ErrorReason + metadata; `warmProfiles` measures the warm "typical" budget; `runConcurrently` releases N goroutines together for race tests. |

## Module interfaces (`backend/internal/*/api.go`)

| Item | Location | Use it for |
|---|---|---|
| identity.Service | backend/internal/identity/api.go | CreateProfile, CheckHandleAvailability, GetMe, GetProfile, UpdateProfile, ChangeHandle, AccountStatus. The only thing identity's Connect handler (server.go) depends on. |
| identity.ValidUserID | backend/internal/identity/validate.go | Delegates to ids.ValidUID (below) for caller-supplied user ids; graph reuses it. Handles get the same reserved-shape check in `handleFormatIssue` / GetProfile |
| ids.ValidUID / ids.UIDMessage | backend/pkg/platform/ids | The one uid predicate `^[A-Za-z0-9-]{1,128}$` (no `_`: composite-key separator, ADR-0008 A3; also rules out `__x__`) plus the shared user_id validation message. Used by authn.IDTokenInterceptor (caller uid, WARN `uid_format_rejected`), identity.ValidUserID and graph validation. Edge doc ids are built only by `edgeID` in internal/graph/repo_firestore.go |
| identity.Directory / LookupProfiles | backend/internal/identity/api.go | Cross-module batch profile hydration (GetProfiles, Forget). LookupProfiles also returns the uids whose users doc was confirmed absent (excludes SUSPENDED/DELETING); graph list RPCs use it for the T27 lazy clean-up |
| identity.Counters | backend/internal/identity/api.go | Cross-module counter increments on `users/{uid}` (posts/followers/following counts) via `store.Batch` — implemented by identity.FirestoreRepo, used by graph (Follow/Block/Unfollow; `AddCounts` merges both counters on one doc into one write) |
| identity.GraphInitializer | backend/internal/identity/api.go | The one seam identity depends on to create `graph/{uid}` inside CreateProfile's transaction; implemented by graph.FirestoreRepo (backend/internal/graph) until the full GraphService exists |

## Not implemented yet (Phase 0 bootstrap)

`graph` (full GraphService), `posts`, `timeline`, `engagement`, `media`, `notifications`, `search`,
`moderation`, `admin` — no Connect servers registered in `cmd/api/main.go`. `identity.DeleteAccount`,
`RequestAccountExport`, `GetAccountExport` are stubbed `Unimplemented` (need those modules' delete/export
fan-out, ADR-0003). Check here before adding a "temporary" cache, rate limiter, error mapper, or
pagination helper anywhere else — one already exists above.
