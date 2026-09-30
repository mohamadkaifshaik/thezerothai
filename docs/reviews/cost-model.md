# Cost model — v0.1 (design estimate; Graph rows use emulator-measured numbers, no production data yet)
Owner: sre-performance (maintains actuals weekly). Seeded by: architect, 2026-09-26, from ADR-0002…0007 and the protos.
Updated 2026-09-30 (T21): Graph rows re-based on `docs/reviews/loadtest-graph.md` (T18) and the T16a/T16b `budgettest` ceilings; see `cost-report-v0.2.0.md` §Graph.
Method: `free-tier-budget` §2. Every RPC comment in `proto/` carries the same worst/typical numbers; change both together.

## 1. Assumptions (replace with measured values after the first 100 users)
| Assumption | Value | Why / sensitivity |
|---|---|---|
| Sessions (app opens) per DAU/day | 4 | drives GetMe, refreshes |
| Home refreshes per DAU/day | 8 (pull + resume; auto-refresh ≥ 60 s apart) | each costs `C` = ceil((F+1)/30) reads even if empty |
| Median following F | 60 → C = 3 incl. self; modelled as ~3 reads overhead/refresh incl. cached graph/userLikes misses | a user following 300 pays ~11/refresh |
| Posts per DAU/day (incl. replies) | 1.0 (30% replies) | conservative; lurker-heavy apps see 0.2–0.5 |
| New followee posts seen per DAU/day | 60 (each read once via `since`) | biggest single read line; scales with F × activity |
| Older pages (infinite scroll) per DAU/day | 1 × 20 items | |
| Likes / reposts / follows per DAU/day | 5 / 0.3 / 0.5 | likes dominate writes |
| Images per DAU/day | 0.2 (≈ 0.15 upload calls) | drives GCS + Vision |
| Instance cache hit rate | ~50% for users/graph/userLikes/post docs | low at Stage 0: few concurrent users, scale-to-zero empties caches |
| Avg billable Cloud Run time per request | 0.1 s at 1 vCPU (low concurrency, little overlap) | conservative: overlap at higher traffic lowers it |
| Avg API response (binary proto, gzip) | 6 KB | |
| Image sizes | thumb ≈ 40 KB, full ≈ 250 KB, avatar thumb ≈ 4 KB; pair stored ≈ 300 KB | |
| Uncached image GETs per DAU/day | ~30 (20 thumbs, 10 avatars) + 3 full views | client disk cache for repeats |
| Web share of DAU | 30% (Hosting transfer counts web API via rewrite + static) | mobile calls `run.app` directly (ADR-0007) |
| `[planned]` rows | engagement + notifications modules, not yet in `proto/` | included so the Phase 1 total is honest |

## 2. Per-RPC budget (Firestore reads/writes per call; worst from proto comments, typical used for totals)
| RPC | reads worst / typical | writes worst / typical | deletes (eventual) | Cloud Run ms (warm, est.) | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|
| IdentityService.GetMe | 2 / 1 | 0 | 0 | 15 | 4 | 4.0 | 0 | 0 |
| IdentityService.GetProfile | 4 / 1 | 0 | 0 | 20 | 3 | 3.0 | 0 | 0 |
| IdentityService.CreateProfile | 2 / 2 | 3 / 3 | 0 | 80 | 0.05 | 0.1 | 0.15 | 0 |
| IdentityService.CheckHandleAvailability | 1 / 1 | 0 | 0 | 15 | 0.15 | 0.15 | 0 | 0 |
| IdentityService.UpdateProfile (+snapshot job ≤ 100 posts) | 2 + 100 / 12.5 avg | 1 + 100 / 12.5 avg | 0 | 40 (+job) | 0.02 | 0.25 | 0.25 | 0 |
| IdentityService.ChangeHandle | 2 / 2 | 2 / 2 (+job) | 1 | 60 | ~0 | ~0 | ~0 | ~0 |
| IdentityService.DeleteAccount (+job) | 1 + O(owned docs) | 1 | O(owned docs) | 30 (+job) | ~0.001 | ~0.1 | ~0 | ~0.5 |
| IdentityService.RequestAccountExport / GetAccountExport | 1 + O(owned docs) / 1 | 2 / 0 | 0 | 30 (+job) | ~0 | ~0 | ~0 | 0 |
| GraphService.Follow (created; ADR-0008 A2: 4 cold / 2 warm) | 4 / **4 measured** (3.96–3.98 mean, T18) | 5 / 5 | 0 | 60 (server p95 6–17 ms on emulator) | 0.5 | 2.0 | 2.5 | 0 |
| GraphService.Unfollow (own 0 reads; the 1 read is the caller's status-interceptor profile read after Follow's `Forget`) | 0 own / **1 logged** | 3 / 3 | 1 / 1 | 40 | 0.1 | 0.1 | 0.3 | 0.1 |
| GraphService.GetRelationships (≤ 50 ids) | 1 / 0.5 planning (0.11 measured warm pool) | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| GraphService.ListFollowers / ListFollowing (page 20) | 102 (page 50) / **30.5** planning = mid of 20.16 warm and 40–42 cold (measured) | 0 | 0 | 70 | 0.3 | 9.15 | 0 | 0 |
| GraphService.Block | 3 / 3 (T16a) | 5 / 3 | 2 / 0 | 60 | 0.02 | 0.06 | 0.06 | ~0 |
| GraphService.Unblock | 1 / 1 (T16a) | 2 / 2 | 0 | 30 | 0.005 | ~0 | 0.01 | 0 |
| GraphService.Mute (3 reads after T26; 2 until then) | 3 / 3 | 2 / 2 | 0 | 30 | 0.02 | 0.06 | 0.04 | 0 |
| GraphService.Unmute | 1 / 1 (T16a) | 1 / 1 | 0 | 30 | 0.005 | ~0 | ~0 | 0 |
| GraphService.ListBlockedUsers / ListMutedUsers | 51 / 10 | 0 | 0 | 40 | 0.02 | 0.2 | 0 | 0 |
| GraphService.ListFollowRequests / RespondToFollowRequest (flag-off stubs) | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| **Graph slice subtotal** | | | | | **≈ 4.0 req** | **≈ 13.1** (was 10.2) | **≈ 2.9** (was 3.35) | **≈ 0.1** |
| PostService.CreatePost (+async notifications) | 19 / 1.5 | 6 + 11 / 4.8 | 1 (idempotency TTL) | 80 | 1.0 | 1.5 | 4.8 | 1.0 |
| PostService.DeletePost (+job) | 1 / 1 | 2 / 2 | 1 + likes/reposts / ~4 | 40 (+job) | 0.05 | 0.05 | 0.1 | 0.2 |
| PostService.GetPost | 4 / 0.5 | 0 | 0 | 15 | 1 | 0.5 | 0 | 0 |
| PostService.GetThread | 56 / 7.5 | 0 | 0 | 60 | 2 | 15.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — refresh overhead | 2 + C / 3 | 0 | 0 | 80 | 8 | 24.0 | 0 | 0 |
| ↳ new followee posts returned by refreshes | (included in 2C + 2·page) | 0 | 0 | — | 60 posts | 60.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — older page | 2 + C + 2·page (269 @ F=5,000) / 23 | 0 | 0 | 120 | 1 | 23.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — cold open | same / 23 | 0 | 0 | 150 | 0.1 | 2.3 | 0 | 0 |
| TimelineService.GetUserTimeline | 54 / 11 | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| MediaService.CreateUpload | 2 / 1 | 6 / 3.3 | 1 (idempotency TTL) | 150 (signBlob ×2/image) | 0.15 | 0.15 | 0.5 | 0.15 |
| MediaService.FinalizeUpload | 5 / 1.7 | 5 / 2.7 | 0 | 800 (Vision + copies) | 0.15 | 0.25 | 0.4 | 0 |
| [planned] Like (+in-batch notification) | 1 / 0 | 4 / 4 | ~0.9 (notification TTL) | 40 | 5 | 0 | 20.0 | 4.5 |
| [planned] Unlike | 1 / 0 | 2 / 2 | 1 / 1 | 40 | 0.5 | 0 | 1.0 | 0.5 |
| [planned] Repost (+notification) | 2 / 0.5 | 5 / 5 | 0 | 60 | 0.3 | 0.15 | 1.5 | 0 |
| [planned] ListNotifications + mark seen | 21 / 10 | 1 / 0.5 | 0 | 40 | 2 | 20.0 | 1.0 | 0 |
| [planned] Pub/Sub push send (reply/mention/follow/repost) | 1 / 1 (device tokens) | 0 | 1 (notification TTL) | 100 | 1.3 | 1.3 | 0 | 1.3 |
| [planned] RegisterDevice (FCM token) | 0 | 1 / 1 | 0 | 20 | 0.1 | 0 | 0.1 | 0 |
| **Total per DAU/day** | | | | | **36.8 requests** | **≈ 191** (was 188) | **≈ 32.6** (was 33) | **≈ 7.8** |

Home timeline = 109 reads/DAU/day (57% of all reads). Likes = 20 writes/DAU/day (61% of all writes).

Graph notes (T21, all from emulator runs; `loadtest-graph.md` is the source):
- **Follow is 4 reads, not the plan's 3.** After a successful Follow, `directory.Forget(caller, target)` evicts both
  profiles, and `AccountStatusInterceptor` re-reads the caller. Measured mean 3.96–3.98 (max 4). The 4 is the cold
  ceiling; on this run it is also the typical. ADR-0008 A2 planned 3, so this row is +0.5 reads/DAU over the ADR.
- **Unfollow logs 1 read, not 0.** The RPC's own batch is 0 reads / 3 writes / 1 delete. The 1 is the caller's
  interceptor profile read once a preceding Follow evicted it. It is counted here because `fs_reads` includes it;
  it slightly double-counts against the identity rows (a profile read the caller was going to pay anyway).
- **ListFollowers page 20 is 20.16 warm and 40-42 cold**; 30.5 is the midpoint (the model's ~50% hit-rate
  assumption, §1). The 20.16 came from a 100-caller / 5-target warm pool, so it is a floor, not a forecast.
- Block/Mute rows are the T16a `budgettest` ceilings; they are not in the k6 run (0.02 calls/DAU, immaterial).
  Mute's 3 depends on T26 (not merged as of this update); today's Mute is 2 reads.
- GetRelationships measured 0.11 mean on a warm pool (worst 2). 0.5 is kept, the planning value.

## 3. Firestore totals vs quota (80% line = 40k reads, 16k writes, 16k deletes per day)
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 19.1k | 48% | 3.3k | 20% | 0.8k | 5% |
| 300 (Stage 0 target) | **57.3k** | **143% (115% of quota)** | 9.8k | 61% | 2.3k | 15% |

**Finding:** reads cross the 80% line at **~210 DAU** (was ~213) and the full free quota at **~262 DAU** (was ~266). Stage 0's
300-DAU target therefore costs a little: ≈ 7.3k reads/day over → ≈ $0.13/month at the upper-bound read price. This is
inside the constitution (pay-per-use, no step change), but the "$0 up to 300 DAU" goal is **not** met on reads without
the levers in §6. Writes stay free to ~614 DAU (was ~603); deletes to ~2,600 DAU. The move is measurement, not design:
graph reads/DAU went 10.2 → 13.1 (Follow 4 not 3, lists 30.5, Unfollow 1, Mute 3).

**This whole-product row includes the `[planned]` likes/notifications/timeline rows, which are not released.** The
released v0.2.0 scope (identity + graph) is 20.4 reads, 3.1 writes, 0.1 deletes per DAU: at 300 DAU that is 6.1k reads
(12.2% of quota, 15% of the 80% line), 0.93k writes (4.6%) and 30 deletes (0.2%), and it runs out at ≈ **2,450 DAU**
(80% line ≈ 1,960). See `cost-report-v0.2.0.md`. The 262-DAU crossover applies once posts, timeline and engagement ship.

## 4. Every free quota: where it runs out, and overage at 2× / 10× that DAU
Overage is for that line alone. Prices are the upper-bound list prices in §7 — **verify** before relying on them.
| Quota (free per month) | Usage per DAU-month | Runs out at DAU | Overage $/month at 2× | at 10× |
|---|---|---|---|---|
| Firestore reads (1.5M = 50k/day) | 5,726 | **262** | $0.90 | $8.10 |
| Firestore writes (600k = 20k/day) | 977 | 614 | $1.08 | $9.72 |
| Firestore deletes (600k = 20k/day) | 233 | 2,581 | $0.12 | $1.08 |
| Firestore storage (1 GiB) | ≈ 6.4 KB/day (posts, likes, notifications with 90-day TTL) | ~1.5 years at 300 DAU | cents | cents |
| Cloud Run requests (2M, shared with dev; ~29k/month fixed: uptime + CI) | 1,104 | 1,786 | $0.79 | $7.10 |
| Cloud Run vCPU-s (180k, shared) | 110 | **1,603** (first Cloud Run limit) | $4.25 | $38.23 |
| Cloud Run GiB-s (360k, shared) | 55 | 6,495 | $0.90 | $8.07 |
| Cloud Run egress to India (free 1 GiB is North America only → effectively 0) | 6.6 MB | **0** (billed from day 1) | $0.24 at 300 DAU | $2.38 at 3k DAU |
| GCS Class A (5,000) | 24 (4 per image) | **208** | $0.03 | $0.23 |
| GCS Class B (50,000) | 918 (image views) | **54** | $0.02 | $0.18 |
| GCS storage (5 GB-months, US only) | 1.8 MB/month growth | ~9 months at 300 DAU | cents | ≈ $0.10/month per extra 5 GB |
| GCS egress (100 GB from NA) | 47 MB | 2,133 | $12.00 | $108.00 |
| Cloud Vision SafeSearch (1,000; paid past it, cap 10,000 — ADR-0005) | 6 units | **158–167** | $1.20 | $13.50 (cap) |
| Firebase Hosting transfer (360 MB/day) | 4 MB | 2,731 | $1.62 | $14.58 |
| Pub/Sub (10 GiB) | ~80 KB (1 KB min per message) | > 100k | $0 | $0 |
| Cloud Logging (50 GiB/project) | 1.1 MB | ~47k | $0 | $0 |
| Cloud Scheduler (3 jobs/billing account) | 1 job used | n/a | $0 | $0 |
| Secret Manager (6 versions, 10k accesses) | 1 version, 1 access per instance start | n/a | $0 | $0 |
| Artifact Registry (0.5 GB) | 3 images × ~25 MB | n/a | $0 | $0 |

## 5. Whole bill by DAU (Vision: every image screened, paid past 1,000/month, capped at 10,000 — ADR-0005, founder 2026-09-27)
| DAU | Firestore | Cloud Run (req + CPU + egress) | GCS (ops + egress) | Hosting | SafeSearch | **Total/month** |
|---|---|---|---|---|---|---|
| 100 | $0 | $0.08 (egress) | $0.02 | $0 | $0 | **≈ $0.10** |
| 300 | $0.13 | $0.24 | $0.10 | $0 | $1.20 | **≈ $1.67** |
| 600 | $1.16 | $0.48 | $0.25 | $0 | $3.90 | **≈ $5.79** |
| 1,000 | $3.22 | $0.79 | $0.45 | $0 | $7.50 | **≈ $11.98** |
| 3,000 | $13.63 | $6.62 | $6.30 | $0.16 | $13.50 (cap hit) | **≈ $40.22** |
Plus prod Firestore weekly backups (ADR-0007): storage-priced, cents/month at < 1 GiB.
Nothing in this table is a fixed fee; every line falls back to $0 with traffic. With paid SafeSearch the $5 budget
alert (ADR-0007) fires at ≈ 550 DAU — consider raising the budget amount then (config change, not an ADR).

## 6. Levers, cheapest first (use before any Stage 2 ADR)
1. Notifications list via `since` + client cache (like the timeline): −15 reads/DAU → reads free to ~250 DAU.
2. GetThread first page 10 instead of 20; lazy "show replies": −5 reads/DAU.
3. Older-page prefetch only after the user scrolls past 70% (never on open): −5…10 reads/DAU.
4. Like notifications collapsed per post per hour (update one doc): writes/like 4 → ~3.3 at scale.
5. Cloud Run CPU: gzip and binary proto (already), avoid per-request allocations in the merge; raise concurrency
   overlap by keeping max instances at 3.
6. Image egress: keep thumbnails ≤ 40 KB; never load `url` in lists.
Scale-up triggers remain those in `free-tier-budget` §6 (Firestore > 1.5M reads/day ≈ 7.9k DAU on this model, or bill > $30/month ≈ 3.3k DAU).

## 7. Prices used (upper bounds; verify on the pricing pages before each stage change)
The pricing pages could not be fetched on 2026-09-26, so these are the upper-bound list prices from memory — **sre-performance
must verify** and replace them, especially for `asia-south1`:
- Firestore: $0.06 / 100k reads, $0.18 / 100k writes, $0.02 / 100k deletes, $0.18 / GiB-month (multi-region list
  prices used as an upper bound; the `asia-south1` regional price should be at or below this).
- Cloud Run (request-based, Tier 1): $0.000024 / vCPU-s, $0.0000025 / GiB-s, $0.40 / million requests. Confirm whether
  `asia-south1` is Tier 1; Tier 2 overage is roughly 40% higher (the free tier is the same).
- Internet egress to India (Cloud Run, GCS): ~$0.12 / GB.
- GCS Standard: Class A $0.005 / 1k, Class B $0.0004 / 1k, $0.020 / GB-month (us-central1).
- Cloud Vision SafeSearch: $1.50 / 1k units after the first 1,000/month.
- Firebase Hosting: $0.15 / GB transfer beyond 360 MB/day.

## 8. Actuals (sre-performance appends weekly)
| Week | DAU | reads/day | writes/day | deletes/day | CR requests/mo | CR vCPU-s/mo | GCS egress GB | Bill | Model error |
|---|---|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — | — | — |

## 9. Dashboard notes (Logs Explorer; no new log-based metric, no new alert policy)
- Graph reads by operation (T21): `jsonPayload.graph_op!="" | sum fs_reads by graph_op`
  (Log Analytics form: `SELECT JSON_VALUE(json_payload.graph_op) AS graph_op, SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) ... GROUP BY graph_op`).
- **Works since PR #36** (updated 2026-09-30): every graph RPC's request line carries `graph_op`, `outcome`,
  `txn_attempts`, `graph_cache_hit`, `edges_removed` (Block) and `feature_disabled` (flag rejections) next to `rpc`,
  `fs_reads`/`fs_writes`/`fs_deletes` and `limit_name`; a WARN `graph_txn_contention` fires when `txn_attempts > 3`
  (`backend/internal/graph/observe.go`; queries in `docs/runbooks/graph.md` §3). Fallback for log lines older than that
  deploy: `jsonPayload.rpc:"GraphService" | sum fs_reads by rpc`.
- Still **not** emitted: `rows_filtered` and `hydration_misses` (lists), and `lazy_removed` (until T27 ships). The purge
  lines `graph_purge_batch` / `purge_missing_counterpart` exist but are written by `opsctl` on the operator's terminal,
  not by the `api` service, so they are not in Cloud Logging.
- Existing alerts (uptime, 5xx, Firestore reads > 40k/day) are unchanged; the graph adds no alert policy.
