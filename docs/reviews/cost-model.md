# Cost model — v0.3 (design estimate; Graph and Posts/Timeline rows use emulator-measured numbers, no production data yet)
Owner: sre-performance (maintains actuals weekly). Seeded by: architect, 2026-09-26, from ADR-0002…0007 and the protos.
Updated 2026-09-30 (T21): Graph rows re-based on `docs/reviews/loadtest-graph.md` (T18) and the T16a/T16b `budgettest` ceilings; see `cost-report-v0.2.0.md` §Graph.
Updated 2026-10-06 (posts-and-timeline T25): Post/Timeline rows re-based on emulator measurements; see `cost-report-posts-timeline.md`. Whole product 191 to 230.0 reads/DAU (released scope 192.9; ADR-0010 forecast 182.6).
Updated 2026-10-09 (P8 T21): rows 35-36 replaced from `cost-report-account-lifecycle.md` (derived from code, not yet measured). Whole-product totals in row 69 and §3-§5 are not yet rewritten: delta +1.1 reads, +0.3 writes, +0.0 deletes per DAU (231.1 reads/DAU; free read quota at about 216 DAU); regenerate at the next weekly update. New fixed line: ADR-0011 C4 alert about $0.39/month, prod only.
Updated 2026-10-23 (ADR-0022, sre-performance handoff): verified prices replace the §7 upper bounds (Firestore asia-south1 $0.035 / $0.104 / $0.012 per 100k, Vision 2 units per image, alerting free before 2027-09-01, INR 95 per USD +/-5%); §4 Firestore overage and the Vision row, §5 and §7 re-priced; new §10 daily gross burn line. Usage inputs are unchanged (230.0 reads/DAU in §2/§3; ADR-0022 uses 232.3 = 230.0 + 1.1 P8 + 1.23 ADR-0021, a +1% difference that is inside the rounding of the tables below). Changes are marked `2026-10-23 ADR-0022`.
Method: `free-tier-budget` §2. Every RPC comment in `proto/` carries the same worst/typical numbers; change both together.

## 1. Assumptions (replace with measured values after the first 100 users)
| Assumption | Value | Why / sensitivity |
|---|---|---|
| Sessions (app opens) per DAU/day | 4 | drives GetMe, refreshes |
| Home refreshes per DAU/day | 8 (pull + resume; auto-refresh ≥ 60 s apart) | each costs `C` = ceil((F+1)/30) reads even if empty |
| Median following F | 60 → C = 3 incl. self; measured 2-4 reads overhead/refresh (graph cold 4, warm 3, all warm 2); modelled 4. `userLikes` is not read until P5 and is not in any row | a user following 300 pays ~11/refresh |
| Posts per DAU/day (incl. replies) | 1.0 (30% replies) | conservative; lurker-heavy apps see 0.2–0.5 |
| New followee posts seen per DAU/day | 60 (each read once via `since`) | biggest single read line; scales with F × activity |
| Older pages (infinite scroll) per DAU/day | 1 × 20 items | |
| Likes / reposts / follows per DAU/day | 5 / 0.3 / 0.5 | likes dominate writes |
| Images per DAU/day | 0.2 (≈ 0.15 upload calls) | drives GCS + Vision |
| Vision units per image (2026-10-23 ADR-0022) | **2**: the full image and its thumbnail are both screened (`VISION_SCREEN_THUMB` default true, set true in prod and dev Terraform; `backend/internal/media/service.go` `finalizeOne`: `units := int64(1); if s.ScreenThumb { units = 2 }`) | 0.2 images x 2 x 30.42 days = **12.17 units per DAU-month** (was 6 at 1 unit per image). Setting `VISION_SCREEN_THUMB=false` halves it |
| Instance cache hit rate | ~50% for users/graph/post docs (assumption; never measured, no traffic yet) | low at Stage 0: few concurrent users, scale-to-zero empties caches |
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
| IdentityService.DeleteAccount (+job; reference account P 300, O = I = 100, derived, `cost-report-account-lifecycle.md`) | 2 + job (P+O+I+...) / **513** (2 RPC + 2 gated + 509 work) | 1 + 300 / **301** | **505** | 30 (+ job about 10 vCPU-s) | 0.001 | 0.51 | 0.30 | 0.51 |
| IdentityService.RequestAccountExport / GetAccountExport (+job; reference account, derived) | 2 / 1 + job 703 + 3 polls = **708** | 2 + 2 (job: lease claim, status) = **4** | 1 (TTL, 7 d) | 30 (+ job about 20 vCPU-s) | 0.001 | 0.71 | 0.004 | 0.001 |
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
| PostService.CreatePost (root; reads exclude the interceptor) | 14 / **2.2** planning (measured 2 warm; +1 per uncached mentioned handle, 3 cold instance, 5 cold with 2 mentions) | 4 / 4 (measured) | 1 (idempotency TTL) | 80 | 1.0 | 2.2 | 4.0 | 1.0 |
| PostService.CreatePost, replay / reused key | 14 / 1 warm (measured); 3 on a cold instance (users + idempotency + post) | 0 | 0 | 30 | — | — | — | — |
| PostService.DeletePost (own post) | 2 / **1** (measured 1 cold, 0 warm, 1 on a no-op or another user's post) | 1 / 1 (0 on no-op, measured) | 1 / 1 (0 on no-op) | 40 | 0.05 | 0.05 | 0.05 | 0.05 |
| PostService.GetPost | 4 / **1.0** (measured 3 cold: post + author + caller graph; 1 post miss with author+graph warm; 0 warm) | 0 | 0 | 15 | 1 | 1.0 | 0 | 0 |
| PostService.GetThread **[planned, P3, not released, not measured]** | 56 / 7.5 | 0 | 0 | 60 | 2 | 15.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — refresh overhead (no `userLikes` until P5) | 2 + C / **4** (measured 4 graph cold, 3 graph warm, 2 all warm; F=60) | 0 | 0 | 80 | 8 | 32.0 | 0 | 0 |
| ↳ new followee posts returned by refreshes | measured +1 read per returned post (new=1: 4, 8: 10, 20: 22) | 0 | 0 | — | 60 posts | 60.0 | 0 | 0 |
| ↳ settle-window re-reads (ADR-0010 D13) | measured unit: +1 read per re-delivered post; frequency derived, ≤ 0.1 per refresh | 0 | 0 | — | 8 | 1.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — older page | 269 (assert 268 + interceptor) / **40** (measured 40 mixed feed, 42 dense feed, 43 on a cold instance; **ADR planning 30, +33%: ADR-0010 revisit flagged**) | 0 | 0 | 120 | 1 | 40.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — cold open | same / **36.5** (measured 30 mixed, 43 dense; midpoint; ADR 30) | 0 | 0 | 150 | 0.1 | 3.65 | 0 | 0 |
| TimelineService.GetUserTimeline (page 20) | 54 / **11** (measured 22 cold page, 0 warm first page, 20-22 page 2, 3 cold refresh with 0 new, 0-1 warm refresh; mix of cold and warm) | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| `AccountStatusInterceptor` caller read on posts/timeline requests (measured unit: 1 cold, 0 warm; mix derived) | 1 / 0 / 1 per home refresh, 0.5 on the other 5.15 requests | 0 | 0 | — | 13.15 req | 10.6 | 0 | 0 |
| **Posts + timeline subtotal (released in P1)** | | | | | **≈ 13.15 req** | **≈ 172.5** (ADR-0010: 162.2) | **≈ 4.05** | **≈ 1.05** |
| MediaService.CreateUpload | 2 / 1 | 6 / 3.3 | 1 (idempotency TTL) | 150 (signBlob ×2/image) | 0.15 | 0.15 | 0.5 | 0.15 |
| MediaService.FinalizeUpload | 5 / 1.7 | 5 / 2.7 | 0 | 800 (Vision + copies) | 0.15 | 0.25 | 0.4 | 0 |
| [planned] Like (+in-batch notification) | 1 / 0 | 4 / 4 | ~0.9 (notification TTL) | 40 | 5 | 0 | 20.0 | 4.5 |
| [planned] Unlike | 1 / 0 | 2 / 2 | 1 / 1 | 40 | 0.5 | 0 | 1.0 | 0.5 |
| [planned] Repost (+notification) | 2 / 0.5 | 5 / 5 | 0 | 60 | 0.3 | 0.15 | 1.5 | 0 |
| [planned] ListNotifications + mark seen | 21 / 10 | 1 / 0.5 | 0 | 40 | 2 | 20.0 | 1.0 | 0 |
| [planned] Pub/Sub push send (reply/mention/follow/repost) | 1 / 1 (device tokens) | 0 | 1 (notification TTL) | 100 | 1.3 | 1.3 | 0 | 1.3 |
| [planned] RegisterDevice (FCM token) | 0 | 1 / 1 | 0 | 20 | 0.1 | 0 | 0.1 | 0 |
| **Total per DAU/day (whole product, incl. `[planned]` rows)** | | | | | **36.8 requests** | **≈ 230.0** (was 191) | **≈ 31.8** (was 32.6) | **≈ 7.65** |

Home timeline = 136.7 reads/DAU/day (59% of all reads). Likes = 20 writes/DAU/day (63% of all writes).

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

Posts/timeline notes (T25, emulator runs; `cost-report-posts-timeline.md` is the source; reads exclude the interceptor unless stated):
- **Measured values** are from the existing integration tests plus throwaway `-overlay` tests (not in the repo). Cache hit rates, the 60 new posts/DAU
  and the call mix are still model assumptions: there is no real traffic.
- **Older page is 40 (mixed feed) to 42 (dense feed), planning 30: +33% to +40%, above the 25% line.** With 61 authors (self + 60) the
  first chunk is self + 29, so there are three chunks and k = ceil(2p/3) = 14; once the small chunk is covered by author-recent, two
  chunks run at k = 20. This is the ADR-0004 over-read, priced higher than the ADR assumed. ADR-0010 lever ("`2p` to `1.5p`
  when older-page reads > 1.4 x page size") has fired: 40 / 20 = 2.0. Not applied (no code change in T25); flagged for P9.
- **Home refresh overhead is 4 only on a fully cold instance** (graph expired, author-recent empty). Graph warm is 3, all warm 2.
  Modelled 4 because refreshes are >= 60 s apart and `CACHE_TTL` is capped at 60 s.
- **New posts cost 1 read each** (measured exactly), so 60 posts/DAU = 60 reads/DAU. The count of 60 is an input, not a measurement.
- **Settle re-read**: measured unit is 1 read per re-delivered post; the frequency (about 0.1 per refresh) is derived, not measurable
  without traffic. Uniform arrivals would give about 0.01 per refresh, so 1.0/DAU is an upper bound.
- **`userLikes` is out of every timeline row until P5** (no read, no cache entry).
- **F = 5,000 measures 168 reads (169 with the interceptor) against the 269 ceiling.** The seeded shape has 8 real authors; the ceiling
  needs every chunk to fill k. The ceiling is an assertion bound, not a planning value.
- Unit costs are exact across runs (deterministic emulator, no variance), so "mean" = the value.

## 3. Firestore totals vs quota (80% line = 40k reads, 16k writes, 16k deletes per day)
Whole product, including the `[planned]` likes, notifications and GetThread rows (230.0 reads, 31.8 writes, 7.65 deletes per DAU):
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 23.0k | 58% | 3.2k | 20% | 0.8k | 5% |
| 300 (Stage 0 target) | **69.0k** | **173% (138% of quota)** | 9.5k | 60% | 2.3k | 14% |

**Finding (whole product):** reads cross the 80% line at **~174 DAU** (was ~210) and the full free quota at **~217 DAU** (was ~262). Stage 0's
300-DAU target costs ≈ 19.0k reads/day over → ≈ **$0.20/month** at the verified asia-south1 read price of $0.035 per 100k (2026-10-23 ADR-0022; was $0.34 at the old $0.06 upper bound, $0.13 before that). Still pay-per-use with no step change, but the
"$0 up to 300 DAU" goal is **not** met on reads (2026-10-23 ADR-0022: nor on the whole bill: Stage 0 is about INR 434/month at 300 DAU, §5, mostly Vision and egress) without the §6 levers. Writes stay free to ~630 DAU (was ~614); deletes to ~2,600 DAU.
Where the +39.2 reads/DAU since the 191 came from, row by row: older page 23 to 40 (+17.0), interceptor line (+10.6, new line), refresh overhead 3 to 4 (+8.0),
cold open 2.3 to 3.65 (+1.35), settle re-reads (+1.0, new line), CreatePost 1.5 to 2.2 (+0.7), GetPost 0.5 to 1.0 (+0.5). The ADR-0010 corrections account for +28.9
(162.2 vs the old posts rows); the measured values add +10.3 on top.

**Released scope (identity + graph + posts/timelines, after P1), the one that matters for the next release:**
20.4 + 172.5 = **192.9 reads**, 7.15 writes, 1.15 deletes, 24.45 requests per DAU. ADR-0010 forecast: 182.6 reads (**measured +5.6%**, within 25%).
| | ADR-0010 forecast | Re-based on measurements | Difference |
|---|---|---|---|
| Reads per DAU per day | 182.6 | **192.9** | +5.6% |
| Reads at 300 DAU | 54.8k (110% of free) | **57.9k (116% of free)** | +5.6% |
| Free quota runs out at | ≈ 274 DAU | **≈ 259 DAU** | -5.5% |
| 80% line (40k) crossed at | ≈ 219 DAU | **≈ 207 DAU** | -5.5% |
| Overage at 300 DAU | 4.8k reads/day, ≈ $0.09/month | **7.9k reads/day, ≈ $0.08/month** (2026-10-23 ADR-0022 price; was $0.14) | **+64% in dollars (+3.1k reads/day, +$0.05)** |
The reads figure is within 25% of the ADR. The dollar figure is not, only because overage is the small difference between two close numbers; it is 5 cents. It is
still inside founder decision D1 (pay-per-use), but the cause is one planning value above 25% (older page, +33%), so the k lever is flagged for P9 and the ADR-0010
revisit is triggered (`cost-report-posts-timeline.md`). At 300 DAU the identity + graph + posts scope costs 57.9k reads against a 40k alert threshold.
Writes: 2.1k/day at 300 DAU (11%), free to ~2,800 DAU. v0.2.0 (identity + graph only) is unchanged: 20.4 reads, ≈ 2,450 DAU.

## 4. Every free quota: where it runs out, and overage at 2× / 10× that DAU
Overage is for that line alone. Prices are the verified list prices in §7 (2026-10-23 ADR-0022; Firestore overage column re-priced from the old $0.06/$0.18/$0.02 bounds to $0.035/$0.104/$0.012 per 100k, i.e. x0.583 / x0.578 / x0.6).
| Quota (free per month) | Usage per DAU-month | Runs out at DAU | Overage $/month at 2× | at 10× |
|---|---|---|---|---|
| Firestore reads (1.5M = 50k/day) | 6,902 | **217** | $0.53 | $4.73 |
| Firestore writes (600k = 20k/day) | 952 | 630 | $0.62 | $5.62 |
| Firestore deletes (600k = 20k/day) | 230 | 2,614 | $0.07 | $0.65 |
| Firestore storage (1 GiB) | ≈ 6.4 KB/day (posts, likes, notifications with 90-day TTL) | ~1.5 years at 300 DAU | cents | cents |
| Cloud Run requests (2M, shared with dev; ~29k/month fixed: uptime + CI) | 1,104 | 1,786 | $0.79 | $7.10 |
| Cloud Run vCPU-s (180k, shared) | 110 | **1,603** (first Cloud Run limit) | $4.25 | $38.23 |
| Cloud Run GiB-s (360k, shared) | 55 | 6,495 | $0.90 | $8.07 |
| Cloud Run egress to India (free 1 GiB is North America only → effectively 0) | 6.6 MB | **0** (billed from day 1) | $0.23 at 300 DAU (1.93 GiB x $0.12) | $2.32 at 3k DAU |
| GCS Class A (5,000) | 24 (4 per image) | **208** | $0.03 | $0.23 |
| GCS Class B (50,000) | 918 (image views) | **54** | $0.02 | $0.18 |
| GCS storage (5 GB-months, US only) | 1.8 MB/month growth | ~9 months at 300 DAU | cents | ≈ $0.10/month per extra 5 GB |
| GCS egress (100 GB from NA) | 47 MB | 2,133 | $12.00 | $108.00 |
| Cloud Vision SafeSearch (1,000 units; paid $1.50 per 1,000 past it, cap 10,000 — ADR-0005). 2026-10-23 ADR-0022: **2 units per image** (full + thumbnail) | **12.17** (was 6) | free runs out at **82** (1,000 / 12.17; was 158–167); cap 10,000 reached at **822** (10,000 / 12.17 = 821.7, about 820) | $1.50 (2,000 units at 164 DAU, 1,000 paid) | $13.47 at 820 DAU (8,980 paid; the cap holds it at $13.50 beyond) |
| Firebase Hosting transfer (360 MB/day) | 4 MB | 2,731 | $1.62 | $14.58 |
| Pub/Sub (10 GiB) | ~80 KB (1 KB min per message) | > 100k | $0 | $0 |
| Cloud Logging (50 GiB/project) | 1.1 MB | ~47k | $0 | $0 |
| Cloud Scheduler (3 jobs/billing account) | 1 job used | n/a | $0 | $0 |
| Secret Manager (6 versions, 10k accesses) | 1 version, 1 access per instance start | n/a | $0 | $0 |
| Artifact Registry (0.5 GB) | 3 images × ~25 MB | n/a | $0 | $0 |

### Read budget as an abuse bound (ADR-0010 D5 as amended; posts-and-timeline T24/T25)
The read-budget counters live in instance memory, so every bound is **per instance lifetime**. Numbers are the ADR/plan bounds (derived, not load-tested here).
The measured per-call costs above stay under them: the largest single call, F = 5,000 home, measures 168 reads against the in-flight hold M = 269.
| Actor | Bound | Reads | $ at the §7 price (re-priced 2026-10-23 ADR-0022: $0.035 per 100k reads) |
|---|---|---|---|
| Unverified (minted) password account, any RPC | 0-read verified-identity gate (`PROFILE_REQUIRED` / `EMAIL_NOT_VERIFIED` from token claims) | **0** | $0 |
| One verified account, one instance lifetime | `READ_BUDGET_PER_UID_PER_DAY` 2,000 + in-flight hold 269 - 1 | **2,308** | $0.0008 |
| One verified account, a day, steady state (<= 3 instances) | 3 x 2,308 | **<= 6,924** (13.8% of free) | ≈ $0.0024 |
| Same, rollout day (<= 6 instances) | 6 x 2,308 | <= 13,848 | ≈ $0.005 |
| Same, idle cycling (<= 90 lifetimes/day) | 90 x 2,308 | ≈ 208k | ≈ $0.07 |
| **Deliberate instance churn (residual R2), ceiling** (<= 270 lifetimes/day) | 270 x 2,308 | **≈ 623k per day** | ≈ $0.22/day |
| Verified sybils (residual R1) | per account x accounts | ≈ 8 accounts exhaust a day's free reads | ≈ $0.002/day each |
Detect with `jsonPayload.limit_name` (`read_budget_daily`, `read_budget_inflight`) split by `read_budget_key`, and the `read_budget_spent` field on every request
line; levers are in `docs/runbooks/abuse-spike.md` (T26). The bound is a hard stop on reads only for the account; the cost is cents, not a step change.

## 5. Whole bill by DAU (Vision: every image screened at 2 units, paid past 1,000/month, capped at 10,000 - ADR-0005; re-priced 2026-10-23 ADR-0022)
Stage 0 as configured (min instances 0, Vision cap 10,000, sweep `*/5`). Verified prices (§7), 232.3 reads, 32.4 writes, 7.71 deletes per DAU (ADR-0022 inputs), 12.17 Vision units per DAU-month, INR 95 per USD. **The Stage 0 bill is not INR 0** at any DAU in this table: egress to India is billed from the first GiB, Vision is paid past 82 DAU, and Firestore reads pass the free quota at about 215 DAU.
| DAU | Firestore | Cloud Run (req + CPU + egress) | GCS (ops + egress) | Hosting | SafeSearch | Backups | **Total USD/month** | **INR/month (95)** | FX -5% / +5% |
|---|---|---|---|---|---|---|---|---|---|
| 100 | $0 | $0.08 (egress) | $0.02 | $0 | $0.33 (1,217 units) | $0.04 | **≈ $0.47** | **≈ 45** | 42 / 47 |
| 300 | $0.22 | $0.23 | $0.10 | $0 | $3.98 (3,650 units) | $0.04 | **$4.57** | **434** | 412 / 456 |
| 600 | $0.95 | $0.46 | $0.25 | $0 | $9.45 (7,300 units) | $0.04 | **≈ $11.15** | **≈ 1,059** | 1,006 / 1,112 |
| 1,000 | $2.36 | $0.77 | $0.44 | $0 | $13.50 (cap hit at 822 DAU) | $0.04 | **$17.12** | **1,626** | 1,545 / 1,707 |
| 3,000 | $9.42 | $6.57 (CPU 3.71 + requests 0.54 + egress 2.32) | $6.06 | $0.16 | $13.50 (cap) | $0.04 | **$35.74** | **3,396** | 3,226 / 3,566 |
Strict variant (Vision cap 1,000, no paid SafeSearch; uploads past the cap go to report-driven review): 300 DAU **$0.59 / INR 56**, 1,000 DAU **$3.61 / INR 343**, 3,000 DAU **$22.25 / INR 2,114**. Credit-mode profile (ADR-0022: service-level min instance 1 at $9.86, Vision cap 20,000 up to 1,300 DAU and 40,000 above, sweep every minute), for the 2026-10-23 to 2026-12-24 window only: 300 DAU **$14.44 / INR 1,371**, 1,000 DAU **$30.24 / INR 2,873**, 3,000 DAU **$85.54 / INR 8,127**; about INR 31 per day at 0 DAU. Source and arithmetic: `docs/plans/credit-runway-cost-model.md` §2-§3.
FX: INR 95 per USD is an assumption (mid-market 94.955 on 2026-10-23); +/-5% moves every INR figure by the same +/-5% (INR 90.25 to 99.75). INR billing accounts pay Google's INR SKU prices, which can differ from USD x 95. GST (18%) is not included and its applicability to this account is unverified.
Prod Firestore weekly backups (ADR-0007) are the $0.04 column (about 2 x 0.5 GiB x $0.035); the earlier tables omitted them.
Fixed monitoring line (decision 2026-10-10, R4; the only fixed lines in this table, not DAU-dependent):
prod keeps 4 alert policies (uptime, 5xx rate, Firestore reads, C4 Auth mutations); dev keeps none of the 3 older ones
(gated off in Terraform). Upper bound at the published $0.35 per metric reference per month plus $0.50 per million points
returned: about **$1.05 to $1.20/month** for prod's 3 older policies, plus **about $0.39/month** for C4 (ADR-0011),
so **about $1.45 to $1.60/month** in total (applies only once alerting is charged, see below). Uptime-check executions are inside the 1M free executions per project.
Verified 2026-10-23 (ADR-0022, Cloud Monitoring pricing page): alerting charges start no sooner than 2027-09-01, and billing, quota and uptime-metric policies are not charged. **So the fixed monitoring line above is $0 until 2027-09-01** and the $1.45 to $1.60/month upper bound applies only from that date; re-check before it.
Nothing else in this table is a fixed fee; every other line falls back to $0 with traffic. With paid SafeSearch at 2 units per image the $5 budget alert (ADR-0007; INR 500 is about $5.26) fires at about 320-330 DAU on this table (was about 520; interpolated between 300 DAU at $4.57 and 600 DAU at $11.15). Raise the budget amount or accept the alert as the signal (config change, not an ADR); ADR-0022 adds the credit-runway gross budget (§10).

## 6. Levers, cheapest first (use before any Stage 2 ADR)
0. **Older-page over-read: k from `2p` to `1.5p` (ADR-0010 reserve lever; its trigger has fired, older page = 2.0 x page).** Derived, not measured: two chunks at k = 15 instead of 20 saves ≈ 10 reads per older page, so ≈ -10 reads/DAU (back to ≈ 183 released). Needs a one-constant backend change and a re-run of the timeline budget tests; flagged for P9.
1. Notifications list via `since` + client cache (like the timeline): −15 reads/DAU → reads free to ~250 DAU.
2. GetThread first page 10 instead of 20; lazy "show replies": −5 reads/DAU.
3. Older-page prefetch only after the user scrolls past 70% (never on open): −5…10 reads/DAU.
4. Like notifications collapsed per post per hour (update one doc): writes/like 4 → ~3.3 at scale.
5. Cloud Run CPU: gzip and binary proto (already), avoid per-request allocations in the merge; raise concurrency
   overlap by keeping max instances at 3.
6. Image egress: keep thumbnails ≤ 40 KB; never load `url` in lists.
Scale-up triggers remain those in `free-tier-budget` §6 (Firestore > 1.5M reads/day ≈ 6.5k DAU on this model, or bill > $30/month ≈ 2.4k DAU on the 2026-10-23 ADR-0022 table in §5).

## 7. Prices used (verified 2026-10-23, ADR-0022; sources and URLs in `docs/plans/credit-runway-cost-model.md` §1b)
Replaces the 2026-09-26 upper-bound prices from memory. Verify again before each stage change and after any Google pricing notice.
- Firestore **asia-south1 (Mumbai)**: $0.035 / 100k reads, $0.104 / 100k writes, $0.012 / 100k deletes (TTL deletes the same price, no free quota), $0.104 / GiB-month storage, backup $0.035 / GiB-month, restore $0.23 / GiB. Free 50k reads, 20k writes, 20k deletes per day and 1 GiB. (Was $0.06 / $0.18 / $0.02 / $0.18 upper bounds.)
- Cloud Run (request-based, asia-south1 is Tier 1): $0.000024 / vCPU-s active, $0.0000025 / vCPU-s idle min instance, $0.0000025 / GiB-s, $0.40 / million requests. Free 2M requests, 180,000 vCPU-s, 360,000 GiB-s per billing account, applied as a Tier 1 spend discount. Idle non-minimum instances and IAM-denied requests are not billed.
- Internet egress to India (Cloud Run, GCS): $0.12 / GiB, **always billed**: Cloud Run's free 1 GiB is North America only, and GCS's free 100 GB applies to egress from North America.
- GCS Standard us-central1: Class A $0.005 / 1k, Class B $0.0004 / 1k, $0.020 / GB-month.
- Cloud Vision SafeSearch: first 1,000 units / month free, then $1.50 / 1,000 units. **2 units per image** (full image + thumbnail, `VISION_SCREEN_THUMB=true`; verified in `backend/internal/media/service.go` `finalizeOne`). Cap-exhaustion DAU for a 10,000 cap = 10,000 / 12.17 units per DAU-month = about 820 (1,000 free units run out at about 82 DAU).
- Cloud Monitoring alerting: not charged before 2027-09-01; billing, quota and uptime-metric policies are not charged; 1M uptime executions free.
- Firebase Hosting: $0.15 / GB beyond 360 MB/day, 10 GB storage free then $0.026 / GB.
- Currency: INR 95.0 per USD (assumption, mid-market 94.955 on 2026-10-23), +/-5% sensitivity; GST 18% not included.

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
- **Posts and timeline (T25).** Same form as the graph query above. Fields on the request line: `rpc`, `fs_reads`, `fs_writes`, `fs_deletes`, `posts_op`
  (`create|get|delete`), `outcome` (`created|replay|found|not_found|deleted|noop:not_owner|rejected:<reason>`), `timeline_op` (`home|user`), `timeline_mode`
  (`cold|refresh|older|gap`), `page_size`, `graph_cache_hit`, `timeline_chunks`, `authors_from_cache`, `items_returned`, `read_budget_spent`.
  - **Reads by RPC, Post and Timeline:** `jsonPayload.rpc=~"PostService|TimelineService" | sum fs_reads by rpc`
    (Log Analytics form, only if enabled; it is not at Stage 0: `SELECT JSON_VALUE(json_payload.rpc) AS rpc, SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) AS reads, COUNT(*) AS calls ... WHERE JSON_VALUE(json_payload.rpc) LIKE '%PostService%' OR JSON_VALUE(json_payload.rpc) LIKE '%TimelineService%' GROUP BY rpc`).
  - By operation: `jsonPayload.posts_op!="" | sum fs_reads by posts_op` and `jsonPayload.timeline_op!="" | sum fs_reads by timeline_op, timeline_mode` (split `outcome` for posts).
  - The T25 revisit signal: mean `fs_reads` where `timeline_mode="older"` over 7 days, against 40 (modelled) and 30 (ADR). Above 1.4 x `page_size` means apply the k lever.
  - Per-user spread: `jsonPayload.read_budget_spent` (never a body or text; `uid_hash` only).
- **Notifications fan-out (N-1/N-2 hardening).** The Pub/Sub push handler's per-delivery line (`message="notification_delivery"`) now carries `rpc="internal.NotificationsFanout"`, `fanout_fs_reads` (equal to `fs_reads`, kept as its own project-level field), `push_throttled` and `created`/`pushed`; `make cost` prints `fanout_fs_reads`. **Totals:** daily Firestore reads = `sum(fs_reads) + sum(removal_log_reads)`; `removal_log_reads` (the detached shared removal-log refresh on `since_token` timeline refreshes) is logged separately and is not in `fs_reads`, while `fanout_fs_reads` duplicates `fs_reads` on the fan-out line and must not be added again. `make cost` prints both columns. Fan-out reads: `jsonPayload.rpc="internal.NotificationsFanout" | sum fanout_fs_reads`. Producer-side drops: `jsonPayload.message="notification_fanout_capped"` (count by `actor_hash`).
- No new log-based metric or alert policy. The existing "reads > 40k/day" alert fires at ≈ 207 DAU for the released scope (≈ 174 whole product).


## 10. Daily gross burn against the credit-runway line (2026-10-23 ADR-0022)
ADR-0022 funds a bounded window from the Google credit: `credit_spend_cap_inr` = INR 23,000 from 2026-10-23, paused on 2026-12-24 unless a RESUMED ADR is approved (cap formula `min(23,000, remaining credit - 2,000)`).
- **Straight line to the budget end (2026-12-26, 64 days):** 23,000 / 64 = **INR 359 per day** (359.4).
- **Straight line to the planned pause (2026-12-24, 62 days):** 23,000 / 62 = **INR 371 per day** (371.0). This is the line the ADR and `credit-runway-cost-model.md` §4 use; the cumulative line on day N is 371 x N.
- **Expected burn (credit mode, model):** about INR 31 per day at ~0 DAU, 45 at 300 DAU, 94 at 1,000 DAU, 267 at 3,000 DAU (cumulative 71% of the cap at 3,000 DAU by 12-24). Stage 0 as configured: 14 / 53 / 112 per day. Anything above the line means a knob or traffic is wrong, not that the plan is working.
- **How to read it (2 minutes a day, founder or sre-performance):** Cloud Console > Billing > Reports, billing account scope (not a project), date range 2026-10-23 to today, **Group by SKU**, in the Credits filter untick everything so the view is gross (promotional credit must not be subtracted, otherwise every figure reads INR 0). Currency INR. Read the cumulative total and divide by days elapsed, then compare with 371 x day. The SKUs that explain a miss: Cloud Run `CPU Allocation Time` / `Memory Allocation Time` and the min-instance (idle) SKUs, `Cloud Vision` SafeSearch units, Firestore `Read Operations` / `Write Operations` in Mumbai, `Networking` internet egress, Cloud Storage `Class B Operations`. Billing data lags by hours to more than a day, so the fast signals are the request-count alert and `make cost` (below), not this report.
- **Vision units:** `make cost PROJECT_ID=dzeroth-prod` prints units used this month (Firestore `admin/vision-YYYYMM` field `units`, UTC month) against `VISION_MONTHLY_CAP`, and units today (sum of `vision_units` on FinalizeUpload request lines since 00:00 UTC). Without gcloud/Firestore credentials it prints `needs gcloud/Firestore credentials` and exits 0 (`scripts/cost-vision.sh`). Each unit past the first 1,000 a month is INR 0.1425 (1.50 USD per 1,000 x 95).
- **Thresholds** on the credit budget are 10 / 25 / 50 / 75 / 90 / 100% of the cap (2026-10-29, 11-07, 11-23, 12-08, 12-17, 12-24 on the straight line); an alert that arrives earlier than its date is the trigger to look the same day (`docs/adr/0022-credit-funded-runway.md`).
- Weekly: append the cumulative gross burn, the line value for that day and the top 3 SKUs to §8 (Bill column).