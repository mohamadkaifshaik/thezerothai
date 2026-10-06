# Posts + profile timeline + home timeline (Phase 1 slices P0 + P1)
Plan owner: planner · Date: 2026-09-30 · Target release: **v0.3.0** (web public beta, see `docs/plans/phase1.md` §4) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, ADR-0002/0003/0004/0006/0008/0009, `proto/dzeroth/{posts,timeline,common,identity}/v1/*.proto`,
`backend/internal/{identity,graph,apiserver}`, `backend/pkg/platform/*`, `firebase/firestore.indexes.json`,
`docs/reviews/cost-model.md`, `docs/reviews/security-audit-v0.1.0.md`, `docs/plans/graph.md` (format and patterns).

> **Design decisions: ADR-0010 (`docs/adr/0010-posts-and-timelines-slice.md`) answers Q1–Q12.** This plan follows the
> ADR. Where the ADR overrides a plan default, the ticket text below already uses the ADR's version:
> - **Q1, Q2, Q3, Q5, Q6, Q7, Q9–Q12:** the defaults are accepted.
>   - Q2 adds `metadata["feature"]` (D2).
>   - Q5 adds two refinements: the IP budget applies only to profile-exempt procedures, and IPv6 is keyed by /64 (D5).
>     The P0-review amendment (D5 A1–A7) adds a 0-read verified-identity gate, an in-flight hold, IP charging for
>     verified callers without a profile, charge-only account operations, and per-instance-lifetime bounds with two
>     residual risks the founder must accept (R1, R2).
>   - Q9's normalisation is specified exactly, including rejection of bidi controls (D9).
> - **Q4 changed (D4):** DeletePost returns **success with 0 writes** for another user's post, an unknown id and an
>   already-deleted id alike. This removes the existence and block oracle.
> - **Q8 changed (D8):** the hashtag grammar admits combining marks and ZWJ/ZWNJ, so Indic tags such as `#भारत` work.
> - **Also changed by the ADR:**
>   - `since_token` becomes a settle watermark with a 15 s window (D13).
>   - Timeline tokens become caller- and kind-bound two-bound windows with a 30-day TTL (D14, new ticket T28).
>   - Cache sizes change and the profile first-page cache merges into author-recent (D15).
>   - GetUserTimeline pages with `Limit(page_size)` (D16).
>   - The purge query is descending (D19 Q-E).
>   - The cold budget ceilings include the `AccountStatusInterceptor` read (D17).
> - **Accepted by the founder 2026-10-01 (ADR-0010 D21, G1–G5):** a URL-span exclusion for mentions and hashtags,
>   shared by server and client through one fixture file; U+2028/U+2029 → `\n`; the handle grammar moves to
>   `pkg/platform/handle` (new ticket **T6b**); invisible-only posts are empty; positive handle hits for mentions are
>   at most 10 s old. The deltas are marked "D21 delta" in T6, T6b, T8, T15, T16 and T19, and **T8 may start once T6b and the T6 follow-up have merged**.

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
  - A per-IP read meter for callers without a profile. Since ADR-0010 D5 A8 it is charged but never rejects
    (CheckHandleAvailability, CreateProfile, marked uids).
  - A 0-read verified-identity gate for unverified password accounts, and an in-flight hold near the cap.
  - Account deletion and export are never blocked by the read budget.
  - A negative handle cache.
  - A CI guard: no `NO_SIDE_EFFECTS` RPC ships uncovered.
  - **Must be in prod before `FEATURE_POSTS` goes beyond `allowlist`.**
- **Backend `internal/posts`.**
  - `CreatePost` (root posts): NFC, ≤ 280 code points, ≤ 10 lines, ≤ 10 mentions resolved via `handles/*`, ≤ 10
    hashtags (Indic-safe grammar, ADR-0010 D8), links left in the text.
  - `DeletePost`: success with 0 writes for anything the caller doesn't own (ADR-0010 D4). `GetPost`.
  - `posts.Reader` (for timeline), `posts.Eraser` + exporter, `opsctl purge-posts|export-posts`.
  - The `PostEvents` hook, which does nothing for now (notifications land in P6).
- **Backend `internal/timeline`.**
  - `GetUserTimeline`, Posts tab (`include_replies=false`). `include_replies=true` runs the real Replies-tab query,
    which returns the same page until P3 because no replies exist (ADR-0010 D11).
  - `GetHomeTimeline`, ADR-0004 steps 1–4 and 6–9: the chunked pull, the exact-prefix merge, the gap token, and the
    author-recent cache.
  - A `since_token` settle watermark (15 s window, ADR-0010 D13) on both timelines.
- **Platform `pkg/platform/cursor`.** Extend it with two-bound `Window` tokens and a TTL-aware decode (ADR-0010 D14).
  Graph tokens are unchanged.
- **Identity.**
  - `Directory.ResolveHandles`, batched and cache-first, for mentions.
  - Move the verified-email check to `pkg/platform/authn` so posts reuses it.
- **Flutter.**
  - `PostsRepository`/`TimelineRepository`.
  - drift tables for timeline items and `since_token`.
  - A shared `PostCard` with rich text: mentions and hashtags tappable, links opened externally.
  - The composer.
  - The Home timeline: cache-first, pull-to-refresh with `since`, dedupe by `post_id`, gap rows, infinite scroll, a
    new-post pill, and auto-refresh at most every 60 s.
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
- Filtering suspended authors out of Home (ADR-0010 D10). At Stage 0 their posts stay in followers' Home until the P7
  `suspend-user` takedown. GetPost and GetUserTimeline do filter them.
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

### Per-RPC budget (Firestore ops per call; source: ADR-0010 "Cost impact", which supersedes the earlier plan table)
Definitions (ADR-0008 A2 convention, ADR-0010 D17):
- F = the caller's following count. C = ceil((F+1)/30), at most 167. p = page size, at most 50.
- **Cold** is the ceiling that tests assert after a reset of every instance cache. It **includes** the
  `AccountStatusInterceptor` read of the caller's `users` doc, because `fs_reads` is counted per request.
- **Warm** assumes every cache hits.
- **Planning** is the per-call value used for the per-DAU columns. It **excludes** the interceptor read, which has its
  own line so it is counted once.
- An empty query still costs 1 read.

| RPC / case | reads cold / warm / planning | writes | deletes | Cloud Run ms | calls / DAU / day | reads / DAU | writes / DAU | deletes / DAU |
|---|---|---|---|---|---|---|---|---|
| CreatePost (root) | 14 / 2 / 2.5 | 4 | 1 (idempotency TTL, eventual) | 80 | 1.0 | 2.5 | 4.0 | 1.0 |
| ↳ replay (same key, same body) / key reused with a different body | 14 / 1 / — | 0 | 0 | 30 | — | — | — | — |
| DeletePost (own post) | 2 / 0 / 1 | 1 (0 on no-op) | 1 (0 on no-op) | 40 | 0.05 | 0.05 | 0.05 | 0.05 |
| GetPost | 4 (+1 if caller `blockedByOverflow`) / 0 / 1 | 0 | 0 | 15 | 1 | 1.0 | 0 | 0 |
| GetUserTimeline, page | 3 + max(p, 20) = 53 at p 50, 23 at p 20 or less (+1 overflow; a cold Posts tab fills the 20-post author-recent entry) / 0 / 11 | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| ↳ `since` refresh, 0 new posts | 4 / 0–1 / — | 0 | 0 | 20 | — | — | — | — |
| GetHomeTimeline, refresh | 2 + C + 2p = **269** at F = 5,000, p = 50 / 0 to C / 4 overhead + new posts | 0 | 0 | 80 | 8 | 32.0 overhead + **60.0 new posts** | 0 | 0 |
| ↳ settle-window re-reads (D13) | within the ceiling / 0 / ≈ 0.1 per refresh | 0 | 0 | — | 8 | ≈ 1.0 | 0 | 0 |
| GetHomeTimeline, older page | 269 / — / 30 | 0 | 0 | 120 | 1 | 30.0 | 0 | 0 |
| GetHomeTimeline, cold open | 269 / — / 30 | 0 | 0 | 150 | 0.1 | 3.0 | 0 | 0 |
| `AccountStatusInterceptor` caller read on P1 requests | 1 / 0 / 1 per home refresh, 0.5 on the other 5.15 requests | 0 | 0 | — | 13.15 req | 10.6 | 0 | 0 |
| Identity CheckHandleAvailability / GetProfile (P0: negative handle cache 10 s, daily cap) | 1 / 0, 3 (+1 overflow) / 0 / unchanged | 0 | 0 | +0 | — | ±0 | 0 | 0 |
| **P0 + P1 total** | | | | | **≈ 13.15 req** | **≈ 162.2** | **≈ 4.05** | **≈ 1.05** |

Derivation notes:
- **CreatePost cold 14** is made of:
  - the interceptor/author `users` read (1);
  - the author `graph` (1), read only if the text has mention candidates;
  - `handles/*` (≤ 10) in one `GetAll`;
  - `idempotency` (1) and `quotas` (1).

  Other CreatePost values:
  - Warm 2 is idempotency + quotas, which are always fresh in the transaction.
  - Planning 2.5 assumes ~30% of posts have mentions and some handle misses.
  - Writes 4: the idempotency doc, the post, `users.postsCount` (`identity.Counters.AddPostsCount`) and `quotas`.
  - These are lower than the proto's 19/6 because reply parent, quote and media reads are out of scope. T2 records this.
- **DeletePost** reads the post (the interceptor adds 1 when cold).
  - If the caller owns it: a blind batch, `Delete(post, Exists)` + `postsCount −1`. An `Exists` failure means a
    concurrent delete won, so the call succeeds with 0 writes (the exactly-once decrement).
  - For anything else (another user's post, an unknown id, an already-deleted id): success, 1 read, 0 writes (D4).
- **GetPost** is the interceptor + post + author `users` (status) + caller graph (`blockedBy`). Add +1 author graph if
  the caller's `blockedByOverflow` is set.
- **GetUserTimeline** is the interceptor + target `users` + caller graph + a page queried with **`Limit(page_size)`**
  (D16, no `+1`). A full page always returns `next_page_token`; the only extra cost is one empty final call when the
  total is an exact multiple of the page size. The Posts-tab first page comes from the author-recent cache (D15).
- **Home refresh overhead is 4 reads, not 3.** Refreshes are ≥ 60 s apart and `CACHE_TTL` is capped at 60 s, so the
  caller's graph is usually expired.
- **Older page / cold open are 30, not 23.** At F = 60, `k = ceil(40/3) = 14`, and two dense chunks return 14 each.
  This is ADR-0004's by-design over-read, now priced.
- **Home "new posts" (60/DAU)** is the largest single line. It comes from `cost-model.md` §1 and scales with F × author
  activity, not with our code. The settle watermark (D13) re-reads ≈ 0.1 posts per refresh.
- **Change vs the earlier plan (133.9 → 162.2 reads/DAU):**
  - interceptor line +10.6;
  - refresh overhead with the graph cold +8;
  - older page and cold open at k = 14 +7.7;
  - settle re-reads +1;
  - CreatePost +0.5 and GetPost +0.5.

  Writes and deletes are unchanged. T22/T25 measure these values, and the planning values move to the measured means.

### Daily totals at the Stage 0 target (300 DAU) vs free quota
Released scope after P1 = v0.2.0 (20.4 R, 3.1 W, 0.1 D, ≈ 11.3 requests per DAU) + P0/P1 (above) = **≈ 182.6 reads,
7.15 writes, 1.15 deletes and 24.45 requests per DAU per day**.

| Quota | Released scope per DAU | at 300 DAU | % of free | Runs out at | vs 80% line |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | 182.6 | 54.8k | **110%** | **≈ 274 DAU** | **over**: the 80% line (40k) is crossed at **≈ 219 DAU** |
| Firestore writes (20k/day) | 7.15 | 2.1k | 11% | ≈ 2,800 DAU | under |
| Firestore deletes (20k/day) | 1.15 | 0.35k | 2% | ≈ 17,000 DAU | under |
| Cloud Run requests (2M/month, shared, ~29k fixed) | 24.45 (≈ 734/month) | 220k/month | 11% | ≈ 2,690 DAU | under |
| Cloud Run vCPU-s (180k/month, 0.1 s/request) | 2.45 | 22k/month | 12% | ≈ 2,450 DAU | under |
| Firestore storage (1 GiB) | ≈ 1.5 KiB per post incl. index entries (ADR-0003) | +13 MiB/month | ≈ 1%/month | years | under |

- **Cost line:** posts + timelines add **≈ 162 reads, 4 writes and 13 requests per DAU per day**.
  - Idle: **$0**.
  - At 300 DAU: **≈ $0.09/month** (≈ 4.8k reads/day over the free line, upper-bound price from `cost-model.md` §7).
  - At 3k DAU: ≈ $9.9/month (reads $8.76, Cloud Run vCPU $0.96, requests $0.09, writes $0.08).
  - This is inside founder decision D1 ("accept pay-per-use"). No new decision is needed; D1 is re-decided at P9 with
    real numbers.
  - The existing "Firestore reads > 40k/day" alert will start firing at **≈ 219 DAU** (previously ≈ 260). That is the
    planned signal to apply `cost-model.md` §6 levers, not an incident.
  - The whole-product model (`cost-model.md` §2, 191 reads/DAU) rises to ≈ 215 once T25 applies these corrections.
  - No free-tier-budget §6 trigger fires. Firestore > 1.5M reads/day is ≈ 8.2k DAU on this model.
- **Levers built in by default:**
  - `since` refresh;
  - auto-refresh ≥ 60 s apart and never in the background;
  - older-page prefetch only after scrolling past 70% (lever §6.3);
  - the author-recent instance cache, which also serves the profile Posts-tab first page (D15).
- **Lever held in reserve (measured first):** lower ADR-0004's over-read factor in `k` from `2·page` to `1.5·page`, only
  if T22/P9 show older-page reads > 1.4 × page size. This tunes a constant and doesn't reopen the algorithm.
- **New GCP service or fixed-cost resource: none.**
  - The flag, the read-budget numbers, `TIMELINE_SETTLE_WINDOW`, `TIMELINE_TOKEN_TTL` and the cache sizes are env
    vars on the existing `api` service.
  - Memory: the new caches take ≤ 113 MiB worst and ≈ 40 MiB typical; the limiters < 5 MiB at Stage 0 (≈ 20–25 MiB per full 100k-key counter, ADR-0010 D15). This stays inside the
    ~150 MiB cache budget of the 512 MiB instance (D15).
  - The indexes already exist.
  - No Pub/Sub topic is needed: this slice has no async work, because a deleted root post has no dependents until
    P3/P4/P5.
  - `cost-guard`: no new Terraform resources.

### Worst-case abuse bounds (inputs to security review T24; ADR-0010 D5 as amended)
Every read-budget counter is in instance memory, so each bound is **per instance lifetime**. "Steady" means at most 3
instances all day; a rollout day runs at most 6; "idle cycling" means one actor repeatedly letting instances scale to
zero (≤ 90 lifetimes a day, ceiling 270; ADR-0010 D5).

| Vector | Control | Worst case |
|---|---|---|
| Minted, unverified password accounts on any RPC (security H1) | 0-read verified-identity gate (D5 A2): `PROFILE_REQUIRED` / `EMAIL_NOT_VERIFIED` from token claims | **0 reads**, for any number of accounts and IPs (was ≈ 518k/day per IPv4, ≈ 14.4M per IPv6 /64) |
| Handle/profile/post/timeline read scraping by one verified account (**the public-repo finding**) | uid budget 2,000 with the in-flight hold (M = 269) + per-procedure buckets; account operations charge-only under `account_ops_daily` (20) | **2,308 per instance lifetime**: ≤ 6,924/day steady (13.8% of free, ≈ $0.004/day); ≤ 13,848 on a rollout day; ≈ 208k/day idle cycling (≈ $0.12/day); ceiling ≈ 623k/day (≈ $0.37/day). Before P0: ~86k–259k/day |
| Verified accounts without a profile, per IPv4 address or IPv6 /64 | ADR-0010 D5 A8: the IP key is a charge-only meter (never rejects; runbook threshold `read_budget_ip_spent >= 500`); each non-exempt call stops at account status (≤ 1 read per uid per 10 s); both per-minute IP limiters keyed by /64 | Each uid ≤ 2,308 per lifetime, so V uids ≤ 6,924 · V/day steady: the same as R1. Calls are capped by the per-minute IP limiter (≤ 518k/day). Was IP key ≤ 501 per lifetime before A8 |
| CheckHandleAvailability loops | 100 calls/uid/day/instance + both budgets | ≤ 100 reads per uid per lifetime |
| Verified sybils, with or without profiles (**residual R1: founder acceptance required**) | Per-account bound × accounts; `read_budget_key=uid` in logs; `abuse-spike.md` | ≈ 8 accounts exhaust a day's free reads in steady state (≈ $0.004/day each) |
| Instance churn (**residual R2: founder acceptance required**) | Detection: one `uid_hash` rejected on ≥ 3 instances in a day; the pre-designed persisted counter behind its trigger | ≤ ≈ 623k reads/day from one actor (≈ $0.37/day) |
| Post spam | `quota.Posts` 100/day (new accounts 20; `config.go:282,294`) + 10/min bucket | 100 × 4 = **400 writes** (2%) |
| Mention fan-out amplification | ≤ 10 mentions, one `GetAll`, counted against the read budget | covered by the read budget |
| Delete churn | 20/min bucket; each delete needs an own post (bounded by the post quota) | ≤ 100 deletes |

## Dependencies & open questions
- **Depends on:**
  - `pkg/platform`: idempotency, quota (`Posts` kind exists, `quota/quota.go:53-61`), snowflake, cursor, budget, cache,
    flags, ratelimit/DailyCap, apierr, degraded. All present.
    - `cursor` holds one `(createdAt, docId)` pair and expires after 24 h. Timelines need a two-bound `Window` and a
      30-day TTL, so **T28 extends it** (ADR-0010 D14). The graph tokens are unchanged.
  - `graph.Reader.Snapshot` (following/blocked/muted/blockedBy). Done.
  - `identity.Directory` and `identity.Counters.AddPostsCount`. Present, unused.
  - The posts indexes. Declared at `firebase/firestore.indexes.json:4-34`. **T26 confirms they are READY in dev and prod.**
- **Import rules (ADR-0002):**
  - timeline imports only the `posts.Reader` and `graph.Reader` interfaces (ADR-0004 handoff: "never query `posts`
    directly from timeline").
  - posts uses `identity.Directory`/`Counters` and `graph.Reader`.
  - identity never imports posts.
- **@architect:** ADR-0010 (T1) answers Q1–Q12 (see "Open design questions" for the outcomes). T2 makes the
  comment-only proto changes.

## Proto and schema changes (comment-only; `buf breaking` clean; no new fields)
| File | Change | Why |
|---|---|---|
| `proto/dzeroth/posts/v1/posts.proto` | CreatePost: document the slice-1 `FEATURE_DISABLED` behaviour for reply/quote/media with `metadata["feature"]` (D2), the mention rules (D7) and hashtag rules (D8); budget "reads 14 cold / 2 warm, writes 4 until replies/quotes/media ship". DeletePost: "not own, unknown or already deleted ⇒ success with 0 writes (D4); reads 2/0, writes 1, deletes 1 (0 on no-op)". GetPost: "reads 4/0 (+1 overflow; +1 once engagement ships)" | Keep proto and cost model in sync (`common.proto:13-14`) |
| `proto/dzeroth/common/v1/common.proto` | FEATURE_DISABLED comment: `metadata["feature"]` names a sub-feature (`replies`/`quotes`/`media`); absent means the whole service (D2). Comment only | Clients hide only the named sub-feature |
| `proto/dzeroth/timeline/v1/timeline.proto` | GetHomeTimeline worst `2 + C + 2p` (269) until engagement adds `userLikes`; GetUserTimeline `3 + max(p, 20)` (53); the D6 visibility semantics; `since_token` is a settle watermark and refreshes may repeat items (the client dedupes by `post_id`, D13); tokens are caller-bound and expire after 30 days (D14) | same |
| `proto/dzeroth/identity/v1/identity.proto` | CheckHandleAvailability/GetProfile: mention the daily read budget and `metadata["limit"]` = `read_budget_daily` / `check_handle_daily` | P0 contract visibility |
| `firebase/firestore.indexes.json` | **No change** (D19). Every P1 query shape maps to an existing index when it orders `createdAt DESC, __name__ DESC`. No `mentionIds` exemption (D12) | Index write cost |
| Firestore `posts/{postId}` | New collection, shape exactly as ADR-0003:80; `visibility = PUBLIC`, `kind = POST`, `isReply = false`, `conversationId = postId` | — |

---

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Contract and gating hardening | T1, T2, T3, T4 | ADR-0010 Accepted; `make proto` green; read budget merged with the guard test in CI |
| M2 | Posts backend ‖ Flutter foundations | T5–T10 (incl. T6b and the D21 deltas once accepted) ‖ T14, T15 | CreatePost/DeletePost/GetPost behind the flag; PostCard + repositories against fakes |
| M3 | Timelines backend ‖ Flutter screens | T28, T11–T13 ‖ T16–T18 | Both timelines implemented; composer, home and profile tabs built |
| M4 | Verification | T19–T25 | Test report PASS with budget assertions; code review APPROVE; security 0 Critical/High; cost report holds |
| M5 | Ops and staged rollout | T26, T27 | Dev deployed flag-on; prod `candidate` GO; prod `allowlist`. The public % rollout goes with v0.3.0 |

**Order:** T1 → T2 → (T3 ‖ T4 ‖ T6 ‖ T7 ‖ T28) → T5 → (T8, T9, T10) → T11 → (T12, T13).
- **D21 (pending the founder):** founder decision → (T6b ‖ T6 D21 delta ‖ T15 D21 delta) → T8. T16 takes its D21
  delta whenever it lands. T6b and the T6 delta touch the same file (`posts/text/text.go`), so merge T6b first.
- T28 (the cursor extension) depends only on T1 and must merge before T11.
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
    - the cursor bindings for `pkg/platform/cursor`. The ADR replaces the draft `home:{uid}` / `user:{target}:{tab}`
      with caller- and kind-bound bindings (D14, implemented in T28/T11);
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
- **Budget.** Doc only. The ADR's "Cost impact" table supersedes this plan's earlier table, and this plan now carries
  it (162.2 reads/DAU).
- **Status.** Written: `docs/adr/0010-posts-and-timelines-slice.md` (PR #69, Accepted on merge).

### T2 — Proto comments, index check, regenerate  [owner: architect] [size: S] [depends: T1]
- **Description.** Apply "Proto and schema changes" exactly. Run `make proto` and commit the generated Go
  (`backend/gen`) and Dart (`app/lib/gen`). Confirm that no composite index is missing for the ADR-0004 queries:
  - `authorId in […] && isReply == false order by createdAt desc`;
  - `authorId == X order by createdAt desc` (± `isReply`).

  Include the `__name__` tie-breaker direction used by the `(createdAt, postId)` cursor. Every descending query orders
  `createdAt DESC, __name__ DESC` (ADR-0010 D19); an ascending `__name__` would need new indexes.
- **Acceptance criteria.**
  - Given the PR, when CI runs `buf lint` and `buf breaking --against main`, then both pass and no field number changed.
  - Given every changed RPC comment, then its numbers equal the cold ceilings in ADR-0010 "Cost impact" (which include
    the interceptor read, D17).
  - Given `firestore.indexes.json`, then each query shape Q-H, Q-P, Q-R, Q-E and Q-C in ADR-0010 D19 maps to a named
    index, listed in the PR body, and the file is unchanged.
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

  Work (ADR-0010 D5 as amended after the P0 reviews, A1–A7):
  1. **Extend** `pkg/platform/ratelimit`'s `DailyCap` (no second limiter type) to count units: `Reserve(key)`,
     `Release(key, n)` and `Charge(key, n)`, with the same IST-day reset and 100k-key LRU. Get-or-create a counter
     under the LRU's lock (`cache.LRU.GetOrSet`).
  2. **In-flight hold (A1).** `Reserve` rejects when `count ≥ cap` (daily) or when
     `inflight > 0 && count + (inflight + 1) · M > cap` (transient). M = 269 for the uid key and 2 for the IP key (code
     constants). `Release` runs in a `defer`, so a panic still charges.
  3. Enforce it in `ratelimit.Interceptor`:
     - the uid key (`READ_BUDGET_PER_UID_PER_DAY`, default 2,000) on every procedure except the charge-only set
       (item 7);
     - after `next`, charge `budget.FromContext(ctx).Reads()` on success **and** on error (the counter is attached by
       `mw.Logging`, `mw.go:115`, which is outermost, so the charge includes the `AccountStatusInterceptor` read).
  4. **Verified-identity gate (A2, allowlist per A10).** A new `authn` interceptor right after `IDTokenInterceptor`,
     before the rate limiter, passes only `google.com`, `apple.com` and `password` with `email_verified` (plus
     `anonymous` on the Auth emulator only). It answers every other caller as follows:
     - CheckHandleAvailability and CreateProfile → FAILED_PRECONDITION + `EMAIL_NOT_VERIFIED`;
     - every other procedure → FAILED_PRECONDITION + `PROFILE_REQUIRED`;
     - 0 Firestore reads, and no limiter key is created.
  5. **IP key (A3–A5).** `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY` (default 500), keyed by `IPBudgetKey`: the IPv4
     address or the IPv6 /64, canonical strings only.
     - **Charge-only everywhere, never rejects (A8):** CheckHandleAvailability, CreateProfile, and the non-exempt
       calls of a uid marked as profile-less on this instance. `ReadBudgetIPEnforce` stays empty.
     - After `next`, when `AccountStatusInterceptor` set `RequestInfo.ProfileRequired`, charge the reads to the IP key
       and mark the uid (10 min LRU). A successful CreateProfile removes the mark, and so does any call that finds a
       profile (`RequestInfo.ProfileFound`, A9); that call charges 0 to the IP key.
     - Callers with a profile are never IP-limited (carrier-grade NAT).
     - `ResolveClientIP` falls back to the rightmost X-Forwarded-For entry when the chosen one does not parse.
     - Both per-minute IP limiters (pre-auth and in-chain) key by `IPBudgetKey`. `http.Server.MaxHeaderBytes = 64 KiB`.
  6. **Rejections (A7).** RESOURCE_EXHAUSTED + `RATE_LIMITED`, 0 Firestore reads (this interceptor runs before
     account status):
     - daily: `metadata["limit"]` = `read_budget_daily`, `retry_after` = time until IST midnight (uid key only; the
       IP key no longer rejects, A8);
     - transient: `read_budget_inflight`, `retry_after` = 1 s;
     - the log line carries `limit_name` with the same value, and `read_budget_key` = `uid` or `ip`.
  7. **Charge-only account operations (A6).** DeleteAccount, RequestAccountExport and GetAccountExport are charged to
     the uid budget but never rejected by it. A shared `DailyCaps` entry, `account_ops_daily`
     (`ACCOUNT_OPS_CALLS_PER_DAY`, 20), bounds them.
  8. Add `DailyCaps` for `CheckHandleAvailability` (100/uid/day, `limit_name=check_handle_daily`).
  9. Add an identity negative handle cache (10 s, reusing `notFoundTTL`, `identity/cache.go:20`) for `ResolveHandle`
     NotFound, used by both RPCs. CreateProfile and ChangeHandle stay transactional, so a stale "available" answer
     can't create a duplicate.
  10. Add a **guard test** in `backend/internal/apiserver`. It builds the mux, enumerates every registered procedure
      whose `IdempotencyLevel == NoSideEffects` (the same mechanical signal `degraded.Interceptor` uses,
      `degraded.go:34-44`), and fails if the read budget is disabled or the procedure is on an unexplained exemption
      list. Future read RPCs are then covered automatically. It also asserts that `ProfileExempt` equals the union of
      the enforced and charge-only IP sets, that the charge-only uid set is exactly the three account operations (each
      with a `DailyCaps` entry), and that `ReadBudgetIP` is wired. It builds these sets with the same exported helper
      `Build` uses.
  11. All numbers go in `config.Config` (rule 11), and `config.Load` rejects values ≤ 0. Add lines in
      `docs/code-map.md`. Correct the comments in `config.go`, `daily_cap.go` and `interceptor.go` that say "overshoot
      is one call" or "≈ 1,503 reads/IP".
- **Acceptance criteria.**
  - Given uid A spent 2,000 reads today on one instance, when A calls any RPC except the three account operations, then
    `RATE_LIMITED` is returned with `limit_name=read_budget_daily`, `read_budget_key=uid` and 0 Firestore reads.
  - Given A at the cap, when A calls DeleteAccount, RequestAccountExport or GetAccountExport, then the read budget does
    not reject it and its reads are charged. The 21st such call in the IST day on that instance gets
    `account_ops_daily`.
  - Given IST midnight passes (fake clock), then A's next call succeeds.
  - Given 50 concurrent calls that each read M, started at spent 0 and again at spent 1,999, then the counter never
    exceeds 2,000 − 1 + 269 = 2,268, and the calls not admitted get `read_budget_inflight` with `retry_after` = 1 s.
  - Given a password account with `email_verified=false`, when it calls GetMe (or any non-exempt RPC), then it gets
    `PROFILE_REQUIRED`; on CheckHandleAvailability or CreateProfile it gets `EMAIL_NOT_VERIFIED`. In both cases
    `fs_reads = 0` and no limiter key is created. A Google or Apple uid is unaffected.
  - Given a caller with a verified email and no profile, when it makes 101 CheckHandleAvailability calls in one IST
    day, then the 101st gets `RATE_LIMITED` (`check_handle_daily`).
  - Given verified uids without profiles from one IP that have spent ≥ 500 reads on the IP key (A8), when a new
    verified uid on that IP calls CheckHandleAvailability and then CreateProfile, both succeed. A profile-less uid's
    GetMe returns `PROFILE_REQUIRED` (not `RATE_LIMITED`), and `read_budget_ip_spent` keeps growing. A caller **with**
    a profile on the same IP is unaffected on every procedure.
  - Given a uid marked on this instance, when its next non-exempt call finds a profile, then the mark is removed and
    that call charges 0 to the IP key (A9).
  - Given an ID token whose `sign_in_provider` is not `google.com`, `apple.com` or verified `password` (for example
    `anonymous` outside the emulator, `phone`, `custom`, or empty), then it gets the A2 answers with `fs_reads = 0`
    and `gate=provider_not_allowed` (A10).
  - Given two IPv6 addresses in the same /64, then they share one IP budget **and** one per-minute IP bucket (pre-auth
    and in-chain). Addresses in different /64s don't.
  - Given an X-Forwarded-For whose chosen entry is not an IP, then the rightmost entry is used, and no limiter stores
    a non-canonical key.
  - Given a rejection, then the error carries `metadata["limit"]` and the log line carries `limit_name` with the same
    value.
  - Given GetProfile(handle = "nosuchuser") twice within 10 s, then Firestore is read once.
  - Given a new `NO_SIDE_EFFECTS` RPC registered without coverage, or an unclassified change to the IP or charge-only
    sets, when `make ci` runs, then the guard test fails and names the procedure.
  - Given typical usage (the k6 identity + graph scripts), then no legitimate call is rejected, transient
    `read_budget_inflight` included.
- **Test notes.** Unit tests with a fake clock, including a parallel-goroutine test of the hold invariant (`-race` in
  CI). An emulator test proves the budget is charged from real `budget.Counter` values (a GetProfile cold call charges
  1–3). A regression test: every graph and identity RPC still passes its existing budget assertions. Instance churn
  can't be tested locally; it is a documented residual (ADR-0010 D5 R2).
- **Status.** Done (2026-10-05, branch `feat/posts-t3-read-budget`). Items 1-11 were already merged on main by the P0
  branch (A1-A10: `DailyCap` Reserve/Release/Charge, the interceptor, the `authn` gate, IP key, `check_handle_daily`,
  `account_ops_daily`, identity `handleFree` cache, `apiserver/guard_test.go`, runbook `abuse-spike.md`). This ticket
  audited them against D5 and added the explicit "2,001st read unit" unit test
  (`TestReadBudget_2001stUnitRejectedWithReadBudgetDaily`). Emulator coverage:
  `internal/graph/readbudget_integration_test.go`. 0 Firestore reads added, $0.
- **Observability.** `limit_name`, `read_budget_key`, `read_budget_spent`, `read_budget_ip_spent`, `profile_required`,
  `gate=email_unverified`, and WARN `read_budget_over_max` (ADR-0010 D20). `docs/runbooks/abuse-spike.md` gets a Logs
  Explorer filter for each (T26 lists them; no new alert policy).
- **Budget.** 0 Firestore reads/writes (in memory). The gate turns ≈ 1 read per minted-uid call into 0. Memory:
  ≈ 200–250 B per key, ≈ 20–25 MiB per full 100k-key counter (ADR-0010 D15); < 5 MiB at Stage 0.

### T4 — Posts/timeline flag, rate limits  [owner: backend-developer] [size: S] [depends: T2]
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

    Every query has a `Limit`. Every descending query orders `createdAt DESC, __name__ DESC` explicitly (ADR-0010 D19;
    shapes Q-H, Q-P, Q-R). Every read calls `budget.FromContext(ctx).AddReads(n)`, with an empty result counted as 1.
    `ByAuthors` receives only the authors **not** covered by the author-recent cache.
  - Caches wrap `pkg/platform/cache.LRU` (ADR-0010 D15):
    - post docs: **20,000** entries, `CACHE_TTL` (60 s), config `CACHE_POSTS_ENTRIES`. Filled by every read path; own
      writes update in place, own deletes evict.
    - author-recent: `{≤ 20 newest root posts, truncated bool, loadedAt}` per author, **1,000** authors, 60 s, config
      `CACHE_AUTHOR_RECENT_ENTRIES`. Entries share `*Post` pointers with the posts cache.
    - **author-recent is also the profile Posts-tab first-page cache.** There is no separate profile-first-page cache.
    - Author-recent is filled by:
      - a Posts-tab first page (T12);
      - home cold-open chunks that did not fill `k`, where every author gets a `truncated=false` entry, empty ones
        included (T13);
      - this instance's CreatePost (prepend, keep `loadedAt`) and DeletePost (remove).
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
  - Given the emulator with `firestore.indexes.json` loaded, then Q-H, Q-P and Q-R with `__name__ DESC` run without a
    missing-index error.
  - Given `CACHE_POSTS_ENTRIES` / `CACHE_AUTHOR_RECENT_ENTRIES` unset, then the defaults are 20,000 / 1,000.
- **Test notes.** Unit tests with a fake repo. An emulator test for query shapes against the real indexes.
- **Observability.** `posts_op`, `fs_reads`/`fs_writes`/`fs_deletes`, `posts_cache_hit`.
- **Budget.** As the Reader methods: 1 read per returned doc, and 1 per empty query.

### T6 — Post text parser (pure)  [owner: backend-developer] [size: S] [depends: T1]
- **Description.** `backend/internal/posts/text` (no I/O). Search `internal/identity/validate.go` for NFC and handle
  regex helpers first, and reuse the handle grammar (`handleRe`) and `norm` instead of redefining them. It does:
  - **Normalisation (ADR-0010 D9), in this order:**
    1. invalid UTF-8 → VALIDATION;
    2. `\r\n` and lone `\r` → `\n`, `\t` → one space;
    3. NFC;
    4. trim `unicode.IsSpace`;
    5. empty → VALIDATION;
    6. reject `Cc` except `\n`, and reject the bidi controls U+202A–U+202E and U+2066–U+2069 (LRM/RLM, ZWJ/ZWNJ and
       emoji sequences are allowed);
    7. ≤ 280 code points;
    8. ≤ 10 lines (at most 9 `\n`).
  - **Mentions (D7):**
    - `@` + `[A-Za-z0-9_]{3,15}`, taken from identity's `handleRe`.
    - The `@` is at the start of the text or after a rune that is not `\p{L}\p{M}\p{N}` and not one of
      `_ @ # / . : & $ + -`.
    - The run is followed by the end of the text or a rune that is not `[A-Za-z0-9_@]`.
    - A run longer than 15 is not a mention (never truncated).
    - Lower-cased, deduplicated keeping the first occurrence, first 10.
  - **Hashtags (D8, Indic-safe):**
    - `#` is at the start of the text or after a rune that is not `\p{L}\p{M}\p{N}` and not one of `_ @ # / &`.
    - The body is `[\p{L}\p{N}_][\p{L}\p{M}\p{N}_\x{200C}\x{200D}]{0,49}`: the first rune is not a mark or joiner, and
      the total is 1–50 code points.
    - The body is followed by the end of the text or a rune outside the body class, and must contain at least one
      `\p{L}`.
    - A run longer than 50 is not a hashtag.
    - Stored as `strings.ToLower` of the NFC body, deduplicated keeping the first occurrence, first 10.
  - Links: no server processing. They count toward length as typed.
- **Acceptance criteria.** The ADR-0010 D7/D8 examples are the table tests, verbatim.
  - Given 280 emoji or combining sequences, then the length check counts code points after NFC. An emoji ZWJ sequence
    counts every code point.
  - Given 11 lines, then VALIDATION `field=text`. Given U+202E anywhere, then VALIDATION. Given U+200F (RLM) or a ZWJ
    emoji, then the text is accepted.
  - **Mentions:**
    - `@Alice @alice` → [alice]; `email@example.com` → none; `(@bob)` → bob; `@bob's` → bob;
    - `@@bob`, `@bob@host`, `https://x.y/@bob`, `@ab`, `@abcdefghijklmnop` (16) and `@al-ice` → none;
    - `hi @carol_` → `carol_`.
  - **Hashtags:**
    - `#Go #go #GO` → [go]; `#भारत` → [भारत] (not `#भ`); `#café` → [café]; `#go_lang` → [go_lang];
    - `#123` → none (**pinned**: no letter); `#१२३`, `a#b`, `https://x.y/p#frag`, `&#39;` and `#` → none.
  - Given 11 hashtags, then only the first 10 are stored and the text is unchanged.
- **Test notes.** Table tests plus fuzz tests (`go test -fuzz`) for panics on arbitrary UTF-8.
- **Observability.** —
- **Budget.** 0.
- **D21 delta (proposed 2026-10-01; only once the founder accepts G1/G2/G4; merge before T8).** Merged as PR #77;
  this is a follow-up PR on `backend/internal/posts/text/{text.go,text_test.go}` after T6b.
  - **G1:** compute URL spans exactly per ADR-0010 D7 "URL spans": case-insensitive `http(s)://`, the explicit
    terminator list (not `unicode.IsSpace`), a non-overlapping scan that resumes after rejected candidates, the
    `\p{L}\p{M}\p{N}` start rule, and the trailing-punctuation and unbalanced-bracket trim. Drop mention and hashtag
    candidates that overlap a span **before** lower-casing, dedupe and the cap of 10.
  - **G2:** step 2 maps U+2028 and U+2029 to `\n`.
  - **G4:** step 4 also trims U+00AD, U+180E, U+200B, U+2060–U+2064, U+FEFF. Step 5 is "empty" when no rune lies
    outside `unicode.IsSpace` ∪ `\p{Cf}` ∪ U+FE00–U+FE0F ∪ U+E0100–U+E01EF.
  - Create `testdata/post_text_grammar.json` (repo root) from the ADR-0010 D21 G1 seed table plus every D7/D8
    example. Its `grammar` and `normalise` arrays are described in D21. The architect reviews the file.
  - **Acceptance criteria.**
    - Every `grammar` row passes: `Normalize(text) == text`, and `Mentions`/`Hashtags` equal the row. Every
      `normalise` row passes. The test asserts that the number of rows run equals the number in the file.
    - `https://ex.com/?ref=@bob` → no mentions; `see https://ex.com/?ref=@bob and @carol` → [carol];
      `https://ex.com/?a=1&b=#go #rust` → [rust]; `xhttps://ex.com/?r=@bob` → [bob]; `https://ex.com/?r=@bob` +
      U+FEFF + `@carol` → [carol].
    - 10 lines joined by U+2028 plus one more U+2029 line → VALIDATION (11 lines). 10 lines joined by U+2028 → stored
      with `\n`.
    - `"​⁠﻿"`, `"‎"`, `"‍"` and `"️"` → VALIDATION (empty). `"hi​"` → `"hi"`. A
      post ending in the England flag (U+1F3F4 + tags + U+E007F) keeps its tag characters. U+202E at either end →
      VALIDATION (still rejected, not trimmed).
    - The fuzz target also checks that no stored mention or hashtag overlaps a URL span.
  - **Budget.** 0 (parser). It lowers CreatePost reads when the only candidates sit in URLs.
  - **Status: built (branch claude/gracious-babbage-2barib).** G1/G2/G4 in `posts/text`; `testdata/post_text_grammar.json`
    (43 grammar + 22 normalise rows, architect to review); Go loads every row and asserts the row count. `Parsed.MentionsInURL`
    feeds the T8 `mentions_in_url` log field. The Dart side (T15 delta) must load the same file.

### T6b — Shared handle grammar: `pkg/platform/handle` (ADR-0010 D21 G3)  [owner: backend-developer] [size: S] [depends: founder accepts D21 G3; merges before the T6 D21 delta and T8]
- **Description.** A refactor with no behaviour change. Reuse-first "generalise and move": one handle grammar, used by
  identity and `posts/text`, with no `internal/` import from the parser.
  1. New `backend/pkg/platform/handle` (stdlib only), modelled on `pkg/platform/ids`:
     - `const MinLen = 3`, `const MaxLen = 15`;
     - `func IsRune(r rune) bool` (`[A-Za-z0-9_]`);
     - `func ValidRun(s string) bool` (`^[A-Za-z0-9_]{3,15}$`).
  2. `backend/internal/identity/validate.go` and `service.go`: delete `handleRe` and `ValidHandleRun`; call
     `handle.ValidRun`. The reserved-shape check (`reservedDocID`), lower-casing and the messages stay in identity.
  3. `backend/internal/posts/text/text.go`: import `pkg/platform/handle`; delete `isHandleRune` and
     `maxMentionRun` in favour of `handle.IsRune` and `handle.MaxLen`; remove the `internal/identity` import.
  4. `docs/code-map.md`: one line for `handle.ValidRun` / `handle.IsRune` / `MinLen` / `MaxLen`.
- **Acceptance criteria.**
  - `grep -rn "handleRe\|ValidHandleRun" backend/` finds nothing.
  - An import-guard test in `backend/internal/posts/text` (parse the package's non-test files with `go/parser`)
    fails if any import path contains `/internal/`.
  - `handle_test.go` covers lengths 2, 3, 15 and 16, `_`, a non-ASCII letter, `-`, and the empty string, and checks
    that `IsRune` agrees with `ValidRun` on single-rune classes.
  - The existing identity and `posts/text` suites pass unchanged (no behaviour change); `make ci` is green.
- **Test notes.** Unit tests only.
- **Observability.** —
- **Budget.** 0.
- **Status: built (branch claude/gracious-babbage-2barib).** `pkg/platform/handle`, identity and `posts/text` use it;
  the import-guard test is `posts/text/imports_test.go`; `docs/code-map.md` updated.

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

### T8 — CreatePost (root posts)  [owner: backend-developer] [size: M] [depends: T5, T6, T7; the founder's D21 decision, then T6b and the T6 D21 delta if accepted]
- **Description.**
  1. Validate:
     - reply/quote/media non-empty → FAILED_PRECONDITION + `FEATURE_DISABLED` with `metadata["feature"]` =
       `replies`, `quotes` or `media` (checked in that order, first match), **before any other validation**, 0 reads
       (ADR-0010 D2);
     - `idempotency.KeyFormatValid`;
     - text (T6);
     - verified email (T7).
  2. Load, cache-first: the author profile (ACTIVE, snapshot fields). Only if the text has at least one mention
     candidate, load the author graph and resolve mentions (T7):
     - drop uids in the author's `blockedBy`;
     - if the author's `blockedByOverflow` is true, drop **all** mentions (fail closed, D7).
  3. Transaction, bounded by a **5 s context deadline** (ADR-0010 D13):
     - `idempotency.Store.Get` → replay path (the stored post id → read the post → return it; a different request hash →
       `IDEMPOTENCY_KEY_REUSED`). `requestHash` covers the normalised text and the four slice-2+ fields (D18);
     - `quotas` read + `quota.CheckAndReserve(Posts, limit)` (new-account limit if the profile is younger than
       `NEW_ACCOUNT_WINDOW`, 24 h);
     - `snowflake.Generate` the id **inside each transaction attempt**, so `createdAt` (= the Snowflake ms) is fresh on
       every retry. An `AlreadyExists` on `posts/{id}` fails the attempt, and the retry draws a new id (D18);
     - `Create(posts/{id})`, `identity.Counters.AddPostsCount(+1)`, `idempotency.Store.Put`.
  4. After commit:
     - update the posts cache and the author-recent cache;
     - `Directory.Forget(author)` (or update it in place, as in graph T30);
     - `PostEvents.Created` (a no-op).
  5. Return `PostView` (viewer flags false).
  6. **Carry-overs from the T7 review (record the decisions in the T8 PR):**
     - **Stale positive handle cache.** `ResolveHandles` caches handle to uid for `CACHE_TTL` (60 s), so a handle
       that was freed and reclaimed by another user can be saved in `mentions[]` under the wrong user. T8 must
       either verify the resolved uid's `HandleLower` against the profile it loads for that uid (via
       `identity.Directory.GetProfiles`, cache-first) or shorten the positive handle TTL to 10 s. Test the freed and
       reclaimed case. **Superseded, if the founder accepts it, by ADR-0010 D21 G5 (proposed 2026-10-01):** do
       both, with the 10 s bound as the guarantee. A profile cached before the rename confirms the stale mapping, so
       the profile check alone is unsound, and loading mentioned profiles would add up to 10 reads.
       1. In `ResolveHandles`, a cached positive entry is a hit only if it is ≤ 10 s old (reuse `notFoundTTL`; the
          handle cache stores `{uid, at}`). Older entries are misses in the same single `GetAll`. GetProfile by
          handle keeps 60 s.
       2. If the uid's profile is already in the instance profile cache (a peek, 0 reads) and its `HandleLower`
          differs from the candidate, treat the candidate as a miss.
     - **More than 10 handles.** `ResolveHandles` returns an untyped error above `identity.MaxResolveHandles`
       distinct handles. T8 must truncate to 10 after dedupe (the parser already caps at `text.MaxMentions`) and
       test 11 mentions.
     - **Lower-casing order.** `ResolveHandles` lower-cases before `handleFormatIssue`, the reverse of the other
       identity paths (validate the raw input first). T8 passes parser output, which is already lower-case and
       valid, so it is unaffected; do not copy the order elsewhere, and prefer validating raw input first if
       `ResolveHandles` is touched.
     - **`allowAnonymous`.** T8 must receive it only through an option wired from `cfg.AuthEmulator` (as
       `identity.WithAllowAnonymous` does), never from a request or a global, and needs a guard test that
       `apiserver.Build` wires it from `cfg.AuthEmulator` and that the default is false.
- **Acceptance criteria.**
  - Given valid text, then `posts/{id}` has the ADR-0003 shape, `users.postsCount` +1, `quotas.posts` +1, and exactly
    one `idempotency` doc with `expireAt` 24 h out.
  - Given the same key replayed (sequentially or concurrently ×10), then exactly one post exists and each response has
    the same `post_id`.
  - Given the same key with different text, then `IDEMPOTENCY_KEY_REUSED` is returned with 0 writes.
  - Given `quotas.posts = 100` (or 20 for an account < 24 h old), then `QUOTA_EXCEEDED` is returned with
    `metadata.quota=posts` and 0 entity writes.
  - Given "@ghost" (no such handle), then the post is created and `mentions` is empty. Given "@bob" where bob blocked
    the author, then `mentions` excludes bob. Given the author's `blockedByOverflow` = true, then `mentions` is empty.
  - Given text with no `@` candidate, then the author graph is not read.
  - **D21 delta (if G1/G5 are accepted):**
    - Given `https://ex.com/?ref=@bob` (bob exists), then `mentions` is empty, and 0 `handles/*` and 0 `graph`
      reads happen.
    - Given bob renames to bob2 and carol claims `bob`, with instance B holding `bob → bob2's uid` in its cache: a
      CreatePost "@bob" on B after 11 s (fake clock) stores carol's uid. At 9 s with B's profile cache showing
      `HandleLower=bob2`, it also stores carol's uid, at 1 extra handle read. At 9 s with no cached profile, the
      stale mapping is the accepted residual: assert it and name it in the test.
    - Log `mentions_in_url` (a count) next to `mentions_dropped`.
  - Given `media_ids`, `reply_to_post_id` or `quote_of_post_id` set, then `FEATURE_DISABLED` with
    `metadata["feature"]` = `media`, `replies` or `quotes` respectively, even if the text is invalid, with 0 reads.
    Given both reply and media, then `feature=replies`.
  - Given a transaction whose first attempt aborts, then the committed post's id (and `createdAt`) comes from the
    retrying attempt, not the first.
  - Given `TIMELINE_SETTLE_WINDOW` < 15 s (3 × the 5 s transaction deadline), then startup fails fast.
- **Test notes.** `budgettest.Assert` (D17): ≤ 14 R cold / 2 R warm, 4 W; replay and reused key ≤ 14 R cold / 1 R
  warm, 0 W.
- **Observability.** `posts_op=create`, `outcome=created|replay|rejected:<reason>`, `mentions_resolved`,
  `mentions_dropped`, `hashtags_count`, `text_len`, `txn_attempts` (WARN if > 3), `feature` on a sub-feature rejection.
  Never log text, handles, hashtags or mention lists (D20).
- **Budget.** 14 cold / 2 warm / 2.5 planning R, 4 W, +1 eventual TTL delete.
- **Status: built (branch claude/gracious-babbage-2barib).** Decisions recorded for the PR:
  - **Stale handle cache (G5):** both halves are in `identity.ResolveHandles` (10 s positive bound via `handleEntry{uid, at}`,
    plus a 0-read profile-cache peek). The residual (rename + reclaim within 10 s on another instance) is asserted and named in
    `resolve_handles_g5_test.go`.
  - **More than 10 handles:** the parser caps at 10 and `resolveMentions` truncates again as a backstop (unit test with 11).
  - **Lower-casing order:** untouched; CreatePost passes parser output.
  - **`allowAnonymous`:** `posts.WithAllowAnonymous` option, wired only as `posts.WithAllowAnonymous(cfg.AuthEmulator)` in
    `apiserver.Build`; default false (unit test) and a source guard `apiserver/posts_anonymous_test.go`.
  - **Settle window:** `TIMELINE_SETTLE_WINDOW` (default and floor 15 s) added to `config.Load`, with tests. T11 reads
    `cfg.TimelineSettleWindow`.
  - **Author profile eviction:** after a commit `Directory.Forget(author)` (as in graph), so the next request on that instance
    pays the interceptor's profile read (cold). The warm figures above assume the profile is cached.
  - Measured on the emulator (`create_integration_test.go`, no interceptor read in the harness): warm 2 R / 4 W; replay warm 1 R /
    0 W; reused key 1 R / 0 W; 3 mention candidates 6 R; cold ceiling with 10 uncached handles 14 R (author profile 1 + graph 1 +
    handles 10 + idempotency 1 + quotas 1) / 4 W. The real interceptor read of the caller's `users` doc is the same
    document as the author profile that `Create` reads through the profile cache (the interceptor has just warmed it),
    so the real cold ceiling is still 14, not 15: the documented 14 counts that one read once.

### T9 — DeletePost + GetPost  [owner: backend-developer] [size: S] [depends: T5]
- **Description.**
  - **DeletePost (ADR-0010 D4):**
    - `post_id` must match `^[0-9]{19}$`, else VALIDATION `field=post_id`, 0 reads. `idempotency_key` is validated
      for format only and is not stored (the operation is state-setting).
    - Read the post: cache first, else 1 read.
    - The caller is the author → a batch: `Delete(post, Exists)` + `AddPostsCount(−1)`. On an `Exists` failure at
      commit (a concurrent delete won), return success with 0 writes.
    - **Every other case (another user's post, unknown id, already deleted) → success with 0 writes.** The response and
      timing class (1 read, no batch) are identical, so there is no existence or block oracle.
    - After a commit:
      - evict the post from this instance's posts cache and the author's author-recent entry;
      - call `Directory.Forget(author)` (`postsCount` changed by a blind increment, ADR-0008 B2);
      - call `PostEvents.Deleted` (a no-op).
  - **GetPost (D6 GetPost column):**
    - the post (cached);
    - the author profile (status) via `identity.Directory`. SUSPENDED, DELETING or a missing `users` doc →
      NOT_FOUND;
    - `author ∈ caller.blockedBy` → NOT_FOUND. If the caller's `blockedByOverflow` is set, do +1 read of the author's
      graph; `caller ∈ author.blocked` → NOT_FOUND;
    - the caller blocked or muted the author → return the post (the client shows the blocker banner; mute is silent).
    - Every NOT_FOUND is code NOT_FOUND, reason UNSPECIFIED, message `post not found`, byte-identical across missing,
      deleted and hidden.
    - Filters use only `graph.Reader.Snapshot` (never a direct `graph/*` read, ADR-0008 D9).
  - **GetUserTimeline's missing-user error** comes from identity's constructor through identity's package API (the
    same bytes as GetProfile). T9 exposes it for T12; don't copy the string.
- **Acceptance criteria.**
  - Given own post, then the doc is gone, `postsCount` −1, and a second DeletePost does 0 writes and returns success.
  - Given 5 concurrent deletes of the same post, then `postsCount` decrements exactly once.
  - **Given someone else's post, then DeletePost returns success with 0 writes and 0 deletes, byte-identical to an
    unknown id and to an already-deleted id.** The post still exists afterwards.
  - Given `post_id = "abc"`, then VALIDATION `field=post_id` with 0 reads.
  - Given the author blocked the caller, then GetPost is NOT_FOUND, byte-identical to a deleted post and to a
    suspended author's post.
  - Given the caller's `blockedByOverflow` = true and the author blocked the caller, then GetPost is NOT_FOUND with
    exactly 1 extra read.
  - Given a deleted post, then GetPost is NOT_FOUND within 60 s on every instance.
- **Test notes.** Budgets (D17): Delete ≤ 2 R cold / 0 warm, 1 W / 1 D (no-op: 0 W / 0 D); GetPost ≤ 4 R cold
  (+1 overflow) / 0 warm. Race test on the emulator.
- **Observability.** `posts_op=delete|get`, `outcome=deleted|noop|noop:not_owner|found|not_found`,
  `posts_cache_hit`. `noop:not_owner` feeds abuse review.
- **Budget.** As the table.
- **Status: built (branch claude/gracious-babbage-2barib).** `Service.Delete` / `Service.GetForViewer` (`service_delete.go`),
  `FirestoreRepo.DeleteOwn` (`repo_delete.go`), handlers in `server.go`, `identity.ProfileNotFoundError` for T12. Decisions:
  - **Order of validation:** `post_id` (`^[0-9]{19}$`, VALIDATION `field=post_id`) first, then `idempotency_key` format; both
    0 reads. GetPost also rejects a malformed id with VALIDATION (0 reads); the plan only fixed this for DeletePost.
  - **Lost races:** the batch counts its writes on a scratch counter, merged only on success, so a lost `Exists` race reports
    0 W / 0 D. An `Aborted` (lock contention on the author's `users` doc from the concurrent `postsCount` increments) is retried
    up to 4 times with 25 ms steps; the retry then loses the `Exists` check and ends as a no-op.
  - **Non-public visibility:** a FOLLOWERS post is NOT_FOUND unless the caller is the author or follows the author (fail
    closed; unreachable in P1 since only PUBLIC is written).
  - **Own post in GetPost:** skips the caller's graph read (a user is never blocked by themselves): 2 R cold instead of 3.
  - Measured on the emulator (`service_delete_integration_test.go`, interceptor read not included): DeletePost own cold 1 R / 1 W /
    1 D, own warm 0 R / 1 W / 1 D, not-owner or unknown or repeat 1 R / 0 W / 0 D; 5 concurrent deletes: 1 W / 1 D in total,
    `postsCount` decremented once. GetPost cold 3 R (post, author, caller graph), warm 0 R, overflow 4 R, 0 W.

### T10 — `posts.Eraser` + exporter + `opsctl` + account-deletion runbook  [owner: backend-developer] [size: S] [depends: T8, T9]
- **Description.**
  - `Eraser.PurgeUser(ctx, uid, checkpoint)`:
    - `posts where authorId == uid order by createdAt desc, __name__ desc limit 500` pages (ADR-0010 D19 Q-E). The
      query is **descending** so it uses the existing `(authorId ASC, createdAt DESC)` index; an ascending order would
      need a new index. It is self-resuming, because deleted docs drop out of the next page;
    - batched deletes (≤ 500);
    - resumable; no counter updates (the user doc is deleted anyway).
    - The `Limit(500)` is an ops path (ADR-0003 purge rule). Rule 5's max 50 governs RPC pagination only.
  - `Exporter.ExportUser(ctx, uid, w)` writes JSON: id, text, createdAt, hashtags, mentions (handles only).
  - Add `opsctl purge-posts|export-posts`, the same flags and guards as `purge-graph` (`cmd/opsctl/main.go:75-95`).
  - Update `docs/runbooks/account-deletion.md`: purge-posts **before** purge-graph, and export-posts in the export
    steps. Rule 10: every collection has a right-to-delete path.
- **Acceptance criteria.**
  - Given U with 1,203 posts, when purge runs and is killed after the first batch, then a re-run with the checkpoint
    completes and no `posts` doc has `authorId == U`.
  - Given `--dry-run`, then only counts are printed and there are 0 writes.
  - Given `opsctl` without `--project`, then it exits non-zero.
  - Given the emulator with `firestore.indexes.json` loaded, then the purge and export queries run with no
    missing-index error and no change to `firestore.indexes.json`.
  - Given the runbook, then the order is purge-posts before purge-graph and before deleting `users`.
- **Test notes.** An emulator crash-resume test (reuse graph's T11 harness; no second harness).
- **Observability.** `posts_purge_batch` with counts.
- **Budget.** O(posts) reads and deletes, once per deletion: a 300-post user costs ≈ 300 R and 300 D.
- **Status: built (branch claude/gracious-babbage-2barib).** `posts/purge.go` (`PurgeUser`, `PlanPurge`, `ExportUser` on
  `FirestoreRepo`), `opsctl purge-posts|export-posts`, runbook updated. Decisions:
  - **Same guards as purge-graph:** `--project` required, `*-prod` typed confirmation, `--dry-run`, and the DELETING >= 120 s
    start gate with `--skip-start-gate`. The retry/give-up loop and the `--out` writer were extracted from the graph code
    (`purgeLoop`, `writeOut`), so there is one policy for both purges.
  - **Dry run** uses a `count()` aggregation limited to 100,000 (billed 1 read per 1,000 index entries, minimum 1), prints
    `dry-run: posts=N (nothing written)`.
  - **Done condition:** a page of fewer than 500 posts ends the purge (the account is DELETING, nothing new arrives), so a
    user with 1,203 posts costs 3 calls, 1,203 R, 1,203 D, 0 W. A user with no posts costs 1 R.
  - **Deletes are not preconditioned** (a concurrent run deleting the same doc is harmless); no counter updates.
  - **Export** streams `{"userId","posts":[{id,text,createdAt,hashtags,mentions(handles only)}]}`, newest first, 500 per page.
  - The emulator does not enforce composite indexes; the queries are Q-E (`authorId ==` + `createdAt DESC, __name__ DESC`),
    which the existing `(authorId ASC, createdAt DESC)` index serves, and `firestore.indexes.json` is unchanged.
  - Measured (`TestPurge_Integration_CrashResume`, `TestExport_Integration`): purge of 1,203 posts killed after the first
    batch and resumed with the checkpoint: 1,203 R / 0 W / 1,203 D, no `authorId == U` doc left, another user's 7 posts kept;
    dry run 2 R max, 0 W; export 1,203 R + 1 (the final empty-page check is skipped when the last page is short, so 1,203 R).

### T28 — `pkg/platform/cursor`: two-bound `Window` tokens + TTL-aware decode  [owner: backend-developer] [size: S] [depends: T1]
- **Description.** Extend the existing package (ADR-0010 D14; reuse-first, no new package):
  - `type Window struct { Upper Cursor; Lower *Cursor }` with `EncodeWindow` / `DecodeWindow`. These use the same
    AES-GCM sealing and binding-as-additional-data as `Encode`. The plaintext gains an optional lower `(createdAt,
    docId)` pair.
  - A TTL-aware decode (`DecodeAt(…, ttl)` or a functional option) usable for both `Cursor` and `Window`, so timeline
    callers can pass `TIMELINE_TOKEN_TTL` (720 h).
  - `Encode`/`Decode` and their 24 h default stay **byte-for-byte compatible**, so graph list tokens already issued
    keep decoding.
  - Add the config key `TIMELINE_TOKEN_TTL` (default `720h`) to `config.Config` (rule 11). T11 consumes it.
    **Follow-up (T4/T28 notes), done:** `config.Load` also rejects values above `MaxTimelineTokenTTL` (2160h = 90
    days) so a typo cannot make timeline tokens effectively immortal.
  - Update `docs/code-map.md`.
- **Acceptance criteria.**
  - Given a Window with and without a Lower bound, when encoded and decoded with the same binding, then it round-trips
    exactly (property test over random `(createdAt, docId)` pairs).
  - Given a Window token decoded with a different binding, or with any byte flipped, then decode fails.
  - Given a `Cursor` token presented to `DecodeWindow` (and vice versa), then decode fails. A since-token can never
    be used as a page token.
  - Given a TTL of 720 h, then a token aged 720 h − 1 s decodes and one aged 720 h + 1 s fails. Given the default
    decode, then the 24 h expiry is unchanged.
  - Given a graph token produced by the pre-change `Encode` (golden fixture), then it still decodes.
- **Test notes.** Unit tests with a fake clock. Golden fixtures for the old format. `go test -fuzz` on
  `DecodeWindow` for panics.
- **Observability.** —
- **Budget.** 0 (pure, no I/O).

### T11 — Timeline core (pure): chunking, exact-prefix merge, tokens, gap, settle watermark  [owner: backend-developer] [size: M] [depends: T5, T28]
- **Description.** Create `backend/internal/timeline` with a pure `merge.go` + `tokens.go` + `watermark.go`,
  implementing ADR-0004 Decision 1–3 exactly:
  - chunks of 30 (followees + self);
  - `k = max(1, ceil(2·page/C))`;
  - the exact-prefix cut at `B`, where an author covered by author-recent is a pseudo-chunk and a truncated entry
    counts as "filled" (ADR-0010 D15);
  - the `gap_page_token` when any chunk filled `k` on a refresh.

  **T28 carry-over:** the cursor codec does not order the two bounds of a `cursor.Window`. T11 must treat a Lower
  bound that is `>=` Upper (by `(createdAt, postId)`) as "lower bound reached" (no next page), never as an error.
  `TIMELINE_TOKEN_TTL` is `config.Config.TimelineTokenTTL` (T28 adds it; default 720h, must be >= 24h).

  **Tokens (ADR-0010 D14)** use the T28 cursor extension, sealed with the existing cursor key and with a TTL of
  `TIMELINE_TOKEN_TTL` (default **720 h = 30 days**). Bindings (AEAD additional data):

  | Token | Binding | Payload |
  |---|---|---|
  | Home `since_token` | `tl\|home\|{caller}\|since` | Cursor |
  | Home `next_page_token` / `gap_page_token` | `tl\|home\|{caller}\|page` | Window: Upper = the oldest item returned; Lower = the old since (gap) or none (scroll) |
  | User `since_token` | `tl\|user\|{caller}\|{target}\|{posts\|replies}\|since` | Cursor |
  | User `next_page_token` / `gap_page_token` | `tl\|user\|{caller}\|{target}\|{posts\|replies}\|page` | Window |

  - **Gap close rule:** a page whose Window has a Lower bound stops at it. Its `next_page_token` carries the same
    Lower bound and is `""` once the lower bound is reached. No item ≤ the old since is ever read.
  - **Settle watermark (ADR-0010 D13),** as a pure function:
    - `W = min(request start, loadedAt of every author-recent entry used) − TIMELINE_SETTLE_WINDOW` (default 15 s);
    - `since_new = max(since_old, min(newest returned, W))`, compared as `(createdAt, postId)` tuples;
    - when W is smaller, encode `(W, "0000000000000000000")`;
    - an empty refresh still advances to `max(since_old, W)`.
  - **Rejections:** an expired, tampered, foreign-caller or wrong-kind token → INVALID_ARGUMENT + `VALIDATION` with
    `field` = `since_token` or `page_token`, 0 reads. Both tokens set → VALIDATION `field=page_token`.
- **Acceptance criteria.**
  - Given adversarial chunk distributions (one chunk with 1,000 recent posts and others sparse; ties on `createdAt`),
    then the merged output is a strict `(createdAt, postId)`-descending prefix of the true merge, with no duplicates
    or gaps across successive pages (property test).
  - Given a refresh where a chunk hit `k`, then `gap_page_token` is set and its Lower bound is the old `since`.
    Following it (and its `next_page_token`s) never returns an item ≤ the old `since` and ends with `""`.
  - Given a tampered token, a token issued to caller B presented by A, a home token on the user timeline (or vice
    versa), a `since` token as `page_token` (or vice versa), or a Posts-tab token on the Replies tab, then VALIDATION
    with the right `field`.
  - Given a token aged 30 d − 1 s, then it is accepted. At 30 d + 1 s, then VALIDATION.
  - Given `newest returned` later than W, then `since_new` encodes W. Given it earlier, then it encodes the newest
    item. Given an empty result, then `since_new = max(since_old, W)`. Given an author-recent entry loaded 40 s ago,
    then W ≤ its `loadedAt` − 15 s.
- **Test notes.** Property-based tests (`testing/quick` or rapid) over random chunk sets. This is the ADR-0004
  handoff requirement. Table tests for every binding pair and for the watermark (fake clock).
- **Observability.** —
- **Budget.** 0 (pure).
- **Status: built (branch feat/timeline-t11-t13).** `merge.go` (`Merge`, `Source`, `Page`, `Compare`), `tokens.go`
  (bindings, `codec`, closed-gap rule), `watermark.go` (`Watermark`, `NextSince`). Decisions recorded for the PR:
  - **`Merge` takes a `keep` filter and returns `Newest`/`Last`/`HasMore`.** The bound B is computed on the unfiltered
    chunk results; filtering and the limit cut come after it. `Last` is the last *examined* item (or the last returned one
    after a limit cut), so a page of mostly filtered posts never re-reads the filtered ones. `Newest` (pre-filter) feeds
    the watermark.
  - **Gap on refresh = `HasMore`,** not only "a chunk filled k": with C = 1, k = 2p and more than p new posts a limit cut
    also leaves items above the old since. A covered author (author-recent) is never "filled": coverage already requires
    a complete entry or one that reaches the lower bound.
  - **Page responses carry no `since_token`** (cold and refresh only); the Flutter store ignores an empty one.
  - Property tests (`merge_test.go`) walk adversarial chunk sets (1,000-post chunk, sparse chunks, ties) through pages,
    gap walks and filtered walks and compare with the true merge.

### T12 — GetUserTimeline  [owner: backend-developer] [size: S] [depends: T11]
- **Description.**
  - Target profile via `identity.Directory`: missing, not ACTIVE, or `target ∈ caller.blockedBy` → NOT_FOUND, using
    identity's missing-user error through its package API (NOT_FOUND, UNSPECIFIED, `profile not found`; the same
    bytes as GetProfile). If the caller's `blockedByOverflow` is set, do +1 read of the target's graph (ADR-0010 D6).
  - **`posts.Reader.ByAuthor(target, include_replies, window, Limit(page_size))`, not `page_size+1` (ADR-0010 D16).**
    A full page always returns `next_page_token`. The only extra cost is one empty final call (1 read) when the total
    is an exact multiple of the page size.
  - `include_replies=false` (Posts tab) queries `authorId == B AND isReply == false`. `true` (Replies tab) queries
    `authorId == B` with no `isReply` filter (D11).
  - Clamp with `limits.ClampPageSize`.
  - **Posts-tab first page from the author-recent cache** (D15; there is no separate profile-first-page cache):
    - `page_size ≤ 20` is served from a fresh entry;
    - on a miss, fill the entry with a `Limit(20)` query;
    - larger page sizes query directly.
  - `since_token` uses the T11 settle watermark (D13). Tokens use the T11 bindings.
  - Muted authors are shown and blocked-by-caller authors are returned (D6); the client shows a banner.
- **Acceptance criteria.**
  - Given since, page or gap tokens, then they are decoded with `cfg.TimelineTokenTTL` via `cursor.DecodeTTL` /
    `cursor.DecodeWindow`, never `cursor.Decode` / `cursor.DecodeAt` (their 24 h TTL would turn every morning
    refresh into a cold open). Test with a token older than 24 h (accepted) and one older than the TTL (rejected).
  - Given 45 posts, then pages of 20 cover all 45 exactly once, stable under concurrent new posts.
  - Given exactly 40 posts and pages of 20, then page 2 returns a `next_page_token`, and page 3 returns 0 items,
    `next_page_token = ""`, and costs 1 query read.
  - Given `since_token` with 0 new posts, then reads ≤ 4 cold (3 + 1 empty query), 0–1 warm.
  - Given the author blocked the caller, then NOT_FOUND, byte-identical to a missing user and to a suspended user.
  - Given a cold page of 20, then reads ≤ 23. At page 50, reads ≤ 53 (`3 + max(p, 20)`, +1 on overflow).
  - Given a warm Posts-tab first page, then reads = 0 and `timeline_cache_hit=true`.
- **Test notes.** Budget assertions per D17; the ADR-0010 D6 matrix, GetUserTimeline column (every row, including
  the overflow and both-block rows).
- **Observability.** `timeline_op=user`, `timeline_mode`, `fs_reads`, `timeline_cache_hit`, `items_returned`,
  `since_clamped`, `page_size`.
- **Budget.** 3 + max(p, 20) cold (53 at p 50) / 0 warm / 11 planning.
- **Status: built (branch feat/timeline-t11-t13).** `internal/timeline/service.go` `user`, `server.go`
  `GetUserTimeline`. Decisions recorded for the PR:
  - `identity.ProfileNotFoundError()` is a new exported wrapper over identity's private `notFoundErr()`, so the missing /
    non-ACTIVE / blocking-target answer is byte-identical to GetProfile without copying the string. The timeline import
    lint now allows `identity.Directory`, `Profile`, `AccountStatusActive`, `ProfileNotFoundError`, `ValidUserID` and
    `posts.ToProto`.
  - Own timeline (`target == caller`) skips the caller graph read (a caller cannot block or be blocked by self).
  - Posts-tab first page: `page_size <= 20`, no tokens, entry fresh and (complete or at least `page_size` posts).
    A refresh is also served from a fresh entry when it is complete or reaches the old since (0 reads).
  - Integration tests live in `internal/timeline/integration` (own directory, so the lint on `internal/timeline`
    still covers every file there).

### T13 — GetHomeTimeline  [owner: backend-developer] [size: M] [depends: T11, T12]
- **Description.** ADR-0004 Decision 1–9, minus the viewer flags (Q3):
  - `graph.Reader.Snapshot(caller)`;
  - **author-recent coverage (ADR-0010 D15):** an author is covered if the entry is fresh (< 60 s) and either
    `truncated == false` or it holds an item at or below the window's lower bound. Covered authors are removed
    **before** chunking, so reads drop to `ceil(uncovered/30)` queries. Each is merged as a pseudo-chunk;
  - chunk the uncovered followees + self;
  - `errgroup` with ≤ 4 in flight;
  - merge (T11);
  - drop `blocked`, `muted` and `blockedBy` authors, even if a stale `following` still lists them. Suspended or
    deleting authors are **not** filtered (D10);
  - on a cold open, give every author in a chunk that did not fill `k` an author-recent entry with `truncated=false`,
    empty ones included;
  - compute `since_token` with the T11 settle watermark, lowering W by the `loadedAt` of every entry used (D13);
  - return tokens (T11 bindings).

  The per-RPC deadline is 10 s. The following cap of 5,000 already exists (graph).
- **Acceptance criteria.** From the ADR-0004 tester handoff, with the ADR-0010 D17 convention:
  - Given since, page or gap tokens, then they are decoded with `cfg.TimelineTokenTTL` via `cursor.DecodeTTL` /
    `cursor.DecodeWindow`, never `cursor.Decode` / `cursor.DecodeAt` (24 h would turn every morning refresh into a
    cold open). Test with a token older than 24 h (accepted) and one older than the TTL (rejected).
  - Given a refresh with 0 new posts, author-recent empty (or disabled) and the graph warm, then reads == C (+1 if
    the interceptor is cold).
  - Given F = 60, page 20, then cold reads ≤ 2 + 3·14 = 44.
  - Given A muted B, then B's posts never appear in A's home. Given B blocked A, then B's posts never appear in A's
    home, even if A's following still lists B (a stale cache).
  - Given F = 5,000 (a seeded graph doc), then worst reads ≤ 269 (`2 + C + 2p`) and latency is < 2 s on the emulator
    (noted as local).
  - Given the caller just posted on this instance, then the post appears on the next refresh with 0 extra reads
    (author-recent updated in place).
  - **D13 regression:** given (fake clock) a post committed with `createdAt` older than an item already returned by a
    previous refresh, then the next refresh delivers it.
  - Given a refresh that returned items newer than W, then `since_clamped=true` is logged, and the next refresh
    returns those items again (the client dedupes).
- **Test notes.** Budget assertions at F = 0, 60, 300 and 5,000; the chunk-boundary case F = 29/30/31; the D6 matrix
  home column.
- **Observability.** `timeline_op=home`, `timeline_mode=cold|refresh|older|gap`, `timeline_chunks`,
  `authors_from_cache`, `items_returned`, `items_filtered`, `fs_reads`, `gap`, `since_clamped`, `page_size`.
- **Budget.** 2 + C + 2p = 269 cold at F = 5,000 / refresh planning 4 overhead + new posts (+ ≈ 0.1 settle re-read) /
  older page 30 / cold open 30.
- **Status: built (branch feat/timeline-t11-t13).** `internal/timeline/service.go` `home`/`homeSources`,
  `server.go` `GetHomeTimeline`, wired in `apiserver.Build` (`Directory`, `CursorKey`, `TokenTTL`, `SettleWindow`).
  Decisions recorded for the PR:
  - Blocked, muted and blocked-by authors are removed from the author list **before** chunking (cheaper than the
    plan's post-merge drop, same result; a `keep` filter in `Merge` stays as defence in depth). C and k use the
    chunks actually queried (`ceil(uncovered/30)`), `k` is capped at the repo's 50 and "filled" is judged against it.
  - A cold-open page can be short (ADR-0004 exact-prefix cut): F = 60, p = 20 returned 14 posts in the emulator test;
    the client follows `next_page_token`.
  - `golang.org/x/sync` moved from indirect to direct in `go.mod` (errgroup, limit 4).
  - `userLikes` / viewer flags are not read (D3): `liked_by_viewer` is always false.

### T14 — Flutter: repositories, drift timeline store, flag plumbing  [owner: frontend-developer] [size: M] [depends: T2]
- **Description.**
  - Check `docs/ui-catalog.md` first. Reuse `ApiClient`, `guardApiCall`, `mapConnectError`, `AppDatabase` and
    `isGraphEnabled` (generalise it to `isFeatureEnabled(name)` rather than copying it).
  - Add `features/posts/data/posts_repository.dart` and `features/timeline/data/timeline_repository.dart`, using the
    generated clients (`app/lib/gen/dzeroth/{posts,timeline}`).
  - Add drift tables in the existing `AppDatabase`:
    - `timeline_items` (feed key, post id, serialized `PostView`, sort key);
    - `timeline_state` (feed key, `since_token`, gap tokens).

    Retention: the newest 500 items per feed. Tokens persist across days (their TTL is 30 days, ADR-0010 D14).
  - **Dedupe by `post_id` on every merge** (refreshes may repeat items from the settle window, D13).
  - **Rejected token (D14):** on INVALID_ARGUMENT + VALIDATION with `field` = `since_token` or `page_token`, drop that
    token, cold-open, and treat the cold page's `next_page_token` as the gap filler. Stop merging when a cached
    `post_id` is reached.
  - **Sub-feature flags (D2):** FEATURE_DISABLED with `metadata["feature"]` hides only that sub-feature (`replies`,
    `quotes`, `media`). An absent `feature` hides all of posts.
  - Add `kFeaturePosts`.
  - Update `ui-catalog.md`.
- **Acceptance criteria.**
  - Given a cached feed, when the app cold-starts offline, then cached items render with no network call.
  - Given a refresh response with `gap_page_token`, then a gap marker row is persisted at the right position.
  - Given a refresh that returns a `post_id` already cached, then the feed holds it once, at its sort position.
  - Given a refresh rejected with `field=since_token`, then the stored `since_token` is cleared, exactly one cold-open
    call is sent, and cached items stay visible.
  - Given a post NOT_FOUND on open, then it is removed from every cached feed.
  - Given the flag is off, then no posts or timeline RPC is ever called.
  - Given FEATURE_DISABLED with `feature=media`, then posts stay enabled.
- **Test notes.** Repository tests with fake clients and an in-memory drift database; a migration test from the
  current schema version.
- **Observability.** Crashlytics non-fatal on unexpected `AppException`.
- **Budget.** The client never refetches items it has. Each refresh sends `since_token`.
- **Follow-ups from the PR #75 review (not in T14, track here).**
  - M3: `refresh` decodes the whole feed twice (`read` before and after). Add `TimelineStore.state()` and `gapRow()`
    for the pre-fetch lookups, and use `selectOnly` in `_postIds`.
  - M4: wire `PostsFeatureGate.onUnexpectedError` to error reporting (Crashlytics) in `bootstrap.dart`.
  - Privacy ticket (separate small PR after #75 merges, CLAUDE.md rule 10): `graph_repository.dart` `upsertFollowing`
    (after an in-flight Follow) and `identity_repository.dart` `upsertProfile` (after an in-flight GetMe) have no session
    guard, so a stale write can land in the next user's cache. Move the session counter onto `AppDatabase` (or a shared
    `SessionEpoch`) and check it inside write transactions for `TimelineStore`, `GraphRepository` and `IdentityRepository`.
  - L1, L4 and the remaining L6 test gaps from the review: pick them up with T17's repository use.

### T15 — Flutter: shared `PostCard` with rich text  [owner: frontend-developer] [size: M] [depends: T14]
- **Description.** `app/lib/shared/widgets/post_card.dart`:
  - author avatar/name/@handle from the snapshot (tap → profile by **user_id**);
  - relative time;
  - text with tappable mentions and hashtags (a no-op/"coming soon" until Phase 2). Mention spans match
    `mentions[].handle` (stored lower-case) **case-insensitively**, and a tap navigates by `mentions[].user_id`
    (ADR-0010 D7);
  - links opened with `url_launcher` in the external browser, `http(s)` only. Never render HTML.
  - An overflow menu: Delete (own posts, with a confirmation) and "Block @x" / "Mute @x", reusing `RelationshipCubit`
    and `showBlockConfirmationDialog`.
  - A counts row hidden until P5.
  - Theme tokens only.
- **Acceptance criteria.**
  - Given text "hi @bob see https://x.y #go", then exactly 3 spans are tappable and the link opens externally.
  - Given text "@Bob" with `mentions = [{handle: "bob"}]`, then "@Bob" is tappable. Given "@carol" with no `mentions`
    entry, then it is plain text.
  - Given `javascript:alert(1)` in the text, then it is plain text (not a link).
  - Given own post, then the overflow shows Delete. For another author's post it shows Block/Mute.
  - Given phone and desktop widths, then there is no overflow.
- **Test notes.** Widget tests for each state; a golden test is optional.
- **Observability.** —
- **Budget.** 0 RPCs (display only).
- **D21 delta (proposed 2026-10-01; only once the founder accepts G1; merge before T8).** The parser was merged as
  PR #80; this is a follow-up PR on `app/lib/features/posts/domain/post_text_parser.dart` and its test.
  - Exclusion runs over **every syntactic URL span** (ADR-0010 D7 "URL spans"), not only over links that pass
    `_isSafeLink`, the spoofing check or the whole-post bidi check. An unsafe span renders as plain text, with no
    mention or hashtag inside it. Span detection runs even when the post has bidi controls (`allowLinks == false`).
  - The terminator set stays ECMAScript `\s` plus `<>"`, which `[^\s<>"]` already is. Add a comment naming D7 so
    nobody "simplifies" it.
  - The test loads `../testdata/post_text_grammar.json` and runs every `grammar` row: mention spans (fed back as
    resolved `pb.Mention`s), hashtag spans and `tappable_links`. It asserts the row count. Grammar rows that are
    duplicated inline in the test move to the fixture.
  - **Acceptance criteria.**
    - `https://ex.café/?r=@bob` with `mentions=[bob]` → one plain span, nothing tappable.
    - `https://google.com@evil.com/x @bob` → only `@bob` is tappable.
    - `؜ https://ex.com/?r=@bob` with `mentions=[bob]` → nothing tappable.
    - Every fixture row passes.
  - **Status: built (branch feat/app-t16-composer; analyze clean, tests pass).** The parser excludes
    `@`/`#` candidates inside every syntactic URL span (unsafe spans render as plain text; detection runs even with bidi
    controls). `post_text_parser_test.dart` runs every `grammar` row of `testdata/post_text_grammar.json` and asserts
    the row count; the grammar rows that were duplicated inline were removed.

### T16 — Flutter: composer  [owner: frontend-developer] [size: M] [depends: T15]
- **Description.**
  - A compose sheet/route with a 280 code-point counter (ADR-0010 D9):
    - apply D9 step 2 (`\r\n`/`\r` → `\n`, `\t` → space) and step 4 (trim);
    - NFC via an NFC package (for example `unorm_dart`, reuse-first: check `pubspec.yaml`);
    - count `runes.length`.

    Share the rule through a documented constant, not a copy of the server regex. The server stays authoritative.
  - Disable Post when the text is empty, over 280 code points or over 10 lines.
  - One UUID idempotency key per intent, reused on retry.
  - Optimistic insert at the top of Home and the own profile. Roll back on error.
  - Friendly errors: `EMAIL_NOT_VERIFIED` (reuse `VerifyEmailView`), `QUOTA_EXCEEDED`, `RATE_LIMITED`,
    `DEGRADED_MODE` (never auto-retried), and `FEATURE_DISABLED`.
- **Acceptance criteria.**
  - Given a network error and a retry, then the same idempotency key is sent, and only one post appears after
    success.
  - Given `QUOTA_EXCEEDED`, then the optimistic item is removed and a snackbar shows the quota message.
  - Given 281 code points, then Post is disabled and the counter shows −1.
  - Given decomposed input (`e` + U+0301) × 280, then the counter shows 0 remaining, not −280 (it counts after NFC).
  - Given 11 lines, then Post is disabled.
  - **D21 delta (if G2/G4 are accepted):** the composer's D9 mirror maps U+2028 and U+2029 to `\n` (step 2), trims
    the D21 G4 invisible list (step 4) and uses the G4 empty predicate. Its tests run the fixture's `normalise` rows
    (`error` ⇒ Post disabled).
    - Given 10 lines joined by U+2028 plus one U+2029 line, then Post is disabled.
    - Given only U+200B/U+2060/U+FEFF (or only LRM, ZWJ or VS16), then Post is disabled.
    - Given a post ending in the England flag emoji, then the counter counts every code point and Post is enabled.
- **Test notes.** Bloc tests (optimistic path, rollback, key reuse); widget tests.
- **Observability.** —
- **Budget.** 1 CreatePost per intent.
- **Status: built (branch feat/app-t16-composer; `flutter analyze` clean, full `flutter test` passes (388 tests)).**
  - `/compose` route plus a "New post" button in `MainShell` (posts flag on, not on Settings).
  - D9 mirror `analyzePostDraft` with the D21 G2/G4 rules, run against the fixture's `normalise` rows. NFC uses
    `unorm_dart` (added to `pubspec.yaml`; `pubspec.lock` still needs `flutter pub get`).
  - `ComposerCubit` (one key per intent, reused on retry, dropped when the text changes) and `PendingPostsCubit`
    (optimistic items, rolled back on error).
  - **Carry-over to T17/T18 (done in T17/T18):** Home and the own profile's Posts tab mount `PendingPostsSection`
    above their feed (`TimelineFeedView`, `pendingAuthorId:` on the own profile).
  - **Review fixes (T17/T18 pass):** U+2028/U+2029, ZWJ/ZWNJ and the combining acute were literal invisible characters
    in `post_text_rules.dart`, `post_text_parser.dart` and two tests; they are now `\u` escapes (same behavior).

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
  - Given `RATE_LIMITED` with `metadata.limit=read_budget_daily`, then a "daily limit reached" banner shows over the
    cache, and no timeline RPC is sent before `retry_after` (ADR-0010 D5).
  - Given two refreshes that both return post X (settle window), then X appears once and the new-post pill doesn't
    count it twice.
  - Given the flag is off, then the placeholder remains.
- **Test notes.** Widget tests with a fake clock and repository: refresh throttle, gap, pagination, empty, error.
- **Observability.** —
- **Budget.** ≤ 8 refreshes + ≤ 1 older page per DAU/day on the model's usage (the client enforces the throttle).
- **Status: built (branch claude/gracious-babbage-2barib; `flutter analyze` clean, full `flutter test` passes (388 tests)).**
  - `HomeScreen` (flag on) = `TimelineFeedView` over a `TimelineCubit(FeedKey.home())`; flag off keeps the placeholder.
    `TimelineCubit`/`TimelineFeedView` are generic (T18 reuses them for `user:{uid}:posts`).
  - Cache first (`cached` once per open), then one refresh unless the feed was refreshed < 60 s ago. The stamp lives in
    `TimelineRepository.sinceRefresh` (monotonic `Stopwatch`, survives screen re-creation; this settles the wall-clock
    follow-up). Resume and a 30 s foreground tick (cancelled in the background) call `refreshIfStale`, at most one RPC per 60 s.
  - "N new posts" pill: auto refreshes hold unseen posts back (counted by `post_id`, so the settle window never counts
    twice; the viewer's own posts are not held); a pull shows them directly.
  - Auto refresh is skipped once the list holds >= `kTimelineRetention` rows (reviewer contract: the store trims there).
  - `RATE_LIMITED`: the repository remembers the last non-in-flight answer (`rateLimitedFor`, default 5 min daily / 30 s
    otherwise when `retry_after` is missing); the cubit sends no timeline RPC while it holds and shows a notice banner over
    the cache (blocking error only with an empty cache). The `read_budget_inflight` retry stays in `InflightRetryInterceptor`.
  - Gap rows (`fillGap`, one call), infinite scroll prefetch at 70 % with no retry after a failure until the user taps
    Retry, relative times re-rendered by the tick (no RPC), Block/Mute hide and Unblock/Unmute restore the author locally
    (`onRelationshipChanged` acts on the cubit, never on the card's context).
  - Own post stored: Home re-reads the cache (no RPC) when a pending post leaves `PendingPostsCubit`.
  - Post cards open `/post/:id` on tap (beyond the plan; needed to reach the T18 route).
  - Not done: the empty state only suggests following people (no people-search screen exists yet); the 500-row skip is by
    cached row count, not scroll offset.
- **Review follow-ups (PR #94, 2026-10-05), done:** the Home screen hands the viewer id to the cubit when the profile loads
  (own posts are never held behind the pill); the foreground tick throttles on the last refresh *attempt*
  (`TimelineRepository.sinceRefreshAttempt`), so an outage retries once per 60 s; the feed rebuilds only when a minute
  boundary passes; the composer keeps one idempotency key per submitted text, so edit-and-revert reuses the original key.
  Flutter tests were written but not run (no Flutter SDK in the authoring container); CI is the first run.
- **Follow-up (PR #75 review, M3/M4/L1/L4/L6):** see the T14 follow-up list; T17 should call `TimelineRepository.cached` once per screen open and avoid a second full-feed decode per refresh.
- **Reviewer contract (PR #75 review, T14 -> T17).**
  - `refresh` and `insertOwnPost` trim the cached feed to about 500 rows (`kTimelineRetention`). The Home screen must
    therefore not auto-refresh on app resume while the user is scrolled past about 500 rows, or the list jumps and loses
    the user's place. Either skip the resume refresh in that state, or compact only at app start or when the feed is opened.
  - The gate refresh throttle uses wall-clock time (`DateTime.now()`), so a clock change can suppress or double a
    refresh. Follow-up: use a monotonic clock (`Stopwatch`) or a trailing refresh instead.
  - `PostCard` does not tick: relative times (`5m`) go stale while a list stays open. T17 should rebuild the visible
    cards on a minute timer (foreground only, no RPC) or pass a fresh `now` after each refresh.
  - `PostCard.onRelationshipChanged` reports Block/Mute/Unblock/Unmute results; T17 uses it to hide or restore the
    author's posts locally (D6) without a refetch. It can fire after the card is unmounted (the request outlives a
    scrolled-away card), so Home's handler must be safe then: act on the feed/store, never on the card's `BuildContext`.

### T18 — Flutter: profile Posts tab, post detail, delete  [owner: frontend-developer] [size: M] [depends: T15]
- **Description.**
  - Below `ProfileHeader` (ADR-0008 D13: the posts plan owns the body), add a Posts tab using GetUserTimeline with the
    same cache/refresh pattern (feed key `user:{uid}:posts`).
  - Hide the Replies tab until P3.
  - A blocked-by-caller banner, "You blocked @x · Show posts", computed from local relationship data (ADR-0010 D6).
    The same banner comes before a blocked author's post on `/post/:id`. Mute shows no banner.
  - A `/post/:id` route using GetPost. NOT_FOUND shows "This post isn't available" and prunes the caches (T14).
  - Delete from the overflow: optimistic removal from every feed, restored on error. **DeletePost success always
    removes the item locally** (the server returns success for not-owned or already-deleted ids too, D4).
- **Acceptance criteria.**
  - Given 45 posts, then 3 pages load with no duplicates.
  - Given Delete confirmed, then the post disappears from Home and the profile immediately, and `postsCount` in the
    header decrements.
  - Given `/post/<deleted>`, then the unavailable view renders with no retry loop.
- **Test notes.** Widget tests: own profile, other, blocked, empty, not-found.
- **Observability.** —
- **Budget.** 1 request per page; first page cached on the device.
- **Status: built (branch claude/gracious-babbage-2barib; `flutter analyze` clean, full `flutter test` passes (388 tests)).**
  - Profile (flag on): `ProfileHeader` (now with an optional "N Posts" count) + single "Posts" tab (Replies hidden) +
    `TimelineFeedView` over `FeedKey.user(uid)`. Own profile also shows pending posts and "You haven't posted yet".
  - Blocked by the viewer: "You blocked @x . Show posts" from the local relationship; the feed is **not requested** until
    "Show posts" (saves the read). Mute shows no banner.
  - `/post/:id` (`PostDetailScreen`, `PostDetailCubit`, `AppRouter.postPath`): NOT_FOUND (and a malformed id) =
    "This post isn't available" with no retry, caches pruned by `PostsRepository.getPost`; the same blocked banner
    ("Show post"), from `GraphRepository.cached`, comes first.
  - Delete: optimistic removal in the feed, restored + snackbar on error; success always removes (D4). One idempotency
    key per post until it succeeds. `PostsRepository.removedPosts` tells every mounted feed (Home under a profile or a post)
    to drop the post, and the header count decrements via `ProfileCubit.postDeleted`.
  - Delete on the post detail pops the screen.

### T19 — Emulator integration tests: posts  [owner: tester] [size: M] [depends: T8, T9, T10]
- **Description.**
  - Contract tests for CreatePost, DeletePost and GetPost: the happy path plus every documented ErrorReason.
  - `budgettest.Assert` on every call.
  - Replay with the same key (sequential and concurrent) and with a reused key and a different body.
  - Quota exhaustion + IST rollover; new-account quota.
  - Concurrent deletes.
  - A reusable **posts invariant checker**: `users.postsCount` == the count of `posts` with that `authorId` (test-only
    `count()` aggregation).
  - The ADR-0010 D6 visibility matrix for GetPost, CreatePost mentions and DeletePost: every row is a case, including
    the overflow row and both-block.
  - DeletePost on another user's post, on an unknown id and on an already-deleted id: byte-identical success, 0 writes,
    0 deletes.
  - The D7/D8 mention and hashtag example tables end to end (stored `mentions`/`hashtags`).
  - **D21 delta (if accepted):** `https://ex.com/?ref=@bob` stores no mention, with 0 `handles/*` and 0 `graph`
    reads (G1); text with U+2028 line breaks is stored with `\n` (G2); an invisible-only post is VALIDATION (G4); a
    handle freed and reclaimed is resolved to the new owner after 11 s (G5).
  - Purge crash-resume (descending query, T10).
  - Degraded readonly.
- **Acceptance criteria.**
  - Given `make test-int`, then all posts tests pass and `internal/posts` coverage is ≥ 70%.
  - Given any RPC exceeding its budget, then the test fails with the RPC name and actual vs budget.
  - Budgets asserted per ADR-0010 D17 (cold after `Reset()` of every instance cache, warm after a priming call):
    - CreatePost ≤ 14 / 2 R, 4 W; replay and reused key ≤ 14 / 1 R, 0 W;
    - DeletePost ≤ 2 / 0 R, 1 W / 1 D; no-op 0 W / 0 D;
    - GetPost ≤ 4 / 0 R, +1 on overflow.
- **Test notes.** Reuse the graph fixtures (seeding users and graph docs). Add the invariant checker to the
  `code-map.md` test-helpers section.
- **Observability.** —
- **Budget.** Not applicable (emulator).
- **Status: integration tests present and green in CI (2026-10-06).** `internal/posts/*_integration_test.go` cover CreatePost, DeletePost, GetPost, budgets, replay and the visibility matrix. A bullet-by-bullet audit of this ticket's list (IST quota rollover, new-account quota, purge crash-resume, degraded readonly) is still open.

### T20 — Emulator integration tests: timelines and read budget  [owner: tester] [size: M] [depends: T3, T12, T13]
- **Description.**
  - The ADR-0004 tester handoff, with the ADR-0010 D17 convention:
    - a refresh with 0 new posts == C, with author-recent empty and the graph warm (+1 if the interceptor is cold);
    - F = 60, p = 20: ≤ 2 + 3·14 = 44 cold;
    - "the gap token never re-reads items older than the previous since".
  - Seeded F = 5,000: home ≤ 2 + C + 2p = 269.
  - GetUserTimeline ≤ 3 + max(p, 20), including the exact-multiple final empty page (D16).
  - The D6 block/mute matrix for both timelines (every row, including overflow, both-block, suspended and deleting).
  - The **D13 regression**: a post committed with `createdAt` older than an already-returned item (fake clock) is
    delivered on the next refresh.
  - **D14 tokens:** tamper; cross-binding home↔user, since↔page, caller A↔B and posts↔replies; expiry at 30 d + 1 s
    (accepted at 30 d − 1 s).
  - T3 (ADR-0010 D5 A1–A7): the read budget rejects at the cap; the parallel-call hold never lets the counter pass
    `cap − 1 + M`; unverified password uids cost 0 reads; verified uids without a profile are charged to their /64;
    the IP budget is enforced on CheckHandleAvailability and charge-only on CreateProfile; the three account
    operations are never rejected by the budget; /64 keying of the IP budget and both per-minute IP limiters; the
    negative handle cache; and the guard test fails when a fake uncapped read procedure is registered.
- **Acceptance criteria.**
  - Given the matrix, then every cell matches ADR-0010 D6.
  - Given the budgets, then all measured reads ≤ the ADR-0010 cold/warm ceilings.
  - Given the P0 finding scenario (a scripted loop of CheckHandleAvailability and GetProfile on random handles), then
    reads stop at the configured budget.
  - Given a script that mints unverified password accounts and rotates them over GetMe and CheckHandleAvailability,
    then `fs_reads` stays 0.
- **Test notes.** Reuse the T19 fixtures.
- **Observability.** —
- **Budget.** Not applicable.
- **Status: integration tests present and green in CI (2026-10-06).** `internal/timeline/integration` and the read-budget suites are in `make test-int`. A bullet-by-bullet audit against this ticket's list (F = 5,000 ceiling, D13 regression, D14 token cases, T3 scenarios) is still open.

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
- **Status: partly done (2026-10-06).** `backend/e2e/posts_smoke_test.go` added and passing on the emulators; `docs/reviews/test-report-posts-timeline.md` written. Open: run the smoke on the prod `candidate` URL (T27).

### T22 — k6 emulator load smoke: timeline read + post create  [owner: sre-performance] [size: S] [depends: T8, T13]
- **Description.** Add `loadtest/timeline_read.js` (50 virtual users, F distributed 10–300, refresh + older page) and
  `loadtest/post_create.js`, following `identity_getme.js` and the graph scripts. Record p95 and `fs_reads`/call from
  the logs.
- **Acceptance criteria.**
  - Given 20 rps for 2 minutes, then refresh p95 is < 400 ms and CreatePost p95 < 500 ms (emulator, machine noted).
  - Given the logs, then the mean `fs_reads` per call is ≤ the planning budget, and there are 0 ERROR lines.
  - Given the logs, then the report states the measured means for (ADR-0010 sre handoff):
    - home refresh overhead;
    - older-page reads per page (flag if > 1.4 × page size: the `k`-factor lever);
    - the `since_clamped` rate;
    - the interceptor's cold share.
- **Test notes.** Results go in T25.
- **Observability.** Existing fields.
- **Budget.** Emulator only.
- **Status: scripts written, not yet run (2026-10-06).** `loadtest/posts_create.js`, `loadtest/timeline_read.js` and a generic `rpcCall` in `graph_common.js`; k6 is not installed in the authoring container. Open: run `make loadtest SCENARIO=timeline_read` and `posts_create`, record results.

### T23 — Code review  [owner: code-reviewer] [size: S] [depends: T3–T18 (per PR)]
- **Description.** Review each PR against CLAUDE.md rules 1–11, ADR-0004/0010 and reuse-first:
  - no second limiter, cache, cursor or verified-email check (the timeline tokens extend `pkg/platform/cursor`, T28;
    the profile first page uses the author-recent cache);
  - every descending query orders `createdAt DESC, __name__ DESC` (ADR-0010 D19);
  - no D20 "never logged" field (text, handles, hashtags, mention lists, tokens, graph arrays) appears in a log call;
  - timeline never queries `posts` directly;
  - every query has a `Limit`, and no read happens in a loop;
  - every read is counted in `budget.Counter` (the read budget depends on it);
  - budget comments match the code;
  - the reuse report is present and the catalogs are updated.
- **Acceptance criteria.** APPROVE on every PR, with no open Blockers.
- **Test notes.** —
- **Observability.** —
- **Budget.** —
- **Status: done for PR #94 (2026-10-05).** APPROVE, no open Blockers; see `docs/reviews/code-review-posts-timeline.md`.

### T24 — Security review: posts/timeline threat model + P0 closure  [owner: security-auditor] [size: M] [depends: T3, T8–T13]
- **Description.** Threat-model:
  - read amplification: close the public-repo finding against T3 and re-check M6's residual risk with the new read
    paths;
  - existence leaks: GetPost/GetUserTimeline byte-identical NOT_FOUNDs (D6), and DeletePost's no-oracle success for
    not-owned/unknown/deleted ids (D4);
  - D5 as amended (A1–A10): the verified-identity gate (provider allowlist, A10), the in-flight hold invariant, the
    IP key as a charge-only meter (A8) with the A9 unmark, the /64 keys, the
    X-Forwarded-For fallback, and residuals R1 (verified sybils) and R2 (instance churn);
  - block bypass: stale caches, the author-recent cache;
  - mention abuse;
  - text rendering: no HTML, link schemes; D9's rejection of bidi controls;
  - cursor forgery and cross-binding; the 30-day timeline token TTL (D14);
  - quota races;
  - idempotency-key reuse;
  - log PII (no post text in logs).

  Write `docs/reviews/security-review-posts-timeline.md`.
- **Acceptance criteria.** 0 Critical/High open. The public-repo finding is marked Closed with evidence (T20 test
  names, config values), and the founder's acceptance of ADR-0010 D5 R1/R2 is recorded in the readiness report.
- **Test notes.** Findings go back to the owning ticket.
- **Observability.** Confirm no request body or text is logged.
- **Budget.** —
- **Status: done for PR #94 (2026-10-05).** 0 Critical/High open; see `docs/reviews/security-review-posts-timeline.md`. Open: mark the public-repo finding Closed with test-name evidence in the readiness report, and record the founder's R1/R2 acceptance there.

### T25 — Cost report and cost-model update  [owner: sre-performance] [size: S] [depends: T19, T20, T22]
- **Description.** Re-base the `cost-model.md` §2 rows for CreatePost, DeletePost, GetPost and the timelines on
  measured values:
  - drop `userLikes` from the timeline rows until P5;
  - add the `AccountStatusInterceptor` line and the settle re-read line (ADR-0010 "Cost impact");
  - add the read budget to §4 as an abuse bound: 2,308 reads per verified account per instance lifetime (≤ 6,924/day
    steady; ceiling ≈ 623k/day under deliberate instance churn); 0 for unverified accounts (ADR-0010 D5);
  - recompute §3 (the crossover DAU) for the released scope (identity + graph + posts/timelines). The ADR predicts
    ≈ 182.6 reads/DAU, a crossover at ≈ 274 DAU and the 80% line at ≈ 219 DAU;
  - restate §2–§5 for the whole product (≈ 215 reads/DAU after these corrections), and add §9 queries by
    `posts_op`/`timeline_op`.

  Write `docs/reviews/cost-report-posts-timeline.md`. Add a Logs Explorer query grouping `fs_reads` by `rpc` for
  Post/Timeline.
- **Acceptance criteria.**
  - Given the report, then every planning value is within 25% of its measured mean, or the difference is explained.
    A difference > 25% triggers the ADR-0010 revisit.
  - Given the report, then released-scope reads at 300 DAU are compared with the ADR-0010 forecast (110% of free,
    ≈ $0.09/month). This is inside founder decision D1 (accept pay-per-use) unless the measured figure exceeds it by
    > 25%. In that case the report names the lever applied (for example the `k` factor) and flags it for P9.
- **Test notes.** —
- **Observability.** The query is documented in `cost-model.md` §9.
- **Budget.** —
- **Status: done 2026-10-06 (not committed).** `cost-model.md` and `cost-report-posts-timeline.md` re-based on emulator measurements. Released-scope reads 192.9/DAU vs the ADR's 182.6 (+5.6%; crossover ≈ 259 DAU, 80% line ≈ 207, ≈ $0.14/month at 300 DAU vs $0.09). One planning value above 25%: home older page 40-42 measured vs 30 (+33%), so the ADR-0010 revisit is triggered and the `k` factor lever (`2p` to `1.5p`) is flagged for P9. Not measured: real traffic, hit rates, dev latency or cold start.

### T26 — Infra/config, indexes READY, runbooks, dev deploy  [owner: production-deployer] [size: S] [depends: T3, T4, T5]
- **Description.**
  - Add env vars to Terraform `cloud-run-api` for dev/prod (ADR-0010 Handoff). Plan-then-OK before apply (founder
    preference).
    - `FEATURE_POSTS` (dev `on`, prod `off`) and its allowlist. **Set `FEATURE_POSTS=off` explicitly in prod
      Terraform**: the code default is `on` in dev and local and `off` in prod, and an explicit value keeps the
      environment from depending on that default;
    - `READ_BUDGET_PER_UID_PER_DAY=2000`, `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY=500`,
      `CHECK_HANDLE_CALLS_PER_DAY=100`, `ACCOUNT_OPS_CALLS_PER_DAY=20`;
    - `TIMELINE_SETTLE_WINDOW=15s` (validated ≥ 15 s), `TIMELINE_TOKEN_TTL=720h`;
    - `CACHE_POSTS_ENTRIES=20000`, `CACHE_AUTHOR_RECENT_ENTRIES=1000`;
    - the T4 rate-limit keys.
  - Deploy `firestore.indexes.json` (unchanged, D19) and confirm the three posts indexes are **READY** in dev and prod
    before any traffic (L5 fix order). Gate line: **every posts index READY in dev** (the emulator does not enforce
    indexes, so no automated test proves this).
  - Before the ADR-0010 D5 A2 gate reaches prod: list password accounts with `emailVerified=false` (Admin SDK
    `accounts:batchGet`, free) and confirm none owns a `users` doc. Record the count, never the uids.
  - Runbooks:
    - `docs/runbooks/posts.md`: failure modes (index missing → FAILED_PRECONDITION, a hot author, read-budget
      rejections of legitimate users → raise via env, the settle window and duplicate refresh items, instance memory
      > 70% → shrink the cache sizes via env);
    - `abuse-spike.md` (ADR-0010 D5 A7 and "Residual risk"). Use Logs Explorer filters, not SQL (Log Analytics is
      not enabled; security L2):
      - `jsonPayload.limit_name` = `read_budget_daily`, `read_budget_inflight`, `check_handle_daily` or
        `account_ops_daily`, split by `jsonPayload.read_budget_key` (`uid`: a heavy account or sybils; `ip`: a farm
        behind one address);
      - counts of `jsonPayload.gate="email_unverified"` (minted-account floods, now 0 reads) and
        `jsonPayload.profile_required=true`;
      - the R2 churn check: one `uid_hash` rejected on ≥ 3 distinct `labels.instanceId` in an IST day;
      - `outcome=noop:not_owner` on DeletePost;
      - levers in order: disable the account, the sign-up kill switch, lower `READ_BUDGET_PER_UID_PER_DAY`,
        `FEATURE_POSTS=off`. State that `DEGRADED_MODE=readonly` does not reduce reads;
    - `cost-spike.md`: the read-budget levers; the 40k-reads alert is expected near ≈ 219 DAU;
    - `account-deletion.md`: purge-posts before purge-graph and before deleting `users` (T10 owns the steps; check
      them here).
- **Acceptance criteria.**
  - Given dev, then the T21 smoke passes with the flag on.
  - Given prod, then indexes are READY, the flag is `off`, and every ADR-0010 env var above is set.
  - Given the A2 pre-check, then 0 unverified password accounts own a profile.
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

  The **`percent` → `on` steps belong to the v0.3.0 release** (with P3 + P7). They require T3 to be live in prod and
  the founder's acceptance of ADR-0010 D5 R1/R2 to be recorded in the readiness report.
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
- **Gate:** no `percent` step until T3 is live in prod, T24 has closed the public-repo finding, and the founder has
  accepted ADR-0010 D5 R1/R2 in the readiness report.
- **Rollback triggers:**
  - 5xx > 2% or p95 > 2× baseline for 10 minutes;
  - Firestore reads > 40k/day while under ~200 DAU (the model is wrong; ADR-0010 puts the 80% line at ≈ 219 DAU);
  - any block-visibility bug.

  Action: `FEATURE_POSTS=off` (reads stop immediately). If writes misbehave, use `DEGRADED_MODE=readonly`. For a code
  defect, shift traffic back to the previous revision (`docs/runbooks/rollback.md`).
- **Data:** expand-only. There is a new collection and no migration. A rollback leaves `posts` docs in place,
  harmless and purgeable via T10.

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The read-budget cap rejects a legitimate power user (large F, heavy scrolling) | Low | Medium | 2,000 ≈ 9–11× a typical day (≈ 183–215 reads/DAU). F = 300 on a heavy day ≈ 980. An account following more than ~1,000 can hit the cap (accepted residual, ADR-0010 D5): non-blocking banner over the cache (T17), `read_budget_spent` shows the distribution, raise via env |
| Refreshes return a few duplicate items (settle window, D13) | Certain | Low | The client dedupes by `post_id` (T14/T17); `since_clamped` rate measured in T22 |
| Suspended authors stay in followers' Home until P7 (D10) | Certain at the first suspension | Medium | The P7 obligation: `opsctl suspend-user` takes the posts down within 60 s (`phase1.md` P7) |
| DeletePost success on a not-owned post surprises API readers (D4) | Certain | Low | Documented in `posts.proto`; `outcome=noop:not_owner` logged for abuse review |
| Instance memory from the new caches | Low | Medium | ≤ 113 MiB worst (D15); resize via env if memory > 70% |
| Per-instance budgets reset with every new instance (scale-to-zero, scale-out, new revision), so bounds are per instance lifetime (ADR-0010 D5 R2) | Certain | Low–Medium ($) | Founder acceptance of R2; detection (one `uid_hash` rejected on ≥ 3 instances a day); the pre-designed persisted counter (SIGTERM flush + seed from the `users` doc) behind its trigger; the Stage 2 ADR moves counters to shared state |
| Verified sybils multiply the per-account bound (ADR-0010 D5 R1) | Low at Stage 0 | Low (≈ $0.004/day per account) | Founder acceptance of R1; the sign-up kill switch; App Check enforcement is the escalation ADR |
| Password users must verify their email before the handle check works (ADR-0010 D5 A2) | Certain | Low (UX) | The existing verify banner; Google/Apple sign-in unaffected |
| A repo forgets to call `budget.AddReads`, silently bypassing the budget | Medium | Medium | T23 review check + `budgettest` assertions on every RPC (T19/T20) |
| The home-timeline read line (60 new posts/DAU) is higher than modelled | Medium | Low ($) | The 40k alert, P9 actuals, levers §6 |
| Author snapshot staleness after renames (until P2) | Certain | Low | Navigation by `user_id`; P2 soon after |
| Merge bugs (dropped or duplicated items) | Medium | High (user trust) | T11 property tests; the D13 settle watermark (regression test in T20); client dedupe by post id |
| Index not READY at traffic shift | Low | High | T26 checks READY first (L5 order) |

## Open design questions (resolved by ADR-0010; the original default is in bold, and the outcome follows the arrow)
- **Q1** Flag granularity: **one `FEATURE_POSTS` for posts + timelines + UI**, or separate flags. → Accepted (D1).
- **Q2** Slice-1 CreatePost scope: **reply/quote/media → `FEATURE_DISABLED`**, or VALIDATION. → Accepted, plus
  `metadata["feature"]` naming the sub-feature (D2).
- **Q3** Viewer flags before P5: **always false, no `userLikes` read**. → Accepted (D3). P5 adds +1 cold read.
- **Q4** DeletePost on another user's post: **NOT_FOUND** (vs PERMISSION_DENIED). Unknown id: **success**.
  → **Changed (D4):** success with 0 writes for another user's post, an unknown id and an already-deleted id alike,
  which removes the existence/block oracle.
- **Q5** P0 numbers: **2,000 reads/uid/day/instance; 500 reads/IP/day for profile-less callers; CheckHandle 100
  calls/uid/day; negative handle cache 10 s**. Budget charged post-call from `budget.Counter`. → Accepted with two
  refinements: the IP budget applies to profile-exempt procedures only, and IPv6 is keyed by /64 (D5). Amended after
  the P0 reviews (D5 A1–A7): verified-identity gate, in-flight hold, IP charge for verified callers without a profile,
  CreateProfile charge-only on the IP key, charge-only account operations, per-instance-lifetime bounds (R1/R2).
  Re-review amendment (D5 A8–A10): the IP key never rejects, a stale mark is cleared by any call that finds a
  profile, and the gate is a provider allowlist. R1/R2 accepted by the founder on 2026-10-01.
- **Q6** Timeline visibility: **muted authors hidden in Home only; a caller who blocks the author still gets the
  author's posts on GetUserTimeline/GetPost (the client shows a banner); author blocked caller ⇒ NOT_FOUND
  everywhere**. → Accepted and made exhaustive in the D6 matrix.
- **Q7** Mentions: **unknown handles stay plain text; mentioning a user the author blocked is allowed** (notifications
  are suppressed later in P6). → Accepted, with an exact grammar (D7). **Amended 2026-10-05 (M2):** mentions of users
  who blocked the author are no longer dropped, and the overflow rule is gone, because the drop revealed who blocked the
  author. P6 must not notify a user who blocked the author.
- **Q8** Hashtag grammar: **`#[\p{L}\p{N}_]{1,50}`, must contain ≥ 1 letter; lower-cased; ≤ 10 stored**.
  → **Changed (D8):** the body admits combining marks and ZWJ/ZWNJ (`#भारत` works); `#123` stays none.
- **Q9** Text: **NFC, trim, ≤ 280 code points, `\n` allowed (≤ 10 lines), other control chars rejected; links count
  as typed**. → Accepted and specified step by step, including rejection of bidi controls (D9).
- **Q10** Suspended/deleting authors' posts in Home: **not filtered at Stage 0** (it would cost a `users` read per
  author). The moderation takedown (P7) and account purge (P8) remove them. GetPost and GetUserTimeline do check
  status (cached). → Accepted (D10). **P7 must make `opsctl suspend-user` take down or hide the user's posts.**
- **Q11** `GetUserTimeline(include_replies=true)` before P3: **same as the Posts tab** (no replies exist). The client
  hides the tab. → Accepted by construction: the real Replies query from day one (D11).
- **Q12** `mentionIds` field (ADR-0003:80): **don't write it in P1** (no query uses it; saves index writes); the P6
  notifications ADR decides. → Accepted, with no exemption added (D12).
