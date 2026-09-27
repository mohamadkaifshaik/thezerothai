# 0002. Go modular monolith with Connect-RPC and buf-managed contracts
Status: Accepted
Date: 2026-09-26
Deciders: architect, founder

## Context
Stage 0 (0 – ~300 DAU, $0/month). ADR-0001 fixed the platform: one Cloud Run service `api` (min 0 / max 3,
512 MiB, concurrency 80) in `asia-south1`, Firestore, GCS, Firebase. We need to decide how the backend code and the
client contracts are shaped so that:
- one container scales to zero and cold-starts fast (target < 1.5 s including the request),
- Flutter on iOS/Android/Web gets typed clients without hand-written models,
- any module (e.g. `timeline`) can later become its own Cloud Run service or move to another store (Stage 2/3)
  without touching its callers or breaking wire compatibility.

Non-functional requirements for Stage 0: p95 timeline read < 400 ms warm, post create < 500 ms, cold start < 1.5 s,
no fixed-cost services, `buf breaking` as a CI gate (rule 9).

## Options
### A. One Go modular monolith, Connect-RPC (HTTP/1.1 + HTTP/2, JSON + binary proto), buf (chosen)
- Pros: one image, one cold start, one set of shared clients (Firestore, Pub/Sub, Storage) per instance;
  Connect speaks plain HTTP POST/GET so it works through Firebase Hosting rewrites and browsers without a proxy
  (gRPC-Web/Envoy not needed); JSON mode is curl-debuggable; `connectrpc/dart` generates Flutter clients;
  `buf lint` + `buf breaking` enforce contract discipline; module seams are Go interfaces.
- Cons: all modules share the 3-instance cap and one deploy; a bad module can crash the process; discipline
  (import boundaries) is by convention + lint, not by network.
- Cost: idle $0; at 300 DAU ≈ 11k requests/day, inside the 2M/month Cloud Run free tier; at 10× (3k DAU) ≈ 3.3M
  requests/month ≈ $0.54 of request fees + ≈ $3.70 vCPU-s overage (see cost model).

### B. One Cloud Run service per module (microservices), gRPC
- Pros: independent scaling/deploys.
- Cons: 10 services → 10 cold starts on a cold path, service-to-service auth, a gRPC-Web proxy for Flutter Web
  (Envoy/LB = fixed cost), cross-service calls multiply requests against the 2M free requests. Nothing at Stage 0
  needs independent scaling.
- Cost: idle $0 but request count per user action roughly 2–4× A; operationally far more expensive.

### C. REST + OpenAPI (chi/echo + oapi-codegen, Dart openapi-generator)
- Pros: familiar, human-readable.
- Cons: weaker schema-evolution tooling than `buf breaking`; the Dart generators are uneven; no binary encoding
  for mobile (bigger payloads = more egress, which is billed outside North America).
- Cost: same as A, slightly more egress.

## Cost impact
- Fixed monthly cost added: **$0**.
- Free-tier quota consumed: Cloud Run requests ≈ 37/DAU/day (≈ 330k/month at 300 DAU = 17% of 2M);
  compute ≈ 0.1 vCPU-s/request (≈ 33k of 180k vCPU-s at 300 DAU). vCPU-s is the first Cloud Run limit (~1,600 DAU). BSR remote plugins for `buf generate`: free.
- Trigger to revisit: a module needs its own scaling/SLO (e.g. timeline > 50% of CPU) or a free-tier-budget §6
  trigger fires → split that module into its own Cloud Run service behind the same proto service.

## Decision
Build one Go 1.23+ monolith (`backend/cmd/api`) with modules under `backend/internal/<module>`, each exposing an
exported Go interface in `api.go` that other modules depend on (never another module's repo or collections).
Public APIs are Connect-RPC services defined in `proto/dzeroth/<module>/v1/*.proto`, linted with buf STANDARD and
gated by buf FILE-level breaking checks. Generated Go goes to `backend/gen` (module path
`github.com/dzeroth/dzeroth/backend`), Dart to `app/lib/gen`, using BSR remote plugins. Read RPCs are marked
`idempotency_level = NO_SIDE_EFFECTS` so Connect clients may use HTTP GET. Errors are Connect codes plus a
`dzeroth.common.v1.ErrorDetail` with a machine-readable `ErrorReason`.

Cross-module atomic writes (e.g. `posts` creating a post and incrementing `users.postsCount` owned by `identity`)
use a **unit-of-work seam**: `pkg/platform/store.Batch` is passed through interface methods such as
`identity.Counters.AddPostsCount(b store.Batch, uid string, delta int64)`; the owning module appends its writes
to the batch, the caller commits once. The Firestore implementation wraps an atomic `WriteBatch` (or a `Transaction` when reads are needed; never `BulkWriter`, which is not atomic);
a future SQL implementation wraps a transaction. No module ever builds a document path it does not own.

## Consequences
- Positive: single cold start; one binary to test against emulators; typed clients on all platforms; contracts
  can outlive the storage engine (the Stage 2 timeline in Memorystore keeps the same RPCs and token format).
- Negative: blast radius is the whole API; mitigated by per-RPC deadlines (≤ 10 s), panic-recovery interceptor,
  and the tagged zero-traffic revision gate (ADR-0007).
- Follow-up: pin remote plugin versions in `proto/buf.gen.yaml` after the first successful generate; add an
  import-boundary lint (`depguard` rules: `internal/<a>` may not import `internal/<b>` except `internal/<b>` root
  interface package).
- Contract rules (binding): never renumber/reuse fields (use `reserved`); new behaviour = new optional fields or new
  RPCs; a breaking change means a new `v2` package served side by side.
- Revisit when: a module's load or failure rate justifies splitting (measured), or Connect stops meeting a client need.

## Handoff
- backend-developer: `buf generate` from `proto/` (`make proto`); implement the handler interfaces from
  `*v1connect`; interceptor order: recover → trace/log → App Check → Firebase auth → degraded mode → rate limit →
  validation. Map domain errors to Connect codes + `ErrorDetail`. Implement `store.Batch` in `pkg/platform/store`.
- frontend-developer: consume `app/lib/gen` via `connectrpc` Dart transport; binary proto on mobile, JSON allowed
  on web for debugging; branch on `ErrorDetail.reason`; never auto-retry `ERROR_REASON_DEGRADED_MODE`.
- production-deployer: CI runs, from the repo root, `buf lint proto` and `buf breaking proto --against '.git#branch=main,subdir=proto'`.
- tester: contract tests per RPC (happy path + each documented error reason) against emulators.
