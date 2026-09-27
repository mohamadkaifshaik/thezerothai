# Cost model — v0 (design estimate, no production data yet)
Owner: sre-performance (maintains actuals weekly). Seeded by: architect, 2026-09-26, from ADR-0002…0007 and the protos.
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
| GraphService.Follow (+1 async notification) | 4 / 2 | 5 + 1 / 6 | 0 | 60 | 0.5 | 1.0 | 3.0 | 0 |
| GraphService.Unfollow | 1 / 0 | 3 / 3 | 1 / 1 | 40 | 0.1 | 0 | 0.3 | 0.1 |
| GraphService.GetRelationships | 1 / 0.5 | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| GraphService.ListFollowers / ListFollowing | 102 / 25 | 0 | 0 | 60 | 0.3 | 7.5 | 0 | 0 |
| GraphService.Block / Mute / requests (all) | 2 / ~4 blended | 4 / 1 | 2 / 0 | 40 | 0.05 | 0.2 | 0.05 | 0 |
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
| **Total per DAU/day** | | | | | **36.8 requests** | **≈ 188** | **≈ 33** | **≈ 7.8** |

Home timeline = 109 reads/DAU/day (58% of all reads). Likes = 20 writes/DAU/day (60% of all writes).

## 3. Firestore totals vs quota (80% line = 40k reads, 16k writes, 16k deletes per day)
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 18.8k | 47% | 3.3k | 21% | 0.8k | 5% |
| 300 (Stage 0 target) | **56.4k** | **141% (113% of quota)** | 9.9k | 62% | 2.3k | 15% |

**Finding:** reads cross the 80% line at **~213 DAU** and the full free quota at **~266 DAU**. Stage 0's 300-DAU target
therefore costs a little: ≈ 6.4k reads/day over → ≈ $0.11/month at the upper-bound read price. This is inside the
constitution (pay-per-use, no step change), but the "$0 up to 300 DAU" goal is **not** met on reads without the levers
in §6. Writes stay free to ~600 DAU; deletes to ~2,600 DAU.

## 4. Every free quota: where it runs out, and overage at 2× / 10× that DAU
Overage is for that line alone. Prices are the upper-bound list prices in §7 — **verify** before relying on them.
| Quota (free per month) | Usage per DAU-month | Runs out at DAU | Overage $/month at 2× | at 10× |
|---|---|---|---|---|
| Firestore reads (1.5M = 50k/day) | 5,640 | **266** | $0.90 | $8.10 |
| Firestore writes (600k = 20k/day) | 995 | 603 | $1.08 | $9.72 |
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
| 300 | $0.11 | $0.24 | $0.10 | $0 | $1.20 | **≈ $1.65** |
| 600 | $1.13 | $0.48 | $0.25 | $0 | $3.90 | **≈ $5.75** |
| 1,000 | $3.19 | $0.79 | $0.45 | $0 | $7.50 | **≈ $11.95** |
| 3,000 | $13.56 | $6.62 | $6.30 | $0.16 | $13.50 (cap hit) | **≈ $40.15** |
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
Scale-up triggers remain those in `free-tier-budget` §6 (Firestore > 1.5M reads/day ≈ 8k DAU on this model, or bill > $30/month ≈ 3.3k DAU).

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
