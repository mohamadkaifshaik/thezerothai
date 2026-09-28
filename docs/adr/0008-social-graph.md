# 0008. Social graph slice: follows, blocks, mutes, feature flags and graph quotas
Status: Accepted — all items except D12 (export contents), which is **Proposed** pending a founder call (see D12).
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
- **Per-RPC budget** (Firestore ops per call, worst / typical; these numbers are the proto comments, D5):

| RPC | reads | writes | deletes | Cloud Run ms | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|
| Follow | 4 / 2 (+1 if caller's `blockedByOverflow`, D2) | 5 / 5 | 0 | 60 | 0.5 | 1.0 | 2.5 | 0 |
| ↳ Follow replay (already following) | 2 / 2 | 0 | 0 | 30 | — | — | — | — |
| Unfollow (blind batch, `Exists` precondition) | 0 / 0 | 3 / 3 (0 on no-op) | 1 / 1 | 40 | 0.1 | 0 | 0.3 | 0.1 |
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

### D12. Export contents (Q12) — **Proposed: needs a founder call**
- Proposed: the export (and `opsctl export-graph` now) contains following and followers (uids + handles), blocked and
  muted. It excludes `blockedBy` — who blocked the subject is data about third parties, and revealing it defeats
  blocking (X and others don't disclose it).
- Why a founder call: this is a legal interpretation of the data-principal's right of access (DPDP Act; GDPR if EU
  users appear), not an engineering choice. It does not block v0.2.0: `opsctl export-graph` implements the proposed
  default, and flipping it later is a one-line change. The founder confirms before the in-app export ships, or before
  the first real export request, whichever is first.

### D13. Profile screen ownership (Q13) — Accepted (plan default)
This plan builds the profile header (identity data + graph actions); the posts/profile-timeline plan adds the tabs and
body. The header is a separate widget listed in `docs/ui-catalog.md` so the two plans don't edit the same widget.

### Other binding details
- **List paging (changed vs plan).** ListFollowers/ListFollowing query with `Limit(page_size)` (not `page_size+1`) and
  return a `next_page_token` whenever the query returned a full page. The plan's `+1` over-read made the worst case 103,
  not the 102 it documents, and costs 1 read on every page; without it, the only extra cost is one empty final call
  (1 read) when the total is an exact multiple of the page size. Pages may be short because of row filtering; clients
  follow `next_page_token` (as ADR-0004). Cursor = `cursor.Encode(createdAt, docId)` (HMAC-signed, ADR-0003).
- **ListBlockedUsers/ListMutedUsers paging:** newest first (reverse array order), token = last uid returned + its
  position; if that uid was removed meanwhile, resume at the first entry older than the recorded position.
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
  `graph.md` (T22); the `private-accounts` plan with its visibility-job section; D12 founder call.
- Revisit when: a `users` doc sustains > 1 write/s; an account nears 5,000 following at scale; graph cache memory
  > 70% of an instance; T20 finds the 60 s block staleness or the handle-availability residual unacceptable; or
  Firestore > 1.5M reads/day.

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
