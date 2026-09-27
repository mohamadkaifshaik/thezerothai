---
name: free-tier-budget
description: GCP/Firebase Always Free limits, the per-request read/write budget method, cost guardrails (budgets, caps, degraded mode) and scale-up triggers. Use for any design, plan, review, infra change or cost question, and before adding any GCP service.
---

# Free-tier budget

## 1. The allowances we design against
Last verified: 2026-09-26 against cloud.google.com/free, the Cloud Run pricing page and Firestore quotas.
Google says these "do not expire, but are subject to change" — re-verify every quarter and before each stage change.

| Service | Always-free allowance | Scope / catches |
|---|---|---|
| Cloud Run (request-based billing) | 2M requests, 180,000 vCPU-s, 360,000 GiB-s per month | Aggregated per **billing account**; any region. Egress: only 1 GiB/month free within North America |
| Firestore | 1 GiB stored; **50,000 reads, 20,000 writes, 20,000 deletes per day**; 10 GiB egress/month | Only the `(default)` database, one per project. TTL deletes, PITR, backups are billed |
| Cloud Storage | 5 GB-months, 5,000 Class A ops, 50,000 Class B ops, 100 GB egress (from NA) per month | **US regions only** (us-west1, us-central1, us-east1). Object GETs are Class B |
| Pub/Sub | 10 GiB messages/month | |
| Cloud Scheduler | 3 jobs | per billing account |
| Cloud Vision | 1,000 units/feature/month | SafeSearch = 1 unit per image |
| Secret Manager | 6 active versions, 10,000 accesses/month | read secrets once at startup |
| Artifact Registry | 0.5 GB storage | cleanup policy: keep last 3 images |
| Cloud Build | 2,500 build-min/month (e2-standard-2) | we build in GitHub Actions anyway |
| Cloud Logging | 50 GiB/project/month | don't log request bodies |
| Compute Engine | 1 e2-micro in us-west1/us-central1/us-east1, 30 GB disk, 1 GB egress | **not used** at Stage 0 (see ADR-0001 option B) |
| Firebase Auth | Email, Google, Apple sign-in at no cost at our scale | **Phone/SMS OTP is billed per SMS — do not enable** |
| FCM, Crashlytics, App Check (Play Integrity / App Attest / reCAPTCHA v3) | no cost at our scale | Play Integrity has a daily call quota |
| Firebase Hosting | 10 GB stored, 360 MB/day transfer | web app only; API traffic via rewrite counts too |

## 2. Budget method (required in every plan and ADR)
For each RPC write a row:
```
| RPC | Firestore reads (worst / typical) | writes | Cloud Run ms | calls per DAU/day |
| GetHomeTimeline (refresh) | ceil(F/30) + new posts ≤ 50 / ~8 | 0 | 40 | 10 |
```
Then: `daily reads = Σ(typical reads × calls per DAU) × DAU` and compare to **80% of quota** (40k reads, 16k writes).
Keep the running table for the whole product in `docs/reviews/cost-model.md` (sre-performance owns it).

Reference numbers for Stage 0 planning (update from real metrics once live):
- ~80–150 reads and ~15–25 writes per DAU per day with caching → **free up to roughly 250–500 DAU**.
- Past that, Firestore overage is on the order of cents per 100k operations (check current Firestore pricing for
  the chosen location) → ~1k DAU is typically a few USD/month. That's the plan: pay-per-use, no step changes.
- Cloud Run: ~15–30 requests per DAU/day → 2M requests ≈ 2k–4k DAU. Not the binding limit.
- Media: ~300 KB per image (full + thumb). 5 GB ≈ 15k images; after that ~$0.02/GB-month.

## 3. Techniques that keep us inside the quota
1. **Denormalize** author snapshot (handle, name, avatarUrl, verified) into every post → timeline = no extra author reads.
2. **Incremental refresh**: clients send `since` cursor; server queries `createdAt > since` → cost ≈ new docs only
   (an empty query result still costs 1 read).
3. **Instance cache** (LRU, TTL 30–120 s): profiles, author recent posts, post docs, follow lists. Invalidate locally on write.
4. **Client cache** (drift / IndexedDB): timeline, profiles, own follow list. Never refetch what's on device.
5. **Deterministic doc IDs** for idempotency (`hash(uid, idempotency_key)`) → `Create()` → `AlreadyExists` = replay. No extra idempotency docs.
6. **Counts on parent docs** (`followersCount`, `likeCount`) — never count by querying (use `count()` aggregation only in admin tools: 1 read per 1,000 index entries).
7. **Limit every query** (default 20, max 50). No unbounded listeners from the client — clients don't talk to Firestore directly.
8. **Batch** with `GetAll` for known IDs; each doc is still 1 read, so cache first.

## 4. Guardrails (Terraform, all free)
- **Billing budget** on the billing account: amount = $5 (or ₹ equivalent), thresholds 25/50/90/100% actual + 100% forecast, email to founders.
  Budget notifications also go to Pub/Sub topic `billing-alerts`.
- **Cloud Run caps:** `max_instance_count = 3`, `containerConcurrency = 80`, 1 vCPU, 512 MiB, request timeout 30 s, CPU only during requests.
- **Per-user quotas** (config): posts 100/day, likes 500/day, follows 200/day, media uploads 20/day, signups rate-limited by App Check + IP bucket.
- **Degraded mode:** env var `DEGRADED_MODE=off|readonly|nomedia`. `readonly` rejects writes with a friendly error;
  `nomedia` stops issuing upload URLs. Flip with `gcloud run services update api --update-env-vars DEGRADED_MODE=readonly`
  (runbook `docs/runbooks/cost-spike.md`). Optional: a tiny Cloud Run function on `billing-alerts` flips it automatically at 100%.
- **Hard stop (last resort, human decision only):** detaching billing stops everything and can lead to resource deletion. Never automate.
- **Vision counter:** `admin/vision-{yyyymm}` incremented per call. Every image is screened (paid past the free 1,000/month, ADR-0005); stop at `VISION_MONTHLY_CAP` (default 10,000) and fall back to report-driven moderation.
- The `cost-guard` hook blocks fixed-cost Terraform resources unless the line carries `# cost-approved: ADR-NNNN`.

## 5. Watching usage (free)
- Firebase console → Firestore → Usage tab (reads/writes/deletes per day).
- Cloud Monitoring built-in metrics: `firestore.googleapis.com/document/read_count`, `.../write_count`,
  `run.googleapis.com/request_count`, `run.googleapis.com/container/instance_count`, `storage.googleapis.com/network/sent_bytes_count`.
- One dashboard (Terraform) with those 5 charts. Keep alert policies to a small handful — check Cloud Monitoring pricing for alerting before adding more.
- Weekly: sre-performance appends actuals vs model to `docs/reviews/cost-model.md`.

## 6. Scale-up triggers (need an ADR; any one sustained 7 days)
| Signal | Next step (roughly in order of cost) |
|---|---|
| Firestore > 1.5M reads/day or bill > $30/month | Tighten caching → Memorystore Basic 1 GB timeline cache or Cloud SQL (ADR) |
| p95 warm latency > 800 ms or cold-start complaints | `min_instance_count = 1` (small fixed cost) |
| Hot doc > 1 write/s sustained (viral post counters) | sharded counters for that collection |
| Need full-text search | Postgres FTS (Cloud SQL) or Typesense on a small VM |
| Video uploads demanded | short client-compressed MP4 first; Transcoder later |
| Users outside India > 40% | add a Cloud Run region + Firebase Hosting geo routing; Firestore stays single-region |
| Revenue > infra bill × 10 | consider Stage 2 of CLAUDE.md |

## Cost-review checklist (use in code review and readiness)
- [ ] New RPC has a budget row; totals still < 80% of free quota at the current stage's DAU target.
- [ ] No query without `Limit`; no read-in-a-loop; cache used for hot reads.
- [ ] No new GCP API/service without checking this table (and an ADR if it has a fixed monthly fee).
- [ ] Logs don't include bodies or large payloads.
- [ ] Media stays under size caps; thumbnails used in lists.
