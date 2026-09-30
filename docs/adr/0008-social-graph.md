# 0008. Social graph slice: follows, blocks, mutes, feature flags and graph quotas
Status: Accepted. All items, including D12 (export contents), which the founder decided on 2026-09-28.
Amended 2026-09-30 ("Amendment 2026-09-30: M4 decisions" below): Mute target existence, the cold/warm budget
convention (supersedes the per-RPC table in Cost impact) and the `_` uid invariant for edge doc ids.
Date: 2026-09-28
Deciders: architect, founder (D1: private accounts and follow requests deferred — founder decision, 2026-09-28)

Inputs: `docs/plans/graph.md` (questions Q1–Q13), CLAUDE.md, ADR-0002, ADR-0003, ADR-0004, ADR-0006 (+ amendments
2026-09-27 and 2026-09-28), `docs/reviews/cost-model.md`, `docs/reviews/release-v0.1.0-readiness.md` §4 (L9, R-N8, R-N12).
Contract: `dzeroth.graph.v1.GraphService`; changes to `identity.v1` and `common.v1` listed in D5.

## Context
Stage 0 (0 – ~300 DAU, $0/month). v0.1.0 shipped identity only; `backend/internal/graph` has nothing but `InitGraph`.
The graph is the input to the home timeline (ADR-0004 filters on `following`, `blocked`, `muted`) and to
notifications, and blocking is half of the UGC "report + block" gap (R-N12). Constraints:
- Firestore free quota 50k reads / 20k writes / 20k deletes per day; reads are the binding limit (cost model §3).
- ADR-0003 fixed `graph/{uid}` as the caller's whole social context in one document (1 read) and edge docs
  `follows/{a}_{b}` for list pages. ADR-0006 §6 requires NOT_FOUND for blocked-by (no existence leak) on every read.
- There is no feature-flag mechanism yet, and this is the first Phase 1 feature to need one. Whatever we choose
  becomes the Phase 1 pattern.
- Readiness item L9: `isPrivate` can be set but is not enforced.

Stage-0 functional requirements: public follow/unfollow with counts and lists; block (cuts edges both ways, hides the
blocker from the blocked user); mute (silent); a relationship lookup for follow buttons; a resumable graph purge for
the manual deletion runbook. Non-functional: plan targets (Follow/Block p95 < 500 ms warm, lists < 400 ms,
GetRelationships < 150 ms, GetProfile ≤ baseline + 20 ms), every RPC with a bounded worst-case read count, every
mutation idempotent and replay-safe, $0 fixed cost.

## Options
Four independent choices. $ figures are Firestore/Cloud Run list-price upper bounds from `cost-model.md` §7, for the
graph slice alone; "300 DAU" is marginal on top of the whole-product model (whose reads already exceed the free line at
~266 DAU), so it prices every graph read as overage.

### 1. How a read path learns "the target blocked the viewer"
**A. `graph/{uid}.blockedBy[]`, written on the target's doc by Block/Unblock (chosen).**
- Pros: every visibility check (GetProfile, Follow, list-row filtering, and later timeline/threads/mentions) is part
  of the viewer's one cached graph read. No N+1 anywhere.
- Cons: Block/Unblock always write a second graph doc (+1 write, ~0.02 calls/DAU); `blockedBy` is sensitive
  third-party data that must never leave the server; the doc needs a cap and an overflow rule.
- Cost: idle $0; 300 DAU ≈ $0.06/month (the whole slice, see Cost impact); 3k DAU ≈ $1.70/month.

**B. Read the target's `graph` doc per check.**
- Cons: +1 read per GetProfile miss, +≤ 50 reads per list page for row filtering, and the timeline could not drop
  authors who blocked the viewer without one read per author (unbounded by page size).
- Cost: ≈ +5 reads/DAU/day now (≈ 17 vs 11.8) and O(authors) per timeline call later. At 3k DAU ≈ +$0.30/month now,
  several $/month once timelines consume it.

**C. `blocks/{blocker}_{blocked}` edge docs, point lookups.**
- Cons: same N+1 as B plus +1 write/+1 delete per block/unblock. Rejected.

### 2. Private accounts and follow requests in this slice
**A. Defer (chosen by the founder, 2026-09-28).** Privacy protects posts, and there are no posts yet; the visibility
job (ADR-0003) needs the posts module. Saves ≈ 4 tickets. Cost: $0 (request RPCs are 0-read stubs).
**B. Ship now.** ≈ +1.5 days backend, +1 day frontend; `followRequests` writes (+2 writes per request).

### 3. Feature-flag mechanism (the Phase 1 pattern)
**A. Env vars on the `api` service, mirrored to clients in `GetMeResponse.enabled_features` (chosen).**
- Pros: 0 reads; server is the only source of truth; flips use the drilled pinned-traffic env-update procedure
  (`cost-spike.md`); flag state is in Terraform and reviewed like code (rule 11).
- Cons: a flip is a new revision (~1 min); allowlists live in an env var (fine for tens of uids).
- Cost: $0 at every scale.

**B. `admin/config` doc, instance-cached 5 min.**
- Pros: flips without a revision. Cons: ≈ 288 reads/day per warm instance (≤ 864/day at 3 instances, ~1.7% of the
  read quota); flag state not in Terraform; a Firestore outage takes flags with it. Cost: ≈ $0.02/month at 3k DAU.

**C. Firebase Remote Config.** Free, but a new client SDK and a second source of truth (client could show UI that
the server rejects). Rejected.

### 4. Follow buttons on list rows
**A. Additive `UserListItem.relationship = 3`, filled from the caller's already-loaded graph snapshot (chosen).**
0 extra reads, saves one request per list page.
**B. No proto change; the client calls GetRelationships per page.** +1 request and ≤ 1 read per page (≈ +0.3
requests/DAU/day). Rejected: pure cost, no benefit.

## Cost impact
- **Fixed monthly cost added: $0.** No new GCP service, API or Terraform resource. The flag, quotas and limits are env
  vars on the existing `api` service; `opsctl` runs on the founder's machine with ADC. `cost-guard` has nothing to flag.
- **Per-RPC budget** (Firestore ops per call, worst / typical; these numbers are the proto comments, D5).
  **Superseded by A2 of the 2026-09-30 amendment** (cold/warm columns, measured T16a numbers). Kept for history;
  budget assertions, proto comments and the cost model follow the A2 table.

| RPC | reads | writes | deletes | Cloud Run ms | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|
| Follow | 4 / 2 (+1 if caller's `blockedByOverflow`, D2) | 5 / 5 | 0 | 60 | 0.5 | 1.0 | 2.5 | 0 |
| ↳ Follow replay (already following) | 2 / 2 | 0 | 0 | 30 | — | — | — | — |
| Unfollow (blind batch, `Exists` precondition; retried on Aborted*) | 0 / 0 | 3 / 3 (0 on no-op) | 1 / 1 | 40 | 0.1 | 0 | 0.3 | 0.1 |
| Block | 3 / 3 | 5 / 3 | 2 / 0 | 60 | 0.02 | 0.06 | 0.06 | ~0 |
| Unblock | 1 / 1 | 2 / 2 (0 on no-op) | 0 | 30 | 0.005 | ~0 | 0.01 | 0 |
| Mute | 2 / 2 | 2 / 2 (0 on replay) | 0 | 30 | 0.02 | 0.04 | 0.04 | 0 |
| Unmute | 1 / 1 | 1 / 1 (0 on no-op) | 0 | 30 | 0.005 | ~0 | ~0 | 0 |
| GetRelationships (≤ 50 ids) | 1 / 0.5 | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| ListFollowers / ListFollowing | 102 / 30 | 0 | 0 | 70 | 0.3 | 9.0 | 0 | 0 |
| ListBlockedUsers / ListMutedUsers | 51 / 10 | 0 | 0 | 40 | 0.02 | 0.2 | 0 | 0 |
| ListFollowRequests / RespondToFollowRequest (stubs) | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| IdentityService.GetProfile (changed) | 3 / 0–1 (+1 if viewer's `blockedByOverflow`) | 0 | 0 | 20 | 3 (already modelled) | ±0 | 0 | 0 |
| IdentityService.GetMe (changed: `enabled_features`) | 2 / 1 (unchanged) | 0 | 0 | 15 | 4 (already modelled) | ±0 | 0 | 0 |
| **Graph slice total** | | | | | **≈ 4.0 requests** | **≈ 11.8** | **≈ 2.9** | **≈ 0.1** |

- **Free-tier quota consumed at 300 DAU:** graph 3.5k reads/day (7.1%), 0.87k writes/day (4.4%), 30 deletes/day
  (0.2%), ≈ 36k Cloud Run requests/month (1.8% of 2M), ≈ 1.8k vCPU-s/month (1%), storage ≈ 30 MiB (≈ 1 KiB per
  follow edge incl. index entries; 3% of 1 GiB). With the v0.1.0 identity baseline (7.3 reads, 0.17 writes per DAU):
  5.7k reads (11.5%), 0.92k writes (4.6%).
- **Where each quota runs out (v0.2.0 = identity + graph only, ≈ 19.1 reads, 3.07 writes, 0.1 deletes, ≈ 11.3
  requests per DAU/day):** reads at ≈ 2,600 DAU (80% line ≈ 2,100); writes ≈ 6,500; deletes ≈ 200k; Cloud Run requests
  ≈ 5,900 DAU. Overage at 2× the read cliff (≈ 5.2k DAU): reads ≈ $0.90/month, writes $0. At 10× (≈ 26k DAU): reads
  ≈ $8.10/month, writes ≈ $3.30/month. **Whole product (cost-model §2):** graph moves ≈ 10.2 → 11.8 reads and
  3.35 → 2.9 writes per DAU; the reads crossover moves from ~213 to ~211 DAU on the 80% line. sre-performance
  restates §2–§4 in T21.
- \* Unfollow retries its batch up to 6 times (exponential backoff, <= ~0.8 s) on a lost lock race (Aborted; security-review follow-up D1). A failed
  attempt writes nothing and only the committed attempt is counted, so the row's budget is unchanged; an exhausted
  retry returns UNAVAILABLE (retryable), never INTERNAL.
- **$ for the slice:** idle $0; 300 DAU ≈ $0.06/month (marginal, all graph reads priced as overage); 3k DAU ≈
  $1.70/month (reads $0.64, writes $0.47, requests $0.14, vCPU $0.43).
- **Abuse bounds per account per day** (inputs to the T20 security review): follow/unfollow churn ≈ 1.6k writes (8% of
  free); block/mute churn ≈ 1.4k writes (7%); list scraping ≤ 300 calls × 102 reads ≈ 30.6k reads (61%, ≈ $0.02/day),
  lever: page_size 20 on other users' lists (≈ 12.6k); relationship enumeration 0 extra reads. Several abusive
  accounts can exhaust the daily free reads: that costs cents, is visible in `fs_reads` logs and the budget alert, and
  is handled by `abuse-spike.md` and the `FEATURE_GRAPH=off` kill switch.
- **Trigger that would change this:** a `users/{uid}` doc sustaining > 1 counter write/s (sharded counters, ADR), any
  account approaching the following cap at scale, or Firestore > 1.5M reads/day (free-tier-budget §6).

## Decision
Adopt option 1A, 2A, 3A and 4A, with the binding details below. D1–D13 answer plan questions Q1–Q13. Where this ADR
differs from the plan's defaults the item says **"Changed vs plan"** and why.

### D1. Private accounts and follow requests are deferred (Q1) — Accepted, founder decision 2026-09-28
- This slice ships public follow/unfollow, block and mute only.
- `UpdateProfile(is_private=true)` → INVALID_ARGUMENT + `ERROR_REASON_VALIDATION`, `metadata.field = "is_private"`,
  message "Private accounts are coming soon", 0 writes. `is_private=false` stays accepted. This **closes L9**.
- `ListFollowRequests` and `RespondToFollowRequest` stay in the proto (wire compatibility) and return
  FAILED_PRECONDITION + `ERROR_REASON_FEATURE_DISABLED` with 0 reads, whatever the flag state.
- `Follow` on a target whose stored `isPrivate` is true (legacy data only) → FAILED_PRECONDITION + `FEATURE_DISABLED`.
  Lists treat legacy private targets as public. The deployer's one-off `count()` check in prod (T23) must find 0 before
  v0.2.0; any hits are reset to false by hand and recorded.
- No writes to `followRequests/*` or `graph.requested[]` in this slice. `FOLLOW_STATE_REQUESTED` is unreachable.
- The `private-accounts` plan ships with or after `posts` and needs its own ADR section on the visibility job.

### D2. `blockedBy[]` with a cap and a fail-closed overflow (Q2) — Accepted. **Changed vs plan** (overflow rule)
- `graph/{uid}` gains `blockedBy[]` (uids that blocked `uid`), written only by Block/Unblock on the target's doc and by
  the purge. It is **never serialized to any client, never exported (D12), never logged as an array.**
- Document size: Firebase UIDs are 28 chars (≈ 29 bytes as an array element). Caps: following 5,000 + blocked 2,000 +
  muted 2,000 + requested 500 + blockedBy 10,000 = 19,500 entries ≈ 566 KB, safely under the 1 MiB doc limit. This
  assumes provider-issued UIDs; we never mint custom-token UIDs (identity validates ≤ 128 chars — do not raise it).
- **Overflow (changed).** The plan default was "at 10,000, skip `blockedBy`, log ERROR". That fails *open*: Follow
  and GetProfile check only `caller.blockedBy`, so a blocker whose entry was skipped could still be followed and
  viewed by the account they blocked. Instead:
  - When the target's `blockedBy` is at the cap, Block still adds the target to the caller's `blocked[]`, skips
    `blockedBy`, and sets `graph/{target}.blockedByOverflow = true` (written once, in the same transaction); ERROR log
    `blockedby_cap_reached` for moderation review.
  - When a viewer's `blockedByOverflow` is true, the fail-closed paths also read the other party's graph doc (cached
    60 s for read paths, fresh inside transactions) and treat `viewer ∈ other.blocked` as blocked-by: **Follow** (+1
    read, in the transaction), **GetProfile**, **ListFollowers/ListFollowing target check** (+1 read each).
  - List *row* filtering for an overflowed viewer uses only `blockedBy` (accepted residual: a blocker may appear as a
    row in a third party's list shown to that viewer). The blocker's posts can't reach the viewer's home timeline,
    because the block removed the edge and Follow is fail-closed. The posts plan decides thread/reply filtering for
    overflowed viewers.
  - Cost: 0 for every account that is not overflowed. At Stage 0 (< 10,000 users) the cap is unreachable; an account
    that reaches it is almost certainly abusive and will be under moderation.
- Unblock removes `blockedBy` normally; `blockedByOverflow` is never cleared automatically (moderation clears it after
  review; stale `true` only costs the overflowed account +1 read on those paths).

### D3. Counters and invariants (Q3) — Accepted (plan default)
- `followersCount`/`followingCount` change by `FieldValue.Increment` through `identity.Counters` **in the same
  transaction or batch as the edge change** (ADR-0002 unit of work, ADR-0003 rule 3). Block combines the two
  decrements per `users` doc. No sharding, **no async (Pub/Sub) counter fan-out** and no recount job at Stage 0.
- Invariants, checked by the T16a invariant checker after every scenario:
  1. `follows/{a}_{b}` exists ⇔ `b ∈ graph/{a}.following`;
  2. `users/{x}.followersCount` = number of `follows/*_{x}`; `followingCount` = number of `follows/{x}_*`;
  3. `b ∈ graph/{a}.blocked` ⇔ `a ∈ graph/{b}.blockedBy` (except when `graph/{b}.blockedByOverflow`);
  4. no follow edge in either direction between a and b while either blocks the other.
- How each mutation keeps them: Follow is a transaction that reads the caller graph fresh (the conflict point with
  Block, which also reads and writes the caller's graph — Firestore serializes them). Unfollow is a blind batch with an
  `Exists` precondition on the edge doc, so a replay or a race with Block fails the whole batch (0 writes → NONE).
  Block deletes edges indicated by the two `following` arrays in its transaction. The purge deletes edges with an
  `Exists` precondition (D10).
- Drift repair (runbook `graph.md`, T22): a `count()` aggregation per affected user, then a manual set, recorded.
- Revisit: a `users/{uid}` doc sustaining > 1 write/s (measured via `txn_attempts` WARNs) → sharded-counter ADR.

### D4. GetRelationships and per-row relationships (Q4) — Accepted (plan default)
- GetRelationships validates 1–50 ids, dedupes, keeps request order, and computes from the caller's cached snapshot
  only: `follow_state` (FOLLOWING/NONE), `blocking` (`id ∈ caller.blocked`), `muting` (`id ∈ caller.muted`). The
  caller's own id → NONE/false/false. It never reads another user's doc, never reports `followed_by`, and **never
  reflects `blockedBy`**: a user who blocked the caller looks like a stranger, apart from the caller's own
  `blocking`/`muting` bits (the caller's own data).
- `UserListItem.relationship = 3` is filled the same way on every list row (0 reads).

### D5. Proto changes (Q5) — Accepted (plan default). All additive; `buf breaking` clean
- `graph.v1.UserListItem.relationship = 3` (`Relationship`).
- `identity.v1.GetMeResponse.enabled_features = 5` (`repeated string`).
- `common.v1.ErrorReason`: `ERROR_REASON_TARGET_BLOCKED = 13` (FAILED_PRECONDITION: the caller blocks the target;
  unblock first), `ERROR_REASON_FEATURE_DISABLED = 14` (FAILED_PRECONDITION: feature not enabled for this caller).
- Comment-only updates: budgets in the table above, block semantics on Block/GetRelationships/List*, the
  request-RPC stubs, GetProfile's block check, UpdateProfile's `is_private` rejection.
- No renumbering, no `v2`. `firebase/firestore.indexes.json`: field override `graph.blockedBy` with `"indexes": []`
  (the other `graph` arrays are already exempt). `blockedByOverflow` is a tiny bool and stays indexed by default (it
  lets moderation query overflowed accounts). No composite index added.

### D6. Feature flags: env var + `GetMe.enabled_features` — the Phase 1 pattern (Q6) — Accepted. **Changed vs plan** (bucketing salt, retirement rule)
- Per feature `<NAME>` (upper snake case in env, lower snake case on the wire, e.g. `FEATURE_GRAPH` ↔ `"graph"`):
  - `FEATURE_<NAME>` = `off | allowlist | percent | on`; default `off`; any other value **fails startup**.
  - `FEATURE_<NAME>_ALLOWLIST` = comma-separated uids (Terraform variable, not a secret). Applies in `allowlist`
    and `percent` modes (allowlisted uids stay on while the percentage ramps).
  - `FEATURE_<NAME>_PERCENT` = 0–100. Bucket = `fnv32a(name + ":" + uid) % 100`. **Changed vs plan:** the plan
    hashed the uid alone, which gives every flag the same 10% cohort; salting with the flag name makes cohorts
    independent. Deterministic per uid.
- `pkg/platform/flags.Enabled(uid, name) bool`, loaded once at startup, 0 reads. Startup logs
  `feature_flags={graph: <mode>}`.
- **Server is authoritative.** Each guarded module checks the flag in its service layer before any Firestore access and
  returns FAILED_PRECONDITION + `FEATURE_DISABLED` (log `feature_disabled=true`).
- **Clients** read `GetMeResponse.enabled_features` (names enabled for this caller), treat a missing name as off,
  ignore unknown names, and on any `FEATURE_DISABLED` error hide the feature and refresh GetMe.
- **Retirement (changed vs plan: new rule).** Shipped clients gate UI on the name, so after a flag reaches `on` and its
  env vars are removed, the server keeps reporting the name as always enabled until the minimum supported app version
  no longer reads it. Never reuse a retired name.
- **What the flag does not cover:** enforcement of existing blocks (GetProfile NOT_FOUND, later timeline filtering) is
  not flagged. Turning `FEATURE_GRAPH` off must never un-hide a blocker. Only the GraphService RPCs are gated.
- Flips follow the pinned-traffic env-update procedure, then Terraform is reconciled (no drift).

### D7. Abuse limits for graph (Q7) — Accepted (plan default). Follow-up to ADR-0006 §3–§4
- Daily quota `quotas/{uid}.blocks` counts Block **and** Mute: 200/day, 50/day for accounts < 24 h
  (`QUOTA_BLOCKS_PER_DAY`, `QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY`). Replays (already blocked/muted) reserve nothing.
  **Unblock and Unmute are never quota-gated.** Follows keep 200/day (50 new).
- Per-procedure token buckets per uid per instance: Follow/Unfollow 30/min; Block/Unblock/Mute/Unmute 20/min;
  ListFollowers/ListFollowing/ListBlockedUsers/ListMutedUsers 20/min; GetRelationships the 60/min default.
- Per-procedure daily in-memory cap, an extension of the existing limiter (no second limiter): 100 list calls per uid
  per instance per IST day (`LIST_CALLS_PER_DAY`), log `limit_name=graph_list_daily`. Approximate by design (resets
  on new instances; ≤ 3× at max instances), like ADR-0006 buckets.
- `page_size` ≤ 50 everywhere; lever if scraping appears: 20 for other users' lists (config).
- CheckHandleAvailability 10 → **20/min** per uid (closes R-N8).
- All numbers are config/env (rule 11).

- **Amendment (security review L3/M3).** Ids of the form `__x__` are rejected as VALIDATION by the shared uid/handle
  validators (Firestore reserves them), and GetProfile (by id and by handle) returns the byte-identical missing-user
  NOT_FOUND for SUSPENDED and DELETING profiles unless the caller is the owner (0 extra reads). That restores the
  premise of the handle-availability residual accepted in D9.

### D8. Staleness (Q8) — Accepted (plan default)
- Mutations read the graph fresh inside their transaction; read paths use the 60 s instance cache (ADR-0004 staleness
  budget), updated in place on the instance that committed the change. A just-blocked user may see the blocker's
  profile for ≤ 60 s on *another* instance (max 3, usually 1). Revisit (a 10 s graph TTL, ≈ 6× more graph reads on
  busy instances) only if the T20 review or a user report requires it.
- Instance cache: the existing `pkg/platform/cache.LRU`, 5k graphs, 60 s. Graph docs are ~3 KB typical; an abusive
  account near the caps can be ~566 KB, so T5 logs `graph_doc_entries` on cache fill and sre-performance watches
  instance memory. Revisit with a byte-weighted cache if any instance exceeds 70% memory.

### D9. Block semantics (Q9) — Accepted. **Changed vs plan** (own blocked/muted lists)
A = caller. "A blocks B" = `B ∈ A.blocked`; "B blocks A" = `B ∈ A.blockedBy`; "C blocks A" = a third party C in a
list about B. NOT_FOUND is **byte-identical** to the missing-user error (same code, message, reason).

| RPC (called by A) | A blocks B | B blocks A | C blocks A (C appears in B's data) | A mutes B |
|---|---|---|---|---|
| GetProfile(B) by id or handle | profile returned (so A can unblock) | NOT_FOUND | unaffected | profile returned |
| CheckHandleAvailability(B's handle) | "taken" | "taken" (accepted residual, see below) | — | "taken" |
| Follow(B) | FAILED_PRECONDITION + `TARGET_BLOCKED` (no auto-unblock) | NOT_FOUND, 0 writes | — | allowed |
| Unfollow(B) | NONE, 0 writes (block already removed the edge) | NONE, 0 writes | — | normal |
| Block(B) | replay: `blocking=true`, 0 writes | allowed (both directions recorded) | — | allowed; mute kept |
| Unblock(B) | removes both sides; follows **not** restored | NONE, 0 writes if A doesn't block B | — | — |
| Mute(B) / Unmute(B) | allowed | allowed, no leak | — | replay: 0 writes |
| GetRelationships([B]) | NONE, `blocking=true` | NONE, false, false (same as a stranger) | — | `muting=true` |
| ListFollowers(B) / ListFollowing(B) | allowed; rows filtered as below | NOT_FOUND | C's row hidden | allowed |
| Rows in any followers/following list | B's row hidden | B's row hidden | C's row hidden | B's row shown (mute is silent) |
| ListBlockedUsers (A's own) | B listed | **B hidden** while B blocks A (changed) | — | — |
| ListMutedUsers (A's own) | — | **B hidden** while B blocks A (changed) | — | B listed |
| ListFollowRequests / RespondToFollowRequest | FEATURE_DISABLED (D1) | FEATURE_DISABLED | — | — |
| GetMe / UpdateProfile / ChangeHandle | unaffected | unaffected | — | unaffected |

- **Changed vs plan (own lists).** The plan said "list rows hide users in either direction", which read literally would
  empty ListBlockedUsers. Rule: the caller's own blocked and muted lists show the caller's own entries **minus users in
  `caller.blockedBy`**. Showing B's live snapshot there while GetProfile(B) says NOT_FOUND would reveal that B blocked
  A. Hiding B costs nothing: A's block/mute of B stays in force, and B reappears once B unblocks A. A can still Unblock
  or Unmute B by id.
- Block removes follow edges in both directions (and, once private accounts ship, pending requests both ways).
- Mute is invisible to the target and affects only the muter's timelines and notifications.
- **Residual accepted:** CheckHandleAvailability says "taken" while GetProfile says NOT_FOUND. It does not
  distinguish blocked-by from suspended or deleting accounts (also NOT_FOUND), so it confirms existence of a handle,
  not a block. security-auditor re-checks in T20; any mitigation is an amendment here.
- **Obligations on later plans** (timeline, posts/threads/replies, mentions, notifications, search): filter authors
  and actors on `blocked ∪ blockedBy` (and `muted` where the feature is a feed, not a direct interaction) via
  `graph.Reader.Snapshot`, never by reading `graph/*` directly.

### D10. Delete cascade (Q10) — Accepted. **Changed vs plan** (preconditions, batch sizes, start gate)
- `graph.Eraser.PurgeUser(ctx, uid, checkpoint) (next, done, err)`: the orchestrator stays in identity (the future
  account-lifecycle `account-delete` job, and `opsctl purge-graph` now) and calls `graph.Eraser` through its interface.
  graph never touches `users/*` except through `identity.Counters`.
- **Start gate (new):** purge runs only after `users/{uid}.status = DELETING` has been committed for ≥ 120 s (2× the
  60 s instance-cache TTL), so no instance still sees the user as ACTIVE and can create a new edge. Follow already
  rejects non-ACTIVE targets (NOT_FOUND) and the account-status interceptor rejects a DELETING caller.
- Steps, each in atomic batches of ≤ 500 ops, `Limit`ed queries:
  1. `follows where followerId == uid`, page 250 (2 ops per edge): delete the edge **with an `Exists` precondition** +
     decrement the followee's `followersCount`.
  2. `follows where followeeId == uid`, page 160 (3 ops per edge): delete the edge (`Exists`), `ArrayRemove(uid)` from
     the follower's `graph.following`, decrement the follower's `followingCount`.
  3. For each b in `graph/uid.blocked` (chunks of 500): `ArrayRemove(uid)` from `graph/b.blockedBy`.
  4. For each b in `graph/uid.blockedBy` (chunks of 500): `ArrayRemove(uid)` from `graph/b.blocked`.
  5. Re-run the step 1–2 queries (1 read each when empty), then delete `graph/uid`.
- **Replay story (Pub/Sub at-least-once, crashes):** steps 1–2 are self-resuming (processed edges no longer match the
  query). The `Exists` precondition (changed vs plan) makes two concurrent runs safe: if another run already deleted
  an edge, that batch fails and is retried from a fresh query, so no counter is decremented twice. Steps 3–4 are
  idempotent `ArrayRemove`s; the checkpoint (`{step, offset}`) only avoids redoing work. A counterpart doc that no
  longer exists (its owner was purged) is skipped and logged `purge_missing_counterpart`; never Set-merge (that would
  resurrect a deleted doc).
- Other users' `muted[]` entries can't be found (arrays are unindexed). They are removed lazily when
  ListMutedUsers/ListBlockedUsers hydration finds a missing user (`ArrayRemove`, +1 write, rare).
- Order in the runbook: purge graph **before** deleting `users/{uid}`, because counters and hydration depend on it.
- Cost at Stage 0: a user with 100 following / 100 followers ≈ 200 reads, ≈ 300 writes, 200 deletes, once per deletion.

### D11. Follow notifications (Q11) — Accepted (plan default)
- Deferred to the notifications plan. graph calls a no-op `FollowEvents.Followed(ctx, follower, followee, at)` after a
  commit that created an edge; replays and no-ops don't call it. It is post-commit and not transactional; the
  notifications plan decides between an in-batch write (via the `store.Batch` seam) and Pub/Sub, and should use a
  deterministic notification id per (follower, followee) so re-follows and redeliveries dedupe.
- The graph budget therefore has no "+1 async" write; the notifications plan adds its own row.

### D12. Export contents (Q12) — **Accepted (founder decision, 2026-09-28)**
- The export (and `opsctl export-graph` now) contains following and followers (uids + handles), blocked and muted.
- It **never** includes `blockedBy`, meaning who has blocked the subject. That's data about third parties, and revealing
  it would defeat blocking (X and others don't disclose it either).
- Founder decision (2026-09-28): "data export should never list who blocked the user". This applies to the manual
  runbook export, `opsctl export-graph` and the future in-app export alike.

### D13. Profile screen ownership (Q13) — Accepted (plan default)
This plan builds the profile header (identity data + graph actions); the posts/profile-timeline plan adds the tabs and
body. The header is a separate widget listed in `docs/ui-catalog.md` so the two plans don't edit the same widget.

### Other binding details
- **List paging (changed vs plan).** ListFollowers/ListFollowing query with `Limit(page_size)` (not `page_size+1`) and
  return a `next_page_token` whenever the query returned a full page. The plan's `+1` over-read made the worst case 103,
  not the 102 it documents, and costs 1 read on every page; without it, the only extra cost is one empty final call
  (1 read) when the total is an exact multiple of the page size. Pages may be short because of row filtering; clients
  follow `next_page_token` (as ADR-0004). Cursor = `cursor.Encode(key, binding, {createdAt, docId})`. **Amended (security review M1):** tokens are sealed with
  AES-256-GCM (key = HKDF-SHA256 of `CURSOR_HMAC_KEY`, no new secret), so they are opaque and cannot leak the doc id
  of a row the block filter hid; they are bound (AEAD data) to `caller|followers-or-following|target`, and expire after
  24 h. Tampered, foreign or expired tokens are INVALID_ARGUMENT/VALIDATION at 0 reads; pre-amendment tokens fail the
  same way (clients restart the list).
- **ListBlockedUsers/ListMutedUsers paging:** newest first (reverse array order), token = last uid returned + its
  position, sealed and bound to the caller and the list (`caller|own-blocked` / `caller|own-muted`, T16b D-5); if that uid was removed meanwhile, resume at the first entry older than the recorded position.
- **Idempotency:** all graph mutations are state-setting with natural keys (ADR-0003), so `idempotency_key` is
  validated for format and not stored. No idempotency docs.
- **Degraded mode:** `DEGRADED_MODE=readonly` rejects every mutating graph RPC (derived from `idempotency_level`, no
  hand-kept list); reads keep working.
- **Required log fields** (every graph RPC): `graph_op`, `outcome` (`created|replay|noop|rejected:<reason>`),
  `fs_reads`, `fs_writes`, `fs_deletes`, `graph_cache_hit`, `txn_attempts` (WARN when > 3), plus `edges_removed`
  (Block), `rows_filtered` and `hydration_misses` (lists), `feature_disabled=true` (flag rejections),
  `limit_name` (limits), ERROR `blockedby_cap_reached`, `graph_purge_batch` and `purge_missing_counterpart` (purge).
  Never log the contents of graph arrays.

## Consequences
- Positive: every block/visibility check stays inside the viewer's single cached graph read, which is what the pull
  timeline (ADR-0004) needs; the slice costs ≈ 12 reads and 3 writes per DAU/day, $0 at Stage 0; the flag pattern
  costs 0 reads and is reusable for every Phase 1 feature; L9 and R-N8 close, R-N12 half-closes (block).
- Negative: `blockedBy` is a privacy liability that must never be serialized (grep test in T16b, security review
  T20); a blocked user can see the blocker's profile for ≤ 60 s on another instance; private accounts are
  user-visibly missing; the in-memory list cap is approximate; overflowed accounts have a documented residual in list
  rows.
- Follow-up: the `firestore-data-model` skill tables are updated with this ADR (graph row, Follow/Block rows,
  quotas); sre-performance restates cost-model §2–§4 (T21); runbooks `account-deletion.md`, `abuse-spike.md` and a new
  `graph.md` (T22); the `private-accounts` plan with its visibility-job section.
- Revisit when: a `users` doc sustains > 1 write/s; an account nears 5,000 following at scale; graph cache memory
  > 70% of an instance; T20 finds the 60 s block staleness or the handle-availability residual unacceptable; or
  Firestore > 1.5M reads/day.

## Amendment 2026-09-30: M4 decisions
Status: Accepted. Deciders: architect. No fixed cost and no non-negotiable rule bends, so no founder sign-off is
required. The founder is informed through the v0.2.0 readiness doc.

Inputs: T16a emulator measurements (M4), `docs/reviews/security-review-graph.md` (L2, L3, L5, I2, §4),
`backend/internal/graph/repo_firestore.go` (Mute, `followRef`), `backend/internal/graph/rpcs.go`,
`backend/internal/identity/validate.go` (`userIDRe`). Three questions came up during M4 verification. This amendment
answers them. It **refines D9 (Mute row), D10 (lazy clean-up) and D2 (uid-shape assumption), and supersedes the
Cost impact per-RPC table.** Every other decision above stands. Follow-up tickets are T26–T30 in `docs/plans/graph.md`.

### A1. Mute checks that the target exists, using the same rule as Block (security review L2)
**Context.** Mute accepts any well-formed uid (1–128 chars), including ones that don't exist. It stores the uid in
`muted[]` and spends `blocks` quota. Two consequences:
- `muted[]` can fill with junk up to 128 bytes per entry, about 258 KB instead of the 58 KB that D2 assumed.
- D10's promised lazy clean-up was never built, so purged uids stay in other users' `muted[]` indefinitely.

**Options.**
- **A. NOT_FOUND when the target has no account (chosen).** The check reads `graph/{target}` inside the Mute
  transaction. That is Block's existence rule, reached through the same `getGraphTxExists`.
  - Pros: no junk entries, and D2's 28-char size assumption holds for `muted[]` too. Mute and Block give the same
    answer for every target, so Mute reveals nothing that Block doesn't already reveal.
  - Cons: +1 read on every Mute (0.02 calls/DAU, so +0.02 reads/DAU). The target graph doc is now in Mute's
    transaction read set. That causes rare contention with the target's own graph writes, which shows up in
    `txn_attempts`.
- **A′. NOT_FOUND unless the target is ACTIVE**, checked through `identity.Directory` (cache-first, 0–1 read).
  Rejected because it creates an oracle. With the M3 fix, GetProfile returns NOT_FOUND for blocked-by, SUSPENDED and
  DELETING alike. If Mute succeeded only for ACTIVE targets, then "Mute succeeds and GetProfile says NOT_FOUND" would
  mean blocked-by and nothing else. D9 requires that muting someone who blocked you leaks nothing.
- **B. Accept every well-formed uid idempotently and only build the lazy clean-up.** Junk keeps its quota cost and
  its doc size. The L3 and A3 charset rules shorten the ids but don't prevent nonexistent 28-char ids. Rejected.
- **B′. Accept everything and drop the clean-up.** That leaves erasure residue in third-party docs (rule 10) and
  dangling `blocked[]` entries from D2 overflow and L5 races. Rejected.

**Decision: A, plus the D10 lazy clean-up is implemented (T27), not dropped.** Exact behaviour:

| Mute(B) by A, where B… | Result | Reads / writes / deletes |
|---|---|---|
| id fails format validation (charset, length, reserved, `_` per A3) | INVALID_ARGUMENT + `VALIDATION`, `field=user_id` | 0 / 0 / 0 |
| B == A | INVALID_ARGUMENT + `VALIDATION` (unchanged) | 0 / 0 / 0 |
| has no `graph/{B}` doc (never existed, or purged by D10 step 5) | **NOT_FOUND, byte-identical to graph's `notFoundErr()`** (Block's and Follow's NOT_FOUND). No quota reserved | 2 / 0 / 0 |
| ACTIVE, SUSPENDED or DELETING (graph doc present) | OK, `muting=true`; quota reserved as before | 3 / 2 / 0 |
| **blocks A** (A ∈ B.blocked, B ∈ A.blockedBy) | **OK, exactly as for a stranger.** Same reads, same response shape. `Relationship` comes from A's own arrays only (D4) | 3 / 2 / 0 |
| is blocked by A | OK (unchanged, D9) | 3 / 2 / 0 |
| already muted (replay) | OK, `muting=true`, 0 writes, no quota | 3 / 0 / 0 |
| A's `muted[]` at 2,000 | FAILED_PRECONDITION `LIMIT_REACHED` (unchanged) | 3 / 0 / 0 |
| A's daily `blocks` quota spent | RESOURCE_EXHAUSTED `QUOTA_EXCEEDED` (unchanged) | 3 / 0 / 0 |

- Order inside the transaction mirrors Block: caller graph, then target graph (NOT_FOUND returns here, before the
  quota read), then `quotas/{uid}`, then replay/cap/quota. Mute never reads `blockedBy` or branches on it, so the
  code path and read count are the same for a blocker and a stranger. That rules out a timing channel.
- **Block keeps the same rule, and L5's "Block: reject non-ACTIVE targets" is declined** for the reason given under
  A′. Block and Mute must answer existence identically. L5's dangling-entry race is covered instead by the T27
  clean-up (the entry disappears the next time the caller opens the list) and by L5's Unblock-tolerance item, which
  stays in the backlog.
- The residual is unchanged. "Mute or Block succeeds, and GetProfile says NOT_FOUND" means blocked-by, SUSPENDED or
  DELETING. That is the same ambiguous set accepted for CheckHandleAvailability in security review §4, and it depends
  on the M3 fix in the same way.
- **D10 refinement (T27).** ListMutedUsers and ListBlockedUsers remove *missing* uids from the caller's own array. A
  uid is missing when it has no `users/{uid}` doc; non-ACTIVE is not missing. The removal is one `ArrayRemove`
  update on `graph/{caller}` (+1 write, and only on a page that found such a uid). That costs 0 extra reads, because
  hydration's `GetAll` already knows which docs don't exist. SUSPENDED and DELETING users are never removed. They are
  hidden from the page as today. The clean-up is best effort: a failure logs WARN and never fails the list RPC.
  Arrays stay unindexed, so the clean-up is still the only way to reach other users' `muted[]`. Residue now lasts
  until the muter next opens that list, not forever. That is acceptable for a pseudonymous id whose account,
  profile, handle and Auth user are all gone.

### A2. Cache-dependent budgets carry cold and warm values (Follow replay measured at 4 cold)
**Context.** The table above gives Follow replay as 2 reads. T16a measured 2 with a warm profile cache and 4 with a
cold one. Follow's `identity.Directory.GetProfiles([caller, target])` reads 2 `users` docs on a miss. Also, a
successful Follow calls `directory.Forget(caller, target)` on its instance. So **a client retry right after a
successful Follow is always cold** on that instance, and in a session of several follows every Follow after the
first misses at least the caller doc. At Stage 0 the instance cache is often empty anyway: max 3 instances, and
scale to zero between bursts. So "typical = warm" understates cost.

**Options.** (a) One "typical" number per row: that's the status quo, and it hides the difference. (b) Cold/warm on
Follow only. (c) **Every row whose cost depends on an instance cache carries both values, plus a named planning
value (chosen).** Per-DAU math must state its hit-rate assumption. A test must know which ceiling it asserts, and
rows that don't depend on a cache shouldn't carry noise.

**Decision (the convention, binding on all later ADRs and plans):**
- Rows whose reads depend on an instance cache (identity profile cache, graph snapshot cache, author-recent cache,
  and so on) show **cold** (every cache misses, plus all conditional reads; this is the worst case and the ceiling
  tests assert) and **warm** (every cache hits). A **planning** value feeds the per-DAU columns, with its assumption
  written next to it.
- Rows that read only inside transactions or with fresh reads (Unfollow, Block, Unblock, Mute, Unmute) show one
  value. For them cold = warm.
- Tests: `budgettest` asserts the cold value after an explicit cache reset, and the warm value after a priming call.
  Proto budget comments use the form `reads 4 cold / 2 warm`.
- Planning values: Follow uses **3** (the caller doc is cold because of `Forget`, the target is warm from the
  profile or list row the user just saw). Read paths keep the cost-model §1 hit-rate assumptions they already used.

**Corrected per-RPC table (supersedes the Cost impact table; measured T16a values marked †):**

| RPC / case | reads cold | reads warm | reads planning | writes (worst / typical) | deletes | Cloud Run ms | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|---|---|
| Follow, created | 4† (+1 if caller `blockedByOverflow`) | 2† | 3 (caller evicted by `Forget`) | 5 / 5† | 0 | 60 | 0.5 | **1.5** | 2.5 | 0 |
| ↳ Follow replay (already following) | 4† (always cold for a retry on the same instance) | 2† | — | 0† | 0 | 30 | — (bounded by the M2 daily cap) | — | — | — |
| ↳ Follow rejected in txn (blocked-by NOT_FOUND, `TARGET_BLOCKED`) | 3† | 1 | — | 0 | 0 | 30 | — | — | — | — |
| ↳ Follow rejected in txn after the quota read (legacy private, `LIMIT_REACHED`, `QUOTA_EXCEEDED`) | 4 | 2 | — | 0 | 0 | 30 | — | — | — | — |
| ↳ Follow rejected before txn (target missing or non-ACTIVE) | 2 | 1 (misses aren't cached) | — | 0 | 0 | 20 | — | — | — | — |
| Unfollow (blind batch, `Exists`) | 0† | = | 0 | 3 / 3† (0 on no-op) | 1† | 40 | 0.1 | 0 | 0.3 | 0.1 |
| Block | 3† | = | 3 | 5† / 3† | 2† / 0† | 60 | 0.02 | 0.06 | 0.06 | ~0 |
| ↳ Block replay | 3† | = | — | 0† | 0 | 40 | — | — | — | — |
| Unblock | 1† | = | 1 | 2 / 2† (0 on no-op) | 0 | 30 | 0.005 | ~0 | 0.01 | 0 |
| Mute (after T26; **2/2/0† until then**) | 3 | = | 3 | 2 / 2 (0 on replay) | 0 | 30 | 0.02 | **0.06** | 0.04 | 0 |
| ↳ Mute NOT_FOUND (after T26) | 2 | = | — | 0 | 0 | 25 | — | — | — | — |
| Unmute | 1† | = | 1 | 1 / 1† (0 on no-op) | 0 | 30 | 0.005 | ~0 | ~0 | 0 |
| GetRelationships (≤ 50 ids) | 1 | 0 | 0.5 | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| ListFollowers / ListFollowing | 102 (page 50) | 50 (page 50) | 30 (page 20, ~50% hydration hits) | 0 | 0 | 70 | 0.3 | 9.0 | 0 | 0 |
| ListBlockedUsers / ListMutedUsers | 51 | 1 (own graph always read fresh) | 10 | 0; +1 on a page that finds a missing uid (T27) | 0 | 40 | 0.02 | 0.2 | ~0 | 0 |
| ListFollowRequests / RespondToFollowRequest (stubs) | 0 | = | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| IdentityService.GetProfile (changed) | 3 (+1 if viewer overflowed) | 0 | 0–1 (already modelled) | 0 | 0 | 20 | 3 | ±0 | 0 | 0 |
| IdentityService.GetMe (changed) | 2 | 1 | unchanged | 0 | 0 | 15 | 4 | ±0 | 0 | 0 |
| **Graph slice total** | | | | | | | **≈ 4.0 requests** | **≈ 12.3** (was 11.8) | **≈ 2.9** | **≈ 0.1** |

"=" means the row doesn't depend on a cache (cold = warm). Unfollow stays at 0R / 3W / 1D.

### A3. Follow doc ids stay `{followerId}_{followeeId}`; `_` becomes a reserved character in uids
**Context.** Identity accepts uids matching `^[A-Za-z0-9_-]{1,128}$`, so `follows/a_b_c` could be the edge `a_b → c`
or the edge `a → b_c`. On the emulator the second Create failed AlreadyExists and surfaced as INTERNAL. The
list-binding `HasPrefix`/`HasSuffix` cursor check (I2) is sound only if no uid contains `_`. Firebase Auth issues
28-char alphanumeric uids for every provider we enable, and we never mint custom-token uids (D2), so nothing can
trigger the collision today. The data is dev-only; prod has `FEATURE_GRAPH=off`.

**Options.**
- **A. Keep the encoding and make "no `_` in a uid" an enforced invariant (chosen).** Uid validation becomes
  `^[A-Za-z0-9-]{1,128}$`. `-` stays: about 600 test fixtures use `uid-*`, and `-` is not the separator. The
  invariant is enforced on target ids (shared validator), on the **caller** uid (authn, after token verification),
  and at id construction (a single `edgeID` helper refuses `_`).
  - Migration cost: $0 and 0 writes. No existing uid contains `_`. T28 verifies that with a Firebase Auth export
    (0 Firestore reads).
- **B. A different separator** (for example `:`). It still needs the same "separator not in uid charset" invariant,
  so it is A plus a migration. It also invalidates every outstanding page token (the cursor carries the doc id) and
  needs a dual-read window. Rejected: pure cost.
- **C. Hashed or length-prefixed ids** (`sha256(a|b)`, `28.a…b`). These are unambiguous without a charset rule. But
  they lose readable ids in the console and runbooks, break the prefix list-binding check, and still need a
  migration of every `follows` doc, the cursor format and the invariant checker. Rejected at Stage 0.

**Decision: A.**
- **Rule 1 and ID conventions:** rule 1 (Snowflake) covers posts and media. Edges use natural composite keys per
  ADR-0003, and A keeps them. `likes/{postId}_{uid}` and `reposts/{postId}_{uid}` are already unambiguous, because
  post ids are decimal Snowflakes. This invariant also makes them unambiguous in the uid position.
- **Path to Stage 3:** in Postgres or Spanner an edge is a composite primary key `(follower_id, followee_id)`, which
  Spanner can interleave under the follower. The migration reads the `followerId` and `followeeId` fields, and never
  parses the doc id. The encoding exists in one function behind `graph.Repo`. Nothing here constrains Stage 2 or 3.
- **Standing invariant (data model):** *a uid never contains `_`. `_` is the composite-key separator in `follows`,
  `likes` and `reposts` doc ids.* If we ever import or mint uids (custom tokens, a migration), they must match
  `^[A-Za-z0-9-]{1,128}$`. If a future provider issues `_`, that needs a new ADR (option C) **before** the provider
  is enabled.
- A3 subsumes the reserved-id rule (`__x__`, security review L3) for uids. The rule stays for handles. It lands after
  the reserved-id change that is in flight, on the same shared validator, not a second regex.

### Cost impact (amendment)
- **Fixed monthly cost added: $0.** No new service, API or Terraform resource. No env var changes.
- **Free-tier quota:** graph reads per DAU 11.8 → **12.3** (+0.5 Follow planning value, +0.02 Mute existence read).
  Writes 2.9 and deletes 0.1 are unchanged. T27 adds ≤ 1 write per stale entry, once, which is negligible.
  - At 300 DAU: graph ≈ 3.7k reads/day (7.4%). With the identity baseline ≈ 5.9k reads/day (11.8%). Writes are
    unchanged at 0.92k (4.6%).
  - v0.2.0 (identity + graph) ≈ 19.6 reads per DAU. The read quota runs out at ≈ **2,550 DAU** (was 2,600), and the
    80% line is at ≈ **2,040 DAU** (was 2,100). Writes (≈ 6,500 DAU), deletes and Cloud Run requests are unchanged.
  - Overage at 2× the read cliff (≈ 5.1k DAU): reads ≈ $0.90/month. At 10× (≈ 25.5k DAU): reads ≈ $8.10/month,
    writes ≈ $3.20/month.
  - Whole product: the 80% reads crossover moves from ~211 to ~210 DAU. sre-performance restates cost-model §2–§4.
  - Slice $: 300 DAU ≈ $0.07/month (marginal); 3k DAU ≈ $1.73/month.
- **Abuse bounds:**
  - A Mute replay loop costs 3 reads per call (was 2). Before the M2 cap that's ≤ 86.4k reads/day/instance, the same
    as a Block replay loop.
  - After the M2 `graph_mutation_daily` cap, the per-account worst is ≤ 500 × 4 × 3 ≈ 6k reads/day. The previous
    4.5k figure used 3 reads per call; Follow cold is 4.
  - A1 removes the junk-`muted[]` doc-size vector. The D2 worst case goes back to ≈ 566 KB.
- **Trigger to revisit A2's planning value:** measured `graph_cache_hit` on Follow (L8 log fields) in the T25
  post-release data. If Follow averages < 2.5 reads/call in prod, the planning value goes down, and vice versa.

### Consequences (amendment)
- Positive:
  - Mute can no longer store junk or nonexistent ids.
  - Mute and Block answer existence the same way, so the D9 residual doesn't grow.
  - Erasure residue in `muted[]` and `blocked[]` now heals itself.
  - Budgets say what they assume, and tests assert the right ceiling.
  - The edge-id invariant is enforced in 3 places at $0.
- Negative:
  - Mute costs +1 read, and its transaction now includes the target's graph doc (watch `txn_attempts`).
  - Follow's planning cost rises by 1 read.
  - Tightening the uid charset is a validation change on a shared path while other validation work is in flight
    (T28 sequencing).
- Revisit: if a provider ever issues `_` in uids (option C ADR); if Follow's measured cold share is high enough to
  justify T30 (in-place cache update instead of `Forget`); if Mute contention WARNs appear.

### Handoff (amendment)
- **backend-developer:**
  - T26 (Mute existence check);
  - T27 (lazy clean-up through an extended `identity.Directory`, never removing non-ACTIVE users);
  - T28 (uid charset `^[A-Za-z0-9-]{1,128}$` on the shared validator, caller-uid check in authn, `edgeID` helper);
    rebase on the in-flight reserved-id and cursor changes;
  - T30 (optional).
- **architect:** T29 (proto budget and charset comments in the cold/warm form; `firestore-data-model` skill rows for
  Follow and Mute plus the `_` invariant).
- **tester:**
  - T16a budget assertions use the A2 cold and warm values: Follow replay asserts 4 cold and 2 warm, not "2".
  - New cases from the T26–T28 acceptance criteria. The D9 matrix gains the A1 Mute rows (blocker, SUSPENDED,
    DELETING, purged).
- **sre-performance (T21):** use the A2 table and planning values. Graph reads per DAU are 12.3.
- **production-deployer (T22):** in `account-deletion.md`, note that other users' `muted[]` and `blocked[]` entries
  for a deleted uid are cleaned lazily (T27), not by the runbook.
- **frontend-developer:** no contract change. Mute can now return NOT_FOUND. Handle it the same way as a NOT_FOUND
  from Follow or Block: the identical "This account doesn't exist" view (original frontend handoff). Verify that the
  mute action's error path uses it.

## Handoff
- **backend-developer:** T3 `pkg/platform/flags` per D6 (salted bucketing, fail-fast parsing, retirement rule) and
  `GetMe.enabled_features`; T4 quotas/limits per D7 (extend `quota` and `ratelimit`, no second limiter); T5 graph core
  with `doc.BlockedBy` and `doc.BlockedByOverflow` (missing fields decode as empty/false), `Reader.Snapshot` exposing
  `BlockedByOverflow`, `identity.BlockChecker` as a consumer-side interface, `InitGraph` also writing
  `blockedBy: []`; T6 GetProfile NOT_FOUND per D9 (+ D2 overflow read), UpdateProfile rejection per D1; T7–T10 per
  D2–D4, D9 and "List paging" (**`Limit(page_size)`, not `+1`**; own lists drop `caller.blockedBy`); T11 purge per D10
  (start gate, `Exists` preconditions, page sizes 250/160, skip missing counterparts). Log fields as listed.
- **frontend-developer:** consume regenerated `app/lib/gen`; map `TARGET_BLOCKED` and `FEATURE_DISABLED` in
  `mapConnectError`; `FeatureFlags` from `enabled_features` (missing = off, unknown ignored; on `FEATURE_DISABLED`
  hide the feature and refresh GetMe); follow buttons on list rows from `UserListItem.relationship`; identical
  "This account doesn't exist" view for NOT_FOUND; never auto-retry `DEGRADED_MODE`.
- **production-deployer:** deploy `firestore.indexes.json` (`graph.blockedBy` exemption) to dev then prod; env vars
  per D6/D7 in Terraform (`FEATURE_GRAPH` dev `on`, prod `off` → allowlist → percent → on); no new resources; the L9
  `count()` check in prod before v0.2.0; runbooks per D10 (purge before deleting `users/{uid}`, wait ≥ 120 s after
  setting DELETING).
- **tester:** the D9 table is the oracle for the T16b matrix, including the two own-list cells; D3 invariant checker
  after every scenario; budget assertions equal to the Cost impact table (lists ≤ 102 at page 50, ≤ 42 at page 20
  cold); purge crash-resume **and** two concurrent purges (no double decrement); a flag-cohort test with two flag names
  (independent cohorts); `blockedByOverflow` fail-closed test (seeded doc at the cap: Follow and GetProfile still
  blocked); grep that `blockedBy`/`blockedByOverflow` never appear in any serialized response or export.
- **security-auditor (T20):** review D2 overflow residual, D8 staleness, D9 handle-availability residual, D12.
- **sre-performance (T21):** restate cost-model §2–§4 with the table above; dashboard note query by `graph_op`.
- **planner:** plan deltas to carry into tickets: ADR filename is `0008-social-graph.md`; T5 adds
  `blockedByOverflow`; T7/T6/T10 add the overflow read; T9 own lists drop `blockedBy` users; T10 uses
  `Limit(page_size)`; T3 salts the bucket hash; T11 adds the start gate, `Exists` preconditions and page sizes.
