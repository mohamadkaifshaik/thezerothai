# Graph: follow, unfollow, block, mute, relationships, follower and following lists
Plan owner: planner · Date: 2026-09-28 · Target release: **v0.2.0** (Phase 1, `mvp-roadmap`) · Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, ADR-0002, ADR-0003, ADR-0004, ADR-0006 (plus its 2026-09-27 and 2026-09-28 amendments),
`proto/dzeroth/graph/v1/graph.proto`, `backend/internal/graph` (only `InitGraph` exists today), `backend/internal/identity`,
`docs/reviews/release-v0.1.0-readiness.md` §4 (L9, R-N8, R-N12), `docs/reviews/cost-model.md`.

> **Defaults assumed so work doesn't block.** The architect confirms or overrides each one in T1. Details are in
> "Open design questions" (§ at the end).
> - **Q1:** private accounts and follow requests are **deferred**. L9 is closed by rejecting `is_private=true`.
> - **Q2:** a `graph/{uid}.blockedBy[]` array makes both block directions a 1-read check.
> - **Q3:** counters use `FieldValue.Increment` in the same transaction. No sharding.
> - **Q4:** `GetRelationships` reads only the caller's graph doc. A new additive field, `UserListItem.relationship`, removes a round trip per list page.
> - **Q6:** the feature flag is an env-var server flag, exposed to clients through `GetMeResponse.enabled_features`.
> - **Q7:** a new daily quota `blocks` (block and mute) plus rate limits per procedure.

---

## Goal & user value
Users can build and control their social graph:
- follow and unfollow people, and see follower and following counts and lists;
- block abusers (a block cuts every follow edge between the two accounts and hides the blocker's profile and lists from
  the blocked user);
- mute accounts they don't want in their timelines, without the other side knowing.

This is the input the home timeline (ADR-0004: pull-on-read over `graph/{uid}.following`, filtered by
`blocked`/`muted`) and notifications need. It also gives users the **block** half of the UGC "report + block"
requirement, which partly closes R-N12. The report flow belongs to the moderation plan.

## Scope
- **Backend `internal/graph`:**
  - `Follow` and `Unfollow`, for public targets only;
  - `Block`, `Unblock`, `Mute`, `Unmute`;
  - `GetRelationships`;
  - `ListFollowers`, `ListFollowing`, `ListBlockedUsers`, `ListMutedUsers`;
  - a cached `graph.Reader` (used by identity now, and by timeline and posts later);
  - `graph.Eraser.PurgeUser`, the delete-cascade building block.
- **Identity changes:**
  - `GetProfile` returns NOT_FOUND when the target blocked the viewer. This closes the `service.go` TODO.
  - `UpdateProfile` rejects `is_private=true` for now. This closes **L9**.
  - A new batched, cache-first profile lookup, used to fill in list rows (hydration).
  - `GetMe` returns the enabled feature flags.
- **Platform:**
  - a server feature flag (`FEATURE_GRAPH`);
  - a `blocks` daily quota;
  - rate limits per procedure for graph RPCs;
  - an in-memory daily cap on list RPCs;
  - CheckHandleAvailability raised to 20/min (**R-N8**).
- **Ops:** an `opsctl` CLI with `purge-graph` and `export-graph` for the manual account-deletion and export runbook.
  The in-app `DeleteAccount` is not built yet.
- **Flutter:**
  - a real profile header (GetProfile, counts, Follow button, block/mute menu);
  - a followers/following list screen;
  - Settings screens for Blocked accounts and Muted accounts;
  - UI gated by the flag.
- **Tests and ops:** emulator integration tests with budget assertions, an e2e smoke test, a k6 smoke test, the cost
  report, runbooks, the dev deploy and the v0.2.0 release.

## Out of scope (explicit non-goals)
- **Private accounts and follow requests.** Covered: the `is_private` toggle, the private branch of `Follow`,
  `ListFollowRequests`, `RespondToFollowRequest`, the follow-request inbox screen, and the post-visibility job.
  - They ship as a separate `private-accounts` plan together with or after `posts`, because privacy protects posts and
    the visibility job (ADR-0003) needs the posts module.
  - In this slice both request RPCs return `FAILED_PRECONDITION` + `ERROR_REASON_FEATURE_DISABLED`.
- **Follow notifications.** They go in the notifications plan. Graph exposes a `FollowEvents` hook that does nothing
  for now, so the budget here has no "+1 async" write.
- **"Follows you" badge and a `followed_by` bit in `GetRelationships`.** These cost 1 read per target.
- **Who-to-follow suggestions, mutual-follower counts, and search by handle** (Phase 2).
- **Timeline filtering.** Graph *provides* `following`, `blocked`, `muted` and `blockedBy` through `graph.Reader`. The
  timeline, posts and notifications plans must use them.
- **The in-app `DeleteAccount` and `RequestAccountExport` jobs** (identity or account-lifecycle plan). This plan
  delivers `graph.Eraser` and a runbook CLI that the job will reuse.
- **Scale-up path** (Stage 2+, needs an ADR):
  - sharded follower counters for accounts with more than 1 follow/s sustained;
  - denormalized snapshots on follow edges, so list pages don't need hydration reads;
  - a Postgres edge table or a Memorystore follow-set cache;
  - raising the 5,000 following cap (a separate `graph_following/{uid}/chunks`).

## Non-functional targets (Stage 0, ≤ 300 DAU)
| Path | p95 warm | Cold (incl. start) |
|---|---|---|
| Follow / Unfollow / Block (transactional) | < 500 ms | < 1.5 s |
| Mute / Unmute / Unblock | < 300 ms | < 1.5 s |
| GetRelationships | < 150 ms | < 1.5 s |
| ListFollowers / ListFollowing / ListBlocked / ListMuted (page 20) | < 400 ms | < 1.5 s |
| GetProfile (with block check) | ≤ v0.1.0 baseline + 20 ms | unchanged |

- Graph read paths may be up to 60 s stale on *other* instances. Mutations always read fresh inside their transaction (Q8).
- Load assumptions come from `cost-model.md` §1, with calls/DAU/day as below.

## Cost (required)

### Per-RPC budget (Firestore ops per call, worst / typical)
F = the caller's following count. "Hydration" means a cache-first `GetAll` on `users/*` (60 s cache).

| RPC | reads (worst / typical) | writes (worst / typical) | deletes | Cloud Run ms | calls / DAU / day | reads / DAU | writes / DAU | deletes / DAU |
|---|---|---|---|---|---|---|---|---|
| Follow (txn: caller graph, quotas; cached target + caller users) | 4 / 2 | 5 / 5 | 0 | 60 | 0.5 | 1.0 | 2.5 | 0 |
| ↳ Follow replay (already following) | 2 / 2 | 0 | 0 | 30 | — | — | — | — |
| Unfollow (blind batch, `Exists` precondition on follows doc) | 0 / 0 | 3 / 3 (0 if no-op) | 1 / 1 | 40 | 0.1 | 0 | 0.3 | 0.1 |
| Block (txn: both graphs, quotas; removes follows both ways) | 3 / 3 | 5 / 3 | 2 / 0 | 60 | 0.02 | 0.06 | 0.06 | ~0 |
| Unblock (fresh caller graph read; write only if blocked) | 1 / 1 | 2 / 2 | 0 | 30 | 0.005 | ~0 | 0.01 | 0 |
| Mute (quotas txn) | 2 / 2 | 2 / 2 | 0 | 30 | 0.02 | 0.04 | 0.04 | 0 |
| Unmute (fresh caller graph read; write only if muted) | 1 / 1 | 1 / 1 | 0 | 30 | 0.005 | ~0 | ~0 | 0 |
| GetRelationships (≤ 50 ids, caller graph only, cached 60 s) | 1 / 0.5 | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| ListFollowers / ListFollowing (target user + caller graph + page ≤ 50 + hydration ≤ 50) | 102 / 30 | 0 | 0 | 70 | 0.3 | 9.0 | 0 | 0 |
| ListBlockedUsers / ListMutedUsers (caller graph + hydration ≤ 50) | 51 / 10 | 0 | 0 | 40 | 0.02 | 0.2 | 0 | 0 |
| ListFollowRequests / RespondToFollowRequest (flag-disabled stubs) | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| IdentityService.GetProfile (changed: + caller graph for blockedBy) | 3 / 0–1 | 0 | 0 | 20 | 3 (already in model) | ±0 | 0 | 0 |
| IdentityService.GetMe (changed: `enabled_features` from env) | unchanged 2 / 1 | 0 | 0 | 15 | 4 (already in model) | ±0 | 0 | 0 |
| **Graph slice total** | | | | | **≈ 4.0 req** | **≈ 11.8** | **≈ 2.9** | **≈ 0.1** |

Notes on the budget:
- **Follow:** 5 writes = `follows` doc + caller graph + 2 `users` counter increments + `quotas`.
  - Worst-case reads add the target and caller `users` docs on a cache miss. The caller doc is needed for the
    new-account quota (created < 24 h).
  - This matches the proto's 4/2 and 5/5. The "+1 async" notification is dropped for this slice.
  - **Superseded (ADR-0008 Amendment 2026-09-30 (2), B1):** Follow plans at **4 reads** (measured 3.96–3.98, T18),
    2.0 reads/DAU; Unfollow logs 1 read (the caller's interceptor profile read; 0 in the batch). Graph ≈ 12.9
    reads/DAU (13.1 with T21's list re-plan). The table above is kept as the original plan.
- **Block:** worst case is a mutual follow: 2 graphs + 2 `users` (both counter pairs are combined per doc) + `quotas`
  = 5 writes, plus 2 `follows` deletes.
  - Typical case with no follow edges: 2 graphs + `quotas` = 3 writes.
  - The proto's 4/1 changes to 5/3 because the target graph now always gets `blockedBy` (Q2) and the `blocks` quota
    is added (Q7). This is a **proto comment update**.
- **Unblock and Unmute read** the caller graph fresh, so a no-op costs 0 writes. A cached "not blocked" could be up to
  60 s stale on another instance and would silently skip the unblock. The proto's 0 reads becomes 1. **Comment update.**
- **List typical:** 30 = page of 20 + about 10 hydration misses (cache hit rate ~50%, `cost-model.md` §1). The
  cost model's 25 changes to 30.
- **GetProfile:** worst case drops from 4 to 3. The target graph read is no longer needed, because `blockedBy` is on
  the viewer's own graph (Q2). **Comment update.**

### Daily totals at the Stage 0 target (300 DAU) vs free quota
| Quota | Graph slice per DAU | Graph at 300 DAU | + v0.1.0 identity baseline (7.3 reads, 0.17 writes) | % of free | vs 80% line |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | 11.8 | 3.5k | 5.7k | **11.5%** | well under |
| Firestore writes (20k/day) | 2.9 | 0.87k | 0.92k | **4.6%** | well under |
| Firestore deletes (20k/day) | 0.1 | 30 | 30 | 0.2% | well under |
| Cloud Run requests (2M/month, shared) | ~4.0 | 1.2k/day ≈ 36k/month | +v0.1.0 ≈ 102k/month | ≈ 5% | well under |
| Cloud Run vCPU-s (180k/month, shared) | ~0.2 vCPU-s | ≈ 1.8k/month | — | ≈ 1% | well under |
| Firestore storage (1 GiB) | ~1 KiB per follow edge incl. index entries | 300 users × 100 follows ≈ 30 MiB | — | ≈ 3% | well under |
| Hosting transfer | +~150 KB web bundle growth per new visitor | negligible | — | — | — |

- **Cost line:** graph adds about **12 reads, 3 writes and 4 requests per DAU per day**, which is **$0/month at 300 DAU**.
  - In the full Phase 1 model (`cost-model.md` §2) the graph rows were already counted (≈ 10.2 reads, 3.35 writes).
  - This plan changes those rows to 11.8 reads and 2.9 writes, a net +1.6 reads/DAU. The whole-product crossover
    moves from ~213 DAU to ~211 DAU on the 80% line. sre-performance updates §2 and §3 (T21).
- **New GCP service or fixed-cost resource: none.**
  - The flag is an env var: 0 reads, no Firebase Remote Config.
  - The `opsctl` CLI runs on the founder's machine.
  - `cost-guard`: no new Terraform resources, only env vars on the existing `api` service.

### Worst-case abuse bounds per account per day (inputs to security review T20)
| Vector | Control | Worst per abusive account/day |
|---|---|---|
| Follow spam, or a follow/unfollow churn loop | `follows` quota 200/day (new accounts 50), Follow bucket 30/min | 200 × 5 writes + 200 × (3 writes + 1 delete) ≈ **1.6k writes** (8% of free) |
| Block, unblock or mute churn | new `blocks` quota 200/day (new accounts 50), covering Block and Mute; bucket 20/min | 200 × 5 + 200 × 2 ≈ **1.4k writes** (7%) |
| Scraping follower lists | bucket 20/min + **in-memory cap of 100 list calls per uid per day per instance** (max 3 instances) | 300 × 102 ≈ **30.6k reads** (61% of daily free, ≈ $0.02/day at list price) |
| Enumerating relationships | GetRelationships reads only the caller's own graph | 0 extra reads |

- A list-scrape by several accounts could exhaust the daily free read quota. That costs cents, not dollars.
- It is detected by the per-RPC `fs_reads` logs and budget alerts, and handled with `abuse-spike.md`.
- Lever if needed: cap `page_size` at 20 when listing *other* users (worst case ≈ 12.6k reads/abuser/day).

## Dependencies & open questions
- **Depends on:**
  - `pkg/platform` (quota, ratelimit, cursor, limits, store, cache, budget, apierr, degraded): all present.
  - `identity.Counters`: implemented, not yet used.
  - Firestore indexes `follows(followeeId, createdAt↓)` and `follows(followerId, createdAt↓)`: already in
    `firestore.indexes.json` and deployed.
- **Import cycle to avoid:**
  - graph needs identity: `identity.Counters`, plus a new `identity.Directory` for batched profiles.
  - identity needs a block check from graph.
  - So identity declares a **consumer-side interface** `identity.BlockChecker` in its `api.go`, the same pattern as
    `GraphInitializer`. graph implements it, and `apiserver.Build` wires it. graph never gets imported by identity.
- **Downstream consumers:**
  - timeline (ADR-0004) uses `graph.Reader.Snapshot(ctx, uid)`, which returns following, blocked, muted, blockedBy
    and requested.
  - The future account-deletion job uses `graph.Eraser.PurgeUser`.
  - Notifications uses `graph.FollowEvents`.
- **@architect:** every question in "Open design questions" below. T1 records the answers in **ADR-0008**, and T2
  makes the contract changes.

## Proto and schema changes (explicit; all additive, `buf breaking` clean)
| File | Change | Why |
|---|---|---|
| `proto/dzeroth/graph/v1/graph.proto` | `UserListItem`: add `Relationship relationship = 3;` (the viewer's relationship to the row's user) | Q4: follow buttons on list rows without a second RPC; computed from the already-loaded caller graph (0 reads) |
| same | Budget comment updates: Follow (no async in this slice), Block 3/3 reads, 5/3 writes, 2/0 deletes; Unblock 1/1, 2/2; Mute 2/2, 2/2; Unmute 1/1, 1/1; List* typical 30; request RPCs "FEATURE_DISABLED until private accounts ship"; block semantics documented on Block/GetRelationships/List* | Keep proto and `cost-model.md` in sync (common.proto convention) |
| `proto/dzeroth/identity/v1/identity.proto` | `GetMeResponse`: add `repeated string enabled_features = 5;` | Q6: server-driven client flag, 0 reads |
| same | Comments: GetProfile "reads 3/0–1; NOT_FOUND if the target blocked the caller (via caller graph blockedBy)"; UpdateProfile "is_private=true rejected with VALIDATION until private accounts ship" | L9 |
| `proto/dzeroth/common/v1/common.proto` | `ErrorReason`: add `ERROR_REASON_TARGET_BLOCKED = 13` (FAILED_PRECONDITION: you blocked this account, unblock first) and `ERROR_REASON_FEATURE_DISABLED = 14` (FAILED_PRECONDITION: feature not enabled for this account) | Distinct client branches (ADR-0002: clients branch on reason) |

| Firestore | Change | Owner |
|---|---|---|
| `graph/{uid}` | New field `blockedBy[]`, capped at 10,000. It is written only by Block/Unblock (the target's doc) and by the purge. It is **never serialized to any client and never exported.** | graph |
| `quotas/{uid}` | New counter `blocks`, the same pattern as `follows` | platform/quota |
| `firebase/firestore.indexes.json` | `fieldOverrides`: exempt `graph.blockedBy` from indexing | architect (T2), deployed by T23 |
| `follows/{a}_{b}` | No change. **Invariant:** the doc exists ⇔ `b ∈ graph/a.following` | graph |
| `followRequests/*`, `graph.requested[]` | No writes in this slice | — |

---

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Contract and design | T1, T2 | ADR-0008 Accepted; `make proto` green; generated Go and Dart committed |
| M2 | Platform and identity seams | T3, T4, T5, T6 | Flag, quotas and limits in config; `graph.Reader` + `BlockChecker` wired; GetProfile block enforcement; L9 closed |
| M3 | Graph RPCs and delete path (backend) ‖ Flutter screens | T7–T11 ‖ T12–T15 | All RPCs implemented behind the flag; screens built against fakes and the generated client |
| M4 | Verification | T16a, T16b, T17, T18, T19, T20, T21 | Test report PASS with budget assertions; code review APPROVE; security 0 Critical/High; cost report holds |
| M5 | Ops and release | T22, T23, T24, T25 | Dev deployed with the flag on; v0.2.0 GO; flag rolled from allowlist to 100% in prod |

Order: T1 → T2 → (T3, T4) → T5 → T6 → (T7, T8, T9 in parallel) → T10 → T11.
- Frontend T12 starts right after T2 and runs in parallel with all backend work, against fakes. T13–T15 follow T12.
- T16a/b follow their RPC tickets. T17–T21 follow M3. T22–T25 come last.

---

## Tickets

### T1 — ADR-0008: graph slice decisions  [owner: architect] [size: M] [depends: —]
- **Description.** Answer every question in "Open design questions" and record the answers in
  `docs/adr/0008-social-graph-blocks-flags-quotas.md`. Cross-reference ADR-0003 and ADR-0006, and add "see ADR-0008"
  pointer notes to them without editing their decisions. The ADR must fix:
  - private-account deferral and the L9 handling (Q1);
  - the `blockedBy` design and its cap (Q2);
  - counter semantics and the invariants (Q3);
  - the `GetRelationships` and per-row relationship design (Q4);
  - the proto list (Q5);
  - the flag mechanism (Q6);
  - quota and rate-limit numbers (Q7);
  - accepted staleness (Q8);
  - the block-semantics table (Q9);
  - the delete-cascade algorithm and checkpointing (Q10);
  - the notification hook (Q11).

  Also update the `firestore-data-model` skill table (the `graph` row, and the Follow/Block rows in the op-cost table).
- **Acceptance criteria.**
  - Given ADR-0008, when read, then it has Options with $ at idle, 300 DAU and 3k DAU; Cost impact = $0 fixed; a
    Decision paragraph; and a Handoff for backend, frontend, deployer and tester.
  - Given each Qn below, then the ADR states the chosen option or explicitly accepts the default.
  - Given the block-semantics table, then every RPC (graph and identity) has a defined behaviour for both
    "caller blocked target" and "target blocked caller".
  - Given the founder, then the Deciders line records the founder's acceptance of the private-account deferral (Q1),
    because it changes a user-visible feature.
- **Test notes.** Not applicable. The tester uses the semantics table as the oracle for T16.
- **Observability.** The ADR lists the required log fields (see T5).
- **Budget.** Doc only. It confirms the budget table in this plan.

### T2 — Proto, error reasons and index-exemption changes  [owner: architect] [size: S] [depends: T1]
- **Description.** Apply the "Proto and schema changes" table exactly:
  - `graph.proto`: add `UserListItem.relationship = 3` and update the comments;
  - `identity.proto`: add `GetMeResponse.enabled_features = 5` and update the comments;
  - `common.proto`: add `ERROR_REASON_TARGET_BLOCKED = 13` and `ERROR_REASON_FEATURE_DISABLED = 14`;
  - `firestore.indexes.json`: add the `graph.blockedBy` exemption.

  Run `make proto` and commit the generated Go (`backend/gen`) and Dart (`app/lib/gen`).
- **Acceptance criteria.**
  - Given the PR, when CI runs `buf lint` and `buf breaking --against main`, then both pass.
  - Given the generated Dart client, when `flutter analyze` runs, then there are 0 new warnings.
  - Given `firestore.indexes.json`, then the `graph` overrides are `following`, `blocked`, `muted`, `requested` and
    `blockedBy`, each with `"indexes": []`, and no composite indexes were added.
  - Given every changed RPC comment, then its reads/writes numbers equal this plan's budget table.
- **Test notes.** The contract tests in T16 cover each new error reason.
- **Observability.** —
- **Budget.** Not applicable.

### T3 — Server feature flag + `GetMe.enabled_features`  [owner: backend-developer] [size: S] [depends: T2]
- **Description.**
  - Add `pkg/platform/flags`, first checking `code-map.md` for existing config patterns. The flag state is loaded at
    startup from env:
    - `FEATURE_GRAPH=off|allowlist|percent|on` (default `off`);
    - `FEATURE_GRAPH_ALLOWLIST` (comma-separated uids; stored in the Terraform variable, not a secret);
    - `FEATURE_GRAPH_PERCENT` (0–100, bucketed by `fnv(uid) % 100`).
  - Add `flags.Enabled(uid, name) bool`.
  - `GetMe` fills `enabled_features` with 0 reads.
  - A graph-service guard (a service-layer check, not a new interceptor) returns FAILED_PRECONDITION +
    `ERROR_REASON_FEATURE_DISABLED` when the flag is off for the caller.
  - The `ListFollowRequests` and `RespondToFollowRequest` stubs always return that error in this slice.
  - Add config fields to `config.Config` and one line in `docs/code-map.md`.
- **Acceptance criteria.**
  - Given `FEATURE_GRAPH=off`, when any GraphService RPC is called, then FAILED_PRECONDITION +
    `FEATURE_DISABLED` is returned with 0 Firestore reads.
  - Given `allowlist` with uid A, when A calls GetMe, then `enabled_features` contains `"graph"`; for uid B it doesn't.
  - Given `percent=10`, when 10,000 random uids are bucketed, then 10% ± 1.5% are enabled, and each uid gets the
    same result every time.
  - Given an invalid value (for example `FEATURE_GRAPH=maybe`), when config loads, then startup fails fast with a clear
    error. It must not silently default to on.
- **Test notes.** Unit table tests; a GetMe integration test asserts reads are unchanged (2/1).
- **Observability.** A startup log line `feature_flags={graph: mode}`. Per request, `feature_disabled=true` on
  rejected calls (for rollout monitoring).
- **Budget.** 0 reads, 0 writes.

### T4 — Quotas, rate limits and list daily cap  [owner: backend-developer] [size: S] [depends: T2]
- **Description.**
  - **Extend** `pkg/platform/quota`, following reuse-first: add `Kind Blocks` and `Record.Blocks`, plus config
    `QUOTA_BLOCKS_PER_DAY` = 200 and `QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY` = 50.
  - Add `ratelimit.Config.PerProcedure` entries:
    - Follow and Unfollow: 30/min;
    - Block, Unblock, Mute, Unmute: 20/min;
    - ListFollowers, ListFollowing, ListBlockedUsers, ListMutedUsers: 20/min;
    - GetRelationships: the default 60/min.
  - **Extend** the limiter with an optional per-procedure **daily in-memory cap** (`LIST_CALLS_PER_DAY` = 100 per uid
    per instance, resetting at the IST day boundary through `quota.TodayAt`). Don't write a second limiter.
  - Raise CheckHandleAvailability from 10 to 20/min (**R-N8**).
  - Every number lives in `config.Config` / env (rule 11).
- **Acceptance criteria.**
  - Given a user with `quotas.blocks = 200` today, when they call Block or Mute, then RESOURCE_EXHAUSTED +
    `QUOTA_EXCEEDED` is returned with `metadata.quota = "blocks"` and 0 entity writes.
  - Given an account younger than 24 h, then the limits are follows 50 and blocks 50.
  - Given 31 Follow calls in one minute from one uid on one instance, then the 31st gets `RATE_LIMITED` with
    `retry_after`.
  - Given 101 list calls from one uid in one IST day on one instance, then the 101st gets `RATE_LIMITED`, and the cap
    resets after IST midnight (tested with a fake clock).
  - Given CheckHandleAvailability, then 20 calls/min pass and the 21st is limited.
- **Test notes.** Unit tests with a fake clock. The quota rollover test runs in T16a on the emulator.
- **Observability.** The existing `RATE_LIMITED`/`QUOTA_EXCEEDED` log fields, plus `limit_name`
  (for example `graph_list_daily`).
- **Budget.** Quota check: +1 read and +1 write on Block and Mute, already in the table. The in-memory cap: 0.

### T5 — Graph module core: repo, cache, `graph.Reader`, `BlockChecker`, service skeleton  [owner: backend-developer] [size: M] [depends: T3]
- **Description.**
  - Expand `backend/internal/graph` into `api.go`, `service.go`, `repo_firestore.go`, `cache.go` and `server.go`,
    following identity's layout. Keep `InitGraph` unchanged, and also initialize `blockedBy: []` in it.
  - Add the `doc.BlockedBy` field. Documents without the field read as empty (expand-only change, no backfill).
  - The instance cache wraps `pkg/platform/cache.LRU` (5k graphs, 60 s) and is updated in place on this instance's
    own commits.
  - Exported interfaces:
    - `Reader.Snapshot(ctx, uid) (Snapshot, error)` returns immutable sets `Following`, `Blocked`, `Muted`,
      `BlockedBy`, `Requested`.
    - `BlockChecker.IsBlockedBy(ctx, viewer, target) (bool, error)`: true if `target ∈ viewer.BlockedBy`.
    - `FollowEvents`: no-op for now.
    - `Eraser`: the interface only; implemented in T11.
  - Declare `identity.BlockChecker` in `identity/api.go` (a consumer-side interface; no import cycle).
  - Register the GraphService Connect handler in `apiserver.Build` with every RPC returning Unimplemented, except the
    flag guard (T3).
  - Update `docs/code-map.md`.
- **Acceptance criteria.**
  - Given the empty graph doc created by CreateProfile, when `Snapshot` is read, then all five sets are empty and there
    is no error.
  - Given a v0.1.0 doc without `blockedBy`, then `Snapshot` returns an empty `BlockedBy`.
  - Given two calls to `Snapshot(uid)` within 60 s, then Firestore is read once (budget counter = 1).
  - Given `internal/identity`, when `depguard` / import lint runs, then identity does not import `internal/graph`.
  - Given `DEGRADED_MODE=readonly`, when a mutating graph RPC is called, then `DEGRADED_MODE` is returned (derived
    from `idempotency_level`, with no hand-maintained list).
- **Test notes.** Unit tests with a fake repo; one emulator test for decoding a doc without the field.
- **Observability.** Every graph RPC logs `fs_reads`, `fs_writes`, `fs_deletes` (`budget.Counter`), `graph_cache_hit`
  and `txn_attempts` for transactional RPCs.
- **Budget.** `Snapshot`: 1 read on a miss, 0 on a hit.

### T6 — Identity changes: batched profile lookup, GetProfile block enforcement, L9 close  [owner: backend-developer] [size: M] [depends: T5]
- **Description.**
  1. Add `identity.Directory.GetProfiles(ctx, uids []string) (map[string]Profile, error)`. It checks the cache first,
     then does one `GetAll` for misses (≤ 50), populates the cache, and drops missing or non-ACTIVE users. Reuse
     `getProfileCached` and `Cache`; no second cache.
  2. Add `identity.Counters.Forget(uids...)`, which evicts cached profiles after the caller's commit so counts show
     the change on this instance straight away.
  3. `GetProfile`: after resolving uid, if `BlockChecker.IsBlockedBy(caller, uid)`, return the **same NOT_FOUND** as
     for a missing profile (same message, same reason). Remove the TODO.
  4. `UpdateProfile`: `is_private=true` returns INVALID_ARGUMENT + `VALIDATION` (`field=is_private`, message "Private
     accounts are coming soon"). `false` stays accepted.
  5. Wire `BlockChecker` and `Directory` in `apiserver.Build`.
- **Acceptance criteria.**
  - Given B blocked A, when A calls GetProfile(B) by id or by handle, then NOT_FOUND is returned, byte-identical to the
    error for a nonexistent uid.
  - Given A blocked B, when A calls GetProfile(B), then the profile is returned, so A can unblock.
  - Given UpdateProfile with `is_private=true`, then `VALIDATION` is returned and there are 0 writes. With
    `is_private=false` the update succeeds.
  - Given 20 uids with 12 cached, then GetProfiles costs exactly 8 reads, in one `GetAll`.
  - Given GetProfile warm, then reads = 0. Cold by handle, reads ≤ 3.
- **Test notes.** Integration test with the identical-error assertion (compare the serialized Connect error).
- **Observability.** No new field. `fs_reads` is already logged.
- **Budget.** GetProfile 3/0–1; GetProfiles ≤ 50/≤ 50 (hit rate ~50%).

### T7 — Follow and Unfollow  [owner: backend-developer] [size: M] [depends: T4, T5, T6]
- **Description.**
  - **Follow** is a transaction:
    1. Read the caller graph and `quotas/{uid}` fresh.
    2. Take the target's and caller's `users` from the cache through `identity.Directory`.
    3. Reject, in this order:
       - self-follow → `VALIDATION`;
       - target missing, not ACTIVE, or `target ∈ caller.blockedBy` → NOT_FOUND;
       - `target ∈ caller.blocked` → `TARGET_BLOCKED`;
       - target `isPrivate` (legacy only) → `FEATURE_DISABLED`;
       - already following → replay: return FOLLOWING with 0 writes;
       - `len(following) ≥ 5,000` → `LIMIT_REACHED`;
       - quota exhausted → `QUOTA_EXCEEDED`.
    4. Write in the same txn: `Create(follows/{a}_{b})`, `ArrayUnion` on the caller graph's following, and
       `identity.Counters.AddFollowingCount(a,+1)` / `AddFollowersCount(b,+1)` / quota reserve.
    5. After commit, update the graph cache, call `Counters.Forget(a,b)` and `FollowEvents.Followed` (no-op).
  - **Unfollow** is a blind batch:
    - `Delete(follows/{a}_{b}, Exists)`, `ArrayRemove` on the caller's following, and decrement both counters.
    - A `NotFound` on commit means not following: return NONE (idempotent, 0 writes).
  - Idempotency key: validate its format and don't store it. Natural keys make both RPCs replay-safe (ADR-0003).
- **Acceptance criteria.**
  - Given A doesn't follow B, when A follows B, then `follows/A_B` exists, B ∈ `graph/A.following`,
    `users/A.followingCount` +1, `users/B.followersCount` +1, `quotas/A.follows` +1, and the response is FOLLOWING.
  - Given the same call replayed, or a second key, then counters are unchanged, the quota is unchanged, and the
    response is FOLLOWING.
  - Given 10 concurrent Follow(A→B) calls, then exactly one edge exists and counters moved by exactly 1.
  - Given A unfollows B twice, then counters are decremented exactly once and the second call does 0 writes.
  - Given B blocked A, when A follows B, then NOT_FOUND is returned with 0 writes. Given A blocked B, then
    `TARGET_BLOCKED` is returned.
  - Given A follows 5,000 accounts, then `LIMIT_REACHED` is returned with `metadata.limit = "following"`.
  - Given Follow racing Block(B blocks A), then the final state always has no edge and counters equal the true edge
    counts (the invariant check in T16a).
- **Test notes.** Emulator tests with `budgettest.Assert`: Follow ≤ 4R/5W, replay ≤ 2R/0W, Unfollow ≤ 0R/3W/1D,
  no-op Unfollow 0 writes. Race tests use goroutines against the emulator.
- **Observability.** `graph_op=follow|unfollow`, `outcome=created|replay|noop|rejected:<reason>`, `txn_attempts`.
  WARN on `txn_attempts > 3`.
- **Budget.** Follow 4/2 R, 5/5 W; Unfollow 0 R, 3 W, 1 D.

### T8 — Block, Unblock, Mute, Unmute  [owner: backend-developer] [size: M] [depends: T4, T5, T6]
- **Description.**
  - **Block** is a transaction:
    1. Read both graphs and the caller's quotas.
    2. Write:
       - caller graph: `blocked += B`, `following -= B`;
       - target graph: `blockedBy += A`, `following -= A`;
       - delete `follows/A_B` and/or `follows/B_A` where the edge exists (per the `following` arrays);
       - decrement the matching counters (combined per `users` doc);
       - reserve the `blocks` quota.
    3. Enforce the caps `blocked ≤ 2,000` (`LIMIT_REACHED`) and `blockedBy ≤ 10,000`. At the `blockedBy` cap, still
       add to the caller's `blocked` but skip `blockedBy`, and log ERROR `blockedby_cap_reached` for moderation review.
    4. Replay (already blocked): 0 writes.
  - **Unblock:** fresh read of the caller graph. If B ∈ `blocked`, `ArrayRemove` on both sides; otherwise 0 writes.
    Unblock does **not** restore follows.
  - **Mute:** a quota transaction plus `ArrayUnion(muted)`, cap 2,000. **Unmute:** fresh read, then remove if present.
  - Mute is never visible to the target.
  - Blocking or muting yourself → `VALIDATION`. Blocking a nonexistent user → NOT_FOUND. Muting someone who blocked
    you is allowed (no leak).
- **Acceptance criteria.**
  - Given A and B follow each other, when A blocks B, then both `follows` docs are deleted, both `following` arrays
    are cleaned, all four counters are decremented exactly once, A.blocked ∋ B, and B.blockedBy ∋ A.
  - Given Block replayed, then 0 writes and the response is `blocking=true`.
  - Given A unblocks B, then A.blocked ∌ B, B.blockedBy ∌ A, and no follow is restored. A second Unblock does
    0 writes.
  - Given A mutes B, then only A's graph changes. `GetRelationships` as B shows nothing about the mute.
  - Given the `blocks` quota is exhausted, then Block and Mute return `QUOTA_EXCEEDED`, while Unblock and Unmute still
    work (unblocking must never be quota-gated).
  - Given `DEGRADED_MODE=readonly`, then all four return `DEGRADED_MODE`.
- **Test notes.** Budgets: Block worst ≤ 3R/5W/2D (mutual follow), typical 3R/3W/0D; Unblock ≤ 1R/2W; Mute ≤ 2R/2W;
  Unmute ≤ 1R/1W.
- **Observability.** `graph_op=block|unblock|mute|unmute`, `edges_removed=0..2`, ERROR `blockedby_cap_reached`.
- **Budget.** As the table.

### T9 — GetRelationships, ListBlockedUsers, ListMutedUsers  [owner: backend-developer] [size: M] [depends: T5, T6]
- **Description.**
  - **GetRelationships:**
    - Validate 1–50 ids, dedupe, and preserve request order.
    - Compute from the caller's cached `Snapshot` only: `follow_state` (FOLLOWING / NONE; REQUESTED unreachable in
      this slice), `blocking`, `muting`.
    - The response must never reflect `blockedBy`. A user who blocked the caller shows as NONE/false/false, the same
      as a stranger.
    - The caller's own id → NONE.
  - **ListBlockedUsers / ListMutedUsers:**
    - Read the caller's graph array, newest first (reverse insertion order).
    - Page with `pkg/platform/cursor`, with docId = the last uid returned. If that uid was removed meanwhile, resume at
      the first uid older than the cursor position recorded in the token.
    - Fill in rows with `identity.Directory`. Deleted users are dropped from the page (the lazy clean-up is in T11).
  - `since` is unset (ADR-0003). `relationship` is filled (Q4).
- **Acceptance criteria.**
  - Given 50 ids, then GetRelationships costs ≤ 1 read, and 0 when cached.
  - Given 51 ids, then `VALIDATION` is returned.
  - Given B blocked A, then A's `GetRelationships([B])` equals that for an unrelated user.
  - Given 45 blocked users and page_size 20, then pages are 20/20/5 with `next_page_token` "" at the end.
  - Given a tampered token, then `VALIDATION` is returned.
  - Given ListBlockedUsers, then reads ≤ 1 + page_size.
- **Test notes.** Budget assertions; a cursor-tamper test; a "removed item between pages" test.
- **Observability.** `graph_op`, `fs_reads`, `hydration_misses`.
- **Budget.** GetRelationships 1/0.5; List{Blocked,Muted} 51/10.

### T10 — ListFollowers, ListFollowing  [owner: backend-developer] [size: M] [depends: T6, T9]
- **Description.**
  - Target visibility:
    - target missing, not ACTIVE, or `target ∈ caller.blockedBy` → NOT_FOUND (same error as GetProfile);
    - `target.isPrivate` (legacy) → treat as public (it can't be set in this slice, see T24).
  - Query `follows where followeeId == X order by createdAt desc, __name__ desc limit page_size+1`, with
    `followerId` for Following. This uses the existing composite indexes; the `+1` detects `has_more`.
  - Cursor: `cursor.Encode(createdAt, docId)`.
  - Fill in rows through `identity.Directory`. Drop rows whose user is missing or not ACTIVE, is in
    `caller.blockedBy`, or is in `caller.blocked`. The page may be short, and the client follows `next_page_token`.
  - `since` = the edge `createdAt`. `relationship` comes from the caller snapshot.
- **Acceptance criteria.**
  - Given B blocked A, when A lists B's followers or following, then NOT_FOUND is returned.
  - Given C follows B and C blocked A, when A lists B's followers, then C is not in the rows.
  - Given 45 followers, then pages of 20 cover all 45 exactly once, newest first, stable under concurrent new follows
    (new edges don't shift older pages).
  - Given page_size 100, then it is clamped to 50 (`limits.ClampPageSize`).
  - Given page_size 20 cold, then reads ≤ 2 + 21 + 20 = 43. Worst at page 50 is ≤ 102.
  - Given the list daily cap (T4) is exhausted, then `RATE_LIMITED` is returned before any read.
- **Test notes.** Budget assertions at page sizes 20 and 50; the block-filter matrix from ADR-0008.
- **Observability.** `graph_op=list_followers|list_following`, `rows_filtered`, `fs_reads`.
- **Budget.** 102 / 30.

### T11 — Graph delete cascade (`graph.Eraser`) + `opsctl` for the manual runbook  [owner: backend-developer] [size: M] [depends: T7, T8]
- **Description.** Implement `Eraser.PurgeUser(ctx, uid, checkpoint) (next checkpoint, done bool, error)`. It is
  resumable, uses `Limit(500)` pages, and uses batched writes of ≤ 500 ops (ADR-0003 "Deletes & privacy"):
  1. `follows where followerId == uid`: delete each edge and decrement the followee's `followersCount`.
  2. `follows where followeeId == uid`: delete each edge, `ArrayRemove(uid)` from the follower's `graph.following`,
     and decrement the follower's `followingCount`.
  3. For each b in `graph/uid.blocked`: `ArrayRemove(uid)` from `graph/b.blockedBy`.
  4. For each b in `graph/uid.blockedBy`: `ArrayRemove(uid)` from `graph/b.blocked`.
  5. Delete `graph/uid`.

  Other users' `muted[]` entries can't be found (arrays are unindexed). They are cleaned lazily: when
  ListMutedUsers/ListBlockedUsers hydration finds a missing user, it does an `ArrayRemove` (+1 write, rare).

  Add `backend/cmd/opsctl`:
  - `purge-graph --project P --uid U` runs `PurgeUser` to completion with the founder's ADC. `--dry-run` prints counts.
  - `export-graph --uid U` writes JSON: following, followers (uids and handles), blocked, muted. **Never blockedBy.**

  Both require `--project` explicitly and a confirmation prompt for prod.
- **Acceptance criteria.**
  - Given U with 3 following, 2 followers, 1 blocked, 1 blockedBy and a mute by someone else, when purge runs, then
    no `follows` doc references U; all affected counters are exact; U is in no `following`/`blocked`/`blockedBy`
    array; and `graph/U` is gone.
  - Given the purge killed after step 1's first batch, when re-run with the checkpoint, then it completes, and counters
    are decremented exactly once per edge. Replay safety: decrement only in the same batch as the edge delete.
  - Given `export-graph`, then the output has no `blockedBy` data.
  - Given `opsctl` without `--project`, then it exits non-zero.
- **Test notes.** An emulator crash-resume test (the ADR-0003 handoff requirement) and a dry-run test.
- **Observability.** `opsctl` prints the ops performed. `PurgeUser` logs `graph_purge_batch` with counts per step.
- **Budget.** O(following + followers + blocked + blockedBy) reads and writes, with deletes = edges. At Stage 0, a user
  with 100/100 edges costs ≈ 200 reads, ≈ 300 writes and 200 deletes, once per deletion.

### T12 — Flutter: GraphRepository, relationship cache, FollowButton, flag plumbing  [owner: frontend-developer] [size: M] [depends: T2]
- **Description.**
  - Check `docs/ui-catalog.md` first and reuse `ApiClient`, `guardApiCall`, `mapConnectError`, `AppErrorView` and
    the theme tokens.
  - Add `features/graph/data/graph_repository.dart` (the generated `GraphServiceClient`) and a `RelationshipCubit`
    (BLoC, freezed state).
  - Keep an in-memory `Map<uid, Relationship>` for the session, and persist the caller's own following set in the
    existing drift `AppDatabase` (add a table there; no second database).
  - Add `FollowButton` in `app/lib/shared/widgets/`:
    - states Follow / Following / Unblock (and a hidden Requested variant for later);
    - optimistic update with rollback on error;
    - one UUID idempotency key per intent, reused on retry;
    - map `QUOTA_EXCEEDED`, `LIMIT_REACHED`, `RATE_LIMITED`, `TARGET_BLOCKED`, `FEATURE_DISABLED` and
      `DEGRADED_MODE` to friendly messages, and never auto-retry `DEGRADED_MODE`.
  - Add `FeatureFlags` from `GetMe.enabled_features`, exposed to widgets and the router.
  - Map the two new ErrorReasons in `mapConnectError` / `AppException`.
  - Update `ui-catalog.md`.
- **Acceptance criteria.**
  - Given the flag is off, then no graph UI element is rendered anywhere.
  - Given a tap on Follow, then the button shows Following immediately. If the RPC fails with `QUOTA_EXCEEDED`, then it
    reverts and a snackbar shows the quota message.
  - Given a retry after a network error, then the same idempotency key is sent.
  - Given GetRelationships was called for 50 ids, then the next build for those ids makes no network call (cache hit).
- **Test notes.** Bloc tests for the cubit (optimistic path, rollback, key reuse); widget tests for every
  FollowButton state; a mapping test for the new reasons.
- **Observability.** Crashlytics non-fatal on unexpected `AppException` types; there is no web error telemetry yet
  (R-N12).
- **Budget.** The client never calls GetRelationships for ids already cached this session. At most 1 call per profile
  view.

### T13 — Flutter: profile header with follow, block and mute  [owner: frontend-developer] [size: M] [depends: T12]
- **Description.**
  - Replace the placeholder `ProfileScreen` body with a header: avatar (existing), display name, `@handle`, bio,
    followers and following counts (tappable → T14), and a `FollowButton`. Hide the button on your own profile.
  - Load GetProfile(handle) and GetRelationships([uid]) in parallel.
  - Overflow menu: Mute/Unmute and Block/Unblock. Block opens a confirmation sheet ("They won't be able to follow you
    or see your profile, and you'll unfollow each other").
  - A NOT_FOUND state shows "This account doesn't exist" (identical wording for blocked-by and missing).
  - A blocking state shows a banner "You blocked @x" with Unblock, and hides counts links.
  - Posts area: keep the "coming soon" placeholder; the posts plan extends this screen.
- **Acceptance criteria.**
  - Given the viewer follows the target, then the header shows Following, and followers count +1 appears
    optimistically.
  - Given Block confirmed, then the button becomes Unblock and the counts refresh.
  - Given GetProfile returns NOT_FOUND, then the not-found view renders, with no retry loop.
  - Given a phone, tablet and desktop width, then the layout uses `ResponsiveScaffold` breakpoints with no overflow.
- **Test notes.** Widget tests: own, other, following, blocking, not-found, flag-off; golden optional.
- **Observability.** As T12.
- **Budget.** One profile view = GetProfile (0–1 reads) + GetRelationships (0–1 reads) = 2 requests.

### T14 — Flutter: followers/following list screen  [owner: frontend-developer] [size: M] [depends: T12]
- **Description.**
  - Routes `/profile/:handle/followers` and `/profile/:handle/following`: one screen with two tabs, taking the uid via
    route `extra` with a fallback GetProfile(handle).
  - Infinite scroll with `page_token`, prefetching at 70%.
  - Rows use the author-snapshot avatar, name, handle, and a `FollowButton` initialised from
    `UserListItem.relationship` (no GetRelationships call).
  - Empty, error and NOT_FOUND states via `AppErrorView`.
  - Pull-to-refresh reloads the first page only.
- **Acceptance criteria.**
  - Given 45 followers, then scrolling loads 3 pages and shows no duplicates.
  - Given a row's user is followed, then its button shows Following with no extra RPC.
  - Given `RATE_LIMITED` (list cap), then a friendly view appears (shared `AppErrorView` text: "You're doing that a bit too fast. Give it a moment and try again.") with no auto-retry storm.
  - Given the flag is off, then the route redirects to the profile.
- **Test notes.** Widget tests with a fake repository: pagination, empty, error, rate-limited.
- **Observability.** —
- **Budget.** 1 request per page; never refetch pages already loaded in the session.

### T15 — Flutter: Blocked accounts and Muted accounts in Settings  [owner: frontend-developer] [size: S] [depends: T12]
- **Description.** Add Settings entries "Blocked accounts" and "Muted accounts" (only when the flag is on) at routes
  `/settings/blocked` and `/settings/muted`, using `ListBlockedUsers` / `ListMutedUsers` with paging. Each row has an
  Unblock / Unmute action with optimistic removal and an undo snackbar (undo = Block/Mute again with a new key).
- **Acceptance criteria.**
  - Given 3 blocked users, then the list shows 3. Unblock removes the row, and the profile then shows Follow.
  - Given an empty list, then an explanatory empty state appears.
  - Given the flag is off, then the entries are hidden.
  - Given the flag is off and the user opens `/settings/blocked` or `/settings/muted` directly, then the route redirects to `/settings`.
    **Interim decision (2026-09-29, founder):** `/settings` is the temporary flag-off target. Revisit after the graph rollout and change it then.
- **Test notes.** Widget tests: list, unblock, undo, empty, error.
- **Observability.** —
- **Budget.** 1 request per page.

### T16a — Emulator integration tests: mutations, races, quotas, invariants  [owner: tester] [size: M] [depends: T7, T8]
- **Description.**
  - Contract tests for Follow, Unfollow, Block, Unblock, Mute and Unmute: the happy path plus every documented
    ErrorReason.
  - `budgettest.Assert` on every call, worst and typical.
  - Replay with the same key and with a new key.
  - Quota exhaustion and the IST-midnight rollover (fake clock or seeded `quotas.day`); new-account quotas; the
    5,000 following cap (seeded graph doc); the blocked cap.
  - Races: concurrent duplicate follows; Follow vs Block; Unfollow vs Block.
  - A reusable **graph invariant checker** (a test helper in `internal/graph`): for every `follows` doc, the matching
    `following` entry exists and vice versa; `users.followersCount` / `followingCount` equal the edge counts. It runs
    after every scenario.
  - Degraded mode (readonly) rejects all mutations.
- **Acceptance criteria.**
  - Given `make test-int`, then all graph tests pass, and `internal/graph` coverage is ≥ 70%.
  - Given any RPC exceeding its documented budget, then the test fails with the RPC name and actual vs budget.
- **Test notes.** Put the invariant checker in `docs/code-map.md` test helpers.
- **Observability.** —
- **Budget.** Not applicable (emulator).

### T16b — Emulator integration tests: visibility, lists, relationships, purge  [owner: tester] [size: M] [depends: T6, T9, T10, T11]
- **Description.**
  - Build the **block-visibility matrix** from ADR-0008: for each of GetProfile (by id or handle), GetRelationships,
    ListFollowers, ListFollowing and Follow, check the cases "A blocked B", "B blocked A" and "third party C blocked
    A", as seen from A.
  - Byte-identical NOT_FOUND for blocked-by vs missing.
  - `blockedBy` never appears in any response (grep the serialized JSON).
  - Pagination completeness and stability.
  - Tampered cursors.
  - The list daily cap.
  - Purge crash-resume (T11).
  - L9: `UpdateProfile(is_private=true)` is rejected.
- **Acceptance criteria.**
  - Given the matrix, then every cell matches ADR-0008.
  - Given all list RPCs at page 20 and 50, then reads ≤ budget.
- **Test notes.** Reuse the T16a fixtures; no second seeding helper.
- **Observability.** —
- **Budget.** Not applicable.

### T17 — E2E smoke, Flutter test sweep, test report  [owner: tester] [size: S] [depends: T13, T14, T15, T16a, T16b]
- **Description.**
  - Extend `backend/e2e` with `graph_smoke_test.go`, runnable against emulators and the `candidate` URL with test
    accounts:
    - A follows B, then GetRelationships;
    - ListFollowers(B) contains A;
    - B blocks A, then A's GetProfile(B) is NOT_FOUND;
    - B unblocks A;
    - clean-up.
  - Run `flutter test` and check that every new screen has widget tests.
  - Write `docs/reviews/test-report-graph.md` with the budget table (actual reads/writes per RPC vs budget), coverage,
    and the matrix results.
- **Acceptance criteria.**
  - Given `make ci` and `make test-int`, then both are green.
  - Given the report, then the verdict is PASS, with every RPC's measured reads/writes ≤ budget.
- **Test notes.** The smoke test must clean up after itself (Unfollow/Unblock) so it can be re-run on prod `candidate`.
- **Observability.** —
- **Budget.** Smoke run ≈ 15 reads and 12 writes per execution.

### T18 — k6 emulator load smoke for graph paths  [owner: sre-performance] [size: S] [depends: T7, T10]
- **Description.** Add `loadtest/graph_follow.js` (Follow/Unfollow churn across 50 virtual users) and
  `loadtest/graph_lists.js` (GetRelationships + ListFollowers pages), following `identity_getme.js`. Run them on
  emulators and record p95 and `fs_reads` per call from the logs.
- **Acceptance criteria.**
  - Given 20 rps for 2 minutes, then p95 for Follow is < 500 ms and for ListFollowers < 400 ms (emulator, local
    machine noted).
  - Given the logs, then the mean `fs_reads`/call is ≤ the typical budget.
  - Given the logs, then there are 0 ERROR lines.
- **Test notes.** Results go in the T21 cost report.
- **Observability.** Uses the existing log fields.
- **Budget.** Emulator only; $0.

### T19 — Code review of graph PRs  [owner: code-reviewer] [size: S] [depends: T3–T15 (per PR)]
- **Description.** Review each PR against CLAUDE.md rules 1–11, ADR-0008 and reuse-first:
  - no second cache, limiter or cursor;
  - no module builds another module's paths;
  - every query has a `Limit`;
  - no reads in a loop (hydration is a single `GetAll`);
  - budget comments match the code;
  - the reuse report is present and the catalogs are updated.
- **Acceptance criteria.**
  - Given each PR, then an APPROVE is recorded, or findings are fixed and re-reviewed.
  - Given the summary, then `docs/reviews/graph-code-review.md` lists 0 open Blockers.
- **Test notes.** —
- **Observability.** Check that every new request path has `fs_reads`/`fs_writes` logging and an ERROR path visible in
  Logs Explorer.
- **Budget.** Verify the budget table against the code.

### T20 — Security review: graph threat model  [owner: security-auditor] [size: M] [depends: T7–T11]
- **Description.** Write a threat model and review, covering:
  - authz: uid from the token only; no RPC can change another user's edges except Block's defined side effects;
  - IDOR on Unfollow/Unblock with arbitrary ids;
  - block-existence leaks:
    - GetProfile, lists and relationships;
    - the known residual: `CheckHandleAvailability` says "taken" while GetProfile says NOT_FOUND. Accept or mitigate.
  - `blockedBy` never serialized or exported;
  - scraping via lists (the bounds in the abuse table);
  - follow-spam and churn bounds; quota bypass with several instances (×3);
  - cursor tampering;
  - `opsctl` safety (explicit project, confirmation, runs only with the founder's ADC);
  - the privacy of the export (no third-party block data).

  Output: `docs/reviews/security-review-graph.md`.
- **Acceptance criteria.** 0 Critical and 0 High open. Every Medium is fixed or has a recorded risk acceptance for
  the v0.2.0 readiness §4.
- **Test notes.** Any finding that needs a test goes back to T16 as a new case.
- **Observability.** Confirm that `blockedby_cap_reached`, `QUOTA_EXCEEDED` spikes and `graph_list_daily` rejections
  can be queried in Logs Explorer.
- **Budget.** Not applicable.

### T21 — Cost report and cost-model update  [owner: sre-performance] [size: S] [depends: T16a, T16b, T18]
- **Description.**
  - Update `docs/reviews/cost-model.md` §2: the Graph rows with this plan's numbers, measured reads/writes from T16 and
    T18 replacing the estimates, and Block/Mute split out.
  - Update §3 and §4: recompute the crossover DAU.
  - Add a graph section to `docs/reviews/cost-report-v0.2.0.md`: per-RPC measured vs budget, daily totals at 300 DAU,
    and the abuse bounds.
  - Confirm no new service or fixed cost, and that `cost-guard` is clean.
- **Acceptance criteria.**
  - Given the report, then Firestore reads, writes and deletes at 300 DAU (identity + graph, as released in v0.2.0)
    are ≤ 80% of the free quota.
  - Given the whole-product model, then the §3 crossover is restated.
- **Test notes.** —
- **Observability.** Add a Logs Explorer query `jsonPayload.graph_op!="" | sum fs_reads by graph_op` to the
  dashboard notes. No new alert policies.
- **Budget.** Not applicable.

### T22 — Runbooks: account deletion/export, abuse, graph failure modes  [owner: production-deployer] [size: S] [depends: T11]
- **Description.**
  - **`docs/runbooks/account-deletion.md`:**
    - replace the `firestore:delete graph/$UID_` step with `opsctl purge-graph` (run *before* deleting
      `users/{uid}`, because counters and hydration depend on it);
    - add `opsctl export-graph` to §3a (export: following, followers, blocked, muted; never who blocked them).
  - **`docs/runbooks/abuse-spike.md`:** a follow-spam and list-scrape section:
    - Logs queries for `QUOTA_EXCEEDED quota=follows` and `limit_name=graph_list_daily`;
    - lower `QUOTA_FOLLOWS_PER_DAY` / `LIST_CALLS_PER_DAY` with the pinned-traffic procedure;
    - `FEATURE_GRAPH=off` as a kill switch;
    - disable the account.
  - **New entry in `docs/runbooks/graph.md`:**
    - `blockedby_cap_reached`: moderation review of the blocked account;
    - counter drift suspected: run the T16a invariant checker logic against dev; prod repair = a count() aggregation
      per affected user, then a manual set, recorded;
    - transaction contention WARNs.
- **Acceptance criteria.**
  - Given a dev test account with follows and blocks, when the new deletion runbook is followed end to end on
    `dzeroth-dev`, then the account leaves no graph residue (verified with the T16a checker) and the steps took
    < 10 min.
- **Test notes.** Record the drill outcome in the runbook (date, dev).
- **Observability.** —
- **Budget.** Drill ≈ tens of ops on dev.

### T23 — Infra and config: flags, limits, indexes, dev deploy  [owner: production-deployer] [size: S] [depends: T2, T3, T4, T5]
- **Description.**
  - Terraform `api` env vars:
    - `FEATURE_GRAPH` (dev `on`, prod `off`), `FEATURE_GRAPH_ALLOWLIST`, `FEATURE_GRAPH_PERCENT`;
    - `QUOTA_BLOCKS_PER_DAY`, `QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY`;
    - `LIST_CALLS_PER_DAY`;
    - the new per-procedure rate-limit settings;
    - CheckHandleAvailability at 20/min.
  - No new resources (`cost-guard` clean).
  - Deploy `firestore.indexes.json` (the `blockedBy` exemption) to dev.
  - Deploy the build to `dzeroth-dev` and run the T17 smoke on dev.
  - Run the one-off L9 check on **prod**: a `count()` aggregation `users where isPrivate == true` (≈ 1 read). If the
    result is > 0, list the uids for the founder, then set them to false by hand (documented) before v0.2.0.
- **Acceptance criteria.**
  - Given `terraform plan` for prod, then the only changes are env vars (0 to add).
  - Given dev, then the T17 smoke passes and indexes are READY.
  - Given prod, then the private-user count is recorded in the readiness doc (expected 0).
- **Test notes.** —
- **Observability.** Check that the startup log shows `feature_flags` on dev and on prod `candidate`.
- **Budget.** Dev smoke ≈ 30 ops. The L9 check: 1 read.

### T24 — Release v0.2.0 through the readiness process (flag off, then allowlist)  [owner: production-deployer] [size: M] [depends: T17, T19, T20, T21, T22, T23]
- **Description.**
  - Prepare the inputs for `docs/reviews/release-v0.2.0-readiness.md`: this plan, ADR-0008, the test report, the code
    and security reviews, the cost report, runbooks, release notes, the rollback target (the current prod revision),
    the flag plan, and the L9 check result.
  - production-reviewer runs the `production-readiness` checklist and must write `VERDICT: GO`.
  - Tag `v0.2.0`. `release-prod` stages a `candidate` revision with **`FEATURE_GRAPH=allowlist`** (founder + 2
    prod smoke test accounts).
  - P2 smoke on `candidate`:
    - the v0.1.0 identity checks;
    - the T17 graph smoke with allowlisted accounts;
    - a non-allowlisted account gets `FEATURE_DISABLED`;
    - indexes READY;
    - 0 `severity>=ERROR`.
  - Promote 10% → watch 15 min → 100% (ask the human before 100%). Deploy Hosting (web UI hidden unless the flag is on).
- **Acceptance criteria.**
  - Given the readiness doc, then it ends with `VERDICT: GO`, with human sign-off for any §4 acceptances.
  - Given prod at 100% with `allowlist`, then allowlisted accounts can follow, block and list, and others see no graph
    UI.
  - Given the P6 watch (+1 h, +24 h), then there are no rollback triggers.
- **Test notes.** The smoke accounts are cleaned up with `opsctl purge-graph` plus the deletion runbook.
- **Observability.** The P6 watch adds `graph_op` `fs_reads`/`fs_writes` sums and the `feature_disabled` count.
- **Budget.** Smoke ≈ 30 ops.

### T25 — Flag rollout in prod: allowlist → 10% → 100%  [owner: production-deployer] [size: S] [depends: T24]
- **Description.** Stage the flag with the pinned-traffic env update procedure, then reconcile Terraform:
  1. allowlist for ≥ 48 h;
  2. `percent=10` for ≥ 24 h;
  3. `on`.

  At each step, check the rollback triggers below. Afterwards append the actuals (reads/writes per DAU for graph) to
  `cost-model.md` §8 and write `docs/reviews/release-v0.2.0-postrelease.md`.
- **Acceptance criteria.**
  - Given each stage, then the trigger checks are recorded in the post-release doc.
  - Given `on`, then Terraform prod has `FEATURE_GRAPH=on` and `terraform plan` shows no drift.
- **Test notes.** —
- **Observability.** As T24.
- **Budget.** Not applicable.

### Follow-up tickets from ADR-0008 "Amendment 2026-09-30: M4 decisions" (A1–A3)
Added by the architect, 2026-09-30. **None of them blocks v0.2.0** (prod at `off` → `allowlist`, where testers are
trusted and Firebase uids can't reach the edge cases). **T26 and T28 block T25 step 2 (`percent`).** T27 blocks the
account-lifecycle (in-app deletion) plan. T29 lands together with T26 and T28. T30 is optional backlog.
These tickets don't touch any file that the in-flight fix work owns (cursor encryption, daily caps, reserved-id
validation, GetProfile non-ACTIVE, Unfollow retry), except that T28 **rebases on the reserved-id change** (same
validator).

Deltas to existing tickets:
- **T16a:** Follow replay asserts 4 R cold and 2 R warm (A2), not "2". Add the A1 Mute cases and the A3 `_` cases
  below.
- **T21:** graph reads/DAU = 12.3, using the ADR A2 table and planning values. **Updated by ADR-0008 Amendment
  2026-09-30 (2):** Follow plans at 4 (not 3) and Unfollow logs 1, so 12.9 (13.1 with T21's measured list
  midpoint).
- **T22:** `account-deletion.md` states that other users' `muted[]`/`blocked[]` entries for the deleted uid are cleaned
  lazily (T27).

### T26 — Mute: target existence check, same rule as Block (ADR-0008 A1)  [owner: backend-developer] [size: S] [depends: T8] [blocks: T25 `percent`]
- **Description.**
  - In `FirestoreRepo.Mute`, read the target graph with the existing `getGraphTxExists`, right after the caller graph
    and **before** `quota.Get` (the same order as Block). If it's missing, return `ErrNotFoundOrBlocked`. The service
    maps that to `notFoundErr()`.
  - No `identity.Directory` call: the rule is "`graph/{target}` exists", not "target is ACTIVE" (ADR A1 option A′ is
    rejected as a block oracle).
  - Mute must not read or branch on `blockedBy`.
  - Update the Go doc comments on the repo and service `Mute` (reads 3, NOT_FOUND 2, replay 3).
- **Acceptance criteria.**
  - Given a well-formed uid with no `graph` doc, when A mutes it, then NOT_FOUND byte-identical to Block's NOT_FOUND,
    0 writes, `quotas/{A}` unchanged, and `fs_reads=2`.
  - Given B blocks A, when A mutes B, then OK with `muting=true`. The response has no field that differs from muting
    a stranger (serialized compare, with user id normalized). `fs_reads=3`, `fs_writes=2`.
  - Given B is SUSPENDED or DELETING (graph doc present), when A mutes B, then OK.
  - Given B was purged (`opsctl purge-graph`), when A mutes B, then NOT_FOUND.
  - Given A already mutes B, when replayed, then OK with 0 writes and 3 reads.
  - Given the `blocks` quota is exhausted, when A mutes an existing B, then `QUOTA_EXCEEDED` (unchanged). A
    nonexistent target still gets NOT_FOUND and 0 writes.
- **Test notes.** Emulator (T16a file). Add a unit test with a fake repo for the error mapping. Add the four A1 Mute
  rows (blocker, SUSPENDED, DELETING, purged) to the T16b D9 matrix.
- **Observability.** `outcome=rejected:not_found` once L8 lands. Until then the request line shows `code=not_found`
  and `fs_reads=2`.
- **Budget.** Mute 3 R / 2 W (+1 read vs today); NOT_FOUND 2 R / 0 W; replay 3 R / 0 W. At 0.02 calls/DAU that's
  +0.02 reads/DAU.

### T27 — Lazy clean-up of missing uids in own blocked/muted lists (ADR-0008 A1, D10 refinement)  [owner: backend-developer] [size: S] [depends: T9] [blocks: account-lifecycle plan; not v0.2.0, not T25]
- **Status: built (PR feat/graph-t27-lazy-cleanup).** `identity.Directory.LookupProfiles` (found + confirmed-missing; a
  negative-cache-only miss is not reported), `graph.Repo.RemoveOwnArrayEntries` (blind ArrayRemove + updatedAt on
  the caller's own doc, NotFound = no-op), `lazyCleanup` in `lists.go`. Fields `hydration_misses`, `lazy_removed`.
  Emulator-measured: cleaning page = 4 R / 1 W (1 graph + 3 profile docs), repeat call = 4 R / 0 W.
- **Description.**
  - Extend `identity.Directory` (reuse-first: a new method, no second cache). For example,
    `LookupProfiles(ctx, uids) (found map[string]Profile, missing []string, err)`, where `missing` means "no
    `users/{uid}` doc". Implement `GetProfiles` on top of it so existing callers don't change.
  - Missing results are never cached (as today).
  - Non-ACTIVE users are neither `found` nor `missing` for this purpose. They must never be removed.
  - In `listOwnArray`, when `missing` is non-empty, issue one `Update(graph/{caller})` with
    `ArrayRemove(missing...)` on the listed array (`muted` or `blocked`) plus `updatedAt`. Then invalidate the caller
    snapshot on this instance.
  - Best effort: on error, log WARN `graph_lazy_cleanup_failed`. The list RPC still succeeds. The page result is
    unchanged, because missing rows were already dropped.
  - Log `hydration_misses` and `lazy_removed=<n>`, counts only. Never log uids.
  - The page token computation must not shift because of the removal. Tokens resume by uid plus recorded position
    (ADR-0008 "ListBlockedUsers/ListMutedUsers paging"), which already tolerates removed entries.
- **Acceptance criteria.**
  - Given A mutes B, and B is purged with `users/{B}` deleted, when A calls ListMutedUsers, then B isn't listed, B is
    removed from `graph/{A}.muted`, and exactly 1 extra write happens. A second call makes 0 writes.
  - Given B is SUSPENDED, when A lists, then B is hidden and **stays** in `muted[]` (0 writes).
  - Given the same for `blocked[]`, when a dangling entry is left by a D2 overflow or an L5 purge race, then it's
    removed on list view and the T16a invariant checker passes.
  - Given the clean-up write fails (fault-injected fake), then the RPC returns the page and logs WARN.
- **Test notes.** Emulator plus a unit test with a fake Directory. This covers security review L2 case T16b-6.
- **Observability.** `lazy_removed` on the request log line (via `logger.RequestInfo`, the same pattern as L8).
- **Budget.** 0 extra reads (hydration's `GetAll` already fetches the missing docs). +1 write only on a page that
  contains a missing uid, once per stale entry, ever. That's ~0 per DAU.

### T28 — Reserve `_` in uids: shared validator, caller uid, `edgeID` helper (ADR-0008 A3)  [owner: backend-developer] [size: S] [depends: the in-flight reserved-id validation change] [blocks: T25 `percent`]
- **Description.**
  - Change the shared uid validator (`identity.ValidUserID` / `userIDRe`, as modified by the in-flight reserved-id
    work) to `^[A-Za-z0-9-]{1,128}$`. Keep ≤ 128 and keep `-`.
  - Update the validation messages in `graph/rpcs.go` and `graph/validate.go` ("1-128 characters of [A-Za-z0-9-]").
  - The reserved-id rule stays for handles. For uids it is now implied; keep its test.
  - **Caller uid:** in `pkg/platform/authn`, after the ID token is verified, reject a uid that fails the same
    predicate with UNAUTHENTICATED and log WARN `uid_format_rejected` with `uid_hash`. Do this before any Firestore
    read.
  - To avoid an import cycle (authn can't import identity), move the predicate to `pkg/platform` (for example
    `pkg/platform/ids.ValidUID`), make `identity.ValidUserID` delegate to it, and record it in `docs/code-map.md`.
  - **`edgeID(a, b string) (string, error)`** in `internal/graph` is the only place a `follows` doc id is built.
    `followRef` and Block's edge deletes use it. It returns an error if either uid contains `_` (INTERNAL, which
    means a bug, because validation should have caught it).
  - One-off verification: run `firebase auth:export` on `dzeroth-dev` and `dzeroth-prod` (0 Firestore reads) and
    count uids containing `_`, expecting 0. Record the result in the PR. If any are found, stop and escalate to the
    architect.
- **Acceptance criteria.**
  - Given a target uid `a_b`, when Follow, Unfollow, Block, Unblock, Mute, Unmute, GetRelationships, ListFollowers,
    GetProfile or `opsctl --uid` receives it, then INVALID_ARGUMENT `VALIDATION`, 0 reads, and 0 ERROR lines.
  - Given an emulator custom token with uid `x_y`, when it calls any authenticated RPC, then UNAUTHENTICATED and
    0 Firestore reads.
  - Given `edgeID("a_b", "c")`, then an error (unit test).
  - Given all existing fixtures (`uid-*`), then unchanged and passing.
- **Test notes.** T16a cases for all three layers. Integration: a regression test showing that the A3 collision
  (`a_b → c` then `a → b_c`) can no longer be constructed.
- **Observability.** WARN `uid_format_rejected` (hashed uid).
- **Budget.** 0 reads and 0 writes. Validation only.

### T29 — Proto comments and data-model skill for A1–A3  [owner: architect] [size: S] [depends: T26, T28 (land in the same PR as T26 to avoid two regenerations)] [blocks: T25 `percent`]
- **Description.**
  - Comment-only `graph.proto` changes: Follow `reads 4 cold / 2 warm (+1 overflow), writes 5; replay 4 cold / 2 warm,
    writes 0`; Mute `reads 3, writes 2 (0 on replay); target without an account => NOT_FOUND`; the `user_id` charset
    `[A-Za-z0-9-]{1,128}`. Run `make proto`, and confirm `buf breaking` is clean.
  - Update the `firestore-data-model` skill's operation cost rows (Follow cold/warm, Mute 3/2) and add the "no `_` in
    uids" invariant under IDs.
- **Acceptance criteria.** `buf lint` and `buf breaking` are clean. The generated code diff contains comments only.
  The skill matches the ADR A2 table.
- **Budget.** Not applicable.

### T30 — (Optional) Update cached profiles in place after graph mutations instead of `Forget`  [owner: backend-developer] [size: S] [depends: T7] [blocks: nothing]
- **Description.** After a committed Follow, Unfollow or Block, apply the counter deltas to this instance's cached
  `users` entries instead of evicting them. This follows the CLAUDE.md read-your-writes rule: update the cache from
  written data. That brings Follow's planning cost from 4 R (measured, ADR-0008 Amendment 2026-09-30 (2) B1) back to
  2–3 R, and makes an immediate replay warm.
- **Acceptance criteria.** Given two consecutive Follows by A on one instance of targets whose profiles are cached,
  then the second reads 2 (not 4). Given GetProfile(A) right after, then the counts reflect the follow with 0 reads.
- **Budget.** Up to −1.0 reads/DAU (0.5 Follows × ≤ 2 reads) plus the Unfollow interceptor read (−0.1).
- **Parked (founder decision, ADR-0008 Amendment 2026-09-30 (2) B2):** `Forget` is kept for counter correctness. The
  old "> 2.5 reads/call" trigger is replaced by the B2 reopen criteria (80%-line breach with `Forget`-attributable
  reads ≥ 5% of daily reads, or a ≥ 10% crossover shift). Do not schedule unless one of them is met.

---

## Rollout plan
- **Flags:** `FEATURE_GRAPH` (server; env var in Terraform), mirrored to clients through `GetMe.enabled_features`.
  - Defaults: **off** in prod and **on** in dev and local.
  - When the flag is off, graph RPCs return `FEATURE_DISABLED` with 0 reads, and every graph UI element is hidden.
  - The identity changes (GetProfile block check, L9 rejection, GetMe field) are **not** flagged. They are
    backward-compatible and safe with an empty graph.
- **Stages:**
  1. dev (`on`, T23);
  2. prod v0.2.0 `candidate` with `allowlist`, then smoke, then traffic 10% → 100% (T24);
  3. flag allowlist (≥ 48 h) → 10% of uids (≥ 24 h) → 100% (T25).
- **Rollback triggers (any one):**
  - 5xx ratio > 2% with ≥ 50 requests in 15 min;
  - warm p95 > 2× the dev baseline on any graph RPC or on GetProfile / GetMe;
  - any unexplained `severity>=ERROR`;
  - Firestore > 15k reads/day or > 5k writes/day in week 1 (launch-scale DAU);
  - > 20 `QUOTA_EXCEEDED quota=follows` per day, or any `graph_list_daily` rejections from > 3 uids (abuse signal:
    run `abuse-spike.md`);
  - a counter/edge invariant violation found by the smoke test;
  - any budget alert.
- **Rollback actions (lightest first):**
  1. `FEATURE_GRAPH=off` via the pinned-traffic procedure (`cost-spike.md`). Data stays; re-enable later.
  2. Tighten quotas and limits by env.
  3. Before 100% traffic, route to the previous revision.
  4. `DEGRADED_MODE=readonly`.

  Firestore data needs no rollback: expand-only schema, and `blockedBy` is ignored by older code.

## Risks
| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Launch-day follow burst: 300 new users × 20 follows × 5 writes = 30k writes, above the 20k/day free quota for one day | Medium / cents | Pay-per-use (≈ $0.02); the new-account quota of 50 bounds it; watched in P6 |
| Block propagation is stale on other instances for ≤ 60 s, so a just-blocked user may still see the profile briefly | Low / low | Mutations are transactional and fresh; max 3 instances, usually 1; the security review accepts it or asks for a shorter TTL (Q8) |
| `blockedBy` makes the "who blocked me" data a privacy liability | Low / high if leaked | Never serialized or exported; the grep test in T16b; security review T20 |
| Deferring private accounts disappoints users, or `isPrivate=true` exists in prod | Medium / low | L9 closed (reject + prod count check in T23); `private-accounts` plan queued next to posts |
| A list-scraping account burns most of the daily read quota | Low / cents | Daily list cap, buckets, logs query, `abuse-spike.md`; lever: page_size 20 for other users' lists |
| Counter drift from a bug in non-transactional paths | Low / medium (visible counts) | All counter changes sit in the same batch or transaction as the edge change; invariant checker; runbook repair |
| Hot `users/{uid}` doc with > 1 follow/s (a viral account) causes contention | Very low at Stage 0 | Measured through `txn_attempts`; sharded counters need an ADR (free-tier-budget §6) |
| The profile screen is owned by two plans (graph now, posts later) | Medium / low | This plan builds only the header; the posts plan extends the body; ui-catalog entry |
| The manual deletion runbook becomes wrong once graph data exists | High if T22 is skipped | T22 is a hard dependency of T24 (readiness checks the runbook) |
| The in-memory daily list cap resets on scale-to-zero or a new instance, so the effective cap is higher | Medium / low | Documented as approximate (like ADR-0006 buckets); worst case bounded ×3 by max instances |

---

## Open design questions (architect decides in T1 / ADR-0008; default in bold)

**Q1. Do private accounts and follow requests ship in this slice?**
- **Default: no.**
  - Privacy only protects content, and there are no posts yet.
  - The visibility job (ADR-0003) needs the posts module.
  - Deferring saves about 4 tickets (Follow's private branch, ListFollowRequests, RespondToFollowRequest, the inbox
    screen and the privacy toggle UI).
- Close L9 by rejecting `is_private=true` in UpdateProfile (VALIDATION) plus a prod `count()` check.
- The request RPCs return `FEATURE_DISABLED`.
- Needs the founder's acceptance.
- Alternative: ship them now. That adds ≈ 1.5 days of backend and 1 day of frontend, and the ListFollowers/Following
  privacy rule: owner or approved follower only, via `target ∈ caller.following`, 0 extra reads.

**Q2. How does a read path know that the target blocked the viewer?**
- **Default: store `blockedBy[]` on `graph/{uid}`, written by Block/Unblock on the target's doc, capped at 10,000.**
  - Every visibility check becomes part of the viewer's single cached graph read: GetProfile, list-row filtering,
    Follow, and later the timeline, threads and mentions.
  - Cost: Block/Unblock always write the target graph (+1 write, ~0.02 calls/DAU).
- Alternative: read the target's graph per check. That is an N+1 in list hydration (+≤ 50 reads/page), and the
  timeline could not drop authors who blocked the viewer without per-author reads.
- Also decide what happens at the cap: default is to keep the blocker's `blocked[]` entry, skip `blockedBy`, and log
  ERROR for moderation.

**Q3. Counter "fan-out" and consistency.**
- **Default:** `FieldValue.Increment` on `users/{a}` and `users/{b}` in the same transaction or batch as the edge
  change (ADR-0003 rule 3).
  - No sharding and no async recount.
  - Block combines decrements per doc.
  - The purge decrements counterpart counters.
  - Invariant: the `follows` doc exists ⇔ the `following[]` entry exists; counts = edges.
- Confirm that no async counter fan-out (Pub/Sub) is wanted at Stage 0.

**Q4. How does GetRelationships batch, and should list rows carry the relationship?**
- **Default:** GetRelationships computes everything from the caller's own graph doc (1 read, 60 s cache) for ≤ 50 ids.
  - It never reports `followed_by` (that would be 1 read per id).
  - It never reflects `blockedBy`.
- Add `UserListItem.relationship = 3` (additive), filled from the already-loaded caller snapshot. This saves one
  request per list page.
- Alternative: no proto change; the client calls GetRelationships per page (+1 request, ≤ 1 read).

**Q5. Proto changes.** **Default: the additive set in "Proto and schema changes":**
- `UserListItem.relationship`;
- `GetMeResponse.enabled_features`;
- `ERROR_REASON_TARGET_BLOCKED` / `ERROR_REASON_FEATURE_DISABLED`;
- comment-only budget and semantics updates.

No renumbering and no `v2`.

**Q6. Feature-flag mechanism (none exists today).**
- **Default:** env vars (`FEATURE_GRAPH` off/allowlist/percent/on).
  - 0 reads, and flips use the drilled pinned-traffic procedure.
  - Clients learn about it from `GetMe.enabled_features`.
- Alternatives:
  - the `admin/config` doc named in ADR-0003, with a 5-min cache: ≈ 100–288 reads/day per live instance, but flips
    without a revision;
  - Firebase Remote Config: free, but a new client dependency, and the flag is split between server and client.
- This becomes the pattern for every Phase 1 flag, so it deserves a decision.

**Q7. Abuse limits for block/mute and list scraping.**
- **Default:**
  - a new `quotas.blocks` covering Block + Mute: 200/day (new accounts 50). Unblock/Unmute are never quota-gated.
  - per-procedure buckets: Follow/Unfollow 30/min, Block/Unblock/Mute/Unmute 20/min, lists 20/min.
  - an in-memory daily cap of 100 list calls per uid per instance.
  - `page_size` max 50 everywhere (lever: 20 for other users' lists).
  - CheckHandleAvailability at 20/min (R-N8).
- Record this as an ADR-0006 follow-up inside ADR-0008.

**Q8. Is ≤ 60 s block staleness on read paths acceptable?**
- **Default: yes.** Mutations read fresh in transactions; read paths use the 60 s cache (ADR-0004 staleness budget),
  updated immediately on the instance that handled the Block.
- Alternative: a 10 s TTL for graph docs (≈ 6× more graph reads on busy instances).

**Q9. Block semantics table.** **Default:**
- Block removes follows in both directions (and, later, pending requests).
- The blocked user gets NOT_FOUND on the blocker's profile and lists (identical to a missing account), can't follow
  (NOT_FOUND), and sees NONE in GetRelationships.
- The blocker can still view the blocked user's profile (to unblock). Following them returns `TARGET_BLOCKED`
  (no auto-unblock).
- List rows hide users in either direction of a block with the viewer.
- Unblock doesn't restore follows.
- Mute is invisible to the target and affects only the muter's timelines and notifications.
- Obligations for later plans: timeline, threads, replies, mentions and notifications must filter on
  `blocked ∪ blockedBy` (and `muted` where relevant) via `graph.Reader`.
- Also decide whether to accept the residual leak "CheckHandleAvailability says taken while GetProfile says NOT_FOUND".
  Default: accept; X shows "you're blocked" anyway.

**Q10. Delete cascade shape.**
- **Default:** `graph.Eraser.PurgeUser` is resumable and checkpointed, following the 5-step algorithm in T11.
- Other users' `muted[]` entries are cleaned lazily on hydration, because arrays are unindexed.
- It is used now by `opsctl purge-graph` (manual runbook) and later by the `account-delete` Pub/Sub job.
- Confirm that the orchestrator stays in identity (account-lifecycle plan) and calls `graph.Eraser` through its
  interface.

**Q11. Follow notifications.** **Default:** deferred to the notifications plan. Graph calls a no-op
`FollowEvents.Followed(a,b)` after commit. That plan decides between a synchronous in-batch write and Pub/Sub.

**Q12. Export contents (DPDP/GDPR).** **Default:** the export includes following, followers, blocked and muted. It
excludes `blockedBy`, which is third-party data about who blocked the subject.

**Q13. Ownership of the profile screen.** **Default:** this plan builds the header (identity data + graph actions). The
posts or profile-timeline plan adds the tabs and body. Architect or planner confirm, to avoid two plans editing the
same widget at once.
