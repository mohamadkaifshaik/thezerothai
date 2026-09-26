---
name: go-service
description: How to structure the Go modular monolith on Cloud Run (Connect-RPC, Firestore repos, auth, caching, Pub/Sub push handlers, config, health, graceful shutdown, Dockerless ko build). Use when creating or restructuring any backend module.
---

# Go modular monolith blueprint

```
backend/
  cmd/api/main.go                 # wiring only: config → clients → modules → mux
  internal/<module>/              # identity, graph, posts, timeline, engagement, media, notifications, search, moderation, admin
    api.go                        # exported Service interface other modules depend on
    server.go                     # Connect handlers (thin: validate → service → map errors)
    service.go                    # business logic, depends on interfaces only
    repo_firestore.go             # Firestore implementation of Repo
    cache.go                      # instance LRU wrapper (optional)
    events.go                     # Pub/Sub publish + /internal push handlers
    *_test.go
  pkg/platform/ (config, logger, authn(firebase), cache, cursor, snowflake, idempotency, ratelimit, pubsubpush, health, errors)
```

## Module rules
- Modules import each other's `api.go` interfaces only — never another module's repo or collections.
- One Firestore client, one Pub/Sub client, one Storage client for the whole process (shared, created at startup).
- Anything slow or fan-out-y (notifications, deletes, moderation, profile-snapshot refresh) goes to Pub/Sub → push back to `/internal/<topic>`.
  Handlers are idempotent (Pub/Sub is at-least-once) and verify the OIDC token audience + push service account.

## main.go skeleton
```go
func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()
    cfg := config.MustLoad[Config]()               // env vars; PORT from Cloud Run
    log := logger.New(cfg)                         // slog JSON with Cloud Logging severity + trace field
    fs := must(firestore.NewClient(ctx, cfg.ProjectID)) // honors FIRESTORE_EMULATOR_HOST
    auth := must(authn.NewFirebaseVerifier(ctx, cfg))   // caches Google public keys; no per-request cost
    c := cache.New(cfg.Cache)
    pub := events.NewPublisher(must(pubsub.NewClient(ctx, cfg.ProjectID))) // honors PUBSUB_EMULATOR_HOST

    graph := graph.New(graph.NewFirestoreRepo(fs), c)
    posts := posts.New(posts.NewFirestoreRepo(fs), graph, c, pub)
    // ... other modules

    mux := http.NewServeMux()
    interceptors := connect.WithInterceptors(authn.Interceptor(auth), ratelimit.Interceptor(cfg), degraded.Interceptor(cfg))
    mux.Handle(postsv1connect.NewPostServiceHandler(posts.Server(), interceptors))
    mux.Handle("/internal/", pubsubpush.Handler(cfg, routes)) // OIDC-verified
    mux.HandleFunc("/healthz", health.OK)

    srv := &http.Server{Addr: ":" + cfg.Port, Handler: h2c.NewHandler(mux, &http2.Server{}), ReadHeaderTimeout: 5 * time.Second}
    go func() { _ = srv.ListenAndServe() }()
    <-ctx.Done()
    shCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second); defer cancel() // Cloud Run gives 10 s
    _ = srv.Shutdown(shCtx); fs.Close()
}
```

## Cold-start discipline (we scale to zero)
- No heavy init: no warming caches, no reading many docs at startup, secrets read once (≤ 1 access per instance start).
- Keep the binary small; avoid giant dependency trees. Target container start < 500 ms.
- Enable Cloud Run **startup CPU boost** (free for request-based billing within quota).

## Required
- `/healthz` (no deps). Cloud Run's startup probe hits it.
- Build with `ko` → distroless static, non-root, `GOMAXPROCS` via `automaxprocs`, `GOMEMLIMIT` = 90% of 512 MiB.
- Log fields: `severity, message, logging.googleapis.com/trace, rpc, uid_hash, fs_reads, fs_writes, latency_ms`.
- Dedicated runtime service account with only: Firestore user, Storage object admin on the media bucket, Pub/Sub publisher, token creator for signing URLs on itself.
- Every Connect handler: deadline (≤ 10 s), input validation, error mapping to Connect codes, idempotency for mutations.
- Unit tests with fake repos; integration tests against the Firestore emulator (`//go:build integration`).
- `golangci-lint` config in `backend/.golangci.yml`.
