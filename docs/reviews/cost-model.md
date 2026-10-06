# Cost model — v0.3 (design estimate; Graph and Posts/Timeline rows use emulator-measured numbers, no production data yet)
Owner: sre-performance (maintains actuals weekly). Seeded by: architect, 2026-09-26, from ADR-0002…0007 and the protos.
Updated 2026-09-30 (T21): Graph rows re-based on `docs/reviews/loadtest-graph.md` (T18) and the T16a/T16b `budgettest` ceilings; see `cost-report-v0.2.0.md` §Graph.
Updated 2026-10-06 (posts-and-timeline T25): Post/Timeline rows re-based on emulator measurements; see `cost-report-posts-timeline.md`. Whole product 191 to 230.0 reads/DAU (released scope 192.9; ADR-0010 forecast 182.6).
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
300-DAU target costs ≈ 19.0k reads/day over → ≈ **$0.34/month** at the upper-bound read price (was $0.13). Still pay-per-use with no step change, but the
"$0 up to 300 DAU" goal is **not** met on reads without the §6 levers. Writes stay free to ~630 DAU (was ~614); deletes to ~2,600 DAU.
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
| Overage at 300 DAU | 4.8k reads/day, ≈ $0.09/month | **7.9k reads/day, ≈ $0.14/month** | **+64% in dollars (+3.1k reads/day, +$0.05)** |
The reads figure is within 25% of the ADR. The dollar figure is not, only because overage is the small difference between two close numbers; it is 5 cents. It is
still inside founder decision D1 (pay-per-use), but the cause is one planning value above 25% (older page, +33%), so the k lever is flagged for P9 and the ADR-0010
revisit is triggered (`cost-report-posts-timeline.md`). At 300 DAU the identity + graph + posts scope costs 57.9k reads against a 40k alert threshold.
Writes: 2.1k/day at 300 DAU (11%), free to ~2,800 DAU. v0.2.0 (identity + graph only) is unchanged: 20.4 reads, ≈ 2,450 DAU.

## 4. Every free quota: where it runs out, and overage at 2× / 10× that DAU
Overage is for that line alone. Prices are the upper-bound list prices in §7 — **verify** before relying on them.
| Quota (free per month) | Usage per DAU-month | Runs out at DAU | Overage $/month at 2× | at 10× |
|---|---|---|---|---|
| Firestore reads (1.5M = 50k/day) | 6,902 | **217** | $0.90 | $8.10 |
| Firestore writes (600k = 20k/day) | 952 | 630 | $1.08 | $9.72 |
| Firestore deletes (600k = 20k/day) | 230 | 2,614 | $0.12 | $1.08 |
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

### Read budget as an abuse bound (ADR-0010 D5 as amended; posts-and-timeline T24/T25)
The read-budget counters live in instance memory, so every bound is **per instance lifetime**. Numbers are the ADR/plan bounds (derived, not load-tested here).
The measured per-call costs above stay under them: the largest single call, F = 5,000 home, measures 168 reads against the in-flight hold M = 269.
| Actor | Bound | Reads | $ at the §7 upper-bound price |
|---|---|---|---|
| Unverified (minted) password account, any RPC | 0-read verified-identity gate (`PROFILE_REQUIRED` / `EMAIL_NOT_VERIFIED` from token claims) | **0** | $0 |
| One verified account, one instance lifetime | `READ_BUDGET_PER_UID_PER_DAY` 2,000 + in-flight hold 269 - 1 | **2,308** | $0.0014 |
| One verified account, a day, steady state (<= 3 instances) | 3 x 2,308 | **<= 6,924** (13.8% of free) | ≈ $0.004 |
| Same, rollout day (<= 6 instances) | 6 x 2,308 | <= 13,848 | ≈ $0.008 |
| Same, idle cycling (<= 90 lifetimes/day) | 90 x 2,308 | ≈ 208k | ≈ $0.12 |
| **Deliberate instance churn (residual R2), ceiling** (<= 270 lifetimes/day) | 270 x 2,308 | **≈ 623k per day** | ≈ $0.37/day |
| Verified sybils (residual R1) | per account x accounts | ≈ 8 accounts exhaust a day's free reads | ≈ $0.004/day each |
Detect with `jsonPayload.limit_name` (`read_budget_daily`, `read_budget_inflight`) split by `read_budget_key`, and the `read_budget_spent` field on every request
line; levers are in `docs/runbooks/abuse-spike.md` (T26). The bound is a hard stop on reads only for the account; the cost is cents, not a step change.

## 5. Whole bill by DAU (Vision: every image screened, paid past 1,000/month, capped at 10,000 — ADR-0005, founder 2026-09-27)
| DAU | Firestore | Cloud Run (req + CPU + egress) | GCS (ops + egress) | Hosting | SafeSearch | **Total/month** |
|---|---|---|---|---|---|---|
| 100 | $0 | $0.08 (egress) | $0.02 | $0 | $0 | **≈ $0.10** |
| 300 | $0.34 | $0.24 | $0.10 | $0 | $1.20 | **≈ $1.88** |
| 600 | $1.58 | $0.48 | $0.25 | $0 | $3.90 | **≈ $6.21** |
| 1,000 | $3.87 | $0.79 | $0.45 | $0 | $7.50 | **≈ $12.61** |
| 3,000 | $15.60 | $6.62 | $6.30 | $0.16 | $13.50 (cap hit) | **≈ $42.18** |
Plus prod Firestore weekly backups (ADR-0007): storage-priced, cents/month at < 1 GiB.
Nothing in this table is a fixed fee; every line falls back to $0 with traffic. With paid SafeSearch the $5 budget
alert (ADR-0007) fires at ≈ 520 DAU (was ≈ 550) — consider raising the budget amount then (config change, not an ADR).

## 6. Levers, cheapest first (use before any Stage 2 ADR)
0. **Older-page over-read: k from `2p` to `1.5p` (ADR-0010 reserve lever; its trigger has fired, older page = 2.0 x page).** Derived, not measured: two chunks at k = 15 instead of 20 saves ≈ 10 reads per older page, so ≈ -10 reads/DAU (back to ≈ 183 released). Needs a one-constant backend change and a re-run of the timeline budget tests; flagged for P9.
1. Notifications list via `since` + client cache (like the timeline): −15 reads/DAU → reads free to ~250 DAU.
2. GetThread first page 10 instead of 20; lazy "show replies": −5 reads/DAU.
3. Older-page prefetch only after the user scrolls past 70% (never on open): −5…10 reads/DAU.
4. Like notifications collapsed per post per hour (update one doc): writes/like 4 → ~3.3 at scale.
5. Cloud Run CPU: gzip and binary proto (already), avoid per-request allocations in the merge; raise concurrency
   overlap by keeping max instances at 3.
6. Image egress: keep thumbnails ≤ 40 KB; never load `url` in lists.
Scale-up triggers remain those in `free-tier-budget` §6 (Firestore > 1.5M reads/day ≈ 6.5k DAU on this model, or bill > $30/month ≈ 2.2k DAU).

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
- **Posts and timeline (T25).** Same form as the graph query above. Fields on the request line: `rpc`, `fs_reads`, `fs_writes`, `fs_deletes`, `posts_op`
  (`create|get|delete`), `outcome` (`created|replay|found|not_found|deleted|noop:not_owner|rejected:<reason>`), `timeline_op` (`home|user`), `timeline_mode`
  (`cold|refresh|older|gap`), `page_size`, `graph_cache_hit`, `timeline_chunks`, `authors_from_cache`, `items_returned`, `read_budget_spent`.
  - **Reads by RPC, Post and Timeline:** `jsonPayload.rpc=~"PostService|TimelineService" | sum fs_reads by rpc`
    (Log Analytics form, only if enabled; it is not at Stage 0: `SELECT JSON_VALUE(json_payload.rpc) AS rpc, SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) AS reads, COUNT(*) AS calls ... WHERE JSON_VALUE(json_payload.rpc) LIKE '%PostService%' OR JSON_VALUE(json_payload.rpc) LIKE '%TimelineService%' GROUP BY rpc`).
  - By operation: `jsonPayload.posts_op!="" | sum fs_reads by posts_op` and `jsonPayload.timeline_op!="" | sum fs_reads by timeline_op, timeline_mode` (split `outcome` for posts).
  - The T25 revisit signal: mean `fs_reads` where `timeline_mode="older"` over 7 days, against 40 (modelled) and 30 (ADR). Above 1.4 x `page_size` means apply the k lever.
  - Per-user spread: `jsonPayload.read_budget_spent` (never a body or text; `uid_hash` only).
- No new log-based metric or alert policy. The existing "reads > 40k/day" alert fires at ≈ 207 DAU for the released scope (≈ 174 whole product).
