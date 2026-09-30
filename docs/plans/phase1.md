# Phase 1 (core MVP): remaining work, ordered in slices
Plan owner: planner · Date: 2026-09-30 · Stage: 0 (0 – ~300 DAU, $0 target) · Source roadmap: `mvp-roadmap` Phase 1
Inputs: CLAUDE.md, ADR-0001…0009, `proto/dzeroth/**`, `backend/internal/**`, `app/lib/**`, `docs/reviews/cost-model.md`,
`docs/reviews/security-audit-v0.1.0.md`, `docs/plans/graph.md`, `infra/terraform/**`.

Detailed tickets exist only for the first build slice: `docs/plans/posts-and-timeline.md` (P0 + P1).
Every other slice gets its own plan (same format as `docs/plans/graph.md`) when it starts.

---

## 1. Where we are (verified in code on branch `docs/adr-0009-n4-and-t31`)

| Area | State | Evidence |
|---|---|---|
| identity module | Built: CreateProfile, CheckHandleAvailability, GetMe, GetProfile, UpdateProfile, ChangeHandle | `backend/internal/identity/api.go:80-91` |
| DeleteAccount, RequestAccountExport, GetAccountExport | **Stubbed: return Unimplemented** | `backend/internal/identity/server.go:154-168` |
| UpdateProfile avatar | **Rejected: a non-empty `avatar_media_id` returns MEDIA_NOT_READY** until the media module exists | `backend/internal/identity/service.go:203-205`, `api.go:72-75` |
| graph module | Built and wired (follow/unfollow/block/mute, lists, purge) | `backend/internal/apiserver/apiserver.go:96-126`, `backend/internal/graph/*` |
| posts, timeline, engagement, media, notifications, search, moderation, admin (backend) | **Not built.** No `internal/<module>` directory exists; not registered in the mux | `apiserver.go:128-129`; Glob of `backend/internal/**` |
| Protos | **Already exist** for `posts.v1`, `timeline.v1` and `media.v1`, with Go and Dart generated code. **No proto** for engagement, notifications or moderation/reports | `proto/dzeroth/{posts,timeline,media}/v1/*.proto`, `backend/gen/dzeroth/{posts,timeline,media}`, `app/lib/gen/dzeroth/{posts,timeline,media}` |
| Firestore indexes for posts | **Already declared**: `(authorId, isReply, createdAt↓)`, `(authorId, createdAt↓)`, `(conversationId, createdAt↑)`, `(hashtags CONTAINS, createdAt↓)`, plus exemptions for `text`/`author`/`media`/`embedded`/`mentions` | `firebase/firestore.indexes.json:4-35,62-67` |
| Platform helpers the slices reuse | idempotency, quota (`Posts`, `Uploads`, `Exports` kinds already exist), snowflake, cursor, budget, flags, cache, DailyCap | `backend/pkg/platform/*`; `quota/quota.go:53-61` |
| Config that exists but is **not wired** | `RATE_LIMIT_TIMELINE_PER_MIN` (6), `RATE_LIMIT_LIKES_PER_MIN` (30), `QUOTA_POSTS_PER_DAY` (100 / new accounts 20), `QUOTA_MEDIA_PER_DAY` | `pkg/platform/config/config.go:59-61,238-247,282-300`; no usage outside config (Grep) |
| Async infra | Pub/Sub topics `media-processing` and `notifications-fanout` (+DLQs); `/internal/*` is a **placeholder handler**; 1 Scheduler job (`daily-maintenance`, prod) | `infra/terraform/modules/pubsub/variables.tf:26-39`, `apiserver.go:227-232`, `envs/prod/main.tf:186-191` |
| TTL policies | `idempotency`, `media`, `notifications`, `exports` on `expireAt` | `modules/firestore/variables.tf:15-40` |
| Buckets | `-media-upload` (private, 2-day lifecycle) and `-media` (public). **No export bucket** | `modules/media-buckets/main.tf:9-40` |
| Vision API | Enabled | `modules/project-services/variables.tf:21` |
| Flutter features | auth, onboarding, home (**placeholder**), profile (header only), graph, settings. **No** compose, timeline, post detail, edit-profile, change-handle or delete-account screens | `app/lib/features/home/presentation/home_screen.dart:5-37`; Grep for `updateProfile|changeHandle|deleteAccount` in `app/lib` (excluding gen) = 0 hits |

**Could not verify:** whether PR #58 (graph T27 lazy clean-up) is still open or merged (no GitHub access from here),
and whether v0.2.0 is tagged or released. `docs/plans/graph.md:2` targets graph at v0.2.0, and
`docs/reviews/cost-report-v0.2.0.md` exists, but there is no `release-v0.2.0-readiness.md`. Deployed state was not checked.

### Contract drift to fix in the slices (found while reading)
- `media.proto:23-26` still says SafeSearch runs "if the monthly Vision counter < 950". ADR-0005 was amended on 2026-09-27
  to "screen every image, paid, capped by `VISION_MONTHLY_CAP` (10,000)" (`docs/adr/0005-...md:3,63-66`). Fix in P4.
- `cost-model.md:29` lists GetProfile at 4/1 reads, but the proto says 3/0–1 (`identity.proto:37`). Fix in P9.
- `posts.proto` and `timeline.proto` budgets include `userLikes` hydration and async notifications, which can't exist
  until P5/P6. P1 documents the reduced numbers (see the posts-and-timeline plan, T2).

---

## 2. Slices

Size uses the graph slice as the yardstick (graph ≈ 31 tickets, M overall). S ≈ ≤ 8 ticket-days, M ≈ 8–20, L ≈ 20+.
Cost lines use the `free-tier-budget` §2 method and the `cost-model.md` §1 assumptions (4 sessions, 8 home refreshes,
F = 60, 1 post/DAU/day, 5 likes, 0.2 images, ~50% cache hit rate). The **v0.2.0 baseline** (identity + graph) is
20.4 reads, 3.1 writes and 0.1 deletes per DAU (`cost-model.md:94`).

### P0 — Read-cost hardening (gating)  [size: S] [owners: architect (numbers, in ADR-0010) → backend-developer → tester → security-auditor]
- **Goal.** No read RPC can be used to push Firestore reads past the free tier. This closes the public-repo review finding:
  - `CheckHandleAvailability` is capped only at 20/min/uid (`config.go:242`). That is 28.8k calls a day per uid per
    instance. Free handles are not cached (`identity/service.go:111-123`), so each call costs 1 read: **58% of the daily
    free reads from one account on one instance**, and 173% across the 3-instance max.
    - The RPC is profile-exempt (`apiserver.go:133-138`) and does not require a verified email. By the codebase's own
      note, password accounts "can be minted by the thousand per hour per IP" (`identity/server.go:30-34`), so the
      attack is also sybil-multipliable.
  - `GetProfile` gets the 60/min default (`config.go:235`), which is 86.4k calls a day. It costs 1–3 reads per call, and
    missing handles are not negatively cached (`service.go:166-179`).
  - Neither RPC has an entry in `DailyCaps` (`apiserver.go:188-200`), which today covers graph RPCs only.
- **Approach.** A per-uid daily **Firestore read budget** interceptor, fed by the existing `budget.Counter`. It bounds any
  mix of read RPCs, including the new timeline and post paths, with one mechanism. Add to it:
  - a per-IP budget for callers without a profile;
  - a 10 s negative handle cache;
  - a CI guard test that fails if any `NO_SIDE_EFFECTS` procedure is registered without being covered.

  Extend `ratelimit`/`DailyCap`; do not add a second limiter (reuse-first).
- **Dependencies.** None. It must be merged **and deployed to prod** before any public (non-allowlist) rollout of P1's
  read paths.
- **Firestore budget.** 0 reads and 0 writes added (in memory).
  - Worst case per abusive account per day after the fix: ≤ (read budget − 1 + one call's worst case 269) × 3
    instances = (2,000 − 1 + 269) × 3 = **6,804 reads** (13.6% of free), against ~86k–259k today (ADR-0010 D5).
  - Profile-less callers: ≤ 1,503 reads per IP (IPv6: per /64), charged only on profile-exempt procedures.
- **Cost line.** $0. It lowers the worst case and doesn't change the typical case.
- **Done when.**
  - The budget interceptor is live in prod.
  - The guard test is in `make ci`.
  - An emulator test shows the 2,001st read-budget unit is rejected with `RATE_LIMITED` and `limit_name=read_budget_daily`.
  - security-auditor re-checks the finding and marks it closed.

### P1 — Posts (create/delete, mentions, hashtags, links) + profile timeline + home timeline  [size: M/L] [owners: architect → backend ‖ frontend → tester → reviewers → sre → deployer]
- **Goal.** Users can post text, see their followees' posts in a chronological home feed with incremental refresh, and see
  anyone's posts on their profile. Everything else in Phase 1 depends on `posts/{postId}` and `posts.Reader`.
- **Scope.** Root posts only (reply, quote and media return `FEATURE_DISABLED` until P3/P4/P5):
  - text of ≤ 280 code points (NFC);
  - server-side mentions (≤ 10, resolved via `handles/*`) and hashtags (≤ 10, stored but not queryable until Phase 2);
  - links are linkified by the client only; no previews (Phase 2, SSRF-safe fetcher);
  - DeletePost, GetPost, GetUserTimeline (Posts tab), GetHomeTimeline (ADR-0004 in full, minus viewer-like flags);
  - a `posts.Eraser` + exporter + `opsctl purge-posts|export-posts`, so the manual deletion runbook covers the new
    collection (CLAUDE.md rule 10);
  - Flutter: composer, `PostCard`, home timeline with drift cache/gap rows, profile Posts tab, delete, `/post/:id`.
- **Dependencies.** P0 (for public rollout only; build in parallel). The graph module (done). ADR-0010
  (`docs/adr/0010-posts-and-timelines-slice.md`) records the slice decisions. No new proto messages are needed, only
  comment updates. `pkg/platform/cursor` gains two-bound window tokens and a TTL-aware decode (plan ticket T28).
- **Firestore budget** (source: ADR-0010 "Cost impact"; full table and derivation in `posts-and-timeline.md`). Cold
  ceilings include the `AccountStatusInterceptor` read. Planning values exclude it; it has its own line.

| RPC | reads cold / warm / planning | writes | deletes | calls/DAU | reads/DAU | writes/DAU |
|---|---|---|---|---|---|---|
| CreatePost (root) | 14 / 2 / 2.5 | 4 | 1 (idempotency TTL) | 1.0 | 2.5 | 4.0 |
| DeletePost | 2 / 0 / 1 (not-owned/unknown: success, 0 writes) | 1 (0 on no-op) | 1 (0 on no-op) | 0.05 | 0.05 | 0.05 |
| GetPost | 4 (+1 overflow) / 0 / 1 | 0 | 0 | 1 | 1.0 | 0 |
| GetUserTimeline | 3 + p = 53 / 0 / 11 | 0 | 0 | 2 | 22 | 0 |
| GetHomeTimeline (refresh / settle re-reads / older / cold) | 2 + C + 2p = 269 / 0 to C / 4 + new posts, ≈ 0.1, 30, 30 | 0 | 0 | 8 / 8 / 1 / 0.1 | 126.0 | 0 |
| `AccountStatusInterceptor` caller read | 1 / 0 / 1 per home refresh, 0.5 otherwise | 0 | 0 | 13.15 req | 10.6 | 0 |
| **P1 total** | | | | **13.15 req** | **≈ 162.2** | **≈ 4.05** (deletes ≈ 1.05) |

- **Cost line.**
  - Released scope after P1 (v0.2.0 baseline + P0/P1) = **≈ 182.6 reads, 7.15 writes, 1.15 deletes, 24.45 requests
    per DAU**.
  - At 300 DAU: **54.8k reads/day, 110% of the free quota**. The free line is crossed at **≈ 274 DAU**, and the 80% line
    (40k) at **≈ 219 DAU**, so the existing "Firestore reads > 40k/day" alert will fire near 219 DAU. That is a planned
    signal, not an incident.
  - The overage is **≈ $0.09/month at 300 DAU** (≈ $9.9/month at 3k DAU), inside founder decision D1. D1 is re-decided at
    P9 with real numbers.
  - Change vs the earlier plan (134 → 162.2 reads/DAU): the interceptor read, a cold graph on 60 s-spaced refreshes,
    ADR-0004's `k = 14` over-read on older/cold pages, settle re-reads, CreatePost/GetPost +0.5 each.
  - Writes: 2.1k/day (11%). Deletes: 0.35k/day (2%).
  - Cloud Run: 220k requests/month for the released scope (11% of 2M); vCPU 22k s/month (12%).
  - New GCP services: none.
- **Done when.**
  - All P1 tickets meet their acceptance criteria.
  - The test report is PASS, with measured reads ≤ budget per RPC.
  - Code review APPROVE; security has 0 Critical/High.
  - The cost report is updated.
  - Dev is deployed and prod runs behind `FEATURE_POSTS=allowlist`.

### P2 — Profile gaps  [size: S] [owners: architect (snapshot job + topic) → backend ‖ frontend → tester]
- **Goal.** Users can edit their profile and rename themselves without leaving stale identity on their posts.
- **Scope.**
  - Flutter: Edit profile (display name, bio) and Change handle screens. Both RPCs exist; there is no UI (Grep = 0 hits).
  - Backend: the `profile-snapshot-refresh` job from ADR-0003:97-100. It rewrites `author` on the newest 100 posts and
    is limited to 5 snapshot edits/day. It is triggered by UpdateProfile/ChangeHandle and runs on a new Pub/Sub
    topic, or a shared `jobs` topic (see the architect question below).
  - The avatar upload lands in P4. This slice leaves `avatar_media_id` rejected.
- **Dependencies.** P1 (posts exist).
- **Budget.** UpdateProfile 2/1 R, 1/1 W, plus job ≤ 100 R/100 W, at 0.02 calls/DAU → 0.25 R, 0.25 W per DAU
  (already in `cost-model.md:32`).
- **Cost line.** $0. It adds a Pub/Sub topic + DLQ + push subscription: pay-per-use, far below 10 GiB/month.
- **Done when.** A rename shows the new handle on the author's last 100 posts within 60 s on the emulator. The job is
  replay-safe (`snapshotVersion` skip). There is a widget test for each new screen.

### P3 — Replies and threads  [size: M] [owners: architect → backend ‖ frontend → tester → reviewers]
- **Goal.** Users can reply, and read a post with its conversation.
- **Scope.**
  - CreatePost with `reply_to_post_id`: a parent read, `replyCount` increment, `conversationId`, `replyToHandle`.
  - A reply to a post whose author blocks the caller, or to a deleted parent, returns NOT_FOUND.
  - GetThread with **first page 10** (cost-model lever §6.2).
  - Profile Replies tab (`include_replies=true`).
  - Flutter: post detail/thread screen, reply composer, tombstones for deleted parents.
- **Dependencies.** P1.
- **Budget.** CreatePost (reply) 15/3 R, 5/5 W; GetThread 55/6 R (worst at page_size 50; the default first page is 10).
  At 2 threads + 0.3 replies per DAU: ≈ 12.9 reads, 1.5 writes, 0.3 deletes per DAU.
- **Cost line.** +3.9k reads/day at 300 DAU. On the ADR-0010 base (182.6 reads/DAU after P1), P1 + P3 + baseline ≈
  195.5 reads/DAU = 58.7k/day, **117% of the free quota at 300 DAU**; the crossover is ≈ 256 DAU. That is ≈ $0.16/month
  over at 300 DAU (upper-bound price, `cost-model.md` §7), inside D1. The P3 ADR re-bases its own rows with the same
  convention: cold ceilings include the interceptor read.
- **Done when.** Thread order is chronological. Replies from blocked or muted authors are dropped. Budget assertions
  pass. A delete of the parent renders a tombstone.

### P4 — Images (signed uploads, SafeSearch with cap, avatars) + post-delete job  [size: M/L] [owners: architect (ADR-0005 follow-ups, proto comment fix, topic) → backend ‖ frontend → tester → security-auditor → deployer]
- **Goal.** Up to 4 images per post, and a profile avatar, all moderated before they become public.
- **Scope.**
  - The `internal/media` module: CreateUpload and FinalizeUpload (the proto exists).
  - IAM `signBlob` signing.
  - Magic-byte check.
  - SafeSearch on every image, bounded by `VISION_MONTHLY_CAP` / `VISION_EXHAUSTED_POLICY` (ADR-0005). Fix the stale
    "< 950" comment in `media.proto:23-26`.
  - `degraded.ProcedureSet` for `nomedia` (today it is empty: `apiserver.go:204`).
  - CreatePost with `media_ids`.
  - The UpdateProfile avatar path, closing `service.go:203-205`.
  - The **`post-delete` job**: this is the first slice where a deleted post leaves dependent data behind (public
    objects).
  - `media.Eraser` for account deletion.
  - Flutter: `image_picker` + `flutter_image_compress`, BlurHash, upload with progress and retry, grid in `PostCard`,
    avatar editor.
- **Dependencies.** P1 (and P2 for the avatar UI placement). It can run in parallel with P3.
- **Budget.**
  - CreateUpload 2/1 R, 6/3.3 W; FinalizeUpload 5/1.7 R, 5/2.7 W. At 0.15 calls/DAU → ≈ 0.4 R, 0.9 W, 0.15 D per DAU.
  - GCS: 4 Class A per image; ~31 Class B (image GETs) per DAU per day.
- **Cost line.** Firestore: negligible. Not $0 at 300 DAU:
  - **Vision ≈ $1.20/month**: free to ~160 DAU, then paid. Already founder-approved in the ADR-0005 amendment.
  - **GCS Class B ≈ $0.09/month**: 50k/month free runs out at **~54 DAU** (`cost-model.md:111`).
  - GCS Class A: runs out at ~208 DAU, cents.
  - All of these are pay-per-use; there is no fixed fee. Storage: 5 GB ≈ 15k images, about 9 months at 300 DAU.
- **Done when.**
  - Oversize, wrong-type and MD5-mismatch uploads are rejected.
  - Cap cut-over is tested with a fake moderator.
  - Unmoderated bytes are never public.
  - Deleting a post removes its public objects (a resumable job, idempotent by message id).
  - `DEGRADED_MODE=nomedia` blocks CreateUpload.

### P5 — Likes, reposts, quote posts  [size: M] [owners: architect (new `engagement.v1` proto, ADR) → backend ‖ frontend → tester → reviewers]
- **Goal.** Users can react to and share posts.
- **Scope.**
  - The new `engagement.v1` service: Like, Unlike, Repost, Undo repost, and optionally ListLikers (only if cheap).
  - `likes/{postId}_{uid}`, `reposts/{postId}_{uid}` (natural-key idempotency).
  - `userLikes/{uid}` hydrates `liked_by_viewer`/`reposted_by_viewer` in timelines (+1 cached read per timeline call).
  - Repost is a `kind=REPOST` post doc, so pull timelines include it (ADR-0003:94).
  - Quote = CreatePost with `quote_of_post_id` (an embedded snapshot).
  - `RATE_LIMIT_LIKES_PER_MIN` gets wired.
  - A new `likes` daily quota (500/day, per `free-tier-budget` §4).
  - The `post-delete` job gains likes/reposts clean-up.
  - `engagement.Eraser`.
- **Dependencies.** P1; the P4 `post-delete` job.
- **Budget.** Like 1/0 R, 3/3 W (no notification yet); Unlike 1/0 R, 2/2 W, 1 D; Repost 2/0.5 R, 5/5 W; +~3 reads/DAU
  of `userLikes` misses. At 5 likes, 0.5 unlikes and 0.3 reposts per DAU → ≈ 3.2 reads, 17.5 writes, 0.5 deletes per DAU.
- **Cost line.** Writes rise to ≈ 26 per DAU (all slices so far) = 7.8k/day at 300 DAU (39% of free). Reads +1k/day.
  $0 for writes up to ~615 DAU.
- **Done when.**
  - A like is idempotent under 10 concurrent calls.
  - Counters are exact (an invariant checker, like graph's).
  - The hot-doc rule is documented: ≤ 1 sustained write/s per post, and sharding only through an ADR with a measured
    trigger.

### P6 — Notifications (in-app + FCM push)  [size: M] [owners: architect (new `notifications.v1` proto, device-token model) → backend ‖ frontend → tester → security-auditor]
- **Goal.** Users learn about follows, mentions, replies, likes, reposts and quotes, both in-app and by push.
- **Scope.**
  - `users/{uid}/notifications/{id}` (TTL 90 days; the TTL policy already exists).
  - ListNotifications with a **`since` cursor + client cache** (cost-model lever §6.1: −15 reads/DAU).
  - Mark seen: `notificationsSeenAt` already feeds GetMe's `count()` (`identity/service.go:137-145`).
  - RegisterDevice/UnregisterDevice (FCM tokens in `users/{uid}/private` or `devices/*`; the architect decides).
  - Fan-out via the existing `notifications-fanout` topic.
  - Hooks: graph `FollowEvents` (a no-op today, `docs/plans/graph.md` T5), posts mentions/replies/quotes, engagement
    likes/reposts.
  - Like notifications collapsed per post per hour (lever §6.4).
  - No notification when the recipient blocks or mutes the actor.
  - `notifications.Eraser`.
- **Dependencies.** P1 (mentions), P3 (replies), P5 (likes/reposts/quotes). The module and FCM registration can start
  after P1; events are wired as each source lands.
- **Budget.** ListNotifications 21/5 R (with `since`), 1/0.5 W; fan-out ~6.3 W and ~1.3 R (device tokens) per DAU; TTL
  deletes ~6 per DAU. ≈ 11.3 reads, 7.4 writes, 6 deletes per DAU.
- **Cost line.** FCM costs $0. Pub/Sub is far below 10 GiB.
  - Reads: the `cost-model.md` figure was 191 reads/DAU (57.3k/day). ADR-0010's corrections raise the whole-product
    model to **≈ 215 reads/DAU → ≈ 64.5k/day at 300 DAU (129% of free)**. That is ≈ $0.26/month over at the
    upper-bound price, still inside D1.
  - Levers §6.1–§6.3 lower this. T25 (posts-and-timeline) and P9 re-derive it from measured values.
  - Writes ≈ 33/DAU = 9.9k/day (50%). Deletes ≈ 7.8/DAU (12%).
- **Done when.**
  - Push arrives on a real Android and iOS device.
  - Tapping it deep-links to `/post/:id` or the profile.
  - The block/mute suppression matrix passes.
  - The fan-out handler is idempotent by Pub/Sub message id.
  - The DLQ is configured.

### P7 — Reports + block flows (UGC store requirement)  [size: S] [owners: architect (small `moderation.v1` proto) → backend ‖ frontend → security-auditor]
- **Goal.** Users can report a post or account, and block from wherever they see content. Required by App Store 1.2 and
  Play UGC policy.
- **Scope.**
  - `ReportContent(target_type, target_id, reason)` writes `reports/{id}`, with a `reports` daily quota.
  - A report copies the reported post's text/media refs into the report doc so a later author delete doesn't destroy
    the evidence (retention: founder decision D4).
  - Moderator actions via `opsctl`: `reports list|resolve`, `takedown-post`, `suspend-user` (suspension already exists
    as `AccountStatusSuspended`). **No admin console at Stage 0.**
  - **Obligation from ADR-0010 D10:** `opsctl suspend-user` must also take down, or mark hidden, every post by the
    suspended user, so suspended content leaves every feed within 60 s. In P1, Home does not filter suspended
    authors (it would cost a `users` read per author per page); only GetPost and GetUserTimeline do. The P7 plan
    prices this takedown as O(user's posts) writes, once per suspension, and makes it resumable like the posts purge.
  - Flutter: a "Report" and "Block @x" entry in the `PostCard` overflow and the profile menu. Reuse `RelationshipCubit`
    and `showBlockConfirmationDialog` from graph (`docs/ui-catalog.md:31,34`); no new block logic.
- **Dependencies.** P1 (the post target). Account reports can ship first.
- **Budget.** ReportContent 1/1 R (quota), 2/2 W at ~0.02 calls/DAU → ~0 per DAU.
- **Cost line.** $0.
- **Done when.**
  - A report is visible to `opsctl reports list` within seconds.
  - A takedown hides the post from every read path within 60 s.
  - A suspension removes all of the user's posts from every follower's Home within 60 s (ADR-0010 D10).
  - The runbook `docs/runbooks/moderation.md` states the response SLA (decision D4).

### P8 — Account deletion + export (store blocker, M5)  [size: M] [owners: architect (ADR: orchestration, export storage) → backend ‖ frontend → tester → security-auditor → deployer]
- **Goal.** In-app, irreversible account deletion and a self-service data export. This closes M5
  (`security-audit-v0.1.0.md:20,62`) and unblocks store submission.
- **Scope.**
  - DeleteAccount (recent sign-in < 5 min, `authn.Claims.AuthTime` exists) sets `status=DELETING` and publishes
    `account-delete`.
  - A resumable job composes the Erasers:
    - graph (built, `graph.Eraser`);
    - posts (P1);
    - media (P4);
    - engagement (P5);
    - notifications/devices (P6);
    - reports as reporter (P7 policy);
    - identity (`users`, `handles`, `quotas`);
    - finally the Firebase Auth user.
  - RequestAccountExport/GetAccountExport compose each module's exporter into a private JSON object with a 15-minute
    signed GET URL.
  - **Export storage:** the proto promises 7-day retention (`identity.proto:203`), but the only private bucket has a
    2-day lifecycle (`media-buckets/main.tf:21`). The architect picks either a prefix-scoped lifecycle rule or a third
    bucket (both $0; US region).
  - Flutter: Settings → Delete account (re-auth, typed confirmation) and Download my data.
- **Dependencies.** Every Eraser/exporter. **Rule for every slice from P1 on:** ship the module's Eraser + exporter in
  the same slice (graph set the pattern), so P8 is orchestration only.
- **Budget.** Sync part 1/1 R, 1/1 W. The job is O(owned docs): a 300-post / 1k-like / 200-edge account costs about
  2k reads and 2k deletes, once. At ~0.001 deletions per DAU per day that is negligible, but one large deletion can use
  ~10% of a day's delete quota.
- **Cost line.** $0. Export objects are KB-sized in free US storage. The Firebase Auth delete is free.
- **Done when.**
  - The crash-resume test passes for the whole chain.
  - After deletion, no document or object references the uid (an emulator sweep test).
  - The export never contains `blockedBy` or other users' private data.
  - The Unimplemented stubs and `TestServer_Phase1Stubs_ReturnUnimplemented` are removed.
  - The runbook is updated from manual to in-app.

### P9 — Cost-model refresh with real numbers  [size: S] [owner: sre-performance]
- **Goal.** Replace the `cost-model.md` §1 assumptions with measured values after the first 100 real users. This is
  roadmap Phase 1's last bullet.
- **Scope.**
  - Actuals table (`cost-model.md` §8) from Cloud Monitoring and the `fs_reads` logs per RPC.
  - Re-derive the crossover DAU.
  - Fix the GetProfile 4/1 row drift.
  - Re-verify the §7 prices for `asia-south1`.
  - Decide whether any lever or Stage 1 step is needed.
- **Dependencies.** P1 live with ≥ 100 users for ≥ 7 days.
- **Cost line.** $0.
- **Done when.** Model error per line is ≤ 25%, or explained. A scale-up trigger check is recorded (`free-tier-budget` §6).

---

## 3. Parallelism and launch order

```
P0 ───────────────┐ (must be in prod before any public P1 rollout)
ADR-0010 → P1 ────┼──► P2 ─────────────┐
                  ├──► P3 ─────────────┤
                  ├──► P4 ──► P5 ──────┼──► P6 (events wired as sources land)
                  └──► P7 ─────────────┤
                                       └──► P8 (orchestration) ──► store submission
                                                            P9 after ≥ 100 users
```
- **In parallel with each other:** P0 ‖ P1; then P2 ‖ P3 ‖ P4 ‖ P7 once P1's `posts.Reader` and posts collection
  have merged. P6's module skeleton + FCM registration can start alongside P5.
- **Serial:** P5 after P4 (it reuses the post-delete job). P8 last (it needs every Eraser).
- **Suggested build order with one backend and one frontend agent:** P0 → P1 → P3 → P7 → P4 → P5 → P2 → P6 → P8 → P9.
  P2 moves earlier if handle renames become common among testers.

## 4. Release cut line
`v0.2.0` is already claimed by the graph slice (`docs/plans/graph.md:2`, `docs/reviews/cost-report-v0.2.0.md`). The two
Phase 1 releases after it are therefore called **v0.3.0** and **v0.4.0**. If v0.2.0 was never tagged, the founder can
renumber them without changing the cut.

| Release | Contents | What it unlocks | Gate |
|---|---|---|---|
| **v0.3.0: web public beta (text)** | P0, P1, P3, P7 (+ P2 if ready) | A usable text product: post, reply, feeds, report, block. Web launch is already allowed (M5 conditional: privacy policy + manual deletion runbook, which P1 extends to posts) | P0 in prod; `FEATURE_POSTS` allowlist → 10% → 100%; readiness GO |
| **v0.4.0: store-ready core (Phase 1 complete)** | P4, P5, P6, P8 (+ P2 if not already) | Images, likes/reposts/quotes, push, in-app deletion/export, so **App Store / Play submission** | Store checklist (`production-readiness` §Compliance); P9 scheduled |

**Cut line:** everything a store reviewer checks for (in-app deletion, push permission UX, image moderation) goes in
v0.4.0. v0.3.0 must still have **report + block** (P7), because any public UGC surface needs them regardless of platform.

## 5. What would break the $0 rule (all pay-per-use; nothing here needs a fixed-fee ADR)
| Item | When | Size at 300 DAU | Status |
|---|---|---|---|
| Firestore reads past 50k/day | released scope after P1 at ≈ 274 DAU (80% line at ≈ 219, ADR-0010); full Phase 1 (≈ 215 reads/DAU) at ≈ 233 DAU | ≈ $0.09/month (after P1) to ≈ $0.26/month (full Phase 1) | **Founder decision D1**; levers §6.1–§6.3 are built into P3/P6/P1 by default |
| Cloud Vision past 1,000 units/month | ~160 DAU | ≈ $1.20/month (cap 10k ≈ $13.50) | Already approved (ADR-0005 amendment, 2026-09-27) |
| GCS Class B past 50k/month | ~54 DAU | ≈ $0.09/month | Pay-per-use; keep thumbnails + client disk cache |
| Cloud Run egress to India | day 1 (the 1 GiB free is North America only) | ≈ $0.24/month | Already in `cost-model.md:109` |
| **Web App Check enforcement** (M6) | only if enforced | **$8/month flat step** past 10k reCAPTCHA assessments | **Needs an ADR with cost.** Not planned. Founder decision D3 |
| `min_instance_count = 1` | only if p95 > 800 ms warm | fixed monthly cost | **Needs an ADR.** Not planned |
| New Pub/Sub topics (`post-delete`, `account-delete`, snapshot refresh) | P2/P4/P8 | $0 (≪ 10 GiB) | Architect: prefer **one shared `jobs` topic** + DLQ to keep Terraform small |
| Cloud Scheduler | any new cron | 3 jobs/billing account; 1 used | New periodic work must reuse `daily-maintenance` |

No Phase 1 slice needs Memorystore, Cloud SQL, a load balancer, a VPC connector or any other fixed-fee resource.
Link previews (which need an SSRF-safe fetcher) are Phase 2.

## 6. Founder decisions (only the real ones)

**Decided 2026-09-30: the founder reviewed this plan and accepted the recommendation for all five decisions (D1–D5).**
| # | Decision | Recommendation |
|---|---|---|
| D1 | At 300 DAU, full Phase 1 is modelled at 172–191 reads/DAU → 52–57k reads/day, just over the 50k free quota (≤ $0.13/month). Accept pay-per-use cents at Stage 0, or require product cuts to hold strict $0 (for example fewer auto-refreshes, or no profile-timeline prefetch)? | **Accept pay-per-use.** Build levers §6.1–§6.3 by default. Keep the 40k-reads alert. Re-decide at P9 with real numbers |
| D2 | Launch shape: public web beta at v0.3.0 (text only, no push, no images), or wait for full Phase 1 (v0.4.0)? | **Public web beta at v0.3.0**, behind `FEATURE_POSTS` percent rollout, and only after P0 is in prod. Real usage de-risks P9 and D1 early |
| D3 | M6: web App Check stays monitor-only (compensated by P0's read budget, per-uid quotas and rate limits), or enforce it with reCAPTCHA (a flat $8/month past 10k assessments)? | **Stay monitor-only** and record the risk acceptance again for v0.3.0. Revisit on the first abuse spike (`docs/runbooks/abuse-spike.md`) |
| D4 | Moderation posture: who reviews reports, how fast, and how long reported content is kept after the author deletes it | **The founder reviews via `opsctl` within 24 h.** Keep the reported content snapshot until the report is resolved, max 90 days, then delete. State this in the privacy policy |
| D5 | Account deletion: immediate and irreversible (as in the proto today), or a grace period (for example 7 days, sign in to cancel)? | **Immediate** (recent sign-in + typed confirmation). A grace period adds a state machine and a Scheduler dependency for little Stage 0 value |

## 7. Open design questions for the architect (defaults proposed; don't block)
- One `FEATURE_POSTS` flag for posts + timeline UI (default), or separate flags. Sub-features (replies, media,
  engagement) get their own flags in their slices.
- One shared `jobs` Pub/Sub topic with typed messages (default), or one topic per job.
- Where each module's Eraser/exporter interface lives (default: `<module>/api.go`, same shape as `graph.Eraser`).
- The read-budget numbers for P0 (defaults are in `posts-and-timeline.md` T3). **Resolved by ADR-0010 D5:** the
  defaults were kept; the IP budget applies to profile-exempt procedures only, and IPv6 is keyed by /64.
- One `FEATURE_POSTS` flag: **resolved by ADR-0010 D1** (accepted).
