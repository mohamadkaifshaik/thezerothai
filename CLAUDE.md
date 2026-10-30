# CLAUDE.md — Project Constitution

Text-first social platform (X/Twitter-style) with image uploads, built by an early-stage startup.
Every agent and every human reads this file first. Decisions here are binding
until superseded by an ADR in `docs/adr/`.

## Prime directive: free tier first, per-use cost only, until users pay for it

We run on the **GCP Always Free tier + Firebase no-cost quotas** from local dev through the
first real production users. Nothing with a fixed monthly fee ships without an Accepted ADR
that names the cost and the user/revenue milestone that justifies it.

- Every resource **scales to zero** when idle. No always-on VMs, clusters, load balancers, or DB instances.
- Every design states its **free-tier budget** (Firestore reads/writes per day, Cloud Run requests, GB stored/served). See the `free-tier-budget` skill.
- Past the free tier we pay **per use** (cents per 100k ops), never a step to a fixed fee by accident.
- The `cost-guard` hook blocks known fixed-cost Terraform resources (including `min_instance_count` above 0) unless marked `# cost-approved: ADR-NNNN`.
- **Honest target:** Stage 0 is designed around the free tier but is not exactly $0 at real traffic. `docs/reviews/cost-model.md` and ADR-0022 put Stage 0 as configured at about INR 434 / 1,626 / 3,396 per month at 300 / 1,000 / 3,000 DAU (egress to India is never free, Cloud Vision SafeSearch is paid past 1,000 units at 2 units per image, Firestore reads pass the free quota at about 215 DAU). What this directive forbids is a **fixed** monthly fee and a bill that does not scale with use.
- **Time-boxed exception:** credit mode (ADR-0022) is the only one; see "Credit mode" below. After 2026-12-24 this prime directive applies unchanged.

## Credit mode (ADR-0022, expires 2026-12-24)

A GCP credit that expires **2026-12-26** pays for a temporary profile. Dates: **2026-12-22** heavy items off, **2026-12-24** services paused (runbook `docs/runbooks/credit-sunset-pause-resume.md`), **2026-12-26** credit gone. Steps and owners live in `docs/runbooks/credit-sunset-pause-resume.md`, section "Dated steps and owners".

- **Allowed until then:** prod service-level min instances 1; `VISION_MONTHLY_CAP` 20k–40k with `reject` at the cap; per-use overage.
- **Capped:** gross spend at `credit_spend_cap_inr` (INR 25,000 or lower), watched by a gross-spend budget.
- **Unchanged:** abuse limits, the "not used" list below, and no committed use discounts, subscriptions or prepaid plans. Nothing that bills after 2026-12-26.
- **Guard:** `cost-guard` accepts `# cost-approved: ADR-NNNN until:YYYY-MM-DD` and stops accepting it after that date (UTC). Use it for min-instance lines.
- **Removal:** after 2026-12-24 delete this section and every "credit mode" mention in this file.

## Stack (fixed)

- **Backend:** Go 1.26 (`backend/go.mod`; CI uses the latest 1.26.x), **one modular monolith** (`backend/cmd/api`) with Connect-RPC (HTTP/JSON + binary proto) managed with `buf`.
- **Clients:** Flutter 3.47.x (pinned in `.github/workflows/ci.yml`; iOS, Android, Web) — BLoc, go_router, freezed, connect-dart generated clients.
- **Cloud:** GCP + Firebase only. Terraform for infra. No click-ops.

## Growth stages (design for Stage 0, keep the door open to Stage 3)

| Stage                | Users          | Monthly cost target    | Architecture                                                                 |
| -------------------- | -------------- | ---------------------- | ---------------------------------------------------------------------------- |
| **0 — Launch** (now) | 0 – ~300 DAU   | **≈ $0–5** (free tier, then per use; ≈ INR 434 at 300 DAU) | Cloud Run + Firestore + GCS + Firebase                                       |
| **0C — Credit mode** (until 2026-12-24, ADR-0022) | 0 – ~3k DAU | ≤ INR 25,000 total from GCP credit | Stage 0 plus the profile in "Credit mode" below |
| 1 — Traction         | ~300 – 20k DAU | ~$1 – $50, pay-per-use | Same, pay Firestore/Cloud Run overage; add min-instance=1 if latency matters |
| 2 — Growth           | 20k – 200k DAU | Funded by revenue      | ADR: Cloud SQL Postgres or keep Firestore; Memorystore; split hot services   |
| 3 — Scale            | 200k+ DAU      | Funded                 | ADR: Spanner, GKE, multi-region, CDN + Cloud Armor                           |

Moving up a stage requires an ADR with measured numbers (see scale-up triggers in `free-tier-budget` and, per hot concern, the `stage-ladder` skill: Stage 0 choice, seam to protect, Stage 2/3 target, trigger).

Stage 0 targets: p95 timeline read < 400 ms warm (cold start < 1.5 s), post create < 500 ms. Availability is whatever
Cloud Run + Firestore give us (both regional, multi-zone managed) — no self-built HA.

## Reference architecture (Stage 0)

| Concern                     | Choice                                                                                                                                                     | Free allowance (verify in `free-tier-budget`)       |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| API compute                 | **Cloud Run** service `api`, request-based billing, min 0 / max 3 instances (prod min 1 only in credit mode), 512 MiB, concurrency 80                                                       | 2M req, 180k vCPU-s, 360k GiB-s /month              |
| Async work                  | Pub/Sub **push** to `api` `/internal/*` (OIDC-authenticated)                                                                                               | 10 GiB messages /month                              |
| Cron                        | Cloud Scheduler → `api` `/internal/cron/*`                                                                                                                 | 3 jobs /billing account                             |
| Database                    | **Firestore Native, `(default)` database**                                                                                                                 | 1 GiB, 50k reads, 20k writes, 20k deletes /day      |
| Cache                       | In-process LRU in each Cloud Run instance + client-side cache (drift/IndexedDB). **No Redis.**                                                             | —                                                   |
| Media                       | GCS bucket in a **US region**, V4 signed PUT URLs, client-side resize/compress, public-read objects                                                        | 5 GB, 5k Class A, 50k Class B, 100 GB egress /month |
| Moderation                  | Cloud Vision SafeSearch on **every** image, paid past the free quota; capped by `VISION_MONTHLY_CAP` (default 10k; higher with `reject` in credit mode), then report-driven review (ADR-0005)                                                                               | 1,000 units /month                                  |
| Search                      | Firestore prefix queries (handles), `array-contains` (hashtags). No search engine.                                                                         | —                                                   |
| Auth                        | Firebase Auth (email, Google, Apple). ID tokens verified in Go. **No phone/SMS OTP** (billed per SMS).                                                     | no-cost tier                                        |
| Abuse                       | Firebase App Check + per-user quotas in Firestore + in-memory rate limits + Cloud Run max-instances cap                                                    | —                                                   |
| Push                        | Firebase Cloud Messaging                                                                                                                                   | free                                                |
| Web hosting + custom domain | **Firebase Hosting** (CDN + TLS); `/api/**` rewrites to Cloud Run                                                                                          | 10 GB stored, 360 MB/day                            |
| Crash reporting             | Firebase Crashlytics                                                                                                                                       | free                                                |
| Secrets                     | Secret Manager (keep ≤ 6 active versions) — most config is plain env vars                                                                                  | 6 versions, 10k accesses                            |
| Observability               | slog JSON → Cloud Logging; built-in Cloud Run metrics; Error Reporting; 1 uptime check                                                                     | 50 GiB logs /project                                |
| CI/CD                       | GitHub Actions + Workload Identity Federation → `ko` image → Artifact Registry (cleanup policy) → `gcloud run deploy` with tagged revision + traffic split | AR 0.5 GB                                           |
| Cost control                | Billing budget alerts (net per project, plus a gross budget in credit mode), max-instances caps, degraded-mode switch                                                                               | free                                                |

**Region:** Cloud Run, Firestore and Artifact Registry in `asia-south1` (Mumbai) for Indian users — Cloud Run's free
tier applies in any region and Firestore's free quota applies to the `(default)` database wherever it lives.
Media bucket in `us-central1` because GCS free storage is **US regions only**. Firestore location is permanent: confirm before `terraform apply`.

**Explicitly not used at Stage 0** (fixed monthly cost): GKE, Spanner, Memorystore, Cloud SQL, external/global HTTPS LB,
Cloud Armor, Cloud CDN (LB-backed), Cloud NAT, Serverless VPC connector, Transcoder, Vertex AI Search, CMEK/Cloud KMS keys,
Binary Authorization, Cloud Deploy, BigQuery streaming, Managed Prometheus, a staging Firestore at scale.
Credit mode does not lift this list.

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
scripts/               # dev.sh, cost-vision.sh, mint-app-token.sh; promotion/ = deploy validators (flag registry, ceilings, until-dates)
testdata/              # fixtures shared by Go and Dart tests (e.g. the post text grammar)
docs/adr/              # Architecture Decision Records (architect owns)
docs/plans/            # Feature plans (planner owns); roadmap.md is the product roadmap
docs/reviews/          # Review, cost and production-readiness reports
docs/runbooks/         # One per failure mode, plus release, rollback and CI enforcement
docs/releases/         # Per-tag release notes and readiness records
docs/code-map.md       # Catalog of shared backend code: search it before writing a helper
docs/ui-catalog.md     # Catalog of shared Flutter UI; docs/x_research/ holds the X reference captures
.claude/               # agents, skills, commands, hooks and settings for the team
.github/workflows/     # ci, deploy-dev, release-prod, promote-prod, terraform
.github/CODEOWNERS    # gate files that need the founder's review
```

ADR numbers 0012–0015 are intentionally unused (reserved for slices that ran in parallel and needed no ADR); the next free number is the highest existing plus one.

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

## Working conventions

- **Status lives in two places.** `docs/plans/roadmap.md` is the product roadmap (open items outside the wave plans are in its section 9) and `docs/plans/phase1.md` the Phase 1 slice overview; each slice has its own plan with per-ticket `Status`. Read the relevant ones before starting work and update ticket status in the PR that merges it.
- **Branches and PRs:** `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `chore/<slug>`; one ticket per PR; merge `origin/main` into the branch rather than rewriting history. Never open a PR or push to `main` unless the human asked. See the `pr-workflow` skill.
- **Working in parallel:** agents work in git worktrees under `.claude/worktrees/` (never in Temp). The assistant is meant to open PRs through its own GitHub App identity, not the founder's, so the code-owner review is always a second identity (`docs/runbooks/ci-enforcement.md`). Do not use bare `git stash` in a shared checkout.
- **Rollout:** every user-facing feature ships behind a server flag (`FEATURE_<NAME>`: off → allowlist → percent → on). See the `flag-rollout` skill.
- **Stop and ask the founder** before: adding any fixed-cost resource, bending a non-negotiable rule, changing a proto contract in a breaking way, accepting an ADR, changing `credit_spend_cap_inr` or the ADR-0022 dates, keeping any credit-mode item on after 2026-12-22, any `prod` apply or traffic shift (ADR-0019), creating or moving a `v*` release tag, or loosening a CI or ruleset gate.
- **Hooks need `jq`.** The guard hooks fail closed (block the edit) when `jq` is missing.

## Release and approval gates (ADR-0019)

- `main` is protected by a ruleset: required CI checks and code-owner review, no bypass actors (`docs/runbooks/ci-enforcement.md`). Gate files (workflows, `.github/CODEOWNERS`, `scripts/promotion/flag-ceiling.json`, `firebase/firestore.indexes.json`, `firebase/field-overrides.ack`, `scripts/mint-app-token.sh`) need the founder's review.
- Merging to `main` deploys **dev** (`deploy-dev.yml`); the promotion validators in `scripts/promotion` must pass (flag registry, flag ceilings, until-dates, fieldOverrides acknowledgement).
- **Prod** only moves by a `v*` tag (ruleset: only the founder creates, moves or deletes them) and the `prod` environment's required-reviewer approval. Flow: tag, `release-prod.yml` stages a 0%-traffic `candidate`, `production-reviewer` issues GO or NO-GO, then `promote-prod.yml` (manual dispatch) shifts traffic 10% then 100%. See `docs/runbooks/rollback.md` and the `release-rollout` skill.
- Terraform `apply` in prod is plan-then-OK. Agents never apply to prod, create release tags or dispatch `promote-prod` on their own.

## Commands

```
make proto        # buf lint + breaking + generate (Go + Dart)
make ci           # lint, vet, unit tests, buf breaking, flutter analyze/test
make emulators    # firebase emulators:start --only firestore,auth,pubsub,storage
make test-int     # integration tests against emulators
make dev          # emulators + API + Flutter web
make cost         # print read/write budget table from docs + last 24h usage (gcloud) and Vision units
make loadtest SCENARIO=timeline_read   # against emulators by default
```

## Definition of Done

- Acceptance criteria in the plan are met and tested.
- Go coverage ≥ 70% on `internal/`; Flutter widget tests for every new screen.
- No new lint warnings; `buf breaking` clean.
- Worst-case Firestore reads/writes per RPC documented; free-tier budget table in `free-tier-budget` still holds at Stage 0 targets.
- Logs + an Error Reporting-visible error path exist for any new request path.
- Runbook entry updated for any new failure mode.
- `make ci` and `make test-int` pass, including the promotion-script checks when flags, Terraform or workflows change; a new flag is registered with its ceiling.
- Shared helpers added to `docs/code-map.md` or `docs/ui-catalog.md`.
- Skills in `.claude/skills/` are the source of procedures (flags, PR workflow, reuse-first, release); read the relevant one instead of guessing.
