# 0007. Environments, regions, CI/CD and cost guardrails
Status: Accepted — founder confirmed Firestore location `asia-south1` and prod weekly backups on 2026-09-27.
Date: 2026-09-26
Deciders: architect, founder

## Context
Stage 0, $0/month. Two GCP projects on one billing account (`dzeroth-dev`, `dzeroth-prod`); local development on the
Firebase Emulator Suite. Firestore free quota is per project (`(default)` DB); Cloud Run, Cloud Scheduler (3 jobs) and
the budget are per billing account, so dev traffic eats prod's Cloud Run allowance. Users are in India. A Firestore
database location cannot be changed after creation (migration = export/import at read+write cost).

## Options
### Region A. Cloud Run + Firestore + Artifact Registry in `asia-south1` (Mumbai); media buckets in `us-central1` (chosen, founder-confirmed 2026-09-27)
- Pros: API ↔ Firestore in-region (~2–5 ms per query) and ~20–40 ms client RTT from India; timeline p95 < 400 ms
  achievable with ≤ 4 sequential query rounds.
- Cons: images are served from the US (first view slower); Firestore regional prices in Asia are somewhat higher
  than us-central1 once past the free tier (verify current list price); API egress to Indian users is billed
  (Cloud Run's 1 GiB free egress is North America only).
- Cost: $0 at Stage 0 except API egress cents (≈ 3 GB/month at 300 DAU ≈ $0.30–0.40/month — verify rate).

### Region B. Everything in `us-central1`
- Pros: cheapest Firestore/egress rates, media co-located, free egress where applicable.
- Cons: ~220–280 ms RTT per client call from India; cold page with several round trips misses 400 ms p95.
- Cost: ≈ $0 at Stage 0; slightly cheaper overage at 10×.

### Region C. Firestore multi-region `nam5`/`eur3`
- Cons: highest per-op prices, far from users. Rejected.

### CI/CD A. GitHub Actions + Workload Identity Federation + `ko` + Artifact Registry + `gcloud run deploy --no-traffic --tag candidate` (chosen)
- Pros: free minutes for our volume, no SA keys, tagged zero-traffic revision for pre-release checks.
- Cost: Artifact Registry within 0.5 GB with cleanup policy (keep 3 images, delete untagged after 1 day).
### CI/CD B. Cloud Build + Cloud Deploy
- Cons: Cloud Deploy has per-pipeline fees beyond the free tier and adds nothing needed at Stage 0.

## Cost impact
- Fixed monthly cost added: **$0**.
- Free-tier quota consumed by operations: uptime check on `/healthz` every 15 min from 3 regions ≈ 8.6k Cloud Run
  requests/month (0.4% of 2M); CI smoke on the `candidate` tag ≈ 200 requests/deploy; Artifact Registry ≈ 3 × ~25 MB images;
  logs ≈ 1 KiB/request ≈ 0.3 GiB/month at 300 DAU (of 50 GiB); Secret Manager 1–2 versions.
- Pay-per-use (not free, sub-dollar): API egress to India; Firestore scheduled backups for prod (storage-priced only,
  ≈ cents/month at < 1 GiB — founder-approved 2026-09-27).
- Triggers: users outside India > 40% → second Cloud Run region (free-tier-budget §6); p95 > 800 ms warm → min-instances ADR.

## Decision
- **Environments.** `local` (emulators, $0), `dev` (`dzeroth-dev`; internal testers; Cloud Run max 1 instance),
  `prod` (`dzeroth-prod`; max 3 instances). No staging project; pre-release checks run on the tagged zero-traffic
  `candidate` revision in prod against prod data with a dedicated test account.
- **Regions (founder-confirmed 2026-09-27).** Cloud Run `api`, Firestore `(default)` (Native, delete protection
  on, PITR off), Artifact Registry, Pub/Sub push endpoints: `asia-south1`. Media buckets and the Terraform state bucket:
  `us-central1`. Firebase Hosting global.
- **Client endpoints.** Web calls `/api/**` via the Firebase Hosting rewrite (same-origin, no CORS). Mobile calls the
  Cloud Run `*.run.app` URL directly so API bytes don't count against Hosting's 360 MB/day transfer. (Verify during
  the dev deploy that Hosting rewrites to Cloud Run in `asia-south1` are supported; fallback: web calls `run.app` with a
  strict CORS allow-list.)
- **Cloud Run config (Terraform, reviewed as code):** request-based billing (`cpu_idle = true`), min 0, max 3 (prod) /
  1 (dev), 1 vCPU, 512 MiB, concurrency 80, timeout 30 s, startup CPU boost, `allUsers` invoker (auth in Go).
- **Async + cron:** Pub/Sub topics `post-delete`, `account-delete`, `profile-snapshot-refresh`, `notify`,
  `billing-alerts`, each push-subscribed to `/internal/<topic>` with OIDC, max 5 delivery attempts, a DLQ topic,
  ack deadline 60 s. Cloud Scheduler: **1 job** `daily-maintenance` (prod) → `/internal/cron/daily`; 2 slots kept
  in reserve (the 3-job limit is per billing account; dev uses none).
- **CI (every PR):** `make ci` (buf lint + breaking, go vet/lint/test, flutter analyze/test), emulator integration
  tests, `terraform fmt/validate/tflint/checkov`, `terraform plan` for dev and prod.
- **CD:** merge to `main` → `ko build` (distroless, non-root) → push to AR → deploy to dev → smoke. Release tag →
  `gcloud run deploy --no-traffic --tag candidate` in prod → smoke + budget assertions against `candidate` URL → production-reviewer
  go/no-go → traffic 10% → 100%. Rollback = shift traffic to the previous revision. Terraform apply for prod behind a
  GitHub environment approval. No SA keys anywhere (WIF only).
- **Cost guardrails:** billing budget $5/month on the billing account, thresholds 25/50/90/100% actual + 100%
  forecast, email + Pub/Sub `billing-alerts`; `DEGRADED_MODE=off|readonly|nomedia` env var flipped by runbook
  (`docs/runbooks/cost-spike.md`) — automatic flip on the 100% alert is a later, optional function; **never automate
  billing detachment**. One dashboard (reads, writes, requests, instances, GCS egress), 1 uptime check, ≤ 3 alert
  policies (5xx rate, Firestore reads/day > 40k, instance count at max for 15 min). `cost-guard` hook stays on.
- **Data safety:** Firestore delete protection on; prod scheduled backups weekly with 14-day retention (founder-approved;
  `modules/firestore` `weekly_backup_enabled = true` in `envs/prod` only; pay-per-use, cents).

## Consequences
- Positive: $0 idle across both projects; reproducible infra; zero-traffic release gate without a staging project.
- Negative: dev and prod share Cloud Run free allowance; no staging data isolation (rc tests hit prod data — use
  dedicated test accounts and clean up); images slower for Indian users on first view.
- Follow-up: runbooks `cost-spike.md`, `abuse-spike.md`, `rollback.md`; `make cost` script reading the dashboard metrics.
- Revisit when: region triggers above; or a second billing account is needed to isolate dev spend.

## Handoff
- production-deployer: Terraform per `gcp-terraform` with the values above; Firestore location `asia-south1` is confirmed (2026-09-27); deploy Firestore indexes/exemptions/rules and Storage rules via
  `firebase deploy --only firestore,storage` from CI; TTL policies stay in Terraform (ADR-0003 names the 4 fields); verify the Hosting-rewrite region support in dev.
- backend-developer: `DEGRADED_MODE`, `APP_CHECK_MODE`, `QUOTA_*`, `VISION_EXHAUSTED_POLICY`, `HANDLE_CHANGE_COOLDOWN`
  as env config with safe defaults; `/healthz` dependency-free; `/internal/cron/daily` (quota doc cleanup is not needed —
  day rollover is lazy; use it for trending hashtags later and for Vision counter reset checks).
- frontend-developer: base URL per platform/env (`/api` on web, `run.app` on mobile); banner for degraded mode.
- tester: CI emulator suite; smoke script used against dev and the `candidate` tag, asserting `fs_reads` per RPC ≤ budget.
- sre-performance: own `docs/reviews/cost-model.md` actuals weekly.
