# CLAUDE.md — Project Constitution

Text-first social platform (X/Twitter-style) with image uploads, built by an early-stage startup.
Every agent and every human reads this file first. Decisions here are binding
until superseded by an ADR in `docs/adr/`.

## Prime directive: $0 until users pay for it

We run on the **GCP Always Free tier + Firebase no-cost quotas** from local dev through the
first real production users. Nothing with a fixed monthly fee ships without an Accepted ADR
that names the cost and the user/revenue milestone that justifies it.

- Every resource **scales to zero** when idle. No always-on VMs, clusters, load balancers, or DB instances.
- Every design states its **free-tier budget** (Firestore reads/writes per day, Cloud Run requests, GB stored/served). See the `free-tier-budget` skill.
- Past the free tier we pay **per use** (cents per 100k ops), never a step to a fixed fee by accident.
- The `cost-guard` hook blocks known fixed-cost Terraform resources unless marked `# cost-approved: ADR-NNNN`.

## Stack (fixed)

- **Backend:** Go 1.23+, **one modular monolith** (`backend/cmd/api`) with Connect-RPC (HTTP/JSON + binary proto) managed with `buf`.
- **Clients:** Flutter (iOS, Android, Web) — BLoc, go_router, freezed, connect-dart generated clients.
- **Cloud:** GCP + Firebase only. Terraform for infra. No click-ops.

## Growth stages (design for Stage 0, keep the door open to Stage 3)

| Stage                | Users          | Monthly cost target    | Architecture                                                                 |
| -------------------- | -------------- | ---------------------- | ---------------------------------------------------------------------------- |
| **0 — Launch** (now) | 0 – ~300 DAU   | **$0** (free tier)     | Cloud Run + Firestore + GCS + Firebase                                       |
| 1 — Traction         | ~300 – 20k DAU | ~$1 – $50, pay-per-use | Same, pay Firestore/Cloud Run overage; add min-instance=1 if latency matters |
| 2 — Growth           | 20k – 200k DAU | Funded by revenue      | ADR: Cloud SQL Postgres or keep Firestore; Memorystore; split hot services   |
| 3 — Scale            | 200k+ DAU      | Funded                 | ADR: Spanner, GKE, multi-region, CDN + Cloud Armor                           |

Moving up a stage requires an ADR with measured numbers (see scale-up triggers in `free-tier-budget`).

Stage 0 targets: p95 timeline read < 400 ms warm (cold start < 1.5 s), post create < 500 ms. Availability is whatever
Cloud Run + Firestore give us (both regional, multi-zone managed) — no self-built HA.

## Reference architecture (Stage 0)

| Concern                     | Choice                                                                                                                                                     | Free allowance (verify in `free-tier-budget`)       |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| API compute                 | **Cloud Run** service `api`, request-based billing, min 0 / max 3 instances, 512 MiB, concurrency 80                                                       | 2M req, 180k vCPU-s, 360k GiB-s /month              |
| Async work                  | Pub/Sub **push** to `api` `/internal/*` (OIDC-authenticated)                                                                                               | 10 GiB messages /month                              |
| Cron                        | Cloud Scheduler → `api` `/internal/cron/*`                                                                                                                 | 3 jobs /billing account                             |
| Database                    | **Firestore Native, `(default)` database**                                                                                                                 | 1 GiB, 50k reads, 20k writes, 20k deletes /day      |
| Cache                       | In-process LRU in each Cloud Run instance + client-side cache (drift/IndexedDB). **No Redis.**                                                             | —                                                   |
| Media                       | GCS bucket in a **US region**, V4 signed PUT URLs, client-side resize/compress, public-read objects                                                        | 5 GB, 5k Class A, 50k Class B, 100 GB egress /month |
| Moderation                  | Cloud Vision SafeSearch on **every** image, paid past the free quota; capped by `VISION_MONTHLY_CAP` (default 10k), then report-driven review (ADR-0005)                                                                               | 1,000 units /month                                  |
| Search                      | Firestore prefix queries (handles), `array-contains` (hashtags). No search engine.                                                                         | —                                                   |
| Auth                        | Firebase Auth (email, Google, Apple). ID tokens verified in Go. **No phone/SMS OTP** (billed per SMS).                                                     | no-cost tier                                        |
| Abuse                       | Firebase App Check + per-user quotas in Firestore + in-memory rate limits + Cloud Run max-instances cap                                                    | —                                                   |
| Push                        | Firebase Cloud Messaging                                                                                                                                   | free                                                |
| Web hosting + custom domain | **Firebase Hosting** (CDN + TLS); `/api/**` rewrites to Cloud Run                                                                                          | 10 GB stored, 360 MB/day                            |
| Crash reporting             | Firebase Crashlytics                                                                                                                                       | free                                                |
| Secrets                     | Secret Manager (keep ≤ 6 active versions) — most config is plain env vars                                                                                  | 6 versions, 10k accesses                            |
| Observability               | slog JSON → Cloud Logging; built-in Cloud Run metrics; Error Reporting; 1 uptime check                                                                     | 50 GiB logs /project                                |
| CI/CD                       | GitHub Actions + Workload Identity Federation → `ko` image → Artifact Registry (cleanup policy) → `gcloud run deploy` with tagged revision + traffic split | AR 0.5 GB                                           |
| Cost control                | Billing budget alerts (50/90/100%), max-instances caps, degraded-mode switch                                                                               | free                                                |

**Region:** Cloud Run, Firestore and Artifact Registry in `asia-south1` (Mumbai) for Indian users — Cloud Run's free
tier applies in any region and Firestore's free quota applies to the `(default)` database wherever it lives.
Media bucket in `us-central1` because GCS free storage is **US regions only**. Firestore location is permanent: confirm before `terraform apply`.

**Explicitly not used at Stage 0** (fixed monthly cost): GKE, Spanner, Memorystore, Cloud SQL, external/global HTTPS LB,
Cloud Armor, Cloud CDN (LB-backed), Cloud NAT, Serverless VPC connector, Transcoder, Vertex AI Search, CMEK/Cloud KMS keys,
Binary Authorization, Cloud Deploy, BigQuery streaming, Managed Prometheus, a staging Firestore at scale.

### Modules inside the monolith (`backend/internal/*`)

`identity` · `graph` (follows/blocks/mutes) · `posts` · `timeline` · `engagement` · `media` · `notifications` · `search` · `moderation` · `admin`.
Each module owns its Firestore collections and exposes a Go interface; modules call each other **only through those interfaces**
so any module can later be split into its own Cloud Run service or moved to another database without touching callers.

### Non-negotiable design rules

1. **IDs:** 64-bit Snowflake-style (time-ordered) for posts/media, encoded as strings in Firestore doc IDs. Never sequential counters in a single doc.
2. **Timeline:** pull-on-read with incremental refresh (`since` cursor) + instance cache + client cache. No write fan-out at Stage 0. See `timeline` skill.
3. **Counters:** `FieldValue.Increment` on the parent doc (≤ 1 sustained write/s per doc is fine at Stage 0). Switch to sharded counters only when a doc exceeds that — measured, via ADR.
4. **Idempotency:** every mutating RPC accepts an `idempotency_key` (stored as a TTL'd Firestore doc).
5. **Pagination:** opaque cursors only, never offset. **Every query has a `Limit`** (default 20, max 50).
6. **Read budget:** every RPC documents its worst-case Firestore reads/writes; no N+1 (denormalize author snapshot into posts; batch `GetAll`).
7. **Media never passes through the API** — clients upload straight to GCS via signed URLs.
8. **The API exposes** `/health` (not `/healthz`: `*.run.app` reserves paths ending in `z`; `/healthz` is kept only as an alias), structured JSON logs with trace IDs, and graceful shutdown (Cloud Run sends SIGTERM; 10 s budget).
9. **Backwards-compatible protos:** never reuse or renumber fields; `buf breaking` gates CI.
10. **Privacy:** right-to-delete path for every collection; PII limited to Firebase Auth + `users/{uid}/private`. Google-managed encryption at rest (default, free).
11. **Cost caps are code:** max-instances, per-user daily quotas and query limits live in Terraform/config and are reviewed like logic.

## Repo layout

```
proto/                 # Protobuf APIs (buf.yaml, buf.gen.yaml)
backend/               # Go module: cmd/api, internal/<module>, pkg/platform
app/                   # Flutter app: lib/features/<feature>/{data,domain,presentation}
firebase/              # firebase.json, firestore.rules (deny-all to clients), firestore.indexes.json, storage.rules
infra/terraform/       # envs/{dev,prod}, modules/*
loadtest/              # k6 scripts (run locally against emulators, tiny smoke in cloud)
docs/adr/              # Architecture Decision Records (architect owns)
docs/plans/            # Feature plans (planner owns)
docs/reviews/          # Review, cost and production-readiness reports
docs/runbooks/
.github/workflows/     # CI/CD
```

## Environments

- **local** — Firebase Emulator Suite (Firestore, Auth, Pub/Sub, Storage) + `go run` + `flutter run`. $0, used for all development and integration tests.
- **dev** — GCP project `dzeroth-dev` on the same billing account; Firestore free quota is per project, Cloud Run's is shared per billing account. Used for cloud smoke tests and internal testers.
- **prod** — GCP project `dzeroth-prod`. Pre-release checks run on a **tagged, zero-traffic revision** (`--no-traffic --tag candidate`), then traffic is shifted.
  No separate staging project at Stage 0.

## The team (subagents in `.claude/agents/`)

| Agent                 | Owns                                                                  | Model  |
| --------------------- | --------------------------------------------------------------------- | ------ |
| `architect`           | ADRs, system design, proto contracts, Firestore data model, cost math | opus   |
| `planner`             | Feature breakdown into tickets in `docs/plans/`                       | opus   |
| `backend-developer`   | Go monolith in `backend/`                                             | sonnet |
| `frontend-developer`  | Flutter app in `app/`                                                 | sonnet |
| `tester`              | Unit/integration (emulators)/e2e tests                                | sonnet |
| `code-reviewer`       | PR-level review against these rules, incl. read/write budget          | opus   |
| `security-auditor`    | Threat model, authz, abuse, secrets                                   | opus   |
| `sre-performance`     | Cost + performance: budgets, quotas, cold starts, dashboards          | sonnet |
| `production-deployer` | Terraform, CI/CD, Cloud Run rollouts                                  | sonnet |
| `production-reviewer` | Final go/no-go gate before prod                                       | opus   |

## Standard workflow (use the `ship-feature` skill)

1. **planner** → `docs/plans/<feature>.md` (tickets, acceptance criteria, owners, **cost line**)
2. **architect** → ADR + proto + Firestore model changes (if needed)
3. **backend-developer** ‖ **frontend-developer** implement against the proto
4. **tester** → tests on emulators; **code-reviewer** + **security-auditor** review
5. **sre-performance** → cost report (reads/writes per request × expected volume) + emulator load smoke
6. **production-deployer** → dev project + tagged zero-traffic prod revision
7. **production-reviewer** → go/no-go → deployer shifts traffic 10% → 100%

No agent marks work done while `make ci` fails.

## Commands

```
make proto        # buf lint + breaking + generate (Go + Dart)
make ci           # lint, vet, unit tests, buf breaking, flutter analyze/test
make emulators    # firebase emulators:start --only firestore,auth,pubsub,storage
make test-int     # integration tests against emulators
make dev          # emulators + API + Flutter web
make cost         # print read/write budget table from docs + last 24h usage (gcloud)
make loadtest SCENARIO=timeline_read   # against emulators by default
```

## Definition of Done

- Acceptance criteria in the plan are met and tested.
- Go coverage ≥ 70% on `internal/`; Flutter widget tests for every new screen.
- No new lint warnings; `buf breaking` clean.
- Worst-case Firestore reads/writes per RPC documented; free-tier budget table in `free-tier-budget` still holds at Stage 0 targets.
- Logs + an Error Reporting-visible error path exist for any new request path.
- Runbook entry updated for any new failure mode.
