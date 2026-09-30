# Posts + profile timeline + home timeline (Phase 1 slices P0 + P1)
Plan owner: planner · Date: 2026-09-30 · Target release: **v0.3.0** (web public beta, see `docs/plans/phase1.md` §4) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, ADR-0002/0003/0004/0006/0008/0009, `proto/dzeroth/{posts,timeline,common,identity}/v1/*.proto`,
`backend/internal/{identity,graph,apiserver}`, `backend/pkg/platform/*`, `firebase/firestore.indexes.json`,
`docs/reviews/cost-model.md`, `docs/reviews/security-audit-v0.1.0.md`, `docs/plans/graph.md` (format and patterns).

> **Defaults assumed so work doesn't block.** The architect confirms or overrides each one in T1 (ADR-0010).
> - **Q1:** one server flag `FEATURE_POSTS` gates PostService, TimelineService and all posts UI (the ADR-0008 D6 mechanism).
> - **Q2:** this slice creates **root posts only**. `reply_to_post_id`, `quote_of_post_id` and `media_ids` return
>   FAILED_PRECONDITION + `ERROR_REASON_FEATURE_DISABLED` until P3/P5/P4.
> - **Q3:** there is no `userLikes` read yet. `liked_by_viewer`/`reposted_by_viewer` are always false until P5 (−1 read per call).
> - **Q4:** DeletePost on someone else's post returns NOT_FOUND (no ownership leak). An unknown or already-deleted id
>   returns success.
> - **Q5:** P0 uses a per-uid **daily Firestore read budget**, 2,000 reads/uid/IST-day/instance.
> - **Q6:** muted authors are hidden from Home only. They are shown on their profile (X behaviour). A caller who
>   blocks the author still gets the author's posts, and the client shows a banner first.

---

## Goal & user value
- **Users can post** short text with @mentions, #hashtags and links.
- **They see a chronological home feed** of the people they follow (plus their own posts). It opens instantly from
  the device cache and refreshes cheaply.
- **Each profile shows that person's posts.**

This is the base every later Phase 1 slice (replies, images, likes, notifications, reports, deletion) builds on.
It also makes the product worth opening, which the graph slice alone does not.

## Scope
- **P0 (gating hardening), T3.** A per-uid daily read budget covering every RPC.
  - A per-IP budget for callers without a profile.
  - A negative handle cache.
  - A CI guard: no `NO_SIDE_EFFECTS` RPC ships uncovered.
  - **Must be in prod before `FEATURE_POSTS` goes beyond `allowlist`.**
- **Backend `internal/posts`.**
  - `CreatePost` (root posts): NFC, ≤ 280 code points, ≤ 10 mentions resolved via `handles/*`, ≤ 10 hashtags, links
    left in the text.
  - `DeletePost`, `GetPost`.
  - `posts.Reader` (for timeline), `posts.Eraser` + exporter, `opsctl purge-posts|export-posts`.
  - The `PostEvents` hook, which does nothing for now (notifications land in P6).
- **Backend `internal/timeline`.**
  - `GetUserTimeline`, Posts tab (`include_replies=false`). `include_replies=true` returns the same page until P3,
    because no replies exist.
  - `GetHomeTimeline`, ADR-0004 steps 1–4 and 6–9: the chunked pull, the exact-prefix merge, the gap token, and the
    author-recent cache.
- **Identity.**
  - `Directory.ResolveHandles`, batched and cache-first, for mentions.
  - Move the verified-email check to `pkg/platform/authn` so posts reuses it.
- **Flutter.**
  - `PostsRepository`/`TimelineRepository`.
  - drift tables for timeline items and `since_token`.
  - A shared `PostCard` with rich text: mentions and hashtags tappable, links opened externally.
  - The composer.
  - The Home timeline: cache-first, pull-to-refresh with `since`, gap rows, infinite scroll, a new-post pill, and
    auto-refresh at most every 60 s.
  - The profile Posts tab, a `/post/:id` detail (single post), and delete-own-post.
- **Tests and ops.** Emulator integration tests with budget assertions, e2e smoke, k6 smoke, the cost report,
  runbooks, the dev deploy, and a prod allowlist rollout.

## Out of scope (explicit non-goals)
- Replies/threads and `GetThread` (P3); images (P4); likes/reposts/quotes and viewer flags (P5); notifications,
  including mention notifications (P6); reports (P7); in-app deletion/export orchestration (P8).
- Hashtag pages and handle search (Phase 2). Hashtags are stored and the index exists
  (`firestore.indexes.json:29-34`), but no RPC queries them.
- Link previews (Phase 2, SSRF-safe fetcher). The client linkifies only.
- The author-snapshot refresh job (P2). In this slice a rename leaves old posts with the old handle/name. Clients
  always navigate by `author.user_id`, never by the snapshot handle.
- Edit window, pinned posts, bookmarks (Phase 2). Private-account visibility (ADR-0008 D1 deferral): every post is
  `VISIBILITY_PUBLIC`.
- **Scale-up path** (Stage 2, needs an ADR): Memorystore materialized timelines (ADR-0004 "Path to Stage 2", same RPC
  contract); sharded `postsCount`; a Redis-backed shared read budget instead of per-instance counters.

## Non-functional targets (Stage 0, ≤ 300 DAU)
| Path | p95 warm | Cold (incl. start) |
|---|---|---|
| CreatePost | < 500 ms | < 1.5 s |
| DeletePost / GetPost | < 300 ms / < 150 ms | < 1.5 s |
| GetHomeTimeline refresh (F ≤ 300) | < 400 ms | < 1.5 s |
| GetHomeTimeline older page / cold (F ≤ 300) | < 600 ms | < 1.5 s |
| GetUserTimeline (page 20) | < 300 ms | < 1.5 s |
| Read-budget interceptor overhead | < 1 ms | — |

Staleness: up to 60 s on other instances (ADR-0004 §6). The author's own posts are inserted optimistically by the client.

## Cost (required)

### Per-RPC budget (Firestore ops per call; worst / typical)
Definitions:
- F = the caller's following count. C = ceil((F+1)/30), at most 167.
- "Cached" means the 60 s instance cache: identity profiles, the graph snapshot, and the new posts/author-recent caches.
- An empty query still costs 1 read.

| RPC | reads (worst / typical) | writes (worst / typical) | deletes | Cloud Run ms | calls / DAU / day | reads / DAU | writes / DAU | deletes / DAU |
|---|---|---|---|---|---|---|---|---|
| CreatePost (root) | 14 / 2 | 4 / 4 | 1 (idempotency TTL, eventual) | 80 | 1.0 | 2.0 | 4.0 | 1.0 |
| ↳ CreatePost replay (same key) | 2 / 2 | 0 | 0 | 30 | — | — | — | — |
| DeletePost | 1 / 1 | 1 / 1 | 1 / 1 | 40 | 0.05 | 0.05 | 0.05 | 0.05 |
| GetPost | 3 / 0.5 | 0 | 0 | 15 | 1 | 0.5 | 0 | 0 |
| GetUserTimeline (page ≤ 50; typical blends a cold page of 20 ≈ 22 and a `since` refresh ≈ 1) | 53 / 11 | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| GetHomeTimeline, refresh | 1 + C + 2·page (268 @ F = 5,000, page 50) / 3 overhead + new posts | 0 | 0 | 80 | 8 | 24.0 overhead + **60.0 new posts** | 0 | 0 |
| GetHomeTimeline, older page | same / 23 | 0 | 0 | 120 | 1 | 23.0 | 0 | 0 |
| GetHomeTimeline, cold open | same / 23 | 0 | 0 | 150 | 0.1 | 2.3 | 0 | 0 |
| IdentityService.CheckHandleAvailability / GetProfile (P0 change: negative handle cache) | unchanged worst; typical ↓ | 0 | 0 | +0 | — | ±0 | 0 | 0 |
| **P0 + P1 total** | | | | | **≈ 13.2 req** | **≈ 133.9** | **≈ 4.05** | **≈ 1.05** |

Derivation notes:
- **CreatePost worst 14** = idempotency doc 1 + `quotas` 1 (both fresh, in the transaction) + author `users` 1 (the
  snapshot, new-account quota and status; cached) + author graph 1 (drops mentions of users who blocked the author;
  cached) + `handles/*` for 10 mentions (one `GetAll`, cache-first).
  - Typical 2: the idempotency miss and `quotas`.
  - Writes 4: the idempotency doc, the post, `users.postsCount` (`identity.Counters.AddPostsCount`, `identity/api.go:98`)
    and `quotas`.
  - This is lower than the proto's 19/6 because reply parent, quote and media reads are out of scope; T2 records it.
- **DeletePost** reads the post (ownership), then does a blind batch: `Delete(post, Exists)` + `postsCount −1`. An
  `Exists` failure means someone else already deleted it: success with 0 writes (the exactly-once decrement).
- **GetPost** = post + author `users` (status) + caller graph (`blockedBy`), all cached.
- **GetUserTimeline** = target `users` + caller graph (both cached) + a page of `limit page_size+1`. The first page per
  (author, tab) is cached 60 s.
- **Home "new posts" (60/DAU)** is the largest single line. It comes from `cost-model.md` §1 and scales with F × author
  activity, not with our code. The `since` token guarantees each is read at most once per device.

### Daily totals at the Stage 0 target (300 DAU) vs free quota
| Quota | P0+P1 per DAU | at 300 DAU | + v0.2.0 baseline (20.4 R, 3.1 W, 0.1 D per DAU) | % of free | vs 80% line |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | 133.9 | 40.2k | **46.3k** | **93%** | **over** (the 80% line is crossed at ~260 DAU) |
| Firestore writes (20k/day) | 4.05 | 1.2k | 2.1k | 11% | under |
| Firestore deletes (20k/day) | 1.05 | 0.3k | 0.35k | 2% | under |
| Cloud Run requests (2M/month, shared) | 13.2 | ≈ 119k/month | ≈ 220k/month | 11% | under |
| Cloud Run vCPU-s (180k/month, shared) | ≈ 1.3 (13.2 × 0.1 s) | ≈ 11.9k/month | — | ≈ 7% | under |
| Firestore storage (1 GiB) | ≈ 1.5 KiB per post incl. index entries (ADR-0003) | 300 posts/day ≈ 13 MiB/month | — | ≈ 1%/month | under |

- **Cost line:** posts + timelines add **≈ 134 reads, 4 writes and 13 requests per DAU per day**. That is **$0/month at
  300 DAU** (reads at 93% of the free quota).
  - The existing "Firestore reads > 40k/day" alert will start firing at ~260 DAU. That is the planned signal to apply
    `cost-model.md` §6 levers, not an incident.
  - Past ~324 DAU on this slice alone, the overage is ≈ $0.02/month per extra 1k reads/day (upper-bound price,
    `cost-model.md` §7).
- **Levers built in by default:**
  - `since` refresh;
  - auto-refresh ≥ 60 s apart and never in the background;
  - older-page prefetch only after scrolling past 70% (lever §6.3);
  - author-recent and profile-first-page instance caches.
- **New GCP service or fixed-cost resource: none.**
  - The flag and the read-budget numbers are env vars on the existing `api` service.
  - The indexes already exist.
  - No Pub/Sub topic is needed: this slice has no async work, because a deleted root post has no dependents until
    P3/P4/P5.
  - `cost-guard`: no new Terraform resources.

### Worst-case abuse bounds per account per day (inputs to security review T24)
| Vector | Control | Worst per abusive account/day |
|---|---|---|
| Handle/profile/post/timeline read scraping (**the public-repo finding**) | T3 read budget 2,000/uid/day/instance (max 3 instances) + per-procedure buckets | **≤ 6k reads** (12% of free), down from ~86k–259k today |
| Sybil sign-up accounts calling `CheckHandleAvailability` | T3 per-IP budget for profile-less callers (500/IP/day) + 100/uid/day cap | ≤ 1.5k reads per IP |
| Post spam | `quota.Posts` 100/day (new accounts 20; `config.go:282,294`) + 10/min bucket | 100 × 4 = **400 writes** (2%) |
| Mention fan-out amplification | ≤ 10 mentions, one `GetAll`, counted against the read budget | covered by the read budget |
| Delete churn | 20/min bucket; each delete needs an own post (bounded by the post quota) | ≤ 100 deletes |

## Dependencies & open questions
- **Depends on:**
  - `pkg/platform`: idempotency, quota (`Posts` kind exists, `quota/quota.go:53-61`), snowflake, cursor, budget, cache,
    flags, ratelimit/DailyCap, apierr, degraded. All present.
  - `graph.Reader.Snapshot` (following/blocked/muted/blockedBy). Done.
  - `identity.Directory` and `identity.Counters.AddPostsCount`. Present, unused.
  - The posts indexes. Declared at `firebase/firestore.indexes.json:4-34`. **T26 confirms they are READY in dev and prod.**
- **Import rules (ADR-0002):**
  - timeline imports only the `posts.Reader` and `graph.Reader` interfaces (ADR-0004 handoff: "never query `posts`
    directly from timeline").
  - posts uses `identity.Directory`/`Counters` and `graph.Reader`.
  - identity never imports posts.
- **@architect:** Q1–Q12 in "Open design questions". T1 records the answers in ADR-0010; T2 makes the comment-only
  proto changes.

## Proto and schema changes (comment-only; `buf breaking` clean; no new fields)
| File | Change | Why |
|---|---|---|
| `proto/dzeroth/posts/v1/posts.proto` | CreatePost: document the slice-1 `FEATURE_DISABLED` behaviour for reply/quote/media, the mention rules (unknown handles stay plain text; mentions of users who blocked the author are dropped) and hashtag rules; budget "reads 14/2, writes 4/4 until replies/quotes/media ship". DeletePost: "not own ⇒ NOT_FOUND; unknown ⇒ success; reads 1/1, writes 1/1, deletes 1/1 until replies ship". GetPost: "reads 3/0–1 (no userLikes until engagement)" | Keep proto and cost model in sync (`common.proto:13-14`) |
| `proto/dzeroth/timeline/v1/timeline.proto` | GetHomeTimeline worst `1 + C + 2·page` (268) until engagement adds `userLikes`; GetUserTimeline 53/11 and the blocked/muted semantics from Q6 | same |
| `proto/dzeroth/identity/v1/identity.proto` | CheckHandleAvailability/GetProfile: mention the daily read budget and `limit_name=read_budget_daily` | P0 contract visibility |
| `firebase/firestore.indexes.json` | Verify only. Architect decides whether to add a `mentionIds` exemption (ADR-0003:80 lists the field; there is no query on it in Phase 1) | Index write cost |
| Firestore `posts/{postId}` | New collection, shape exactly as ADR-0003:80; `visibility = PUBLIC`, `kind = POST`, `isReply = false`, `conversationId = postId` | — |

---

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Contract and gating hardening | T1, T2, T3, T4 | ADR-0010 Accepted; `make proto` green; read budget merged with the guard test in CI |
| M2 | Posts backend ‖ Flutter foundations | T5–T10 ‖ T14, T15 | CreatePost/DeletePost/GetPost behind the flag; PostCard + repositories against fakes |
| M3 | Timelines backend ‖ Flutter screens | T11–T13 ‖ T16–T18 | Both timelines implemented; composer, home and profile tabs built |
| M4 | Verification | T19–T25 | Test report PASS with budget assertions; code review APPROVE; security 0 Critical/High; cost report holds |
| M5 | Ops and staged rollout | T26, T27 | Dev deployed flag-on; prod `candidate` GO; prod `allowlist`. The public % rollout goes with v0.3.0 |

**Order:** T1 → T2 → (T3 ‖ T4 ‖ T6 ‖ T7) → T5 → (T8, T9, T10) → T11 → (T12, T13).
- Frontend T14 starts right after T2. T15 → T16 → T17/T18 run in parallel with all backend work, against fakes.
- T19 follows T8–T10, T20 follows T12–T13, and T21–T25 follow M3. T26 and T27 come last.
- **T3 is a hard prerequisite of T27's `percent` step.**

---

## Tickets

### T1 — ADR-0010: posts and timeline slice decisions  [owner: architect] [size: M] [depends: —]
- **Description.**
  - Write `docs/adr/0010-posts-and-timelines-slice.md`. It answers Q1–Q12 ("Open design questions") and cites
    ADR-0003 (data model), ADR-0004 (the timeline algorithm is **not** reopened; this ADR only fixes slice-level
    choices) and ADR-0008 (the block/mute semantics table, extended to posts).
  - It must include:
    - the text normalisation spec;
    - the mention/hashtag grammars, with examples;
    - the cursor bindings (`home:{uid}`, `user:{target}:{tab}`) for `pkg/platform/cursor`;
    - cache sizes within the ADR-0004 §6 memory budget;
    - the read-budget numbers for T3, with the math;
    - a posts row in the **block/mute visibility table** for GetPost, GetUserTimeline and GetHomeTimeline, for the
      cases "caller blocked author", "author blocked caller", "caller muted author" and "author suspended/deleting".
  - Update the `firestore-data-model` skill op-cost rows for Create post and the two timelines.
- **Acceptance criteria.**
  - Given ADR-0010, when read, then it has Options with $ at idle, 300 DAU and 3k DAU; Cost impact = $0 fixed; a
    Decision paragraph; and a Handoff for backend, frontend, deployer and tester.
  - Given each Qn, then the ADR states the chosen option or explicitly accepts the default.
  - Given the visibility table, then every (RPC × relationship) cell has one defined outcome, which the tester uses as
    the oracle in T19/T20.
  - Given the read-budget section, then it shows typical per-DAU usage (≈ 191 reads, `cost-model.md` §2) against the
    chosen cap, and the worst-case abusive total across max instances.
- **Test notes.** Not applicable (doc). T19/T20 use its tables as oracles.
- **Observability.** The ADR lists the required log fields (T5, T8, T13).
- **Budget.** Doc only. It confirms this plan's table.

### T2 — Proto comments, index check, regenerate  [owner: architect] [size: S] [depends: T1]
- **Description.** Apply "Proto and schema changes" exactly. Run `make proto` and commit the generated Go
  (`backend/gen`) and Dart (`app/lib/gen`). Confirm that no composite index is missing for the ADR-0004 queries:
  - `authorId in […] && isReply == false order by createdAt desc`;
  - `authorId == X order by createdAt desc` (± `isReply`).

  Include the `__name__` tie-breaker direction used by the `(createdAt, postId)` cursor.
- **Acceptance criteria.**
  - Given the PR, when CI runs `buf lint` and `buf breaking --against main`, then both pass and no field number changed.
  - Given every changed RPC comment, then its numbers equal this plan's budget table.
  - Given `firestore.indexes.json`, then each query shape in ADR-0010 maps to a named index, listed in the PR body.
- **Test notes.** —
- **Observability.** —
- **Budget.** Not applicable.

### T3 — P0 gating: daily Firestore read budget, negative handle cache, uncapped-read guard  [owner: backend-developer] [size: M] [depends: T1 (numbers); can start on defaults]
- **Description.** Closes the public-repo finding. The evidence:
  - `CheckHandleAvailability`:
    - 20/min/uid is its only cap (`config.go:242`, `apiserver.go:142,176`);
    - free handles are never cached (`identity/service.go:111-123`);
    - it is profile-exempt and does not need a verified email (`apiserver.go:133-138`).
  - `GetProfile`:
    - 60/min default (`config.go:235`);
    - missing handles are not negatively cached (`service.go:166-179`).
  - Neither has a `DailyCaps` entry (`apiserver.go:188-200`).

  Work:
  1. **Extend** `pkg/platform/ratelimit` with a `ReadBudget`: the same IST-day semantics and LRU as `DailyCap`
     (`daily_cap.go:21-69`), but it counts units instead of calls, through `Reserve(key) bool` and `Charge(key, n)`.
     Don't write a second limiter type; generalise `DailyCap` so both share the counter.
  2. Enforce it in `ratelimit.Interceptor`:
     - before `next`, reject if the uid's spent reads for today ≥ `READ_BUDGET_PER_UID_PER_DAY` (default 2,000);
     - after `next`, charge `budget.FromContext(ctx).Reads()` (the counter is attached by `mw.Logging`, `mw.go:115`).
     - Overshoot is bounded by one call's worst case (≤ 268).
     - Callers with no profile (profile-exempt procedures) are also charged to an IP key,
       `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY` (default 500).
     - A rejection is `RATE_LIMITED` with `retry_after` = time until IST midnight and `limit_name=read_budget_daily`.
  3. Add `DailyCaps` for `CheckHandleAvailability` (100/uid/day, `limit_name=check_handle_daily`).
  4. Add an identity negative handle cache (10 s, reusing `notFoundTTL`, `identity/cache.go:20`) for `ResolveHandle`
     NotFound, used by both RPCs. CreateProfile and ChangeHandle stay transactional, so a stale "available" answer
     can't create a duplicate.
  5. Add a **guard test** in `backend/internal/apiserver`. It builds the mux, enumerates every registered procedure
     whose `IdempotencyLevel == NoSideEffects` (the same mechanical signal `degraded.Interceptor` uses,
     `degraded.go:34-44`), and fails if the read budget is disabled or the procedure is on an unexplained exemption
     list. Future read RPCs are then covered automatically.
  6. All numbers go in `config.Config` (rule 11). Add a line in `docs/code-map.md`.
- **Acceptance criteria.**
  - Given uid A spent 2,000 reads today on one instance, when A calls any RPC, then `RATE_LIMITED` is returned with
    `limit_name=read_budget_daily` and 0 Firestore reads.
  - Given IST midnight passes (fake clock), then A's next call succeeds.
  - Given a caller with no profile, when it makes 101 CheckHandleAvailability calls in one IST day, then the 101st
    gets `RATE_LIMITED` (`check_handle_daily`).
  - Given many uids from one IP without profiles spending 500 reads in total, then further profile-exempt calls from
    that IP are rejected. A caller **with** a profile on the same IP is unaffected.
  - Given GetProfile(handle = "nosuchuser") twice within 10 s, then Firestore is read once.
  - Given a new `NO_SIDE_EFFECTS` RPC registered without coverage, when `make ci` runs, then the guard test fails
    and names the procedure.
  - Given typical usage (the k6 identity + graph scripts), then no legitimate call is rejected.
- **Test notes.** Unit tests with a fake clock. An emulator test proves the budget is charged from real
  `budget.Counter` values (a GetProfile cold call charges 1–3). A regression test: every graph and identity RPC still
  passes its existing budget assertions.
- **Observability.** `limit_name` on rejections. A new per-request field `read_budget_spent`. A log-based query in
  `docs/runbooks/abuse-spike.md` to find uids hitting the cap (no new alert policy).
- **Budget.** 0 Firestore reads/writes (in memory). Memory: ≤ 100k keys × ~64 B ≈ 6 MiB.

### T4 — Posts/timeline flag, rate limits, daily call caps  [owner: backend-developer] [size: S] [depends: T2]
- **Description.**
  - Add `FEATURE_POSTS` (`off|allowlist|percent|on`, default `off`) via `flags.LoadSpec`, following the `FeatureGraph`
    pattern (`config.go:166-168`, `apiserver.go:85`). `GetMe.enabled_features` returns `"posts"` (0 reads).
  - Wire `PerProcedure` buckets:
    - GetHomeTimeline: the existing `RATE_LIMIT_TIMELINE_PER_MIN` = 6 (`config.go:238`, unwired today);
    - GetUserTimeline: 30/min;
    - CreatePost: 10/min;
    - DeletePost: 20/min;
    - GetPost: the default 60/min.
  - The `posts` quota uses the existing `QUOTA_POSTS_PER_DAY`/`QUOTA_NEW_ACCOUNT_POSTS_PER_DAY` (`config.go:282,294`).
  - Register nomedia procedures: none in this slice.
- **Acceptance criteria.**
  - Given `FEATURE_POSTS=off`, when any Post/Timeline RPC is called, then FAILED_PRECONDITION + `FEATURE_DISABLED` is
    returned with 0 reads.
  - Given 7 GetHomeTimeline calls in one minute, then the 7th is `RATE_LIMITED` with `retry_after`.
  - Given an invalid `FEATURE_POSTS` value, then startup fails fast.
- **Test notes.** Unit table tests; extend the `config_test.go` defaults.
- **Observability.** Startup `feature_flags` includes `posts`. `feature_disabled=true` on rejected calls.
- **Budget.** 0.

### T5 — Posts module core: doc, repo, caches, `posts.Reader`, server registration  [owner: backend-developer] [size: M] [depends: T4]
- **Description.**
  - Create `backend/internal/posts` with `api.go`, `service.go`, `repo_firestore.go`, `cache.go` and `server.go`,
    using identity/graph's layout.
  - The doc struct follows ADR-0003:80. All counters start at 0.
  - `posts.Reader`:
    - `Get(ctx, id)`;
    - `GetMany(ctx, ids)` (cache-first `GetAll`, ≤ 50);
    - `ByAuthors(ctx, authorIDs []string /*≤30*/, window Window, limit int)`, where Window is `{After, Before
      (createdAt, postId)}` and `isReply=false` is fixed;
    - `ByAuthor(ctx, authorID, includeReplies bool, window, limit)`.

    Every query has a `Limit`. Every read calls `budget.FromContext(ctx).AddReads(n)`, with an empty result counted
    as 1.
  - Caches wrap `pkg/platform/cache.LRU`: post docs (20k, 60 s) and author-recent (the last 20 posts per author, 5k
    authors, 60 s), updated in place on this instance's own writes.
  - `PostEvents` does nothing for now. Declare the `Eraser`/`Exporter` interfaces (implemented in T10).
  - Register PostService and TimelineService in `apiserver.Build`. Every RPC returns Unimplemented behind the T4 flag
    guard.
  - Update `docs/code-map.md`.
- **Acceptance criteria.**
  - Given `ByAuthors` over 3 authors with 0 matching posts, then reads = 1.
  - Given `GetMany` of 20 ids with 12 cached, then reads = 8 in one `GetAll`.
  - Given `internal/timeline`, when the import lint runs, then it imports only `posts` and `graph` interfaces.
  - Given `DEGRADED_MODE=readonly`, then CreatePost and DeletePost are rejected, and GetPost and the timelines are not.
    This comes mechanically from `idempotency_level`.
- **Test notes.** Unit tests with a fake repo. An emulator test for query shapes against the real indexes.
- **Observability.** `posts_op`, `fs_reads`/`fs_writes`/`fs_deletes`, `posts_cache_hit`.
- **Budget.** As the Reader methods: 1 read per returned doc, and 1 per empty query.

### T6 — Post text parser (pure)  [owner: backend-developer] [size: S] [depends: T1]
- **Description.** `backend/internal/posts/text` (no I/O). Search `internal/identity/validate.go` for NFC and handle
  regex helpers first, and reuse the handle grammar (`handleRe`) instead of redefining it. It does:
  - NFC normalisation, trimming, and rejecting empty or control characters (except `\n`); length ≤ 280 code points;
  - extracting mentions (`@handle`, identity's grammar, deduplicated, first 10);
  - extracting hashtags (`#[\p{L}\p{N}_]{1,50}`, lower-cased, deduplicated, first 10);
  - links: no server processing. They count toward length as typed.
- **Acceptance criteria.**
  - Given 280 emoji or combining sequences, then the length check uses code points after NFC, as the ADR-0010 spec says.
  - Given "@Alice @alice", then there is one mention. Given "email@example.com", then there is no mention.
  - Given "#Go #go #GO", then the hashtags are ["go"]. Given "#123", then the ADR-0010 grammar decides, and the test
    pins the outcome.
  - Given 11 hashtags, then only the first 10 are stored and the text is unchanged.
- **Test notes.** Table tests plus fuzz tests (`go test -fuzz`) for panics on arbitrary UTF-8.
- **Observability.** —
- **Budget.** 0.

### T7 — Identity: `Directory.ResolveHandles`; shared verified-email check  [owner: backend-developer] [size: S] [depends: T3 (negative cache)]
- **Description.**
  1. `identity.Directory.ResolveHandles(ctx, lowers []string) (map[string]string, error)`: cache-first (the handle
     cache plus the T3 negative cache), then one `GetAll` on `handles/*` for misses (≤ 10). Missing handles are
     absent from the map.
  2. **Generalise and move** `requireVerifiedEmailForPassword` (`identity/server.go:30-45`) to `pkg/platform/authn`
     as `RequireVerifiedEmail(ctx, action string)`, keeping identity's message. Update identity's caller.
     CLAUDE.md/ADR-0006 require verified email before posting.
- **Acceptance criteria.**
  - Given 10 handles with 6 cached, then reads = 4 in one `GetAll`.
  - Given a password account with `email_verified=false`, when CreatePost is called, then FAILED_PRECONDITION +
    `EMAIL_NOT_VERIFIED` is returned. CreateProfile behaviour is unchanged (existing tests pass).
- **Test notes.** Unit tests plus the existing identity suite.
- **Observability.** —
- **Budget.** ResolveHandles ≤ 10 / ~0–4.

### T8 — CreatePost (root posts)  [owner: backend-developer] [size: M] [depends: T5, T6, T7]
- **Description.**
  1. Validate: `idempotency.KeyFormatValid`; text (T6); reply/quote/media non-empty → `FEATURE_DISABLED` (Q2);
     verified email (T7).
  2. Load, cache-first: the author profile (ACTIVE, snapshot fields) and the author graph (`blockedBy`, to drop
     mentions per ADR-0010). Resolve mentions (T7).
  3. Transaction:
     - `idempotency.Store.Get` → replay path (the stored post id → read the post → return it; a different request hash →
       `IDEMPOTENCY_KEY_REUSED`);
     - `quotas` read + `quota.CheckAndReserve(Posts, limit)` (new-account limit if the profile is younger than 24 h);
     - `snowflake.Generate` id;
     - `Create(posts/{id})`, `identity.Counters.AddPostsCount(+1)`, `idempotency.Store.Put`.
  4. After commit:
     - update the posts cache and the author-recent cache;
     - `Directory.Forget(author)` (or update it in place, as in graph T30);
     - `PostEvents.Created` (a no-op).
  5. Return `PostView` (viewer flags false).
- **Acceptance criteria.**
  - Given valid text, then `posts/{id}` has the ADR-0003 shape, `users.postsCount` +1, `quotas.posts` +1, and exactly
    one `idempotency` doc with `expireAt` 24 h out.
  - Given the same key replayed (sequentially or concurrently ×10), then exactly one post exists and each response has
    the same `post_id`.
  - Given the same key with different text, then `IDEMPOTENCY_KEY_REUSED` is returned with 0 writes.
  - Given `quotas.posts = 100` (or 20 for an account < 24 h old), then `QUOTA_EXCEEDED` is returned with
    `metadata.quota=posts` and 0 entity writes.
  - Given "@ghost" (no such handle), then the post is created and `mentions` is empty. Given "@bob" where bob blocked
    the author, then `mentions` excludes bob.
  - Given the `media_ids`, `reply_to_post_id` or `quote_of_post_id` field set, then `FEATURE_DISABLED`.
- **Test notes.** `budgettest.Assert`: ≤ 14R/4W worst, 2R/4W typical, replay ≤ 2R/0W.
- **Observability.** `posts_op=create`, `outcome=created|replay|rejected:<reason>`, `mentions_resolved`, `txn_attempts`.
  WARN if `txn_attempts > 3`.
- **Budget.** 14 / 2 R, 4 / 4 W, +1 eventual TTL delete.

### T9 — DeletePost + GetPost  [owner: backend-developer] [size: S] [depends: T5]
- **Description.**
  - **DeletePost:**
    - read the post (1);
    - not the caller's → NOT_FOUND (Q4);
    - missing → success;
    - else a batch: `Delete(post, Exists)` + `AddPostsCount(−1)`. On `NotFound` at commit, return success with 0 writes.
    - Evict it from this instance's posts, author-recent and profile-first-page caches.
    - `PostEvents.Deleted` (a no-op).
  - **GetPost:**
    - the post (cached);
    - the author profile (status). SUSPENDED or DELETING → NOT_FOUND, the byte-identical error.
    - `author ∈ caller.blockedBy` → NOT_FOUND;
    - the caller blocked or muted the author → return the post (the client decides; ADR-0010 table).
- **Acceptance criteria.**
  - Given own post, then the doc is gone, `postsCount` −1, and a second DeletePost does 0 writes and returns success.
  - Given 5 concurrent deletes of the same post, then `postsCount` decrements exactly once.
  - Given someone else's post, then NOT_FOUND is returned with 0 writes, and the error is byte-identical to a missing id.
  - Given the author blocked the caller, then GetPost is NOT_FOUND, byte-identical to a deleted post.
  - Given a deleted post, then GetPost is NOT_FOUND within 60 s on every instance.
- **Test notes.** Budgets: Delete ≤ 1R/1W/1D; GetPost ≤ 3R. Race test on the emulator.
- **Observability.** `posts_op=delete|get`, `outcome`.
- **Budget.** As the table.

### T10 — `posts.Eraser` + exporter + `opsctl` + account-deletion runbook  [owner: backend-developer] [size: S] [depends: T8, T9]
- **Description.**
  - `Eraser.PurgeUser(ctx, uid, checkpoint)`:
    - `posts where authorId == uid order by createdAt limit 500` pages;
    - batched deletes (≤ 500);
    - resumable; no counter updates (the user doc is deleted anyway).
  - `Exporter.ExportUser(ctx, uid, w)` writes JSON: id, text, createdAt, hashtags, mentions (handles only).
  - Add `opsctl purge-posts|export-posts`, the same flags and guards as `purge-graph` (`cmd/opsctl/main.go:75-95`).
  - Update `docs/runbooks/account-deletion.md`: purge-posts **before** purge-graph, and export-posts in the export
    steps. Rule 10: every collection has a right-to-delete path.
- **Acceptance criteria.**
  - Given U with 1,203 posts, when purge runs and is killed after the first batch, then a re-run with the checkpoint
    completes and no `posts` doc has `authorId == U`.
  - Given `--dry-run`, then only counts are printed and there are 0 writes.
  - Given `opsctl` without `--project`, then it exits non-zero.
- **Test notes.** An emulator crash-resume test (reuse graph's T11 harness; no second harness).
- **Observability.** `posts_purge_batch` with counts.
- **Budget.** O(posts) reads and deletes, once per deletion: a 300-post user costs ≈ 300 R and 300 D.

### T11 — Timeline core (pure): chunking, exact-prefix merge, tokens, gap  [owner: backend-developer] [size: M] [depends: T5]
- **Description.** Create `backend/internal/timeline` with a pure `merge.go` + `tokens.go`, implementing ADR-0004
  Decision 1–3 exactly:
  - chunks of 30 (followees + self);
  - `k = max(1, ceil(2·page/C))`;
  - the exact-prefix cut at `B`;
  - the `gap_page_token` when any chunk filled `k` on a refresh.

  Tokens use `pkg/platform/cursor` (HMAC key `cfg.CursorHMACKey`) with bindings `home:{uid}` / `user:{target}:{tab}`,
  so a token from one context is rejected in another. Sending both `page_token` and `since_token` is
  INVALID_ARGUMENT (the `timeline.proto` header).
- **Acceptance criteria.**
  - Given adversarial chunk distributions (one chunk with 1,000 recent posts and others sparse; ties on `createdAt`),
    then the merged output is a strict `(createdAt, postId)`-descending prefix of the true merge, with no duplicates
    or gaps across successive pages (property test).
  - Given a refresh where a chunk hit `k`, then `gap_page_token` is set and bounded below by the old `since`.
    Following it never returns an item ≤ the old `since`.
  - Given a tampered token or a token with the wrong binding, then VALIDATION.
- **Test notes.** Property-based tests (`testing/quick` or rapid) over random chunk sets. This is the ADR-0004
  handoff requirement.
- **Observability.** —
- **Budget.** 0 (pure).

### T12 — GetUserTimeline  [owner: backend-developer] [size: S] [depends: T11]
- **Description.**
  - Target profile via `identity.Directory`: missing, not ACTIVE, or `target ∈ caller.blockedBy` → NOT_FOUND, the
    same error as GetProfile.
  - `posts.Reader.ByAuthor(target, include_replies, window, page_size+1)`.
  - Clamp with `limits.ClampPageSize`.
  - Cache the first page per (author, tab) for 60 s; evict it on this instance's own create/delete.
  - Muted authors are shown and blocked-by-caller authors are returned (Q6); the client shows a banner.
- **Acceptance criteria.**
  - Given 45 posts, then pages of 20 cover all 45 exactly once, stable under concurrent new posts.
  - Given `since_token` with 0 new posts, then reads ≤ 1 (0 with a warm first-page cache).
  - Given the author blocked the caller, then NOT_FOUND, byte-identical to a missing user.
  - Given a cold page of 20, then reads ≤ 23. At page 50, reads ≤ 53.
- **Test notes.** Budget assertions; the block matrix from ADR-0010.
- **Observability.** `timeline_op=user`, `fs_reads`, `timeline_cache_hit`.
- **Budget.** 53 / 11.

### T13 — GetHomeTimeline  [owner: backend-developer] [size: M] [depends: T11, T12]
- **Description.** ADR-0004 Decision 1–9, minus the viewer flags (Q3):
  - `graph.Reader.Snapshot(caller)`;
  - chunk followees + self;
  - an author-recent cache short-circuit (an author whose cached newest post is older than `since` and whose entry
    is < 60 s old costs 0 reads);
  - `errgroup` with ≤ 4 in flight;
  - merge (T11);
  - drop `blocked`, `muted` and `blockedBy` authors;
  - return tokens.

  The per-RPC deadline is 10 s. The following cap of 5,000 already exists (graph).
- **Acceptance criteria.** From the ADR-0004 tester handoff:
  - Given a refresh with 0 new posts and a cached graph, then reads == C.
  - Given F = 60, page 20, then reads ≤ C + 40 + 1.
  - Given A muted B, then B's posts never appear in A's home. Given B blocked A, then B's posts never appear in A's
    home, even if A's following still lists B (a stale cache).
  - Given F = 5,000 (a seeded graph doc), then worst reads ≤ 268 and latency is < 2 s on the emulator (noted as local).
  - Given the caller just posted on this instance, then the post appears on the next refresh with 0 extra reads
    (author-recent updated in place).
- **Test notes.** Budget assertions at F = 0, 60, 300 and 5,000; the chunk-boundary case F = 29/30/31.
- **Observability.** `timeline_op=home`, `timeline_chunks`, `authors_from_cache`, `fs_reads`, `gap=true|false`.
- **Budget.** 268 / refresh ~8 (C = 3 + ~5 new), older 23, cold 23.

### T14 — Flutter: repositories, drift timeline store, flag plumbing  [owner: frontend-developer] [size: M] [depends: T2]
- **Description.**
  - Check `docs/ui-catalog.md` first. Reuse `ApiClient`, `guardApiCall`, `mapConnectError`, `AppDatabase` and
    `isGraphEnabled` (generalise it to `isFeatureEnabled(name)` rather than copying it).
  - Add `features/posts/data/posts_repository.dart` and `features/timeline/data/timeline_repository.dart`, using the
    generated clients (`app/lib/gen/dzeroth/{posts,timeline}`).
  - Add drift tables in the existing `AppDatabase`:
    - `timeline_items` (feed key, post id, serialized `PostView`, sort key);
    - `timeline_state` (feed key, `since_token`, gap tokens).

    Retention: the newest 500 items per feed.
  - Add `kFeaturePosts`.
  - Update `ui-catalog.md`.
- **Acceptance criteria.**
  - Given a cached feed, when the app cold-starts offline, then cached items render with no network call.
  - Given a refresh response with `gap_page_token`, then a gap marker row is persisted at the right position.
  - Given a post NOT_FOUND on open, then it is removed from every cached feed.
  - Given the flag is off, then no posts or timeline RPC is ever called.
- **Test notes.** Repository tests with fake clients and an in-memory drift database; a migration test from the
  current schema version.
- **Observability.** Crashlytics non-fatal on unexpected `AppException`.
- **Budget.** The client never refetches items it has. Each refresh sends `since_token`.

### T15 — Flutter: shared `PostCard` with rich text  [owner: frontend-developer] [size: M] [depends: T14]
- **Description.** `app/lib/shared/widgets/post_card.dart`:
  - author avatar/name/@handle from the snapshot (tap → profile by **user_id**);
  - relative time;
  - text with tappable mentions (→ profile by `mentions[].user_id`) and hashtags (a no-op/"coming soon" until
    Phase 2);
  - links opened with `url_launcher` in the external browser, `http(s)` only. Never render HTML.
  - An overflow menu: Delete (own posts, with a confirmation) and "Block @x" / "Mute @x", reusing `RelationshipCubit`
    and `showBlockConfirmationDialog`.
  - A counts row hidden until P5.
  - Theme tokens only.
- **Acceptance criteria.**
  - Given text "hi @bob see https://x.y #go", then exactly 3 spans are tappable and the link opens externally.
  - Given `javascript:alert(1)` in the text, then it is plain text (not a link).
  - Given own post, then the overflow shows Delete. For another author's post it shows Block/Mute.
  - Given phone and desktop widths, then there is no overflow.
- **Test notes.** Widget tests for each state; a golden test is optional.
- **Observability.** —
- **Budget.** 0 RPCs (display only).

### T16 — Flutter: composer  [owner: frontend-developer] [size: M] [depends: T15]
- **Description.**
  - A compose sheet/route with a 280 code-point counter using the same NFC rule as T6 (share the rule through a
    documented constant, not a copy of the server regex).
  - Disable Post when the text is empty or over the limit.
  - One UUID idempotency key per intent, reused on retry.
  - Optimistic insert at the top of Home and the own profile. Roll back on error.
  - Friendly errors: `EMAIL_NOT_VERIFIED` (reuse `VerifyEmailView`), `QUOTA_EXCEEDED`, `RATE_LIMITED`,
    `DEGRADED_MODE` (never auto-retried), and `FEATURE_DISABLED`.
- **Acceptance criteria.**
  - Given a network error and a retry, then the same idempotency key is sent, and only one post appears after
    success.
  - Given `QUOTA_EXCEEDED`, then the optimistic item is removed and a snackbar shows the quota message.
  - Given 281 code points, then Post is disabled and the counter shows −1.
- **Test notes.** Bloc tests (optimistic path, rollback, key reuse); widget tests.
- **Observability.** —
- **Budget.** 1 CreatePost per intent.

### T17 — Flutter: Home timeline screen  [owner: frontend-developer] [size: M] [depends: T15]
- **Description.** Replace the `HomeScreen` placeholder (`home_screen.dart:5-37`) with the ADR-0004 §7 behaviour:
  - render the cache instantly;
  - refresh with `since_token` on pull and on app resume;
  - auto-refresh ≤ every 60 s while foregrounded, never in the background;
  - a "N new posts" pill instead of auto-inserting;
  - infinite scroll with `page_token`, prefetching only after 70%;
  - gap rows that load with `gap_page_token`;
  - an empty state that suggests following people.
- **Acceptance criteria.**
  - Given an app resume 20 s after the last refresh, then no RPC is sent. After 61 s, one refresh with `since_token`
    is sent.
  - Given a gap row tap, then exactly one call with `gap_page_token` is sent and the row is replaced by the items.
  - Given `RATE_LIMITED` (including `read_budget_daily`), then the cache stays visible with a non-blocking banner and
    no retry storm.
  - Given the flag is off, then the placeholder remains.
- **Test notes.** Widget tests with a fake clock and repository: refresh throttle, gap, pagination, empty, error.
- **Observability.** —
- **Budget.** ≤ 8 refreshes + ≤ 1 older page per DAU/day on the model's usage (the client enforces the throttle).

### T18 — Flutter: profile Posts tab, post detail, delete  [owner: frontend-developer] [size: M] [depends: T15]
- **Description.**
  - Below `ProfileHeader` (ADR-0008 D13: the posts plan owns the body), add a Posts tab using GetUserTimeline with the
    same cache/refresh pattern (feed key `user:{uid}:posts`).
  - Hide the Replies tab until P3.
  - A blocked-by-caller banner, "You blocked @x · Show posts".
  - A `/post/:id` route using GetPost. NOT_FOUND shows "This post isn't available" and prunes the caches (T14).
  - Delete from the overflow: optimistic removal from every feed, restored on error.
- **Acceptance criteria.**
  - Given 45 posts, then 3 pages load with no duplicates.
  - Given Delete confirmed, then the post disappears from Home and the profile immediately, and `postsCount` in the
    header decrements.
  - Given `/post/<deleted>`, then the unavailable view renders with no retry loop.
- **Test notes.** Widget tests: own profile, other, blocked, empty, not-found.
- **Observability.** —
- **Budget.** 1 request per page; first page cached on the device.

### T19 — Emulator integration tests: posts  [owner: tester] [size: M] [depends: T8, T9, T10]
- **Description.**
  - Contract tests for CreatePost, DeletePost and GetPost: the happy path plus every documented ErrorReason.
  - `budgettest.Assert` on every call.
  - Replay with the same key (sequential and concurrent) and with a reused key and a different body.
  - Quota exhaustion + IST rollover; new-account quota.
  - Concurrent deletes.
  - A reusable **posts invariant checker**: `users.postsCount` == the count of `posts` with that `authorId` (test-only
    `count()` aggregation).
  - The ADR-0010 visibility matrix for GetPost.
  - Purge crash-resume.
  - Degraded readonly.
- **Acceptance criteria.**
  - Given `make test-int`, then all posts tests pass and `internal/posts` coverage is ≥ 70%.
  - Given any RPC exceeding its budget, then the test fails with the RPC name and actual vs budget.
- **Test notes.** Reuse the graph fixtures (seeding users and graph docs). Add the invariant checker to the
  `code-map.md` test-helpers section.
- **Observability.** —
- **Budget.** Not applicable (emulator).

### T20 — Emulator integration tests: timelines and read budget  [owner: tester] [size: M] [depends: T3, T12, T13]
- **Description.**
  - The ADR-0004 tester handoff: read counts for a refresh with 0 new posts, page 20 at F = 60, and "the gap token
    never re-reads items older than the previous since".
  - Seeded F = 5,000.
  - The block/mute matrix for both timelines.
  - Token tamper and cross-binding.
  - T3: the read budget rejects at the cap, the IP budget for profile-less callers, the negative handle cache, and the
    guard test fails when a fake uncapped read procedure is registered.
- **Acceptance criteria.**
  - Given the matrix, then every cell matches ADR-0010.
  - Given the budgets, then all measured reads ≤ the table.
  - Given the P0 finding scenario (a scripted loop of CheckHandleAvailability and GetProfile on random handles), then
    reads stop at the configured budget.
- **Test notes.** Reuse the T19 fixtures.
- **Observability.** —
- **Budget.** Not applicable.

### T21 — E2E smoke, Flutter test sweep, test report  [owner: tester] [size: S] [depends: T16, T17, T18, T19, T20]
- **Description.**
  - Add `backend/e2e/posts_smoke_test.go`, runnable on emulators and the prod `candidate` URL with test accounts:
    1. A follows B;
    2. B posts;
    3. A's home refresh contains it;
    4. B's profile timeline contains it;
    5. B deletes it;
    6. A's GetPost is NOT_FOUND;
    7. clean-up.
  - Run `flutter test` and check that every new screen has widget tests.
  - Write `docs/reviews/test-report-posts-timeline.md` with the measured budget table, coverage and matrix results.
- **Acceptance criteria.** Given `make ci` and `make test-int`, then both are green and the report verdict is PASS.
- **Test notes.** The smoke test cleans up after itself, so it can re-run on `candidate`.
- **Observability.** —
- **Budget.** A smoke run ≈ 20 reads and 10 writes.

### T22 — k6 emulator load smoke: timeline read + post create  [owner: sre-performance] [size: S] [depends: T8, T13]
- **Description.** Add `loadtest/timeline_read.js` (50 virtual users, F distributed 10–300, refresh + older page) and
  `loadtest/post_create.js`, following `identity_getme.js` and the graph scripts. Record p95 and `fs_reads`/call from
  the logs.
- **Acceptance criteria.**
  - Given 20 rps for 2 minutes, then refresh p95 is < 400 ms and CreatePost p95 < 500 ms (emulator, machine noted).
  - Given the logs, then the mean `fs_reads` per call is ≤ the typical budget, and there are 0 ERROR lines.
- **Test notes.** Results go in T25.
- **Observability.** Existing fields.
- **Budget.** Emulator only.

### T23 — Code review  [owner: code-reviewer] [size: S] [depends: T3–T18 (per PR)]
- **Description.** Review each PR against CLAUDE.md rules 1–11, ADR-0004/0010 and reuse-first:
  - no second limiter, cache, cursor or verified-email check;
  - timeline never queries `posts` directly;
  - every query has a `Limit`, and no read happens in a loop;
  - every read is counted in `budget.Counter` (the read budget depends on it);
  - budget comments match the code;
  - the reuse report is present and the catalogs are updated.
- **Acceptance criteria.** APPROVE on every PR, with no open Blockers.
- **Test notes.** —
- **Observability.** —
- **Budget.** —

### T24 — Security review: posts/timeline threat model + P0 closure  [owner: security-auditor] [size: M] [depends: T3, T8–T13]
- **Description.** Threat-model:
  - read amplification: close the public-repo finding against T3 and re-check M6's residual risk with the new read
    paths;
  - existence leaks: GetPost/DeletePost/GetUserTimeline byte-identical NOT_FOUNDs;
  - block bypass: stale caches, the author-recent cache;
  - mention abuse;
  - text rendering: no HTML, link schemes;
  - cursor forgery and cross-binding;
  - quota races;
  - idempotency-key reuse;
  - log PII (no post text in logs).

  Write `docs/reviews/security-review-posts-timeline.md`.
- **Acceptance criteria.** 0 Critical/High open. The public-repo finding is marked Closed with evidence (T20 test
  names, config values).
- **Test notes.** Findings go back to the owning ticket.
- **Observability.** Confirm no request body or text is logged.
- **Budget.** —

### T25 — Cost report and cost-model update  [owner: sre-performance] [size: S] [depends: T19, T20, T22]
- **Description.** Re-base the `cost-model.md` §2 rows for CreatePost, DeletePost, GetPost and the timelines on
  measured values:
  - drop `userLikes` from the timeline rows until P5;
  - add the read budget to §4 as an abuse bound;
  - recompute §3 (the crossover DAU) for the released scope (identity + graph + posts/timelines).

  Write `docs/reviews/cost-report-posts-timeline.md`. Add a Logs Explorer query grouping `fs_reads` by `rpc` for
  Post/Timeline.
- **Acceptance criteria.** Given the report, then released-scope reads at 300 DAU are ≤ 100% of the free quota, or
  the report names the lever applied and D1 in `phase1.md` records the founder's call.
- **Test notes.** —
- **Observability.** The query is documented in `cost-model.md` §9.
- **Budget.** —

### T26 — Infra/config, indexes READY, runbooks, dev deploy  [owner: production-deployer] [size: S] [depends: T3, T4, T5]
- **Description.**
  - Add env vars to Terraform `cloud-run-api` for dev/prod: `FEATURE_POSTS` (dev `on`, prod `off`) and its allowlist,
    `READ_BUDGET_PER_UID_PER_DAY`, `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY`, `CHECK_HANDLE_CALLS_PER_DAY`, and the new
    rate limits. Plan-then-OK before apply (founder preference).
  - Deploy `firestore.indexes.json` and confirm every posts index is **READY** in dev and prod before any traffic
    (L5 fix order).
  - Runbooks:
    - `docs/runbooks/posts.md`: failure modes (index missing → FAILED_PRECONDITION, a hot author, read-budget
      rejections of legitimate users → raise via env);
    - update `cost-spike.md` and `abuse-spike.md` with the read-budget levers.
- **Acceptance criteria.**
  - Given dev, then the T21 smoke passes with the flag on.
  - Given prod, then indexes are READY and the flag is `off`.
  - Given `cost-guard`, then there are no new resources.
- **Test notes.** —
- **Observability.** —
- **Budget.** $0.

### T27 — Prod candidate and allowlist rollout  [owner: production-deployer] [size: S] [depends: T21, T23, T24, T25, T26]
- **Description.**
  1. Deploy the tagged `candidate` revision with no traffic and run the T21 smoke.
  2. Get the production-reviewer GO.
  3. Shift traffic 10% → 100% with `FEATURE_POSTS=off`.
  4. Set `allowlist` (founder + internal testers) and watch for 48 h: `fs_reads` by `rpc`, 5xx, p95.

  The **`percent` → `on` steps belong to the v0.3.0 release** (with P3 + P7) and require T3 to be live in prod.
- **Acceptance criteria.**
  - Given the allowlist for 48 h, then 5xx < 1%, home refresh p95 < 400 ms warm, and measured reads per call ≤ budget.
  - Given any rollback trigger, then the flag goes back to `off` within 5 minutes (a config change, no redeploy of code).
- **Test notes.** —
- **Observability.** Readiness evidence per `production-readiness`.
- **Budget.** Allowlist traffic is negligible.

---

## Rollout plan
- **Flags:**
  - `FEATURE_POSTS`: `off` in prod at deploy; `allowlist` after T27; then, at v0.3.0, `percent` 10 → 50 → `on`.
  - The P0 read budget is **always on**. It is a guard, not a feature, and is tuned via env.
- **Gate:** no `percent` step until T3 is live in prod and T24 has closed the public-repo finding.
- **Rollback triggers:**
  - 5xx > 2% or p95 > 2× baseline for 10 minutes;
  - Firestore reads > 40k/day while under 250 DAU (the model is wrong);
  - any block-visibility bug.

  Action: `FEATURE_POSTS=off` (reads stop immediately). If writes misbehave, use `DEGRADED_MODE=readonly`. For a code
  defect, shift traffic back to the previous revision (`docs/runbooks/rollback.md`).
- **Data:** expand-only. There is a new collection and no migration. A rollback leaves `posts` docs in place,
  harmless and purgeable via T10.

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The read-budget cap rejects a legitimate power user (large F, heavy scrolling) | Low | Medium | 2,000 ≈ 10× the modelled 191/DAU; the `read_budget_spent` field shows the distribution; tune via env |
| Per-instance budgets are approximate (reset on scale-to-zero; ×3 instances) | Certain | Low | Accepted at Stage 0 (same as DailyCap, `daily_cap.go:14-20`); the Stage 2 ADR moves it to shared state |
| A repo forgets to call `budget.AddReads`, silently bypassing the budget | Medium | Medium | T23 review check + `budgettest` assertions on every RPC (T19/T20) |
| The home-timeline read line (60 new posts/DAU) is higher than modelled | Medium | Low ($) | The 40k alert, P9 actuals, levers §6 |
| Author snapshot staleness after renames (until P2) | Certain | Low | Navigation by `user_id`; P2 soon after |
| Merge bugs (dropped or duplicated items) | Medium | High (user trust) | T11 property tests; client dedupe by post id |
| Index not READY at traffic shift | Low | High | T26 checks READY first (L5 order) |

## Open design questions (architect decides in T1 / ADR-0010; default in bold)
- **Q1** Flag granularity: **one `FEATURE_POSTS` for posts + timelines + UI**, or separate flags.
- **Q2** Slice-1 CreatePost scope: **reply/quote/media → `FEATURE_DISABLED`**, or VALIDATION.
- **Q3** Viewer flags before P5: **always false, no `userLikes` read**.
- **Q4** DeletePost on another user's post: **NOT_FOUND** (vs PERMISSION_DENIED). Unknown id: **success**.
- **Q5** P0 numbers: **2,000 reads/uid/day/instance; 500 reads/IP/day for profile-less callers; CheckHandle 100
  calls/uid/day; negative handle cache 10 s**. Budget charged post-call from `budget.Counter`.
- **Q6** Timeline visibility: **muted authors hidden in Home only; a caller who blocks the author still gets the
  author's posts on GetUserTimeline/GetPost (the client shows a banner); author blocked caller ⇒ NOT_FOUND
  everywhere**.
- **Q7** Mentions: **unknown handles stay plain text; mentions of users who blocked the author are dropped;
  mentioning a user the author blocked is allowed** (notifications are suppressed later in P6).
- **Q8** Hashtag grammar: **`#[\p{L}\p{N}_]{1,50}`, must contain ≥ 1 letter; lower-cased; ≤ 10 stored**.
- **Q9** Text: **NFC, trim, ≤ 280 code points, `\n` allowed (≤ 10 lines), other control chars rejected; links count
  as typed**.
- **Q10** Suspended/deleting authors' posts in Home: **not filtered at Stage 0** (it would cost a `users` read per
  author). The moderation takedown (P7) and account purge (P8) remove them. GetPost and GetUserTimeline do check
  status (cached).
- **Q11** `GetUserTimeline(include_replies=true)` before P3: **same as the Posts tab** (no replies exist). The client
  hides the tab.
- **Q12** `mentionIds` field (ADR-0003:80): **don't write it in P1** (no query uses it; saves index writes); the P6
  notifications ADR decides.
