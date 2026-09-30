# 0010. Posts and timelines slice (Phase 1 P0 + P1): slice decisions, visibility, read budget
Status: Proposed (architect, 2026-09-30). Becomes Accepted when the founder merges it. No fixed cost is added and no
non-negotiable rule bends. Four items change the plan's defaults or earlier numbers and are listed for the founder
under "Founder attention" at the end.
Date: 2026-09-30
Deciders: architect, founder (on merge)

Inputs: `docs/plans/posts-and-timeline.md` (Q1–Q12, T1–T27), `docs/plans/phase1.md` (P0, P1, D1–D5),
ADR-0003 (data model, ids, idempotency), ADR-0004 (pull timeline), ADR-0008 (graph, D2 overflow, D6 flags, D9 block
table, A2 cold/warm convention, B1/B2), ADR-0009, `docs/reviews/cost-model.md`, `proto/dzeroth/{posts,timeline,
identity,common}/v1/*.proto`, `firebase/firestore.indexes.json`, and in `backend/`: `pkg/platform/{cursor,budget,cache,
ratelimit,limits,idempotency,quota,snowflake}`, `pkg/platform/authn/interceptor.go` (`AccountStatusInterceptor`),
`internal/apiserver/apiserver.go` (interceptor order), `internal/identity/{validate,cache,api}.go`.

This ADR does **not** reopen ADR-0004's algorithm (chunked pull, `k = max(1, ceil(2·page/C))`, exact-prefix merge,
gap token, two-level cache). It fixes the slice-level choices ADR-0004 left open. D13 tightens how `since_token` is
computed, because the literal "newest item returned" rule loses posts (a correctness bug, explained in D13). ADR-0004
gets a cross-reference note; its decision text is unchanged.

## Context
Stage 0 (0 – ~300 DAU, $0 target, pay-per-use past the free tier, founder decision D1). v0.2.0 (identity + graph) is
built. `posts`, `timeline` and their protos exist; no backend module does. P1 ships root posts, a profile Posts tab
and the home timeline behind `FEATURE_POSTS`. P0 closes the public-repo finding: a single account could spend 58% of
the daily free reads through `CheckHandleAvailability` alone (`phase1.md` §P0).

Functional requirements for this stage: create/delete root text posts with mentions, hashtags and links; read one
post; a user's posts; a chronological home feed of followees + self with cheap incremental refresh; a right-to-delete
and export path for `posts` (rule 10); a hard bound on per-account daily Firestore reads across every RPC.

Non-functional: plan targets (CreatePost p95 < 500 ms, home refresh < 400 ms warm, GetUserTimeline < 300 ms, cold
< 1.5 s); every RPC has a bounded cold ceiling and a planning value (ADR-0008 A2); every write is idempotent and
replay-safe; no fixed cost.

Facts from the code that shape the numbers below:
- **Every non-exempt request reads the caller's `users` doc in `AccountStatusInterceptor`** (instance cache 60 s).
  `fs_reads` is per request, so a cold request pays +1 before the handler runs (ADR-0008 B1 measured this on
  Unfollow). The plan's P1 ceilings left this read out. Here the cold ceilings include it.
- `CACHE_TTL` is capped at 60 s (ADR-0009 T33). The client auto-refreshes Home **at most** every 60 s, so a
  typical refresh finds the caller's graph and profile **expired**. The plan's "3 overhead, graph cached" is
  therefore optimistic by about 1–2 reads per refresh.
- `pkg/platform/cursor` tokens hold one `(createdAt, docId)` pair and expire after **24 h**. The timeline token
  contract needs two bounds for `gap_page_token` and tokens that survive a night on the device.
- For an older page at F = 60 (C = 3, page 20), `k = ceil(40/3) = 14`. Two dense chunks return 14 each, so the page
  reads ≈ 29 docs, not the 20–23 the plan assumed. That is ADR-0004's by-design over-read (bound `C + 2·page`), and
  it is now priced honestly.

## Options
$ uses the `cost-model.md` §7 upper bounds ($0.06 per 100k reads, $0.18 per 100k writes). "300 DAU" and "3k DAU" are
marginal on top of v0.2.0. At 300 DAU the released scope crosses the free read line, so marginal reads are priced as
overage (upper bound).

### 1. How `since_token` advances (ADR-0004 D1 refinement)
- **A. Newest item returned (ADR-0004 literal).** It costs no extra reads. But a post that commits after a refresh
  and is older than the newest item that refresh returned is **never delivered**. Three things cause this: another
  instance's author-recent cache entry that is up to 60 s old, a CreatePost transaction that commits after its
  `createdAt`, and instance clock skew. The post sits between cached items, and neither `since` nor `page_token`
  ever covers that range again. $0 at every scale, but it is a silent data-loss bug.
- **B. A settle watermark (chosen, D13).** `since = max(old since, min(newest returned, W))`. W is the request start
  minus a settle window, lowered further to the load time of any cache entry used. Refreshes re-read posts from
  the last ~15–75 s, and the client dedupes by `post_id`.
  - Cost: F = 60 at Stage 0 activity gives ≈ 0.1 re-read per refresh, so +~1 read/DAU.
  - $: idle $0; 300 DAU +300 reads/day ≈ $0.005/month; 3k DAU ≈ $0.05/month.
- **C. Server-assigned commit order** (write `createdAt` with a server timestamp, query on it). It fixes the commit
  race but not the cache race. It breaks "`createdAt` = Snowflake time", so the cursor's `(createdAt, id)` would no
  longer match id order. Rejected.

### 2. Bounding read abuse across all RPCs (P0)
- **A. Per-uid daily Firestore read budget fed by `budget.Counter` (chosen, D5).** One mechanism covers every current
  and future RPC, charged with the reads actually spent (interceptor reads included). It adds a per-IP budget for
  profile-exempt calls and a CI guard. $0, 0 Firestore ops, ≈ 13 MiB of memory.
- **B. Per-procedure daily call caps only** (extend `DailyCaps` to every read RPC). It can't bound a mix of RPCs whose
  costs differ 1 to 269×. It needs a hand-kept list and silently misses new RPCs. $0. Rejected.
- **C. Enforce web App Check (reCAPTCHA)** to stop scripted clients. That is a flat $8/month past 10k assessments,
  and the founder declined it (phase1 D3). It also doesn't bound a real signed-in account. Rejected at Stage 0.

### 3. DeletePost on a post the caller doesn't own (Q4)
- **A. NOT_FOUND for another user's post, success for unknown ids (plan default).** This is an **oracle**. "Delete
  says NOT_FOUND" means the id exists, and a GetPost NOT_FOUND for the same id then means the author blocked the
  caller (or is suspended or deleting). ADR-0008 D9 forbids that leak. It also contradicts T9's own "byte-identical
  to a missing id" criterion. Rejected.
- **B. NOT_FOUND for others, unknown and deleted alike.** No oracle. But a retry after a lost response to a
  successful delete gets NOT_FOUND. That breaks the proto's documented idempotency ("replay/unknown ⇒ success") and
  T9's replay criterion. Rejected.
- **C. Success with 0 writes for another user's post, an unknown id and an already-deleted id alike (chosen, D4).**
  No oracle, idempotent, no proto change. It logs `outcome=noop:not_owner` for abuse review. $0 in every option
  (1 read each).

### 4. Refresh overhead: accept expired caches, or lengthen the caller's own graph/profile TTL
- **A. Accept it and budget honestly (chosen).** Refresh planning is 4 reads + new posts (graph cold, C = 3), plus
  the interceptor line in the budget table. +8 reads/DAU against the plan. $: 300 DAU ≈ $0.04/month; 3k DAU ≈
  $0.43/month.
- **B. A 120 s TTL for the caller's own graph and profile.** Blocks and suspensions would take up to 120 s to apply,
  which breaks ADR-0008 D8 (60 s) and ADR-0009 T33's `CACHE_TTL ≤ 60 s` cap under the 120 s purge start gate.
  Rejected. Revisit only with a Stage 1 ADR.

## Cost impact
- **Fixed monthly cost added: $0.** No new GCP service, API, Pub/Sub topic, Scheduler job or Terraform resource. New
  env vars go on the existing `api` service (D5, D14, D15, Handoff). The indexes already exist (D19). `cost-guard`
  has nothing to flag.

### Per-RPC budget (supersedes the plan's table; the proto comments carry these numbers)
The ADR-0008 A2 convention applies:
- **Cold** is the ceiling tests assert after a cache reset. It includes the `AccountStatusInterceptor` caller read,
  because `fs_reads` is per request.
- **Warm** assumes every cache hits.
- **Planning** excludes the interceptor read, which has its own line so it is counted once.

F = following, C = ceil((F+1)/30) ≤ 167, p = page size ≤ 50.

| RPC / case | reads cold | reads warm | reads planning | writes | deletes | CR ms | calls/DAU | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|---|---|
| CreatePost (root) | 14 (interceptor/author `users` 1 + author `graph` 1 only if the text has mention candidates + `handles/*` ≤ 10 in one `GetAll` + `idempotency` 1 + `quotas` 1) | 2 (idempotency + quotas, always fresh in the transaction) | 2.5 (~30% of posts have mentions; handle misses) | 4 (idempotency, post, `users.postsCount`, quotas) | 1 eventual (idempotency TTL) | 80 | 1.0 | 2.5 | 4.0 | 1.0 |
| ↳ replay (same key, same body) | 14 | 1 (idempotency; post cached on the writing instance, else +1) | — | 0 | 0 | 30 | — | — | — | — |
| ↳ key reused with a different body | 14 | 1 | — | 0 | 0 | 30 | — | — | — | — |
| DeletePost | 2 (interceptor + post) | 0 (post cached) | 1 | 1 (`postsCount` −1); 0 on no-op | 1 (post); 0 on no-op | 40 | 0.05 | 0.05 | 0.05 | 0.05 |
| GetPost | 4 (interceptor + post + author `users` + caller `graph`; +1 author `graph` if caller `blockedByOverflow`) | 0 | 1 (author profile; the rest is warm from the feed the post was opened from) | 0 | 0 | 15 | 1 | 1.0 | 0 | 0 |
| GetUserTimeline, page | 3 + p = 53 at p 50 (interceptor + target `users` + caller `graph` + `Limit(p)`; +1 if overflowed) | 0 (Posts-tab first page from the author-recent cache) | 11 (a cold page of 20 ≈ 23 blended with `since` refreshes ≈ 1) | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| ↳ `since` refresh, 0 new posts | 4 (3 + 1 empty query) | 0–1 | — | 0 | 0 | 20 | — | — | — | — |
| GetHomeTimeline, refresh | 2 + C + 2p = **269** at F = 5,000, p = 50 (interceptor + graph + chunk queries; exact chunk worst is C·k ≤ 198 + 2, the formula is kept as the ceiling) | 0 to C (0 when every author is covered by the author-recent cache) | 4 overhead (graph cold, refreshes are ≥ 60 s apart; C = 3 at F = 60) + new posts | 0 | 0 | 80 | 8 | 32.0 overhead + **60.0 new posts** | 0 | 0 |
| ↳ settle-window re-reads (D13) | within the ceiling | 0 | ≈ 0.1 per refresh | 0 | 0 | — | 8 | ≈ 1.0 | 0 | 0 |
| GetHomeTimeline, older page | 269 | — | 30 (graph 0.5 + two dense chunks × k = 14 + one sparse chunk) | 0 | 0 | 120 | 1 | 30.0 | 0 | 0 |
| GetHomeTimeline, cold open | 269 | — | 30 | 0 | 0 | 150 | 0.1 | 3.0 | 0 | 0 |
| `AccountStatusInterceptor` caller read on P1 requests | 1 | 0 | 1 on each home refresh (TTL = refresh spacing), 0.5 on the other 5.15 requests | 0 | 0 | — | 13.15 req | 10.6 | 0 | 0 |
| Identity CheckHandleAvailability (P0: negative cache 10 s, daily cap) | 1 | 0 | unchanged | 0 | 0 | 15 | — | ±0 | 0 | 0 |
| Identity GetProfile (P0: negative handle cache 10 s) | 3 (+1 overflow) | 0 | unchanged | 0 | 0 | 20 | — | ±0 | 0 | 0 |
| **P0 + P1 total** | | | | | | | **≈ 13.15 req** | **≈ 162.2** | **≈ 4.05** | **≈ 1.05** |

**Change vs plan (133.9 → 162.2 reads/DAU):** the interceptor line +10.6, refresh overhead with the graph cold +8,
older page and cold open over-read at k = 14 +7.7, settle re-reads +1, CreatePost +0.5, GetPost +0.5. Writes and
deletes are unchanged. Each correction follows from the code (see Context), not from a new feature. T22/T25 measure
them, and the planning values move to the measured means (ADR-0008 B1 rule).

### Daily totals and where each quota runs out
Released scope after P1 = v0.2.0 (20.4 R, 3.1 W, 0.1 D, ≈ 11.3 requests per DAU) + P0/P1 (above) = **≈ 182.6 reads,
7.15 writes, 1.15 deletes and 24.45 requests per DAU per day**.

| Quota | Per DAU/day | At 300 DAU | % of free | Runs out at | Overage at 2× / 10× that DAU |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | 182.6 | 54.8k | **110%** | **≈ 274 DAU** (80% line ≈ 219) | $0.90 / $8.10 per month |
| Firestore writes (20k/day) | 7.15 | 2.1k | 11% | ≈ 2,800 DAU | $1.08 / $9.72 |
| Firestore deletes (20k/day) | 1.15 | 0.35k | 2% | ≈ 17,000 DAU | cents |
| Cloud Run requests (2M/month, shared, ~29k fixed) | 24.45 (≈ 734/month) | 220k/month | 11% | ≈ 2,690 DAU | $0.79 / $7.10 |
| Cloud Run vCPU-s (180k/month, 0.1 s/request) | 2.45 | 22k/month | 12% | ≈ 2,450 DAU | $4.25 / $38.23 |
| Firestore storage (1 GiB) | ≈ 1.5 KiB per post incl. index entries | +13 MiB/month | 1%/month | years | cents |

- **$ for the slice (marginal):** idle **$0**; 300 DAU ≈ **$0.09/month** (≈ 4.8k reads/day over the free line);
  3k DAU ≈ **$9.9/month** (reads $8.76, Cloud Run vCPU $0.96, requests $0.09, writes $0.08).
- Against D1 (founder, accepted): the plan forecast 93% of the free reads at 300 DAU; this ADR puts it at 110%. That is
  still cents, inside D1's "accept pay-per-use" decision, and the existing "reads > 40k/day" alert now fires at
  ≈ 219 DAU instead of ≈ 260. No new decision is needed; D1 is re-decided at P9 with real numbers, as agreed. The
  whole-product model (`cost-model.md` §2, 191 reads/DAU) rises to ≈ 215 once T25 applies these corrections.
  sre-performance restates §2–§5 in T25.
- **Levers (measured before any use):**
  - the existing ones: `since` refresh, a 60 s auto-refresh floor, prefetch only after 70%;
  - new: lower ADR-0004's over-read factor (`2·page` → `1.5·page` in `k`), only if T22/P9 show older-page reads
    > 1.4 × page size. That tunes a constant and doesn't reopen the algorithm.
- **Trigger** (free-tier-budget §6): none fires. Firestore > 1.5M reads/day is ≈ 8.2k DAU on this model.

## Decision
Adopt option 1B, 2A, 3C and 4A, with D1–D20 below. Q1–Q12 are the plan's questions. **"Changed vs plan"** marks every
override, with the reason.

### D1. Flag (Q1): one `FEATURE_POSTS`. Accepted (plan default)
- `FEATURE_POSTS=off|allowlist|percent|on` (+ `_ALLOWLIST`, `_PERCENT`) gates PostService, TimelineService and all
  posts UI, following ADR-0008 D6 exactly. `GetMe.enabled_features` includes `"posts"` (0 reads).
- It is checked in each service before any Firestore access: FAILED_PRECONDITION + `FEATURE_DISABLED`, 0 reads (the
  interceptor's read still happens, and that is logged).
- Block enforcement is never flagged (D6 of ADR-0008): turning the flag off never un-hides anything, and the flag
  gates only these two services.
- Later sub-features (replies, media, engagement) get their own flags in their slices.

### D2. Slice-1 CreatePost scope (Q2): root posts only. Accepted, **with an addition**
- If `reply_to_post_id`, `quote_of_post_id`, `media_ids` or `media_alt_texts` is non-empty, the call returns
  FAILED_PRECONDITION + `ERROR_REASON_FEATURE_DISABLED`, 0 reads, and nothing is validated first.
- **Addition:** `metadata["feature"]` names the sub-feature: `replies`, `quotes` or `media` (checked in that order,
  first match). Reason: ADR-0008 D6 tells clients to "hide the feature" on FEATURE_DISABLED. Without the name, a
  client would hide all of posts. With it, a client hides only the named sub-feature; an absent `feature` means the
  whole service. Comment-only in `common.proto`; no new field.
- Stored posts in this slice have `kind = POST`, `isReply = false`, `conversationId = postId`, `visibility = PUBLIC`,
  no `replyToId`/`quoteOfId`/`repostOfId`/`embedded`/`media`, and all counters at 0.

### D3. Viewer flags (Q3): always false, no `userLikes` read. Accepted (plan default)
When P5 ships, every timeline and post read gains +1 cold / 0 warm (`userLikes`). The proto comments say
"+1 once engagement ships". The ceiling formula becomes `3 + C + 2p`.

### D4. DeletePost semantics (Q4). **Changed vs plan** (option 3C)
- Steps:
  1. Read the post: cache first, else 1 read.
  2. If the caller is the author, commit one batch: `Delete(posts/{id}, Exists)` + `identity.Counters.AddPostsCount(−1)`.
     If the `Exists` precondition fails (a concurrent delete won), the call succeeds with 0 writes. That gives the
     exactly-once decrement.
  3. **In every other case (another user's post, unknown id, malformed-but-valid-shape id, already deleted), return
     success with 0 writes.** The response and the timing class (1 read, no batch) are identical, so there is no
     existence or block oracle.
- `post_id` must match `^[0-9]{19}$`, else VALIDATION `field=post_id`, 0 reads.
- After a commit, evict the post from this instance's posts cache and author-recent entry, and call
  `Directory.Forget(author)`: `postsCount` changed by a blind increment, so ADR-0008 B2 applies, and the founder
  kept `Forget` for exactly this reason. Then call `PostEvents.Deleted` (a no-op).
- `idempotency_key` is validated for format and not stored. The operation is state-setting (ADR-0008 "Other binding
  details").
- Log `outcome = deleted | noop | noop:not_owner`.
- No async job in P1: a root post has no dependants until P3/P4/P5. The P4 `post-delete` job is added with the
  first dependant.

### D5. P0 read budget (Q5). Accepted numbers, **with two refinements**
- **Mechanism.** Generalise `ratelimit.DailyCap` (T3) so one counter type counts either calls or units, with the same
  IST-day reset, LRU of 100k keys and no idle TTL (security L1).
  - Inside `ratelimit.Interceptor`, before `next`: reject if the key's spent units ≥ cap.
  - After `next`: `Charge(key, budget.FromContext(ctx).Reads())`. The counter comes from `mw.Logging`, which is
    outermost, so the charge includes interceptor reads.
  - Charge on success and on error alike.
- **Numbers (config, rule 11):**
  - `READ_BUDGET_PER_UID_PER_DAY = 2000`
  - `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY = 500`
  - `CHECK_HANDLE_CALLS_PER_DAY = 100` (a `DailyCaps` entry, `limit_name=check_handle_daily`)
  - negative handle cache 10 s: reuse identity's `notFoundTTL`, applied to `ResolveHandle` NotFound, used by
    CheckHandleAvailability, GetProfile-by-handle and `ResolveHandles`.
- **Rejection:** RESOURCE_EXHAUSTED + `RATE_LIMITED`, `retry_after` = time to the next IST midnight,
  `metadata["limit"]` = `read_budget_daily` or `check_handle_daily`. The log carries `limit_name` with the same value.
  0 Firestore reads, because the interceptor runs before account status.
- **Refinement 1 (IP key scope).** The IP budget is charged and enforced **only on profile-exempt procedures**
  (today CreateProfile and CheckHandleAvailability). The rate-limit interceptor runs before account status, so
  "caller without a profile" isn't known there, but "exempt procedure" is known mechanically. Callers with a profile
  are never IP-limited on other procedures. That matters in India, where carrier-grade NAT puts thousands of real
  users behind one IP.
- **Refinement 2 (IPv6).** The IP key is the full IPv4 address, or the **/64 prefix** of an IPv6 address. A single
  host rotates freely inside its /64, so a full-address key is not a bound.
- **Guard test (T3.5):** every registered procedure with `IdempotencyLevel == NoSideEffects` must be covered (all
  are, because the budget applies to every procedure). The exemption list is empty and must stay explained.
- **Math: typical use against the cap.**
  - Released scope after P1: ≈ 183 reads/DAU/day. Whole Phase 1 model: 191 (cost-model §2), ≈ 215 after T25.
  - The cap is **≈ 9–11× a typical day**.
  - Heavy but legitimate, F = 300 (C = 11): 20 refreshes × (2 + 11 + 5) = 360; 10 older pages × (2 + 11·4) = 460;
    4 profile pages × 23 = 92; 10 GetPost × 4 = 40; GetMe and others ≈ 30. That totals **≈ 980**, under the cap.
  - F = 1,000 (C = 34) reaches ≈ 1,700 on the same day and is close to the cap.
  - F = 5,000 hits it after ≈ 11 refreshes.
  - Accepted residual: an account following more than ~1,000 others can hit the cap on a heavy day. It gets a
    non-blocking banner and keeps its cache (T17), and the cap is raised via env. There are no such accounts at
    Stage 0.
- **Math: worst-case abusive totals.**
  - Overshoot is bounded by one call's worst case. The cap is checked before the call, so a call starting at 1,999
    can add up to 269. Per instance: 2,000 − 1 + 269 = 2,268.
  - Across max 3 instances: **≤ 6,804 reads per account per IST day (13.6% of the free quota, ≈ $0.004/day)**. Before
    P0 it was ≈ 86k–259k.
  - Profile-less, per IP (or /64): (500 − 1 + 2) × 3 ≈ **1,503 reads/day**. CheckHandleAvailability: ≤ 100 × 3 =
    300 calls/uid/day.
  - Sybils with profiles still multiply the per-account bound. About 7 such accounts exhaust a day's free reads, at
    ≈ $0.12/month per account per day of abuse. That is visible as `limit_name=read_budget_daily` and handled by
    `abuse-spike.md`. App Check enforcement stays declined (D3 of phase1).

### D6. Visibility (Q6). Accepted (plan default), made exhaustive
A = caller, B = author. NOT_FOUND strings are **byte-identical within each RPC**:
- GetPost uses code NOT_FOUND, reason UNSPECIFIED, message `post not found` for missing, deleted and every hidden
  case.
- GetUserTimeline uses identity's missing-user error (NOT_FOUND, UNSPECIFIED, `profile not found`), the same bytes
  GetProfile returns. Reuse identity's constructor through its package API; do not copy the string.

The table is the tester's oracle (T19/T20). Every cell has exactly one outcome.

| Relationship of A to B | GetPost(B's post) | GetUserTimeline(B) | GetHomeTimeline (B's posts) | CreatePost by A mentioning @B | DeletePost(B's post) by A |
|---|---|---|---|---|---|
| A == B (own) | returned | returned | always included | mention kept | deleted |
| stranger (no relation) | returned | returned | not present (not followed) | kept | success, 0 writes (D4) |
| A follows B | returned | returned | included | kept | success, 0 writes |
| **A blocks B** | returned; client shows a "You blocked @B" banner first | returned; client banner "You blocked @B · Show posts" | dropped (also, the block removed the edge) | kept (P6 suppresses the notification) | success, 0 writes |
| **B blocks A** (B ∈ A.blockedBy) | NOT_FOUND | NOT_FOUND (`profile not found`) | dropped, even if a stale `following` still lists B | **dropped** (plain text, no link) | success, 0 writes |
| both block each other | NOT_FOUND | NOT_FOUND | dropped | dropped | success, 0 writes |
| **A mutes B** | returned (mute is silent; no banner) | returned | dropped | kept | success, 0 writes |
| **B SUSPENDED** | NOT_FOUND | NOT_FOUND | **still included** (Q10, D10) | kept | success, 0 writes |
| **B DELETING** | NOT_FOUND | NOT_FOUND | still included until the purge removes the posts (Q10) | kept | success, 0 writes |
| B's `users` doc missing (purged, posts not yet) | NOT_FOUND | NOT_FOUND | still included until purge-posts runs (runbook order: purge-posts before users delete) | plain text (handle gone) | success, 0 writes |
| A's `blockedByOverflow` = true (ADR-0008 D2) | +1 read of B's graph; `A ∈ B.blocked` ⇒ NOT_FOUND | same +1 read and rule | no extra read: B can't be in A's `following` (Follow is fail-closed, Block removed edges) | **all mentions dropped** (fail closed, 0 extra reads) | unchanged |
| A is SUSPENDED/DELETING | PERMISSION_DENIED `ACCOUNT_RESTRICTED` (interceptor, every RPC) | same | same | same | same |

Rules behind the table:
- Filters use only `graph.Reader.Snapshot(A)` (`blocked`, `blockedBy`, `muted`, `blockedByOverflow`), never a direct
  `graph/*` read (ADR-0008 D9 obligation). Status comes from `identity.Directory`, which drops non-ACTIVE users.
- "Returned" to a blocker is deliberate. A needs to see what they blocked in order to unblock, and GetProfile
  already returns the profile (ADR-0008 D9). The banner is client-side, from A's own `GetRelationships`/snapshot data.
- Mentions don't depend on status: `handles/*` has no status. A mention of a suspended user links to a profile that
  shows NOT_FOUND, which is acceptable.
- Staleness: a new block is visible on other instances within 60 s (ADR-0008 D8).

### D7. Mentions (Q7). Accepted (plan default), with the overflow rule from D6
- **Grammar** (applied to the normalised text, D9):
  - A mention is `@` followed by a handle run `[A-Za-z0-9_]{3,15}` (identity's `handleRe`, reused, not redefined).
  - The `@` must sit at the start of the text or after a rune that is **not** a letter, mark or number
    (`\p{L}\p{M}\p{N}`) and not one of `_ @ # / . : & $ + -`.
  - The run must be followed by the end of the text or a rune that is not `[A-Za-z0-9_@]`.
  - A run longer than 15 is **not** a mention. It is never truncated.
- **Resolution.**
  - Lower-case the handle; dedupe preserving first occurrence; take the first 10.
  - Resolve all of them in one `identity.Directory.ResolveHandles` call: cache-first, one `GetAll` for misses, and
    NotFound negatively cached for 10 s.
  - Unknown or reserved handles stay plain text.
  - Drop uids in the author's `blockedBy`. If the author's `blockedByOverflow` is true, drop all mentions.
  - The author's graph is read only when at least one candidate exists, so posts without mentions cost 0 graph reads.
  - Mentioning oneself or a user the author blocks is allowed.
- **Stored** as `mentions[] = {userId, handle}`, where `handle` is the **lower-case** handle as resolved at write
  time. Clients match text spans case-insensitively and always navigate by `userId`. The text itself is unchanged.
- **Examples:** `@Alice @alice` → [alice] · `email@example.com` → none · `(@bob)` → bob · `@bob's` → bob ·
  `@@bob` → none · `@bob@host` → none · `https://x.y/@bob` → none · `@ab` → none (too short) ·
  `@abcdefghijklmnop` (16) → none · `@al-ice` → `al` is too short, so none · `hi @carol_` → `carol_`.

### D8. Hashtags (Q8). **Changed vs plan:** the grammar admits combining marks and ZWJ/ZWNJ
- **Why:** the default `#[\p{L}\p{N}_]{1,50}` cuts Indic words at their first vowel sign. Devanagari matras are
  `\p{M}`, so `#भारत` became `#भ`. Most of our users are Indian, so this is a concrete defect.
- **Grammar:**
  - `#` is at the start of the text or after a rune that is not `\p{L}\p{M}\p{N}` and not one of `_ @ # / &`.
    That keeps URL fragments and HTML entities such as `&#39;` out.
  - The body is `[\p{L}\p{N}_][\p{L}\p{M}\p{N}_\x{200C}\x{200D}]{0,49}`. The first rune is not a mark or joiner, and
    the total is 1–50 code points.
  - The body is followed by the end of the text or a rune outside the body class.
  - The body must contain at least one `\p{L}`.
  - A run longer than 50 is not a hashtag.
- **Stored:** `strings.ToLower` of the body (after NFC), deduped with first occurrence kept, first 10.
- **Examples:** `#Go #go #GO` → [go] · `#123` → none (**pinned**: no letter) · `#१२३` → none · `#भारत` → [भारत] ·
  `#café` → [café] · `#go_lang` → [go_lang] · `a#b` → none · `https://x.y/p#frag` → none · `#` → none ·
  11 tags → first 10 stored, text unchanged.

### D9. Text normalisation (Q9). Accepted, **specified exactly**
Applied in this order in `internal/posts/text` (pure):
1. Invalid UTF-8 → VALIDATION `field=text`. Connect already rejects most of it; check again anyway.
2. `\r\n` and lone `\r` → `\n`; `\t` → one space.
3. NFC (`golang.org/x/text/unicode/norm`, the package identity already uses).
4. Trim leading and trailing `unicode.IsSpace` runes (this includes `\n`).
5. Empty → VALIDATION.
6. Reject (VALIDATION) any `Cc` rune except `\n` (C0, DEL, C1) and the explicit bidi formatting controls
   U+202A–U+202E and U+2066–U+2069, which enable display spoofing. LRM/RLM (U+200E/U+200F), ZWJ/ZWNJ and emoji
   sequences are allowed.
7. Length **≤ 280 code points** (`utf8.RuneCountInString`) of the result. Emoji ZWJ sequences count every code point.
   That is documented, and the client counts the same way.
8. **≤ 10 lines**, meaning at most 9 `\n`.
- Links are left as typed and count toward the length. The server doesn't rewrite, shorten or preview them. Clients
  linkify only explicit `http://` and `https://` URLs.
- The stored `text` is the normalised string. Mentions and hashtags are extracted from it.

### D10. Suspended and deleting authors in Home (Q10). Accepted (plan default)
- They are not filtered at Stage 0: checking would cost a `users` read per distinct author per page.
- GetPost and GetUserTimeline do filter them, from cache.
- The P7 plan must make `opsctl suspend-user` take down, or mark hidden, the user's posts, so suspended content leaves
  every feed within 60 s. That is recorded as a P7 obligation.
- Deletion is covered by the runbook order (purge-posts before `users`) and the 120 s start gate.

### D11. `include_replies=true` before P3 (Q11). Accepted, **by construction**
- `include_replies=false` (Posts tab): `authorId == B AND isReply == false`.
- `true` (Replies tab): `authorId == B` with no `isReply` filter.
- Both are the real queries from day one. Until replies exist, the results are identical, and P3 needs no change.
  The client hides the tab until P3.

### D12. `mentionIds` (Q12). Accepted (plan default)
- P1 does not write `mentionIds` (ADR-0003 lists it), and no exemption is added.
- If P6 queries it with `array-contains`, it needs the default single-field index. An exemption would block that
  query, so don't add one now.
- The P6 ADR decides whether the field is written.

### D13. `since_token` is a settle watermark, not the newest item. **Changed vs ADR-0004 D1** (option 1B)
- For each request, compute `W = min(request start, loadedAt of every author-recent entry used to answer it) −
  TIMELINE_SETTLE_WINDOW`. The window defaults to **15 s**.
- Then `since_new = max(since_old, min(newest item returned, W))`, compared as `(createdAt, postId)` tuples.
  - When W is the smaller value, the token encodes `(W, "0000000000000000000")`, which sorts before any real id at
    that instant.
  - A refresh that returned nothing still advances to `max(since_old, W)`.
- Items newer than W are returned again on the next refresh. **The client dedupes by `post_id`** (it already must;
  ADR-0004 §7). Log `since_clamped=true` when W was the smaller value.
- **CreatePost** generates the Snowflake, and with it `createdAt`, **inside each transaction attempt**. It bounds the
  transaction with a **5 s** context deadline. Config validation requires `TIMELINE_SETTLE_WINDOW ≥ 3 × 5 s`, so a
  commit is always visible before W passes its `createdAt`.
- The same rule applies to GetUserTimeline's `since_token`.
- The gap token is unchanged: its lower bound is the old since.

### D14. Tokens: bindings, two-bound window tokens, 30-day TTL. **Changed vs plan** (bindings name the caller and the token kind; TTL)
- **Extend `pkg/platform/cursor`** (reuse-first, no new package):
  - `Window{Upper Cursor; Lower *Cursor}` with `EncodeWindow`/`DecodeWindow`: the same AES-GCM sealing, and the
    plaintext gains the optional lower pair;
  - a TTL-aware decode (`DecodeAt(…, ttl)` or an option). `Encode` stays unchanged, so graph tokens are unaffected.
- **Bindings** (AEAD additional data; `|` is safe because uids never contain it, ADR-0008 A3):

| Token | Binding | Payload |
|---|---|---|
| Home `since_token` | `tl|home|{caller}|since` | Cursor (D13) |
| Home `next_page_token` / `gap_page_token` | `tl|home|{caller}|page` | Window: Upper = oldest item returned; Lower = the old since (gap) or none (scroll) |
| User `since_token` | `tl|user|{caller}|{target}|{posts|replies}|since` | Cursor |
| User `next_page_token` / `gap_page_token` | `tl|user|{caller}|{target}|{posts|replies}|page` | Window |

- **Why the changes:**
  - The plan's `home:{uid}` / `user:{target}:{tab}` couldn't tell a `since` token from a page token.
  - It couldn't carry a gap's lower bound.
  - `user:` tokens were shareable across callers, while graph tokens are per caller (ADR-0008 M1).
- **Paging a gap:** a page whose Window has a Lower bound stops at it. Its `next_page_token` carries the same Lower
  bound, and it returns `""` when the lower bound is reached. The gap is closed, and no item ≤ the old since is ever
  read.
- **TTL:** `TIMELINE_TOKEN_TTL` = **720 h (30 days)** for timeline tokens. The client persists `since` and gap tokens
  across days, and a 24 h TTL would turn every morning's first refresh into a cold open with an unfillable gap row.
  Tokens are caller-bound and sealed, so a longer life leaks nothing new.
- **Rejections:**
  - An expired, tampered, foreign or wrong-kind token → INVALID_ARGUMENT + `VALIDATION`, `field` = `since_token` or
    `page_token`, 0 reads.
  - Both tokens set → VALIDATION `field=page_token`.
- **Client rule on a rejected token:** drop that token, cold-open, and treat the cold page's `next_page_token` as the
  gap filler. Stop merging when a cached `post_id` is reached.

### D15. Caches: sizes within ADR-0004 §6's ~150 MiB. **Changed vs ADR-0004 §6** (sizes; profile-first-page cache merged)
- **Posts** (`posts/{id}` → immutable `*Post`): **20,000** entries, `CACHE_TTL` (60 s).
  - The worst entry is ≈ 2.5 KiB: text ≤ 1,120 B, snapshot ≈ 0.3 KiB, 10 hashtags, 10 mentions, overhead. That gives
    ≤ 50 MiB worst and ≈ 12 MiB typical (~600 B).
  - Filled by every read path. Own writes update it in place; own deletes evict.
  - Config `CACHE_POSTS_ENTRIES`.
- **Author-recent** (authorId → `{posts ≤ 20 newest root posts, truncated bool, loadedAt}`): **1,000** authors,
  60 s. Config `CACHE_AUTHOR_RECENT_ENTRIES`.
  - Entries share `*Post` pointers with the posts cache: ≤ 50 MiB worst, ≈ 12 MiB typical.
  - **This is also the profile Posts-tab first-page cache.** ADR-0004's separate "profile first pages (2k)" cache is
    merged into it, so there is one cache, one invalidation path, and a profile view warms Home.
  - The size is cut from 5,000: at worst-case post size, 5,000 × 20 would be ≈ 250 MiB. Stage 0 has fewer than 1,000
    active authors.
  - **Filled by:**
    - a GetUserTimeline Posts-tab first page (the query always uses `Limit(20)` when filling; `page_size ≤ 20` is
      served from the entry, larger sizes query directly);
    - home cold-open chunks that did **not** fill `k`. Each author in such a chunk gets an entry with
      `truncated=false`, including an empty one, which makes sparse authors free for 60 s;
    - this instance's own CreatePost: prepend to an existing entry and keep its `loadedAt`;
    - this instance's own DeletePost: remove the post.
  - **Used for an author** if the entry is fresh and either `truncated == false` or it holds an item at or below the
    window's lower bound. In the merge, a covered author is a pseudo-chunk, and a truncated one counts as "filled"
    for the exact-prefix bound B.
  - Covered authors are removed **before** chunking, so the reads drop to `ceil(uncovered/30)` queries. Every entry
    used lowers W (D13).
- **Unchanged:** graph (5k), identity profiles, handles and negative caches (20k each), and the new negative handle
  entries share identity's `notFound` LRU. `userLikes` (5k) arrives with P5.
- **In-memory limiters:** ≈ 100k uid keys + 100k IP keys × ~64 B ≈ 13 MiB.
- **Total:** new caches ≤ 113 MiB worst, ≈ 40 MiB typical. With existing caches (≈ 35 MiB typical) that stays inside
  the ~150 MiB budget of the 512 MiB instance. sre-performance watches instance memory, and above 70% the sizes
  shrink via env.

### D16. GetUserTimeline pages with `Limit(page_size)`, not `+1`. **Changed vs plan** (ADR-0008 list-paging rule)
- The query returns `next_page_token` whenever it returns a full page. The only extra cost is one empty final call
  (1 read) when the total is an exact multiple of the page size.
- It saves 1 read on every page.
- Ceiling: `3 + p` (53 at p 50).

### D17. Budget convention for this slice
- Proto comments and `budgettest` use the cold ceilings above, which **include** the interceptor read.
- Planning values exclude it, and the interceptor has its own line in the cost model.
- T19/T20 assert cold after `Reset()` of every instance cache, and warm after a priming call.
- "Refresh with 0 new posts == C" (ADR-0004 tester handoff) is asserted with the author-recent cache **disabled or
  empty** and the graph warm. Add +1 for the interceptor if it is cold.

### D18. Identity and ordering of post docs
- `createdAt` = the Snowflake's millisecond timestamp. `(createdAt, __name__)` order therefore equals id order, and
  cursors and ties are consistent.
- An `AlreadyExists` on `posts/{id}` (node collision) fails the transaction attempt, and the next attempt draws a
  fresh id (ADR-0003 "retry once" is subsumed by the transaction retry).
- Idempotency is ADR-0003 mechanism 2, via `idempotency.Store.Get` in the transaction and `Put` in the same unit.
  `requestHash` covers the normalised text and the four slice-2+ fields, so a reused key with a different body →
  `IDEMPOTENCY_KEY_REUSED` with 0 writes.
- Quota: `quota.Posts`, 100/day; accounts younger than `NEW_ACCOUNT_WINDOW` (24 h) get 20/day.
- The verified-email check comes from `authn.RequireVerifiedEmail` (T7).

### D19. Indexes: every P1 query shape maps to an existing index (no change to `firestore.indexes.json`)
Firestore appends `__name__` to a composite index **in the direction of the index's last field**. Every descending
query must therefore order `createdAt DESC, __name__ DESC` explicitly. That is required anyway to pass
`(createdAt, id)` cursor values. An ascending `__name__` would need new indexes.

| # | Query shape (all `Limit`ed) | Index (`firestore.indexes.json`) |
|---|---|---|
| Q-H | Home chunk: `authorId in [≤30] AND isReply == false ORDER BY createdAt DESC, __name__ DESC` + `StartAfter`/`EndBefore` (`since`, Window) | posts `(authorId ASC, isReply ASC, createdAt DESC)` (lines 4–11) |
| Q-P | Posts tab: `authorId == B AND isReply == false ORDER BY createdAt DESC, __name__ DESC` | same index (lines 4–11) |
| Q-R | Replies tab: `authorId == B ORDER BY createdAt DESC, __name__ DESC` | posts `(authorId ASC, createdAt DESC)` (lines 12–19) |
| Q-E | Purge/export (T10): `authorId == U ORDER BY createdAt DESC, __name__ DESC LIMIT 500` (self-resuming: deleted docs drop out). **Changed vs T10**, which ordered ascending and would have needed a new `(authorId, createdAt ASC)` index | `(authorId ASC, createdAt DESC)` (lines 12–19) |
| Q-C | Test-only invariant: `count()` where `authorId == U` | automatic single-field index on `authorId` |
| Q-G | Point reads: `posts/{id}`, `handles/*` `GetAll`, `idempotency/{hash}`, `quotas/{uid}`, `users/{uid}`, `graph/{uid}` | none needed |

- Existing exemptions stay: `text`, `author`, `media`, `embedded`, `mentions`, `replyToHandle`.
- No `mentionIds` exemption (D12).
- `hashtags` stays indexed for the Phase 2 `(hashtags CONTAINS, createdAt DESC)` index (lines 28–35).
- Counters stay indexed by default. Exempting them only saves storage, which is not binding now.
- **T26 confirms every posts index is READY in dev and prod before any traffic.**
- The ADR-0003 purge rule (`Limit(500)` pages) is an ops path. Rule 5's max-50 limit governs RPC pagination.

### D20. Required log fields
All go through `logger.RequestInfo.Set`, one line per request. **Never logged:** post text, handles, hashtag
strings, mention lists, tokens, and graph arrays.
- **Every request (existing and T3):** `rpc`, `fs_reads`, `fs_writes`, `fs_deletes`, `read_budget_spent` (the uid's
  total after the charge), `limit_name` (on rejections), `feature_disabled=true` (flag rejections).
- **posts (T5, T8, T9):**
  - `posts_op` (`create|delete|get`);
  - `outcome` (`created|replay|deleted|noop|noop:not_owner|found|not_found|rejected:<reason>`);
  - `posts_cache_hit` (count);
  - `txn_attempts`, with a WARN when > 3;
  - `mentions_resolved` and `mentions_dropped` (counts);
  - `hashtags_count`;
  - `text_len` (code points);
  - `feature` on a sub-feature rejection (D2).
- **timeline (T12, T13):**
  - `timeline_op` (`home|user`);
  - `timeline_mode` (`cold|refresh|older|gap`);
  - `timeline_chunks`;
  - `authors_from_cache`;
  - `timeline_cache_hit` (a Posts-tab first page from author-recent);
  - `items_returned` and `items_filtered`;
  - `gap` (bool);
  - `since_clamped` (bool, D13);
  - `page_size`.
- **Purge (T10):** `posts_purge_batch` with counts.

## Consequences
- **Positive:**
  - Every P1 RPC has a cold ceiling that includes the reads the request actually spends, so the P0 budget, the tests
    and the cost model agree.
  - One read-budget mechanism bounds every RPC, current and future, at ≤ 6.8k reads per account per day.
  - The since watermark removes a silent post-loss bug before any user sees it.
  - Timeline tokens survive overnight.
  - Indic hashtags work.
  - DeletePost and GetPost leak neither existence nor blocks.
  - $0 fixed; cents at 300 DAU.
- **Negative:**
  - Reads per DAU are ≈ 21% higher than the plan: the free line is at ≈ 274 DAU for the released scope, and the 40k
    alert fires near 219 DAU.
  - Refreshes may return a few duplicates, which the client must dedupe.
  - A heavy user following more than ~1,000 accounts can hit the daily read cap.
  - Suspended authors stay in followers' Home until P7.
  - DeletePost returns success for posts the caller doesn't own. That is correct, but it surprises API readers.
- **Follow-up:**
  - T2 applies the proto comments.
  - The `firestore-data-model` skill is updated (this change).
  - The planner carries the plan deltas (Handoff).
  - T25 re-bases `cost-model.md` §2–§5.
  - P7 owns suspended-content takedown (D10).
  - P5 adds `userLikes` (+1).
- **Revisit when:**
  - a T22/P9 measurement differs from a planning value by more than 25%;
  - legitimate `read_budget_daily` rejections appear in logs;
  - instance memory exceeds 70%;
  - older-page reads exceed 1.4 × page size (lever: the `k` factor);
  - Firestore exceeds 1.5M reads/day (Stage 2 ADR, `timeline` skill).

## Handoff
- **backend-developer:**
  - **T3:** D5, including the two refinements, `metadata["limit"]`, the IPv6 /64 key and the guard test.
  - **T4:** D1; the buckets as in the plan (home 6/min, user 30/min, create 10/min, delete 20/min, GetPost 60/min).
  - **T5:** D15 (caches, config keys), D18, D19 query shapes with explicit `__name__ DESC`, `Reader.ByAuthors`
    taking only uncovered authors.
  - **T6:** D7–D9 grammars, with the examples as table tests. Reuse `handleRe` and `norm`.
  - **T7:** `ResolveHandles` per D7.
  - **T8:** D2 (with `metadata.feature`), D7, D13 (Snowflake inside each attempt, 5 s transaction deadline), D18.
  - **T9:** D4 (not-owner is success), D6's GetPost column, identity's missing-user error for GetUserTimeline via
    identity's API.
  - **T10:** Q-E (descending query).
  - **T11:** the D14 cursor extension (`EncodeWindow`/`DecodeWindow`, TTL-aware decode), bindings and the gap close
    rule.
  - **T12:** D11, D16, D6.
  - **T13:** D13 watermark, D15 coverage rules, D6 home column.
  - **New config (all env, rule 11):** `READ_BUDGET_PER_UID_PER_DAY=2000`,
    `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY=500`, `CHECK_HANDLE_CALLS_PER_DAY=100`, `TIMELINE_SETTLE_WINDOW=15s`
    (validated ≥ 15 s), `TIMELINE_TOKEN_TTL=720h`, `CACHE_POSTS_ENTRIES=20000`, `CACHE_AUTHOR_RECENT_ENTRIES=1000`,
    plus the T4 rate-limit keys.
  - Log fields per D20.
- **frontend-developer:**
  - Dedupe timeline items by `post_id` on every refresh (D13).
  - On VALIDATION with `field=since_token` or `page_token`, drop the token and cold-open (D14).
  - FEATURE_DISABLED with `metadata.feature` hides only that sub-feature (D2).
  - The composer counts code points of the NFC string after the D9 steps 2 and 4. Use an NFC package (for example
    `unorm_dart`) and `runes.length`; the server stays authoritative. Allow ≤ 10 lines.
  - Linkify only `http(s)://`.
  - Mention spans match `mentions[].handle` case-insensitively, and taps navigate by `user_id`.
  - Blocked-author banners come from local relationship data (D6).
  - `RATE_LIMITED` with `metadata.limit=read_budget_daily` shows a "daily limit reached" banner over the cache, with
    no retry before `retry_after`.
  - DeletePost success always removes the item locally.
- **production-deployer (T26):**
  - Add the new env vars to `cloud-run-api` for dev and prod: `FEATURE_POSTS` dev `on`, prod `off`, plus the keys
    listed for the backend.
  - Plan-then-OK before apply.
  - Verify that the three posts indexes are READY (D19) in dev and prod before any traffic.
  - No new resources, and nothing for `cost-guard` to flag.
  - Runbooks:
    - `posts.md`: index missing ⇒ FAILED_PRECONDITION; read-budget rejections ⇒ raise via env; the settle window;
    - `abuse-spike.md`: query `limit_name=read_budget_daily` by uid count;
    - `account-deletion.md`: purge-posts before purge-graph and before deleting `users`.
- **tester (T19–T21):**
  - D6 is the matrix oracle; every cell is a case, including the overflow row and both-block.
  - Budget assertions use the D17 cold and warm values: CreatePost ≤ 14/2 (replay ≤ 14/1, 0 writes), DeletePost
    ≤ 2/0 and 1 W/1 D (no-op 0 W/0 D), GetPost ≤ 4/0 (+1 overflow), GetUserTimeline ≤ 3 + p, home ≤ 2 + C + 2p.
  - A refresh with 0 new posts == C with author-recent empty and the graph warm.
  - F = 60, p = 20: ≤ 2 + 3·14 cold.
  - A D13 regression: a post committed with `createdAt` older than an already-returned item (fake clock) is
    delivered on the next refresh.
  - D14 tamper, cross-binding (home↔user, since↔page, caller A↔B) and expiry at 30 d + 1 s.
  - DeletePost on another user's post and on an unknown id is byte-identical success with 0 writes.
  - Hashtag and mention example tables (D7, D8).
- **sre-performance (T22, T25):**
  - Use the Cost impact table's planning values and the interceptor line.
  - Report measured means for refresh overhead, older-page reads/page, `since_clamped` rate and interceptor
    cold share.
  - Restate `cost-model.md` §2–§5 (whole product ≈ 215 reads/DAU) and §9 queries by `posts_op`/`timeline_op`.
- **security-auditor (T24):**
  - Confirm D4 (no oracle) and the D6 byte-identity.
  - Review the D14 30-day TTL, D5's IP scope, the IPv6 /64 key and the sybil residual.
  - Confirm the D9 bidi control rejection and that no text is logged (D20).
- **planner (plan deltas):**
  - Q4 → D4 (T9 criteria: "someone else's post ⇒ success, 0 writes, byte-identical to an unknown id").
  - The T10 query is descending.
  - The T11 bindings, window tokens and TTL (D14).
  - The T12 page query is `Limit(page_size)`, not `+1`.
  - The budget table and totals come from this ADR (162.2 R per DAU).
  - The T6 hashtag grammar is D8.
  - T8 gets the transaction deadline and the per-attempt Snowflake.
  - The P7 plan gets the suspended-content takedown (D10).

## Founder attention (no approval needed unless you disagree; nothing here adds a fixed cost)
1. **Reads at 300 DAU: 110% of free, up from the plan's 93%.** That is ≈ $0.09/month, inside D1 ("accept pay-per-use").
   The 40k/day alert will fire near 219 DAU. It is a planned signal, not an incident.
2. **DeletePost on someone else's post returns success (0 writes)** instead of NOT_FOUND. This avoids a
   "who blocked me" oracle.
3. **`since` refreshes may return a few posts twice** (the client dedupes). This fixes silently lost posts.
4. **Daily read cap of 2,000 per account per instance.** An account following more than ~1,000 others can hit it on
   a heavy day, and the cap can be raised by env.
