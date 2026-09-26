# 0001. Free-tier-first architecture
Status: Accepted
Date: 2026-09-26
Deciders: architect, founder

## Context
We are an early-stage startup with no revenue. The original design (GKE Autopilot, Cloud Spanner, Memorystore
Redis Cluster, global HTTPS LB + Cloud Armor + Cloud CDN, Transcoder, Vertex AI Search, CMEK, Cloud Deploy,
three environments) was sized for 50M DAU. Most of those services bill **per hour whether or not anyone uses them**.

Rough idle cost of the original design (list prices, approximate, before any traffic):
| Item | Why it costs even at zero users | Order of magnitude / month |
|---|---|---|
| Spanner dev 100 PU + staging 1000 PU + prod ≥ 3 nodes | billed per provisioned capacity-hour | hundreds → thousands of USD |
| Memorystore Redis Cluster (≥ 3 shards, replicas) × envs | billed per node-hour | hundreds of USD |
| GKE Autopilot pods (≥ 3 replicas × 10 services) | pod resource requests billed continuously | hundreds of USD |
| Global external HTTPS LB forwarding rules × envs | per rule-hour | ~$18+ per env |
| Cloud Armor policies + rules, Cloud NAT, KMS keys | per policy/rule/gateway/key | tens of USD |
Total: well above $1,000/month before the first user. Not survivable pre-revenue.

Constraint: stay inside GCP **Always Free** + Firebase no-cost quotas from dev through first production users,
while keeping the code shaped so we can scale later without a rewrite.

## Options
### A. Serverless: Cloud Run + Firestore + GCS + Firebase (chosen)
- Pros: every component scales to zero; free tier covers roughly the first ~1k DAU; beyond that pay-per-use in cents;
  zero servers to patch; managed multi-zone availability; Firebase gives Auth, FCM, Hosting, Crashlytics, App Check free.
- Cons: Firestore read quota (50k/day) is the binding limit → forces pull timeline with incremental refresh and caching;
  no SQL joins/full-text search; cold starts (~0.5–1.5 s for Go); vendor-specific data model.
- Cost at Stage 0: $0 (plus possibly cents for API egress outside North America).

### B. One free e2-micro VM: Go + SQLite (Litestream → GCS) or Postgres
- Pros: SQL, no per-operation quotas, full-text search via SQLite FTS5/Postgres.
- Cons: e2-micro (2 shared vCPU burst, 1 GB RAM) is **US-only** (us-west1/us-central1/us-east1) → ~250 ms extra latency
  for Indian users; single point of failure; we patch the OS, TLS (Caddy), backups; free VM egress is 1 GB/month on
  Premium tier (Standard tier offers 200 GB/month per region but check external IPv4 charges); no autoscaling.
- Cost: ~$0–$5/month; ops time is the real cost.

### C. Original design, smallest sizes
- Cost: still hundreds of USD/month idle. Rejected.

## Decision
Option A. One Go modular monolith on Cloud Run (request-based billing, min 0 / max 3 instances) in `asia-south1`,
Firestore `(default)` database in `asia-south1`, media in a `us-central1` GCS bucket (free storage is US-only),
Firebase Auth / Hosting / FCM / App Check / Crashlytics, Pub/Sub push for async work, Cloud Scheduler for cron.
Two GCP projects (dev, prod) on one billing account. Module boundaries are Go interfaces so storage and services
can be swapped later.

## Consequences
- Positive: $0 idle cost; nothing to operate; quick deploys; same code path from local emulators to prod.
- Negative: timeline design is shaped by read quotas; search is prefix/hashtag only; no video at launch;
  moderation automation limited to 1,000 Vision units/month.
- Follow-up: budget alerts + degraded-mode switch in Terraform; read/write budget per RPC in every plan.

## Revisit when (scale-up triggers — any one, sustained 7 days)
- Firestore bill > $30/month **or** reads > 1.5M/day → ADR for Redis/Memorystore timeline cache or Cloud SQL.
- p95 timeline read > 800 ms warm, or cold starts hurt retention → set `min-instances=1` (~a few $/month).
- Need full-text search → ADR: Postgres FTS on Cloud SQL, or Typesense/Meilisearch on a small VM.
- Video demand → ADR: short MP4 (client-compressed) first; Transcoder only with revenue.
- Revenue or funding lets us spend > $100/month → re-evaluate Stage 2 in CLAUDE.md.

## Handoff
- backend-developer: monolith skeleton per `go-service`; Firestore repos per `firestore-data-model`.
- frontend-developer: client-side image compression, incremental timeline refresh, local cache.
- production-deployer: Terraform per `gcp-terraform` including budgets and caps.
- tester: emulator-based integration suite.
