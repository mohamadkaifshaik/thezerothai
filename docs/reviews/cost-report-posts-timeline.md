# Cost report — posts and timelines (P0 + P1)
Owner: sre-performance. Date: 2026-10-06. Ticket: `docs/plans/posts-and-timeline.md` T25. Method: `free-tier-budget` §2.
Status: **Re-based on emulator measurements. One planning value is above the 25% line (older page); the ADR-0010 revisit is triggered and the k lever is flagged for P9. Everything else is within 25% or explained.**

## How this was measured (and what was not)
- **Measured:** Firestore emulator, `go test -tags=integration` through `firebase emulators:exec`, reading `budget.Counter` reads/writes/deletes per call
  (the same number `fs_reads`/`fs_writes`/`fs_deletes` log) and the per-request JSON log lines of `e2e/TestE2E_PostsSmoke_FollowPostTimelinesDelete`.
  All suites passed (`internal/posts`, `internal/timeline/integration`, `e2e` posts smoke).
- **Scenarios the existing tests do not log** (warm/cold splits, mentions, older-page walks, refresh with N new posts, settle, user-timeline pages) were measured with
  throwaway Go tests added through `go test -overlay`. They are not in the repo and no production code or repo test file was changed.
- **Counts exclude the `AccountStatusInterceptor` read** unless stated: the tests call the handler below the interceptors. The interceptor's unit cost
  (1 read cold, 0 warm) is confirmed by the e2e log lines (CreatePost B logged 3 = idempotency + quotas + interceptor; home with F = 1 logged 3 = graph + 1 chunk + interceptor).
- The emulator is deterministic, so repeat runs give the same value: "mean" in the acceptance criterion equals the measured value for each scenario.
- **Not measured:** real traffic, real instance cache hit rates (the model's ~50% is an assumption), the call mix per DAU (60 new posts/DAU, 8 refreshes/DAU), the settle
  frequency, Cloud Run CPU/latency on dev (no cloud access), Firestore prices (§7 upper bounds, unverified). Emulator latency is indicative only and is not used.
- No k6 (not installed). The seeded feeds are synthetic: "dense" = every one of 60 followees has 15 posts; "mixed" = one third have 20, one third have 3, one third have none.

## 1. Measured vs planning (reads per call, excluding the interceptor)
| RPC / case | ADR-0010 planning | Measured | Diff | Verdict |
|---|---|---|---|---|
| CreatePost, no mention, instance warm | 2.5 (blend) | **2** reads, 4 writes, 0 deletes (10 of 10 calls) | -20% | Within 25%. 2.5 is the blend with mentions. |
| CreatePost, mentions, handles cached / uncached | | 2 / **2 + 1 per uncached handle** (cold instance: 3 plain, 5 with 2 mentions) | | Blend at 30% mentions, ~50% handle misses = 2.2 (derived). 2.5 is within 14%. Model now **2.2**. |
| CreatePost replay (same body) / key reused | 1 warm | **1** warm; 3 on a cold instance (users + idempotency + post); reused key cold 2; 0 writes | 0% | Matches. |
| DeletePost own post | 1 | **0** warm (post cached on the writing instance), **1** cold, 1 for a no-op or another user's post; writes 1, deletes 1 (0 / 0 on no-op) | planning is the cold value | Difference explained: deletes are rare and often hit a different instance, so the cold 1 is kept. 0.05 calls/DAU, immaterial. |
| GetPost | 1 | **0** warm, **1** post miss with author and graph warm, **3** fully cold (post + author + caller graph) | 0% on the opened-from-feed case | Within 25% for the feed case. If every open were fully cold it would be 3 (+0.4 reads/DAU at a 50% mix: 1.5 vs 1, flagged as an assumption, immaterial at 1 call/DAU). |
| GetUserTimeline cold page 20 | ceiling 22 | **22** (2 + p; the author has 20+ posts) | 0% | Matches the ceiling. |
| GetUserTimeline warm first page | 0 | **0** | 0% | Matches. |
| GetUserTimeline page 2: same instance / cold instance | | **20** / **22** | | Page 2 is a fresh query (the author-recent cache holds page 1 only). |
| GetUserTimeline refresh, 0 new: cold / same instance | 3 (+1 interceptor = 4) | **3** / **0** | 0% | Matches. |
| GetUserTimeline p = 50, 45 posts | ceiling 52 | **47** (2 + 45) | | Under the ceiling. |
| GetUserTimeline per call (blend) | 11 | 22 cold first page, 0 warm first page, 20-22 page 2, 3 or 0-1 refresh: a 50/50 cold/warm mix is 11 (derived) | 0% | Within 25%. The mix is an assumption. |
| Home refresh, 0 new, F = 60 | 4 overhead | **4** graph cold + authors cold, **3** graph warm, **2** same instance as the open (two chunks covered by author-recent) | 0 to -50% | Planning 4 equals the fully cold case; a mean of 3 would be -25%. Kept at 4 because refreshes are >= 60 s apart and the graph TTL is <= 60 s. |
| Home refresh with N new posts (cold instance) | 4 + new posts | N = 1: **4**; N = 8: **10**; N = 20: **22** (graph warm: 3, 9, 21) | 0% | **+1 read per returned post** (an empty chunk query is replaced by a returned doc). 60 posts/DAU = 60 reads/DAU. The 60 is an input. |
| Settle re-read (D13) | 0.1 per refresh (= 1.0/DAU) | unit cost **+1 read per re-delivered post** (20 posts re-delivered by the next refresh: 21 reads vs 22; 21 again after 15 s, then 3). Frequency is **derived**, not measured | n/a | Uniform arrivals give about 0.01 re-reads per refresh, bursty about 0.03, so 1.0/DAU is an upper bound. Kept. |
| **Home older page, F = 60, page 20** | **30** | **40** (mixed feed, constant over 8 pages), **42** (dense feed, 8 pages), **43** on a cold instance | **+33% / +40%** | **Above 25%: ADR-0010 revisit triggered.** See §3. |
| Home cold open, F = 60, page 20 | 30 | **30** (mixed), **43** (dense) | 0% / +43% | Midpoint 36.5 used (+22%, within 25%). The dense feed is the ceiling shape (43 = 1 graph + 3 chunks x 14). |
| Home, F = 5,000, page 50 | ceiling 269 (268 asserted) | **168** (+1 interceptor = 169) | -37% below the ceiling | A ceiling, not a planning value. The seeded graph has 8 real authors, so most chunks return 1 read. Assertion passes. |
| `AccountStatusInterceptor` caller read | 10.6 reads/DAU | unit measured: **1** cold, **0** warm; mix derived (1 per home refresh, 0.5 on the other 5.15 requests) | n/a | The mix is an assumption (no traffic). A successful CreatePost evicts the author's profile, so the next call pays 1. |

**Why the older page is 40, not 30.** `homeAuthors` is self + 60 followees sorted, so chunk 1 is self + 29, chunk 2 is 30, chunk 3 is 1 author. With 3 chunks
k = ceil(2 x 20 / 3) = 14 and each full chunk reads 14: 42. After a cold open the 1-author chunk is covered by author-recent, so 2 chunks run at k = 20: 40.
Planning 30 assumed two dense chunks and one sparse one (14 + 14 + ~2). A feed where most followees have deep history is exactly the older-page case.

## 2. Per-DAU numbers with measured values (reads per DAU per day)
| Row | calls/DAU | reads/call | reads/DAU | ADR-0010 | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|
| CreatePost | 1.0 | 2.2 | 2.2 | 2.5 | 4.0 | 1.0 |
| DeletePost | 0.05 | 1 | 0.05 | 0.05 | 0.05 | 0.05 |
| GetPost | 1 | 1 | 1.0 | 1.0 | 0 | 0 |
| GetUserTimeline | 2 | 11 | 22.0 | 22.0 | 0 | 0 |
| Home refresh overhead | 8 | 4 | 32.0 | 32.0 | 0 | 0 |
| Home new posts | 60 posts | 1 | 60.0 | 60.0 | 0 | 0 |
| Settle re-reads | 8 | 0.125 | 1.0 | 1.0 | 0 | 0 |
| Home older page | 1 | **40** | **40.0** | 30.0 | 0 | 0 |
| Home cold open | 0.1 | 36.5 | 3.65 | 3.0 | 0 | 0 |
| Interceptor line | 13.15 req | | 10.6 | 10.6 | 0 | 0 |
| **Posts + timeline** | **13.15 req** | | **172.5** | **162.2** | **4.05** | **1.05** |

`userLikes` is not in any timeline row: the code reads no likes until P5, so the model carries no such line.

## 3. ADR-0010 forecast vs re-based (released scope and whole product)
Released scope = v0.2.0 (20.4 R, 3.1 W, 0.1 D, 11.3 req) + posts/timeline above.
| | ADR-0010 forecast | Re-based | Diff |
|---|---|---|---|
| Reads per DAU | 182.6 | **192.9** | **+5.6%** |
| Writes per DAU / deletes / requests | 7.15 / 1.15 / 24.45 | 7.15 / 1.15 / 24.45 | 0% |
| Reads at 300 DAU | 54.8k, 110% of free | **57.9k, 116% of free** | +5.6% |
| Free reads run out at | ≈ 274 DAU | **≈ 259 DAU** | -5.5% |
| 80% line (40k reads/day) | ≈ 219 DAU | **≈ 207 DAU** | -5.5% |
| Overage at 300 DAU | 4.8k reads/day, ≈ $0.09/month | **7.9k reads/day, ≈ $0.14/month** | reads over free +64%, dollars +$0.05 |
| 2x the crossover (518 DAU) / 10x (2,590 DAU), reads only | $0.90 / $8.10 | $0.90 / $8.10 | by construction (overage = quota x 30 x price) |
| Writes run out at | ≈ 2,800 DAU | ≈ 2,800 DAU | 0% |

- **Reads per DAU are within 25% of the ADR (+5.6%).** The overage in dollars exceeds the ADR's forecast by more than 25% (+64%), only because overage is the small
  difference between two nearly equal numbers (57.9k vs 50k). It is 5 cents a month and stays inside founder decision D1 (accept pay-per-use). It is flagged
  because the cause is a single planning value that is above 25%.
- **Lever named: the `k` over-read factor** (ADR-0010 reserve lever, `2p` to `1.5p`). Its stated trigger, "older-page reads > 1.4 x page size" (28 at p = 20), has fired:
  40 and 42 = 2.0 x and 2.1 x. **Derived, not measured:** two chunks at k = 15 instead of 20 read about 30, saving ≈ 10 reads per older page and ≈ 10 reads/DAU (192.9 back to ≈ 183,
  i.e. the ADR forecast, ≈ $0.09). It tunes a constant and does not reopen the algorithm. Not applied here (T25 does not touch production code). **Flag for P9** with real
  `timeline_mode="older"` data, and re-run the timeline budget tests after any change. Caveat: the emulator feed is synthetic; a production feed with shallow history reads less.
- **Whole product** (adds the unreleased `[planned]` GetThread, likes, notifications): 230.0 reads/DAU (the ADR said "≈ 215": its own planning values sum to ≈ 220 with the rows
  in `cost-model.md`; the measured values add +10.3). Reads cross the 80% line at ≈ 174 DAU and the free quota at ≈ 217 DAU; at 300 DAU that is 69.0k reads/day, ≈ $0.34/month.
  Not a gate for this release.

## 4. Quotas for the released scope at 300 DAU
| Quota | Per DAU | At 300 DAU | % of free | Runs out at | Verdict |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | 192.9 | 57.9k | **116%** | ≈ 259 DAU (80% line ≈ 207) | **Over the 80% line, as the ADR predicted; D1 applies** |
| Firestore writes (20k/day) | 7.15 | 2.1k | 11% | ≈ 2,800 DAU | PASS |
| Firestore deletes (20k/day) | 1.15 | 0.35k | 2% | ≈ 17,000 DAU | PASS |
| Cloud Run requests (2M/month, shared) | 24.45 | 220k/month | 11% | ≈ 2,690 DAU | PASS |
| Cloud Run vCPU-s (180k/month) | 2.45 | 22k/month | 12% | ≈ 2,450 DAU | PASS |

**Pass/fail:** per-RPC budgets hold (every ceiling assertion passed; no RPC exceeded its documented worst case). The 80%-of-quota check fails at 300 DAU on reads, as ADR-0010 already states
("approved plan" = D1 plus the levers in `cost-model.md` §6). It first matters at ≈ 207 DAU, when the existing 40k-reads alert starts to fire: the planned signal, not an incident.

## 5. Abuse bound added to `cost-model.md` §4 (from ADR-0010 D5; derived, not load-tested)
| Actor | Reads |
|---|---|
| Unverified (minted) account, any RPC | **0** |
| One verified account, one instance lifetime | **2,308** |
| One verified account, one day, steady state (<= 3 instances) | **<= 6,924** (13.8% of free, ≈ $0.004) |
| Rollout day (<= 6 instances) | <= 13,848 |
| Idle cycling (<= 90 lifetimes) | ≈ 208k (≈ $0.12) |
| Deliberate instance churn, ceiling (<= 270 lifetimes) | **≈ 623k per day** (≈ $0.37/day) |
The largest single measured call (F = 5,000 home) is 168, under the in-flight hold of 269, so no legitimate call is rejected by the hold.

## 6. Fixed cost and cost-guard
- New GCP service, API, Terraform resource, Pub/Sub topic, Scheduler job or secret: **none**. No always-on resource. Cloud Run stays min 0 / max 3.
- No code, Terraform or test file changed in this ticket.

## 7. Dashboard
`cost-model.md` §9 carries the Logs Explorer query: `jsonPayload.rpc=~"PostService|TimelineService" | sum fs_reads by rpc`, with `posts_op` / `timeline_op` / `timeline_mode`
variants and the older-page revisit signal. No log-based metric, no new alert policy.

## 8. Open items
1. **P9:** measure `timeline_mode="older"` `fs_reads` on real traffic; if it stays above 1.4 x `page_size`, ask the architect/backend to lower the k factor (`2p` to `1.5p`), then re-run the budget tests.
2. Cache hit rates, new posts/DAU (60), refreshes/DAU (8) and the interceptor mix are assumptions until the first 100 users (`cost-model.md` §8 actuals).
3. Prices in `cost-model.md` §7 are unverified upper bounds; every dollar figure here inherits that.
4. Cold start, p95 on dev and Cloud Run tuning belong to the dev smoke (T26/T27); not measured here.
5. A cloud smoke would add reads against real Firestore: none was run.
