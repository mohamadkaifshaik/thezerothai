# 0010. Posts and timelines slice (Phase 1 P0 + P1): slice decisions, visibility, read budget
Status: Proposed (architect, 2026-09-30). Becomes Accepted when the founder merges it. No fixed cost is added and no
non-negotiable rule bends. The items that change the plan's defaults or earlier numbers are listed for the founder
under "Founder attention" at the end. **Two residual risks need the founder's explicit acceptance** (D5 "Residual
risk", R1 and R2).
Date: 2026-09-30. **Amended 2026-09-30** after the P0 reviews (`p0-read-budget-security-review.md` H1, M1–M4, L1;
`p0-read-budget-code-review.md` M1, M2): D5 is rewritten (A1–A7), and Options 2b/2c, Cost impact, D15, D20,
Consequences, Handoff and Founder attention follow it. The earlier D5 statements "overshoot is bounded by one call"
and "profile-less ≈ 1,503 reads/day per IP" were wrong (concurrency, instance churn and non-exempt RPCs). The numbers
below replace them.
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
- **Every read-budget counter is in memory, per Cloud Run instance** (`ratelimit.DailyCap`). It resets whenever an
  instance starts: after scale-to-zero, on scale-out, and on every new revision. A bound stated "per day" is really a
  bound per instance lifetime (P0 security review M2).
- **A password account is free to mint and needs no verified email until CreateProfile** (audit H1). Before this
  amendment such a uid could call any non-exempt RPC for 1 Firestore read (`AccountStatusInterceptor`), charged only
  to itself (P0 security review H1). The ID token already carries `email_verified` and `sign_in_provider`, so the
  server can recognise these callers for 0 reads.

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
  profile-exempt calls and a CI guard. $0, 0 Firestore ops, a few MiB of memory at Stage 0 (D15).
- **B. Per-procedure daily call caps only** (extend `DailyCaps` to every read RPC). It can't bound a mix of RPCs whose
  costs differ 1 to 269×. It needs a hand-kept list and silently misses new RPCs. $0. Rejected.
- **C. Enforce web App Check (reCAPTCHA)** to stop scripted clients. That is a flat $8/month past 10k assessments,
  and the founder declined it (phase1 D3). It also doesn't bound a real signed-in account. Rejected at Stage 0.

### 2b. Callers without a profile (P0 security review H1)
- **A. A 0-read verified-identity gate, plus IP charging for verified callers without a profile (chosen, D5 A2–A3).**
  Unverified password accounts are the only kind that is free to mint. They are answered from ID-token claims with 0
  reads. $0 and 0 Firestore ops. It removes ≈ 518k reads/day of exposure per IPv4 address and ≈ 14.4M per IPv6 /64
  (security H1).
- **B. Mark and IP-charge only** (the review's fixes 1–4). $0. A uid is unknown on its first call to each instance,
  and the mark lives in memory, so every minted uid still gets 1 unchecked read per instance lifetime. The per-/64
  per-minute limiter (≈ 518k/day) stays the only real bound. Kept only as A's second layer.
- **C. A custom claim set at CreateProfile.** Also 0 reads, but it adds an Identity Toolkit call inside CreateProfile
  with a partial-failure state that needs a repair path, a backfill of existing profiles, and a forced token refresh
  in every client. A gets the same 0-read result from a claim Firebase already issues. Rejected.
- **D. Enforce App Check (reCAPTCHA on web).** A flat $8/month step past 10k assessments, declined by the founder
  (phase1 D3). Rejected at Stage 0. It stays the escalation lever for residual R1.

### 2c. Per-instance counters and instance churn (P0 security review M2)
- **A. State the bounds per instance lifetime, record founder acceptance, and pre-design the fix behind a trigger
  (chosen, D5 "Residual risk").** $0, 0 Firestore ops.
- **B. Persist the counter now.** On SIGTERM, flush each uid's spend ≥ 100; seed a new instance from the `users` doc
  the account-status interceptor already reads (0 extra reads). $0 fixed, ≈ 300–600 writes/day at 300 DAU (1.5–3% of
  the free writes), plus SIGTERM-path code and tests. Deferred until its trigger fires: the risk today is
  ≤ ≈ $0.12/day per actor in the realistic case, and detection exists.
- **C. A shared counter in Memorystore.** ≈ $35/month fixed. Rejected (Stage 2 ADR).

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
- **The D5 amendment adds no Firestore operation.** The verified-identity gate, the in-flight hold and the IP charge
  are in memory. The gate removes ≈ 1 read per call made by minted, unverified accounts. The instance-churn fix is
  pre-designed but not built (Option 2c).

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
| Unverified password caller, any RPC (D5 A2 gate) | 0 (was 1 per uid per 10 s per instance on non-exempt RPCs) | 0 | 0 | 0 | 0 | — | — | ±0 | 0 | 0 |
| DeleteAccount / RequestAccountExport / GetAccountExport (D5 A6: charge-only, `account_ops_daily`) | 2 each (interceptor + 1), unchanged | 1 | unchanged | unchanged | unchanged | — | — | ±0 | ±0 | ±0 |
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
Adopt option 1B, 2A (with 2b-A and 2c-A from the P0-review amendment), 3C and 4A, with D1–D20 below. Q1–Q12 are the plan's questions. **"Changed vs plan"** marks every
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

### D5. P0 read budget (Q5). Accepted numbers, **with refinements; amended after the P0 reviews (A1–A7)**
- **Mechanism.** Generalise `ratelimit.DailyCap` (T3) so one counter type counts either calls or units, with the same
  IST-day reset, LRU of 100k keys and no idle TTL (security L1).
  - Inside `ratelimit.Interceptor`, before `next`: `Reserve` each budget key of the call (A1 decides admission).
  - After `next`, in a `defer` so a panic still settles it: `Release(key, budget.FromContext(ctx).Reads())`. The
    counter comes from `mw.Logging`, which is outermost, so the charge includes interceptor reads.
  - Charge on success and on error alike.
- **Numbers (config, rule 11):**
  - `READ_BUDGET_PER_UID_PER_DAY = 2000`
  - `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY = 500`
  - `CHECK_HANDLE_CALLS_PER_DAY = 100` (a `DailyCaps` entry, `limit_name=check_handle_daily`)
  - **new:** `ACCOUNT_OPS_CALLS_PER_DAY = 20` (a `DailyCaps` entry, `limit_name=account_ops_daily`, A6)
  - code constants, not env (lowering them would silently break the bound): `readBudgetMaxCallReads = 269`,
    `ipBudgetMaxCallReads = 2`, `profileLessMarkTTL = 10 min`.
  - `config.Load` rejects any of the env values `<= 0` (code review m3).
  - negative handle cache 10 s: reuse identity's `notFoundTTL`, applied to `ResolveHandle` NotFound, used by
    CheckHandleAvailability, GetProfile-by-handle and `ResolveHandles`.
- **A1. In-flight hold: the overshoot is one call per key per instance lifetime, at any concurrency** (security M1,
  code M1).
  - Each unit budget has a per-call hold M: **269** for the uid key (the largest cold ceiling in this ADR,
    GetHomeTimeline `2 + C + 2p`) and **2** for the IP key (every IP-keyed call reads at most 1 doc).
  - `Reserve(key)`:
    - rejects as **daily** when `count ≥ cap`;
    - rejects as **transient** when `inflight > 0` and `count + (inflight + 1) · M > cap`;
    - otherwise admits the call and increments `inflight`.
  - `Release(key, n)` adds the actual reads `n` and decrements `inflight`.
  - Invariant: `count + inflight · M ≤ cap − 1 + M`, as long as no call reads more than M. So the counter never passes
    `cap − 1 + M` in one instance lifetime (2,268 for a uid, 501 for an IP), however many calls run in parallel.
  - **Not enough:** the code review's `inflight > 0 && count + M > cap`. Calls admitted in parallel below `cap − M`
    still land later: six home refreshes admitted at 1,000 end at ≈ 2,614.
  - Legitimate parallelism: `max(1, floor((cap − spent) / M))` calls may be in flight. That is 7 on a fresh day, and 1
    once spent > 1,462. A transient rejection costs 0 reads, and the client retries it once (Handoff).
  - A new RPC with a cold ceiling above 269 raises the constant in the same PR (T23 check). At runtime, a call that
    reads more than M logs WARN `read_budget_over_max=true`, because the bound assumes that never happens.
- **A2. Verified-identity gate: unverified password accounts cost 0 reads** (security H1, the primary fix).
  - A new `authn` interceptor runs right after `IDTokenInterceptor` and before the rate limiter. It uses the T7
    predicate: `sign_in_provider == "password" && !email_verified`, the check `identity.requireVerifiedEmailForPassword`
    makes today, moved to `pkg/platform/authn`.
  - For such a caller:
    - CheckHandleAvailability and CreateProfile return FAILED_PRECONDITION + `EMAIL_NOT_VERIFIED`;
    - every other procedure returns FAILED_PRECONDITION + `PROFILE_REQUIRED`, with the account-status interceptor's
      message.
  - Either way it costs 0 Firestore reads and creates no limiter key, so minted uids cannot fill the LRUs (security L5).
  - `PROFILE_REQUIRED` is truthful. Since audit H1 (2026-09-27) CreateProfile refuses unverified password accounts, so
    such an account has no profile. The client's `GetMe → PROFILE_REQUIRED → create-profile` flow is unchanged.
  - **Change vs ADR-0006 §2:** CheckHandleAvailability stays profile-exempt but now needs a verified email for
    password accounts. Google and Apple sign-ins are unaffected. A password user verifies the email before the form
    can check handle availability (Founder attention 5).
  - **Preconditions:** before the gate reaches prod, a one-off check shows that no password account with
    `emailVerified=false` owns a `users` doc (T26). Any future email-change flow must use `verifyBeforeUpdateEmail`, so
    a verified account never becomes unverified.
- **A3. Verified callers without a profile are charged to their IP key** (H1, second layer).
  - On its `!exists` branch, `AccountStatusInterceptor` sets `RequestInfo.ProfileRequired = true`.
  - After `next`, when that flag is set, the rate limiter charges the call's reads to the caller's IP key (unless the
    call already reserved it) and marks the uid in a per-instance `profileLess` LRU (100k entries, TTL 10 min; reuse
    `cache.LRU`, no new limiter type).
  - Before `next`, a marked uid calling a non-exempt procedure also reserves the IP key. If the IP budget is spent,
    the call is rejected with `retry_after` = 10 min, because the mark may be stale (a user who just created a profile
    on another instance).
  - A successful CreateProfile on this instance removes the mark.
  - A caller whose profile this instance has seen is never marked, so real users behind carrier-grade NAT keep
    Refinement 1's protection.
- **A4. IP key scopes** (security M3).
  - **Enforced** (reserve and charge): CheckHandleAvailability, and the non-exempt calls of a marked uid (A3).
  - **Charge-only:** CreateProfile. The IP key never rejects it; it is already bounded by the verified email, the
    per-uid budget and the `handles` transaction. One abuser behind a shared IPv4 address can no longer block sign-ups
    for everyone behind it.
  - Config: explicit sets `ReadBudgetIPEnforce` and `ReadBudgetIPChargeOnly`. The guard test asserts
    `ProfileExempt == Enforce ∪ ChargeOnly` (security L6), so a new exempt procedure must be classified.
- **A5. IP key form** (security M4, H1 item 4, Refinement 2).
  - `ResolveClientIP`: if the chosen entry (after the Google-egress step or the `TRUSTED_PROXY_HOPS` override) does not
    parse as an IP, fall back to the rightmost entry, which the Google front end appended. If that does not parse
    either, there is no IP key (as today without X-Forwarded-For, which happens only locally).
  - `IPBudgetKey(ip) (key string, ok bool)` returns only a canonical `netip` string: the IPv4 address, or the IPv6 /64
    prefix (≤ 43 bytes). It never returns raw input.
  - Every IP-keyed structure uses it: `PreAuthIPMiddleware`'s limiter, the in-chain `cfg.IP` per-minute limiter and
    `ReadBudgetIP`. Rotating addresses inside a /64 no longer escapes the per-minute limits.
  - The API's `http.Server` sets `MaxHeaderBytes = 64 KiB`.
- **A6. Account operations are charge-only on the uid budget** (code review M2, rule 10).
  - DeleteAccount, RequestAccountExport and GetAccountExport are charged to the uid budget but never rejected by it
    (no Reserve, no hold). A user at the cap can still delete or export.
  - Their own bound is a shared `DailyCaps` entry, `account_ops_daily`: 20 calls per uid per IST day per instance.
    Each call reads at most 2 docs (interceptor + 1), so at most 40 reads per instance lifetime. Real flows use at most
    5 calls (request, a few polls, delete). Without this cap, GetAccountExport alone could read ≈ 259k docs/day per uid
    under the 60/min default bucket.
  - The guard test asserts that the charge-only set is exactly these three, each with a comment and a `DailyCaps`
    entry.
- **A7. Rejections and logs** (security L1, code m7). The client-visible metadata is unchanged except for the new
  transient value.

| Cause | Client error | `metadata["limit"]` | `retry_after` | log `limit_name` | log `read_budget_key` | Reads |
|---|---|---|---|---|---|---|
| uid budget spent | RESOURCE_EXHAUSTED + `RATE_LIMITED` | `read_budget_daily` | to IST midnight | `read_budget_daily` | `uid` | 0 |
| IP budget spent, CheckHandleAvailability | same | `read_budget_daily` | to IST midnight | `read_budget_daily` | `ip` | 0 |
| IP budget spent, marked uid on a non-exempt RPC (A3) | same | `read_budget_daily` | 10 min | `read_budget_daily` | `ip` | 0 |
| in-flight hold (A1) | same | `read_budget_inflight` | 1 s | `read_budget_inflight` | `uid` or `ip` | 0 |
| CheckHandleAvailability calls | same | `check_handle_daily` | to IST midnight | `check_handle_daily` | — | 0 |
| account operations (A6) | same | `account_ops_daily` | to IST midnight | `account_ops_daily` | — | 0 |
| unverified password account (A2) | FAILED_PRECONDITION + `EMAIL_NOT_VERIFIED` (exempt RPCs) or `PROFILE_REQUIRED` (all others) | — | — | — (`gate=email_unverified`) | — | 0 |

  - `read_budget_spent` is always the uid's spend. `read_budget_ip_spent` is the IP key's spend whenever that key was
    reserved, charged or rejected. The IP address itself is never logged.
  - `profile_required=true` when A3 marks a uid.
  - The daily rejections run before account status, so they cost 0 reads (unchanged).
- **Refinement 1 (IP key scope)** is replaced by A3–A4. Callers with a profile are still never IP-limited. The IP key
  applies to CheckHandleAvailability (enforced), CreateProfile (charge-only) and marked uids without a profile
  (enforced). That matters in India, where carrier-grade NAT puts thousands of real users behind one IP.
- **Refinement 2 (IPv6)** is kept: the IP key is the full IPv4 address, or the **/64 prefix** of an IPv6 address. A5
  extends it to both per-minute IP limiters.
- **Guard test (T3.5):** every registered procedure with `IdempotencyLevel == NoSideEffects` must be covered (all are,
  because the budget applies to every procedure). `ReadBudgetExempt` is empty and must stay explained. The test also
  asserts the A4 and A6 sets and that `ReadBudgetIP` is wired, using the same exported helper `Build` uses (L6).
- **Math: typical use against the cap.**
  - Released scope after P1: ≈ 183 reads/DAU/day. Whole Phase 1 model: 191 (cost-model §2), ≈ 215 after T25.
  - The cap is **≈ 9–11× a typical day**.
  - Heavy but legitimate, F = 300 (C = 11): 20 refreshes × (2 + 11 + 5) = 360; 10 older pages × (2 + 11·4) = 460;
    4 profile pages × 23 = 92; 10 GetPost × 4 = 40; GetMe and others ≈ 30. That totals **≈ 980**, under the cap.
  - F = 1,000 (C = 34) reaches ≈ 1,700 on the same day and is close to the cap. Past 1,462 its parallel calls go one
    at a time (A1), and the client's single silent retry covers that.
  - F = 5,000 hits it after ≈ 11 refreshes.
  - Accepted residual: an account following more than ~1,000 others can hit the cap on a heavy day. It gets a
    non-blocking banner and keeps its cache (T17), and the cap is raised via env. There are no such accounts at
    Stage 0.
- **Math: worst-case abusive totals (replaces the earlier figures).**
  - Every counter lives in instance memory, so each bound is per key **per instance lifetime**. A per-day figure is
    that bound times the lifetimes an attacker gets:
    - **steady:** at most 3 instances all day (max-instances 3);
    - **rollout day:** the tagged `candidate` revision and the serving revision run side by side, at most 6;
    - **idle cycling:** spend, stay idle until the instance scales to zero, repeat. With ≥ 15 min idle to reach zero
      and ≥ 1 min to spend, that is at most 90 lifetimes per instance slot per day. One actor holds at most 7 calls in
      flight (A1), which keeps one instance busy: ≤ 90 lifetimes a day. Forcing 3 instances every cycle needs other
      load: ≤ 270, the ceiling.
    - Cloud Run chooses the idle-to-zero time ("up to 15 min"). T22/T26 measure it in dev; a shorter time scales the
      idle-cycling rows up linearly.
  - Prices are marginal, at the `cost-model.md` §7 upper bound of $0.06 per 100k reads (at 300 DAU the released scope
    is already past the free line).

| Actor | Per instance lifetime | Per IST day, steady | Rollout day | Idle cycling, one actor | Ceiling (270 lifetimes) |
|---|---|---|---|---|---|
| Unverified password accounts (any number, any IP) | 0 | 0 | 0 | 0 | 0 |
| One verified account, with or without a profile | 2,000 − 1 + 269 + 20 × 2 = **2,308** | ≤ 6,924 (13.8% of free, ≈ $0.004) | ≤ 13,848 | ≈ 208k (4.2× free, ≈ $0.12) | ≈ 623k (12.5× free, ≈ $0.37; ≈ $11/month if repeated daily) |
| One IPv4 address or IPv6 /64, IP key (CheckHandleAvailability + marked uids) | 500 − 1 + 2 = **501** | ≤ 1,503 | ≤ 3,006 | ≈ 45k | ≈ 135k |
| Same IP: first calls of V verified, unmarked uids without a profile | ≤ V per 10 min | ≤ 432 · V (V = 5: 2,160) | ≤ 864 · V | — | ≤ 518k (the per-minute IP limiter: 120/min per instance, now per /64) |

  - For comparison: before P0 one account could spend ≈ 86k–259k/day. Before this amendment, minted unverified uids
    gave ≈ 518k/day per IPv4 address and ≈ 14.4M/day per IPv6 /64 (security H1). Those rows are now 0.
  - Every non-zero row needs a verified identity: a verified mailbox (password), or a Google or Apple account. The
    uids in the last row are each also held to their own 2,308 per lifetime.
- **Residual risk: needs FOUNDER acceptance, recorded in the release readiness report before the T27 `percent`
  step.**
  - **R1. Verified sybils.** Each verified account adds up to its own bound: ≤ 6,924 reads/day in steady state. About
    8 such accounts exhaust a day's 50k free reads (≈ $0.03/day of overage for all 8). A catch-all mail domain makes
    verified password accounts cheap to mint. The levers are the Firebase sign-up throttle, the sign-up kill switch,
    disabling accounts, and App Check enforcement (declined at Stage 0, phase1 D3; an $8/month step past 10k
    assessments).
  - **R2. Instance churn.** The bounds are per instance lifetime, not per day. One verified account that idle-cycles
    instances all night can reach ≈ 208k reads/day (≈ $0.12/day). The ceiling with forced scale-out is ≈ 623k/day
    (≈ $0.37/day, ≈ $11/month if repeated every day), which would trip the $5 budget alert in about two weeks.
    - Detection: the same `uid_hash` rejected with `read_budget_daily` on 3 or more distinct instances (the log
      entry's `labels.instanceId`) in one IST day, or a budget alert driven by reads.
    - Response: `abuse-spike.md` (disable the account).
    - **Pre-designed fix, not built (Option 2c-B):** on SIGTERM, flush each uid's spend ≥ 100 reads with one
      `Increment` on `users/{uid}.readSpent{day, n}`; seed a new instance's counter from the `users` doc the
      account-status interceptor already reads (0 extra reads). ≈ 300–600 writes/day at 300 DAU, $0 fixed. It bounds
      an account at ≈ cap + 100 per extra lifetime. **Trigger:** the detection matches on 2 days in any 7, or one
      budget alert is attributable to reads.
  - Proposed acceptance wording (the founder copies it, dated, into the readiness report): *"I accept ADR-0010 D5
    residuals R1 and R2. At Stage 0 each verified account can spend up to about 6.9k Firestore reads a day in steady
    state, and up to about 623k a day (about $0.37) in the worst case if it deliberately cycles Cloud Run instances.
    Verified sybil accounts multiply this. The controls are the budget alerts, the abuse-spike runbook, and the
    pre-designed persisted counter behind its trigger."*

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
- **In-memory limiters:** an entry is ≈ 200–250 B (key, counter, list element, map; security L5), not 64 B, so a
  full 100k-key LRU is ≈ 20–25 MiB. There are six `DailyCap`s (uid and IP read budgets, `check_handle_daily`,
  `graph_list_daily`, `graph_mutation_daily`, `account_ops_daily`), the per-minute limiters and the D5 A3
  `profileLess` LRU. Filling all of them would need 100k distinct verified uids (or /64s) calling every RPC on one
  instance in one IST day, and would not fit in 512 MiB. At Stage 0 each holds hundreds of keys (< 5 MiB in total).
  The A2 gate keeps unverified uids out of every limiter, and A5 keeps IP keys canonical and short. If instance
  memory passes 70%, lower the LRU key limits (`maxTrackedKeys`, `maxTrackedDailyKeys`) before the cache sizes.
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
- **Every request (existing and T3):** `rpc`, `fs_reads`, `fs_writes`, `fs_deletes`, `feature_disabled=true` (flag
  rejections), and the D5 A7 fields:
  - `read_budget_spent` (the uid's total after the charge) and `read_budget_ip_spent` (when the IP key was used);
  - `limit_name` and `read_budget_key` (`uid` or `ip`) on rejections;
  - `profile_required=true` (A3 mark), `gate=email_unverified` (A2), WARN `read_budget_over_max=true` (A1).
  - The IP address is never logged.
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
  - One read-budget mechanism bounds every RPC, current and future: 2,308 reads per verified account per instance
    lifetime (≤ 6.9k a day in steady state), and minted, unverified accounts cost 0 reads.
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
  - The read bounds are per instance lifetime, not per day. Deliberate instance cycling and verified sybils are
    residuals the founder must accept (D5 R1, R2).
  - Password sign-ups must verify their email before the handle check works (D5 A2).
  - Near the cap an account runs one call at a time; extra parallel calls get a 1 s retry (D5 A1).
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
  - the D5 R2 detection matches on 2 days in any 7, or a budget alert is attributable to reads (build the persisted
    counter, Option 2c-B);
  - legitimate `read_budget_inflight` retries show up in logs (switch the hold from one global M to per-procedure
    ceilings);
  - older-page reads exceed 1.4 × page size (lever: the `k` factor);
  - Firestore exceeds 1.5M reads/day (Stage 2 ADR, `timeline` skill).

## Handoff
- **backend-developer:**
  - **T3:** D5 as amended (A1–A7). The P0 branch already has part of A1; its admission rule must change as below.
    1. A1 hold: `Reserve` rejects when `count ≥ cap` or when `inflight > 0 && count + (inflight + 1) · M > cap`;
       `Release(key, n)` runs in a `defer`; M = 269 (uid) and 2 (IP) as code constants; the transient rejection is
       `read_budget_inflight` with a 1 s `retry_after`; WARN `read_budget_over_max` when a call reads more than M.
    2. A2 gate interceptor right after `IDTokenInterceptor`, using the T7 predicate; 0 reads, no limiter keys.
    3. A3: `RequestInfo.ProfileRequired`, the `profileLess` LRU (10 min), the IP charge after `next`, the IP reserve
       for marked uids, and the unmark on CreateProfile.
    4. A4: explicit enforced and charge-only IP sets; CreateProfile is charge-only.
    5. A5: `ResolveClientIP` falls back to the rightmost entry; `IPBudgetKey` returns `(key, ok)`; both per-minute IP
       limiters key by it; `MaxHeaderBytes = 64 KiB`.
    6. A6: `ReadBudgetChargeOnly` = DeleteAccount, RequestAccountExport, GetAccountExport, plus `account_ops_daily`.
    7. A7 log fields. `config.Load` rejects values ≤ 0. Fix the `config.go`, `daily_cap.go` and `interceptor.go`
       comments that still say "overshoot is one call" or "≈ 1,503 reads/IP".
    8. The guard test also covers the A4 and A6 sets and the `ReadBudgetIP` wiring.
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
    `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY=500`, `CHECK_HANDLE_CALLS_PER_DAY=100`, `ACCOUNT_OPS_CALLS_PER_DAY=20`,
    `TIMELINE_SETTLE_WINDOW=15s` (validated ≥ 15 s), `TIMELINE_TOKEN_TTL=720h`, `CACHE_POSTS_ENTRIES=20000`,
    `CACHE_AUTHOR_RECENT_ENTRIES=1000`, plus the T4 rate-limit keys. The A1 holds and the A3 mark TTL are code
    constants, not env.
  - Log fields per D20.
- **architect (follow-up; comment-only proto, rides with the T3 PR, `buf breaking` clean):**
  - `common.proto` RATE_LIMITED lists `read_budget_inflight` (1 s `retry_after`, retry once) and `account_ops_daily`.
  - `identity.proto`: CheckHandleAvailability needs a verified email for password accounts (`EMAIL_NOT_VERIFIED`, 0
    reads) and its IP budget is enforced; CreateProfile is charge-only on the IP key; DeleteAccount,
    RequestAccountExport and GetAccountExport are never rejected by the read budget (`account_ops_daily` instead);
    the file header says unverified password callers get `PROFILE_REQUIRED` at 0 reads.
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
  - `RATE_LIMITED` with `metadata.limit=read_budget_inflight` is transient: retry once, silently, after
    `retry_after` (1 s); show an error only if the retry also fails.
  - CheckHandleAvailability returning `EMAIL_NOT_VERIFIED` shows the existing "verify your email" banner on the
    create-profile screen instead of availability. After the user verifies, refresh the ID token
    (`getIdToken(true)`) before calling again.
  - CheckHandleAvailability returning `RATE_LIMITED` (any limit): stop live checks and let CreateProfile's
    `HANDLE_TAKEN` decide.
  - DeletePost success always removes the item locally.
- **production-deployer (T26):**
  - Add the new env vars to `cloud-run-api` for dev and prod: `FEATURE_POSTS` dev `on`, prod `off`, plus the keys
    listed for the backend.
  - Plan-then-OK before apply.
  - Verify that the three posts indexes are READY (D19) in dev and prod before any traffic.
  - Before the D5 A2 gate reaches prod: list password accounts with `emailVerified=false` (Admin SDK
    `accounts:batchGet`, free) and confirm none owns a `users` doc. Record the count, never the uids.
  - No new resources, and nothing for `cost-guard` to flag.
  - Runbooks:
    - `posts.md`: index missing ⇒ FAILED_PRECONDITION; read-budget rejections ⇒ raise via env; the settle window;
    - `abuse-spike.md` (D5 A7 and "Residual risk"): Logs Explorer filters, not SQL (Log Analytics is not enabled;
      security L2), on `jsonPayload.limit_name` = `read_budget_daily`, `read_budget_inflight`, `check_handle_daily`
      or `account_ops_daily`, split by `jsonPayload.read_budget_key` (`uid`: a heavy account or sybils; `ip`: a farm
      behind one address); counts of `jsonPayload.gate="email_unverified"` (minted-account floods, now 0 reads) and
      `jsonPayload.profile_required=true`; the R2 churn check (one `uid_hash` rejected on ≥ 3 distinct
      `labels.instanceId` in an IST day); the levers in order: disable the account, the sign-up kill switch, lower
      `READ_BUDGET_PER_UID_PER_DAY`, `FEATURE_POSTS=off`. It must say that `DEGRADED_MODE=readonly` does not reduce
      reads;
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
  - D5 read budget (T3/T20):
    - N parallel calls at spent 0 and at `cap − 1` never push the counter past `cap − 1 + M`; the rest get
      `read_budget_inflight` with a 1 s `retry_after`;
    - an unverified password uid gets `PROFILE_REQUIRED` on GetMe and `EMAIL_NOT_VERIFIED` on CheckHandleAvailability,
      with 0 reads;
    - a verified uid without a profile rotating on GetMe is charged to its /64, then rejected with
      `read_budget_key=ip`; CreateProfile still succeeds from that IP;
    - DeleteAccount, RequestAccountExport and GetAccountExport succeed for a uid at the cap;
    - a malformed X-Forwarded-For entry falls back to the rightmost entry; two addresses in one /64 share the
      per-minute IP buckets.
- **sre-performance (T22, T25):**
  - Use the Cost impact table's planning values and the interceptor line.
  - Report measured means for refresh overhead, older-page reads/page, `since_clamped` rate and interceptor
    cold share.
  - Restate `cost-model.md` §2–§5 (whole product ≈ 215 reads/DAU) and §9 queries by `posts_op`/`timeline_op`.
  - Measure Cloud Run's idle-to-zero time in dev (last request to `instance_count` 0) and restate the D5 churn rows if
    it is under 15 min.
- **security-auditor (T24):**
  - Confirm D4 (no oracle) and the D6 byte-identity.
  - Re-review the P0 closure against D5 A1–A7 (H1, M1, M3, M4, L1, L6) and confirm that residuals R1 and R2 match
    the code.
  - Review the D14 30-day TTL.
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

## Founder attention (items 1–6 need no approval unless you disagree; item 7 needs your explicit acceptance; nothing here adds a fixed cost)
1. **Reads at 300 DAU: 110% of free, up from the plan's 93%.** That is ≈ $0.09/month, inside D1 ("accept pay-per-use").
   The 40k/day alert will fire near 219 DAU. It is a planned signal, not an incident.
2. **DeletePost on someone else's post returns success (0 writes)** instead of NOT_FOUND. This avoids a
   "who blocked me" oracle.
3. **`since` refreshes may return a few posts twice** (the client dedupes). This fixes silently lost posts.
4. **Daily read cap of 2,000 per account per instance lifetime.** An account following more than ~1,000 others can
   hit it on a heavy day, and the cap can be raised by env. Near the cap an account runs one call at a time; extra
   parallel calls are retried after 1 s (D5 A1).
5. **Password sign-ups verify their email before the handle check works** (D5 A2). Google and Apple sign-ins are
   unaffected. This is what makes mass-created accounts cost 0 reads. It refines ADR-0006 §2, which let
   CheckHandleAvailability run before verification.
6. **Account deletion and export are never blocked by the read budget** (D5 A6). They have their own cap of 20 calls
   a day per instance, far above the ≤ 5 a real user needs.
7. **Your acceptance is needed for residual risks R1 and R2** (D5 "Residual risk"). Verified sybil accounts multiply
   the per-account bound (about 8 exhaust the free reads for a day). One account that deliberately cycles instances
   can reach ≈ 623k reads (≈ $0.37) a day in the worst case. Copy the acceptance wording from D5, dated, into the
   release readiness report. It is a condition for the T27 `percent` step. Without it P0 stays open and the rollout
   stops at `allowlist`.
