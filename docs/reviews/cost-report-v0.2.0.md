# Cost report — v0.2.0 (identity + social graph)
Owner: sre-performance. Date: 2026-09-30. Ticket: `docs/plans/graph.md` T21. Method: `free-tier-budget` §2.
Status: **Graph section complete. The Identity baseline is carried over from `release-v0.1.0-readiness.md` §3. Other
sections (Cloud Run tuning, cold start on dev, actuals) are added by T24/T25 and are not covered here.**

Inputs: `docs/reviews/loadtest-graph.md` (T18 k6 on emulators), T16a/T16b `budgettest` ceilings, ADR-0008 plus the
2026-09-30 amendment (A2 cold/warm table). `docs/reviews/test-report-graph.md` (T17): **pending, not yet written; not
referenced for any number here.** Everything is emulator-measured or a stated planning value. No cloud access was used.

## Graph: per-RPC measured vs budget
Reads shown are per call as logged in `fs_reads` (includes the caller's `AccountStatusInterceptor` profile read).

| RPC | Budget (ADR-0008 A2) | Measured | Verdict |
|---|---|---|---|
| Follow (created) | 4 cold / 2 warm / **3 planning**; 5 writes | **3.96 mean, 3.98 follow-only, max 4**; 5 writes / 0 deletes; p95 7.5-20.2 ms (limit 500) | **Over the planning value (3), at the cold ceiling (4).** Within the documented worst. |
| Unfollow | 0 reads, 3 writes, 1 delete | **1.00 read** (all calls), 3 writes / 1 delete | **Logged reads exceed the 0 in the table.** The RPC's own batch is 0; the 1 is the interceptor read after Follow's `Forget`. |
| ListFollowers, page 20 | 102 (page 50) worst; **30 planning** | **20.16 mean warm** (max 42; cold 40-42); p95 17.1 ms (limit 400) | Within the planning value on the warm pool. Cold 41 is above 30. |
| GetRelationships, 20 ids | 1 cold / 0 warm / 0.5 planning | **0.11 mean** (563 of 601 calls 0 reads; max 2) | Within budget on mean. Max 2 exceeds the documented 1 (cold caller profile + graph doc): footnote. |
| Block / Unblock / Mute / Unmute | 3 / 1 / 3 (after T26; 2 until then) / 1 reads | T16a `budgettest` ceilings pass; **not in the k6 run** | Not load-measured; 0.05 calls/DAU total. |

Deviations (stated plainly, not tuned away):
1. **Follow is ~4 reads/call, plan said 3.** After a successful Follow, `directory.Forget(caller, target)` evicts both
   profiles, and the interceptor re-reads the caller on the next call. With max 3 instances and scale-to-zero the
   "target warm" assumption in A2 rarely holds. Model now uses **4** (+0.5 reads/DAU).
2. **Unfollow logs 1 read, plan said 0.** Same interceptor read. Model uses 1 (+0.1 reads/DAU).
3. **ListFollowers is 20.16 warm and 40-42 cold.** The warm figure comes from a 100-caller / 5-target pool that stays
   resident. Model uses **30.5** (midpoint; matches the ~50% hit-rate assumption in `cost-model.md` §1).
4. The A2 revisit trigger (lower the planning value if prod Follow averages < 2.5 reads/call) points the other way on
   emulator data: the planning value should go **up** to 4. The T25 post-release `graph_cache_hit` data decides.
   Architect call: amend A2, or take optional T30 (update cached profiles in place instead of `Forget`), which would
   bring Follow back toward 2-3.

## Graph: per-DAU numbers (measured values substituted)
| Row | calls/DAU/day | reads/call | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|
| Follow | 0.5 | 4 | 2.0 | 2.5 | 0 |
| Unfollow | 0.1 | 1 | 0.1 | 0.3 | 0.1 |
| GetRelationships | 3 | 0.5 | 1.5 | 0 | 0 |
| ListFollowers / ListFollowing | 0.3 | 30.5 | 9.15 | 0 | 0 |
| Block | 0.02 | 3 | 0.06 | 0.06 | ~0 |
| Unblock | 0.005 | 1 | 0.005 | 0.01 | 0 |
| Mute | 0.02 | 3 | 0.06 | 0.04 | 0 |
| Unmute | 0.005 | 1 | 0.005 | ~0.005 | 0 |
| ListBlockedUsers / ListMutedUsers | 0.02 | 10 | 0.2 | 0 | 0 |
| **Graph total** | **≈ 4.0 req** | | **13.1** (ADR-0008 A2: 12.3) | **2.9** | **0.1** |

Identity baseline (v0.1.0 readiness §3): 7.3 reads, 0.17 writes, 0 deletes, ~7.3 requests per DAU. Graph's changes to
GetMe/GetProfile are ±0. Graph's Follow/Unfollow interceptor read is possibly double-counted against this baseline
(conservative).

## Daily totals at 300 DAU (identity + graph, as released in v0.2.0)
| Quota | Identity | Graph | Total per DAU | At 300 DAU | % of free quota | % of the 80% line | Verdict |
|---|---|---|---|---|---|---|---|
| Firestore reads (50k/day) | 7.3 | 13.1 | 20.4 | **6.1k** | **12.2%** | 15.3% | **PASS** (limit 80%) |
| Firestore writes (20k/day) | 0.17 | 2.9 | 3.1 | **0.93k** | **4.6%** | 5.8% | **PASS** |
| Firestore deletes (20k/day) | 0 | 0.1 | 0.1 | **30** | **0.15%** | 0.2% | **PASS** |
| Cloud Run requests (2M/month, shared) | ~7.3 | ~4.0 | ~11.3 | ≈ 102k/month, plus uptime/CI (~52k per env) | ≈ 8% | | PASS |

Sensitivities (all still PASS):
- Every graph cache cold (Follow 4, Unfollow 1, lists 41, GetRelationships 1): graph 17.7 reads/DAU, total 25.0, 7.5k
  reads/day at 300 DAU = **15%** of quota.
- Identity at its documented worst (20.3): 20.3 + 13.1 = 33.4, 10.0k reads/day = **20%** of quota.
- Launch burst of 300 new profiles: identity 900 writes; total writes ≈ 1.6k = 8%.

**Result: within 80% on every Firestore dimension at 300 DAU, with large headroom (reads at 15% of the 80% line).**

Quota exhaustion for identity + graph (reads are still the binding limit):
| Quota | Runs out at | 80% line at | $/month at 2× that DAU | at 10× |
|---|---|---|---|---|
| Firestore reads | **≈ 2,450 DAU** (50k / 20.4) | ≈ 1,960 | $0.90 (reads only) | $8.10 |
| Firestore writes | ≈ 6,480 DAU | ≈ 5,190 | $1.08 | $9.72 |
| Firestore deletes | > 100k DAU | | $0 | ~$0 |

(The ADR-0008 amendment estimated 2,550 / 2,040 with 19.6 reads/DAU; the difference is Follow 4, Unfollow 1, lists 30.5.)

**Whole-product crossover restated** (`cost-model.md` §3): including the `[planned]` likes, notifications and timeline
rows, graph moves 10.2 to 13.1 reads/DAU, so the total is ≈ 191 reads/DAU. Reads cross the 80% line at **~210 DAU**
(was ~213; ADR-0008 predicted ~210) and the full quota at **~262 DAU** (was ~266). At 300 DAU the whole product is 57.3k
reads, 115% of quota, ≈ $0.13/month overage. That comes from the unreleased engagement/timeline rows and is **not a
v0.2.0 gate**; the identity + graph criterion passes. It stays an open finding in `cost-model.md` §3 with the §6 levers.

## Abuse bounds (per abusive account per day, measured per-call costs)
| Vector | Control | Worst per account/day |
|---|---|---|
| Follow spam or follow/unfollow churn | `follows` quota 200/day (new accounts 50), Follow bucket 30/min; `graph_mutation_daily` cap 500/day/instance | 200 Follow (4 reads, 5 writes) + 200 Unfollow (1 read, 3 writes, 1 delete) = **1.0k reads, 1.6k writes (8% of writes), 200 deletes** |
| Block/unblock/mute churn | `blocks` quota 200/day (new 50), bucket 20/min | 200 × (3 reads, 5 writes) + 200 × (1 read, 2 writes) = **0.8k reads, 1.4k writes (7%)** |
| Mutation replay loop under the daily cap | 500 mutations/day | ≤ 500 × 4 reads ≈ **2k reads** (ADR bound ≤ 6k counts 3 instances) |
| List scraping | bucket 20/min + 100 list calls per uid per day per instance (max 3 instances) | page 50: 300 × 102 = **30.6k reads (61% of daily free)**. Page 20, measured cold 42: 300 × 42 = **12.6k (25%)** |
| Relationship enumeration | GetRelationships reads only the caller's graph | 0 extra reads |

- One abusive account cannot breach the free read quota with page 20, and can reach 61% with page 50. Several accounts
  can. That costs cents (≈ $0.06 per 100k reads over quota at list price), not dollars.
- Detection: per-RPC `fs_reads` logs, the reads > 40k/day alert, budget emails. Response: `docs/runbooks/abuse-spike.md`.
- Lever if needed: cap `page_size` at 20 when listing other users (worst case about 12.6k).
- Not verified: the daily caps are per instance and in memory, so a scale-to-zero restart resets them (ADR-0006).

## Fixed cost and cost-guard
- **New GCP service, API, or fixed-cost resource: none.** The flag, quotas and limits are env vars on the existing `api`
  service. The graph adds no Terraform resource, Pub/Sub topic, scheduler job or secret.
- **`cost-guard` clean:** the hook's forbidden-resource pattern and its `min_instance_count > 0` pattern were run over
  every `*.tf` in `infra/` on this branch (0 hits) and over the additions in `origin/infra/graph-t23` vs `main`
  (variables and env vars only; no new `resource` blocks). Cloud Run stays at min 0 / max 3.
- Index cost: the two `follows` indexes already exist and are deployed; `graph.blockedBy` is exempted from indexing.

## Dashboard notes
- Add to the dashboard notes / saved Logs Explorer queries: `jsonPayload.graph_op!="" | sum fs_reads by graph_op`
  (also in `cost-model.md` §9). **No new alert policy and no log-based metric** (observability skill).
- **Update 2026-09-30 (resolves the earlier finding that these fields were missing):** PR #36 emits `graph_op`,
  `outcome`, `txn_attempts`, `graph_cache_hit`, `edges_removed` and `feature_disabled` on the graph request line, plus a
  WARN `graph_txn_contention` when `txn_attempts > 3` (`backend/internal/graph/observe.go`; queries in
  `docs/runbooks/graph.md` §3). The saved query above works, so T24 and the T25 `graph_cache_hit` revisit trigger can use
  it. Fallback for log lines older than that deploy: `jsonPayload.rpc:"GraphService" | sum fs_reads by rpc`.
- Still **not** emitted from ADR-0008 "Required log fields": `rows_filtered` and `hydration_misses` (lists), and
  `lazy_removed` (until T27 ships). The purge lines (`graph_purge_batch`, `purge_missing_counterpart`) come from `opsctl`
  on the operator's terminal, not from the `api` service.

## Open items
1. T17 `test-report-graph.md`: pending; add its numbers here if they differ from the T16 ceilings.
2. Architect: A2 planning value for Follow (3 to 4) or T30.
3. Mute at 3 reads depends on T26; current Mute is 2 reads (model uses 3, immaterial at 0.02 calls/DAU).
4. Prices in `cost-model.md` §7 are still unverified upper bounds; this report's $ figures inherit that.
5. Cloud smoke on dev (cold start, real p95) is not part of T21 (no cloud access); belongs to T23/T24.
