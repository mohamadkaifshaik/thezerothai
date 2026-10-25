# 0021. Composer extras: reply audience, content disclosure, scheduled posts
Status: Accepted (founder, 2026-10-23; includes the five founder decisions recorded in "Founder decisions" below, and the rule-4 bend in item 3)
Clarified 2026-10-23 (PR #247): pinned the exact CreatePost `requestHash` suffix bytes and order; reconciled the Stage 0 functional line with D3 (disclosure labels are accepted on any post kind). No decision changed.
Implementation notes 2026-10-26 (pending 2.17, after #291 and #292): "Implementation notes (2026-10-26)" at the end records where the scheduled-posts code as built differs from the text (publish transaction, item log level, Scheduler retries, the 500 rule, the media hold, the exact window cap, smaller details). No decision of this ADR changed: the media hold (note 5) is the founder's decision of 2026-10-26 (pending 2.15) and the exact window cap (note 6) tightens a cap this text calls soft (pending 2.16).
Date: 2026-10-23 (revised the same day after `docs/reviews/security-review-adr-0021.md`; see §Security review)
Deciders: architect (proposal); founder (accepted 2026-10-23). Product defaults below were proposed by the founder's delegate in
`docs/plans/composer-w15-w6.md` "Answers to the open questions" (2026-10-23).

Plan: `docs/plans/composer-w15-w6.md` (gate ticket CMP-A1; tickets CMP-B1..B4, C1..C4, D1..D8).
Related: ADR-0003 (data model, quotas), ADR-0005 (media, SafeSearch), ADR-0006 (App Check), ADR-0008 (graph, D4,
D10 start gate), ADR-0010 (posts: D2 sub-feature flags, D13/D18 Snowflake createdAt), ADR-0011 (account lifecycle,
T11 guard, cron), ADR-0016 (moderation), ADR-0017 (notifications), ADR-0018 (engagement, rule-4 bend precedent).

## Context
W6 adds three composer features observed on X (`docs/x_research/screens/composer.md`, captured 2026-10-23):
- **Reply control:** "Who can reply?" with five radios (Everyone, Accounts you follow, Accounts you follow and who
  they follow, Only accounts you mention, Verified accounts). The default is Everyone.
- **Content disclosure:** two switches, "Paid partnership" and "Made with AI", both off by default.
- **Scheduling:** a date/time dialog with a read-only time-zone row and a "Will send on ..." summary. After Confirm,
  the primary button reads **Schedule**, a tappable "Will send on ..." line sits above the audience pill, and the
  **reply control and Add poll are disabled** while a schedule is set (§1b). A "Scheduled posts" list sits inside
  Drafts (§6). The list rows and the result of pressing Schedule were not captured (UNKNOWN).

Stage 0 (CLAUDE.md): ~300 DAU, $0 target, Cloud Run min 0 / max 3, Firestore `(default)`. Per
`docs/reviews/cost-model.md` §3 the baseline is about 231 reads/DAU/day, roughly 69k reads/day at 300 DAU. Reads are
**already above** the free 50k at the Stage 0 target, so every added read is billed. Writes are about 31.8/DAU/day
(48% of 20k at 300 DAU).

**What the code has today (verified):**
- `proto/dzeroth/posts/v1/posts.proto` defines `PostService{CreatePost, DeletePost, GetPost, GetThread}`.
  - Next free field numbers: `Post` 18, `CreatePostRequest` 7, `EmbeddedPost` 7, `PostView` 4.
  - In `common.proto`, the next `ErrorReason` value is 16 (`REAUTH_REQUIRED = 15`; `LIMIT_REACHED = 9` exists).
  - Nothing named `reply_policy`, disclosure or schedule exists.
- `backend/internal/posts/service_create.go`: `Create` reads the author, then calls `replyParent` (line 93). That
  calls `resolveTarget` (`service_engagement.go:63`), which applies the GetPost visibility rules of `viewable`
  (`service_delete.go:157-216`) and resolves a REPOST to the original. `viewable` checks only the **parent's** author
  (and an embedded author); it never looks at the conversation root. It skips the caller's graph when the caller wrote
  the parent (line 187), and a caller who blocked the author still gets the post. Then `Create` resolves mentions
  (line 103) **before** the transaction and calls `repo.Create`. `requestHash` (line 234) guards against
  IDEMPOTENCY_KEY_REUSED.
- `backend/internal/posts/service_thread.go:183-238`: `threadContext` already has a single "usable context post"
  predicate (lines 204-225), described below in D2.
- `backend/internal/posts/repo_create.go` runs one transaction with a 5 s deadline (line 36). The **post id (a
  Snowflake) and createdAt are drawn inside every attempt** (line 167; ADR-0010 D13/D18), and the timeline `since`
  watermark depends on that. Inside the attempt the order is idempotency doc, quotas, media, then
  `quota.CheckAndReserve` (line 188). `users.postsCount` is bumped through the `identity.Counters` seam (line 195),
  a field `Update` with an implicit Exists precondition.
- The Firestore client (`cloud.google.com/go/firestore` v1.26.0, `transaction.go:208-241`) rolls a transaction back
  only when the callback **returns** an error. The repo's wrapper `store.RunTransaction` (`pkg/platform/store/txn.go:25-36`)
  adds budget accounting but no recover. A panic inside the callback skips the rollback, and the transaction stays
  open until the server expires it.
- `golang.org/x/sync` v0.24.0 `errgroup.Group.Go` deliberately does not pass a goroutine's panic on to `Wait`
  (`errgroup.go`, the comment in `Go`). An unrecovered worker panic ends the process.
- `backend/internal/graph/api.go`: `Reader.Snapshot(uid)` returns the whole `graph/{uid}`, cached 60 s.
- `backend/internal/apiserver/apiserver.go:401-416`:
  - `protectInternal` is an OIDC verifier: the audience must be the service URL, and the email must be in
    `INTERNAL_OIDC_ALLOWED_EMAILS` (the pubsub-push SA). The allowlist is the same for every `/internal/*` route.
  - Every other `/internal/*` path hits `pubsubpush.PlaceholderHandler`, which answers 202 and does nothing
    (`pubsubpush.go:57-61`).
  - `/internal/cron/daily-maintenance` is served by `identity.Lifecycle.CronHandler` (`lifecycle_jobs.go:564`). It
    takes POST only, runs under a 25 s deadline with `budget.WithCounter`, and answers 204, or 500 so Cloud Scheduler
    retries. Its `recoverPanic` (lines 95-106, unexported) covers only the handler goroutine. The `Backstop` workers
    (`errgroup.Group`, lines 474-496) have no recover.
- `infra/terraform/modules/scheduler/main.tf` creates one job per map entry: UTC, `retry_count = 3`, OIDC with the
  pubsub-push SA. Prod (`envs/prod/main.tf:308`) has 1 job, `daily-maintenance`; dev (`envs/dev/main.tf:317`) has
  `jobs = {}`. **The billing account uses 1 of its 3 free jobs.** The pubsub-push SA holds only `run.invoker`
  (`modules/iam/main.tf:102-111`).
- App Check is in **monitor** mode in both envs (`envs/dev/main.tf:261`, `envs/prod/main.tf:253`).
- `backend/pkg/platform/quota`: `quotas/{uid}` is a per-IST-day record. `Get` returns a fresh record on a new day and
  `CheckAndReserveN` `Set`s the whole doc (`quota.go:172-178`). It can hold a daily counter, but **not** a persistent
  one. Config names follow `QUOTA_<KIND>_PER_DAY` and `QUOTA_NEW_ACCOUNT_<KIND>_PER_DAY`, with the window
  `QUOTA_NEW_ACCOUNT_WINDOW` (24 h) (`config.go:510, 648-691`).
- `backend/pkg/platform/logger/redact.go`: `ScrubErr` (line 66) is `RedactErr` plus a pattern pass that replaces any
  `documents/...` path (line 55), so third-party uids in Firestore error text never reach a log line.
- Account deletion (`identity/lifecycle.go`):
  - Erasers run in registration order, all `BeforeIdentity`. `lifecycle_wiring_test.go:178` pins the order.
  - The start gate is 120 s, twice the 60 s cache TTL.
  - The T11 guard (`apiserver/lifecycle_collections_guard_test.go`) fails `make ci` for any collection without a row.
- Suspension (`cmd/opsctl/moderation.go:37`): the settle pass runs `config.MaxCacheTTL + 15 s` = 75 s after the
  status write, which is enough for a request that read ACTIVE from the 60 s cache just before its 5 s transaction.

**Stage 0 requirements:**
- *Functional:* a root post or quote can carry a reply policy; any post (root, reply or quote) can carry two disclosure
  labels, which are never rejected for the post kind (D3). A user can schedule a root
  post with up to 4 images for 2 min to 60 days ahead, then list and cancel it. Clients can show who may reply.
- *Non-functional:*
  - 0 extra timeline reads.
  - Replies in EVERYONE conversations +0 reads. Replies in restricted conversations at most **+4 cold** reads, +0
    warm (the security review's root check costs more than the plan's +2; see D2 "Cost").
  - At most 5 min of publish lateness in steady state.
  - Never double-publish.
  - $0 fixed cost.
  - `buf breaking` clean.
  - Deletion covers every new document.

## Options (scheduling mechanism; the other two features have no real alternative)
| | A. One Cloud Scheduler sweep (recommended) | B. Cloud Tasks, one task per post | C. Fold into `daily-maintenance` (one 5-min job running both) | D. In-process timer |
|---|---|---|---|---|
| Lateness | ≤ 5 min + run time | about 0 | ≤ 5 min | none, until the instance dies |
| New service / IAM | none (the job module exists) | Cloud Tasks API, queue, enqueuer role, DeleteTask on cancel | none | none |
| Horizon | any (60 d) | documented max `scheduleTime` is 30 days, so 60 d needs re-enqueue chaining | any | n/a |
| Coupling | own route, own flag, own degraded-mode rule | per-post state in two systems | ties publishing to the account-deletion backstop, which ADR-0011 Q8/Q9 says must **never** sit behind a flag or degraded mode; the sweep must | n/a |
| Idle $/month | $0 (2 of 3 free jobs) | $0 inside the free ops (unverified in `free-tier-budget`) | $0 (1 of 3) | $0 |
| Verdict | **chosen** | rejected: new service, unverified quota, 30-day cap, cancel needs a second API | rejected: the slot is not scarce (2 of 3) and the coupling is unsafe | rejected: Cloud Run scales to 0 and has CPU only during requests |

## Decision
### D1. Scheduling: one sweep job, prod only
- **The job.** Prod gets one Cloud Scheduler job, `publish-scheduled`, POST `/internal/cron/publish-scheduled`, with
  OIDC like `daily-maintenance`. The schedule `*/5 * * * *` is a Terraform variable. That makes **2 of 3** free jobs.
  Dev keeps `jobs = {}`.
- **Testing in dev (plan error).** `gcloud scheduler jobs run` cannot run a job that does not exist. Dev calls the
  route directly with an OIDC token minted for the dev pubsub-push SA:
  `curl -X POST -H "Authorization: Bearer $(gcloud auth print-identity-token --impersonate-service-account=<dev pubsub-push SA> --audiences=<dev api_url> --include-email)" <dev api_url>/internal/cron/publish-scheduled`
  - **Fallback** if gcloud's impersonation needs more than `getOpenIdToken` (not verified from the repo): mint the
    token through IAM Credentials with the founder's own access token, which needs only the OpenID role:
    `curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d '{"audience":"<dev api_url>","includeEmail":true}' https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<dev pubsub-push SA>:generateIdToken`
    and pass the returned `token` as the Bearer.
  - **The grant (security review L-5).** `roles/iam.serviceAccountOpenIdTokenCreator` (only
    `iam.serviceAccounts.getOpenIdToken`), **not** `serviceAccountTokenCreator` (which also grants `getAccessToken`,
    `signBlob`, `signJwt`). Bound on the **dev** pubsub-push SA only, to a principal given as a Terraform variable,
    with an IAM condition `request.time < timestamp("<apply date + 30 days>")`. **Never in prod.** Renewal is a new
    dated dev apply.
  - Why it matters: the verifier's allowlist is not per route (`apiserver.go:404-416`), so a token minted for this
    curl is also accepted by `/internal/pubsub/jobs` and `/internal/pubsub/notifications-fanout`.
  - **Follow-up, out of scope here (review I-1):** a separate `cron-invoker` SA accepted only on `/internal/cron/*`
    (per-route allowlists), plus `iss` and `email_verified` checks in `pubsubpush.go`. That needs its own small ADR or
    security ticket.
  - The comment at `envs/dev/main.tf:316` has the same `gcloud scheduler jobs run` problem for `daily-maintenance`.
    Fix both.
- **The route.** Mounted with `protectInternal` next to line 412. POST only, a 25 s context deadline,
  `budget.WithCounter` (system reads, never charged to a user's ADR-0010 D5 budget), and route-level panic recovery.
  `posts` needs its own recover wrapper, because identity's `recoverPanic` is unexported. Per-item recovery is in
  §Sweep.

### D2. Reply policy
- **Enum.**
  - `UNSPECIFIED=0` means EVERYONE. Every post written before this ADR has it.
  - `EVERYONE=1`.
  - `FOLLOWING=2`: the conversation author follows the replier.
  - `MENTIONED_ONLY=3`.
  - `FOLLOWING_OF_FOLLOWING=4` and `VERIFIED=5` are **declared now and rejected** with VALIDATION
    (`field=reply_policy`, "not available yet").
  - *Plan error (CMP-B1):* the plan says to reserve those two names. A proto `reserved` entry can never be removed
    under the `FILE` breaking rules in `proto/buf.yaml` (RESERVED_ENUM_NO_DELETE), so the names would be lost forever.
- **Where it can be set.** Only on a root post or a quote, since either starts its own conversation. A
  non-UNSPECIFIED value on a reply is VALIDATION ("set who can reply on the first post of a conversation").
- **Inheritance.** The policy covers the whole conversation, as on X. Without that, an allowed replier's reply would
  open a door for everyone else.
  - Each reply stores the effective policy copied from its parent. That costs 0 reads, because the parent is already
    loaded.
  - **No uid is copied.** Copying the root author's id or the mention ids into other users' reply docs would create
    new account-deletion residue (ADR-0011 Q10 allowlist plus a privacy-policy change).
- **Enforcement.** It runs in `service.Create` right after `replyParent` returns (service_create.go:93), before
  mentions and the transaction.
  - A REPOST parent is already resolved to the original, so the original's policy applies.
  - **Only when the parent's (inherited) policy is FOLLOWING or MENTIONED_ONLY.** An EVERYONE / absent policy keeps
    today's reply rules exactly, with +0 reads and no root check.
- **The root R and "R usable" (security review M-1).**
  - For a reply to the root itself (`parent.ConversationID == parent.ID`), R is the parent. Otherwise R is
    `posts.Get(parent.ConversationID)`, cache first.
  - **R is usable** under exactly the `threadContext` predicate (`service_thread.go:204-225`), reused as one shared
    helper rather than copied:
    - R exists, is `PUBLIC` and not `Hidden()` (no takedown or suspension, ADR-0016);
    - R's author has an ACTIVE profile (`directory.GetProfiles` omits SUSPENDED, DELETING and missing authors);
    - unless the caller is R's author: R's author does not block the caller (`snap.BlockedBy`), the caller does not
      block R's author (`snap.Blocked`), and the caller's `blockedByOverflow` is false (fail closed, no extra read);
    - for a QUOTE root, the embedded author does not block the caller.
  - **Any unusable R returns the single NOT_FOUND "post not found" answer**, the same `s.notFound` that `viewable`
    gives. GetThread already shows this case as `root_unavailable`, so the answer reveals nothing new.
  - **Only once R is usable** is the policy evaluated. REPLY_NOT_ALLOWED can therefore never mean "R's author blocked
    me", because a block in either direction has already answered NOT_FOUND. This holds for deep replies too; the
    earlier claim that "a blocked caller never sees REPLY_NOT_ALLOWED" was true only for direct replies to the root.
  - Two deliberate differences from `viewable` on a direct reply (R = parent), neither an oracle:
    - a caller who blocked R's author gets NOT_FOUND here, although GetPost still shows them the post (the caller
      knows their own block);
    - an overflowed caller (more than 10,000 blockers) fails closed instead of paying `viewable`'s extra read.
- **Who may reply** (R usable):
  - R's author: always.
  - **FOLLOWING:** `graph.Reader.Snapshot(R.AuthorID).Following[caller]`. 1 read cold, 0 warm (60 s cache), no N+1.
    A follow change can take up to 60 s to apply.
  - **MENTIONED_ONLY:** the caller must be in `R.Mentions[].UserID`. 0 reads beyond R. Only the root's mentions grant
    access, so a reply cannot widen the audience by mentioning more people.
- **Cost** (cold; all caches 60 s, so typically +0):
  - Parent = R: `viewable` has already loaded R, its author and the caller's graph. MENTIONED_ONLY +0, FOLLOWING +1
    (R's author's graph).
  - Deeper: R +1, R's author profile +1 (0 when it is the parent's author), the caller's graph +1 only when the caller
    wrote the parent (`viewable` skipped it), FOLLOWING +1. Worst case: MENTIONED_ONLY +3, FOLLOWING +4.
- **Refusal.** `PERMISSION_DENIED` + new `ERROR_REASON_REPLY_NOT_ALLOWED = 16` with `metadata["policy"]`. Nothing is
  written and nothing is stored under the idempotency key.
- **Follow-state disclosure.** Under FOLLOWING, a refusal tells the caller whether R's author follows them. That is
  already public through `ListFollowing` (graph.proto:104, open to any caller the target has not blocked). Nothing
  new leaks, and ADR-0008 D4 is not bent. This holds only while following lists are public: the private-accounts ADR
  must revisit both the refusal and `viewer_reply_permission` (review I-4).
- **Viewer hint.** `PostView.viewer_reply_permission` is ALLOWED, NOT_ALLOWED or UNKNOWN.
  - Timelines decide it with 0 reads **for root posts only**: EVERYONE, the viewer is the author, or MENTIONED_ONLY.
  - A REPOST row has no policy of its own: the hint uses `embedded.replyPolicy`. `EmbeddedPost` carries no mentions,
    so a MENTIONED_ONLY or FOLLOWING repost row is UNKNOWN (review I-6).
  - Reply rows in restricted conversations, and FOLLOWING roots, are UNKNOWN. The client shows the policy label and
    lets the server decide.
  - GetPost of a root may spend ≤ +1 cold read (R's author's graph). **GetPost of a reply in a restricted
    conversation returns UNKNOWN** and never derives the hint from R's usability: ALLOWED vs NOT_ALLOWED for a
    mentioned viewer would recreate the M-1 oracle.
  - GetThread already loads R through `threadContext`: with `root_unavailable` the hint is UNKNOWN; otherwise it is
    computed (≤ +1 cold read for FOLLOWING).
- **Flag.** `FEATURE_REPLY_AUDIENCE` gates **setting** a policy.
  - With the flag off, a non-UNSPECIFIED value is FEATURE_DISABLED with `feature="reply_audience"` and 0 reads.
  - Check order (ADR-0010 D2): replies, quotes, media, reply_audience, content_disclosure.
  - **Enforcement is not flag-gated**, so switching the flag off never silently reopens a conversation a user
    restricted.
- **Out of scope.** Changing the policy after posting (X allows it; that needs a later ADR). Quoting and reposting a
  restricted post stay allowed, as on X.

### D3. Content disclosure
- **Fields.** Two bools, `paid_partnership` and `made_with_ai`, asserted by the user. No detection, nothing rejected:
  they are labels only.
- **Copy.** Client copy must not imply legal-compliance advice. A false label can be reported through the existing
  ReportContent.
- **Storage.** On the post doc, and **copied into the `Embedded` snapshot** by `snapshotOf` (service_engagement.go:94)
  so reposts and quotes keep the label. *Plan error (CMP-C2):* the plan puts them in "the denormalised author
  snapshots", but `AuthorSnapshot` is per user, not per post.
- **Rendering.** The client shows each label on the content it belongs to: a quote's own labels on the quote, the
  embedded post's labels on the embed (review I-6).
- **Flag.** `FEATURE_CONTENT_DISCLOSURE` off with either bool true gives FEATURE_DISABLED
  (`feature="content_disclosure"`). Turning it off leaves existing labels rendered.

### D4. Scheduled posts
- **Root posts only.** `SchedulePostRequest` lists its fields explicitly and does not nest `CreatePostRequest`.
  Nesting would carry a second `idempotency_key`, plus reply and quote targets that can disappear before publish.
- **Reply policy with a schedule (departs from X; founder item 2).** `reply_policy` **is allowed** with `publish_at`,
  and the control stays enabled. The policy is plain data on the post, enforced at reply time. MENTIONED_ONLY uses
  the mentions resolved at publish, so nothing depends on the delay.
- **Polls are out of scope, with a forward-compatible path.**
  - `SchedulePostRequest` has no poll field. The polls ADR decides whether polls and schedules combine. X disables
    that combination, probably because a poll's length should start at publish.
  - Clients send poll fields only when `enabled_features` lists polls, because proto3 silently drops unknown fields
    on an older server.
  - Each scheduled doc carries `schemaVersion: 1`. A sweep that finds a higher version marks the doc FAILED
    `UNSUPPORTED` rather than publishing a partial post. This keeps a revision rollback safe.
- **Time.**
  - The wire carries UTC `publish_at` only; the IANA zone is a client display concern.
  - The server truncates `publish_at` to the minute and requires
    `now + SCHEDULED_MIN_LEAD (2 min) ≤ publish_at ≤ now + SCHEDULED_HORIZON (60 d)`, otherwise VALIDATION
    `field=publish_at`.
  - Server time is the authority (Google NTP). The response echoes the stored time, so "Will send on ..." stays
    truthful even when the device clock is skewed.
- **Limits (config).**
  - At most `SCHEDULED_MAX_PENDING` (25) pending items per user. Enforced by a `count()` over
    `status == PENDING` with `Limit(SCHEDULED_MAX_PENDING + 1)` (rule 5; still 1 read). → `LIMIT_REACHED`
    (`limit=scheduled_pending`).
  - **At most `SCHEDULED_PER_AUTHOR_PER_RUN` (3) pending items within ±4 min of the new `publish_at`** (security
    review L-3, applied differently; founder item 4). A `count()` over `status == PENDING && publishAt` in
    `[t − 4 min, t + 4 min]` with `Limit(4)`, served by the COLLECTION index below, 1 read. Any 5 consecutive
    minutes then hold at most 3 of one author's items, so a 5-min sweep run normally sees ≤ 3 per author and the
    per-run cap in §Sweep only acts on a backlog. → `LIMIT_REACHED` (`limit=scheduled_window`).
  - At most `QUOTA_SCHEDULES_PER_DAY` (50) SchedulePost calls per IST day, and `QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY`
    (10) for accounts younger than `QUOTA_NEW_ACCOUNT_WINDOW` (review L-4; named after the existing quota keys, not
    `SCHEDULED_PER_DAY*`). Counted in a new daily field `quotas.schedules` (`quota.Schedules`), read and written in
    the transaction. → `QUOTA_EXCEEDED` (`quota=schedules`). This exact cap bounds schedule/cancel churn.
  - Both counts run **outside** the transaction, so the 25 and the window caps are **soft**. Concurrent calls can
    overshoot by the number in flight. The 10/min CreatePost bucket (SchedulePost and Cancel share it) bounds that,
    but it is a per-instance in-memory limiter, so the real bound is bursts across up to 3 instances, still capped by
    the daily quota (review I-3). A persistent counter cannot live on `quotas/{uid}`, which resets daily.
    [Amended: see Implementation notes 6]
  - **`quotas.schedules` can be reset by an older revision** (review I-3): `CheckAndReserveN` `Set`s the whole record,
    so a revision without the field zeroes it on that user's next quota'd call. The L-1 rollout rule below keeps old
    revisions off traffic once the flag is on, so this happens only on a rollback. Bound: one extra day's quota
    (≤ 50, or 10) per reset, still under the pending and window caps.
- **SchedulePost order (security review L-6).**
  1. Flags (FEATURE_POSTS, FEATURE_SCHEDULED_POSTS, then media / reply_audience / content_disclosure), 0 reads.
  2. `idempotency_key` format, verified email, request shape (media ids, alt texts, enum values). 0 reads.
  3. Normalise, which is pure: text parse (NFC), `publish_at` truncated to the minute, `reply_policy` with
     UNSPECIFIED and EVERYONE both stored as **absent**. Compute the doc id and `requestHash` from these
     **effective** values.
  4. Read `users/{uid}/scheduled/{id}` (1 read). If it exists: same hash → return the stored item (a replay, 0
     writes); a different hash → IDEMPOTENCY_KEY_REUSED.
  5. Only then the time checks: lead and horizon against `now`.
  6. The pending count, then the window count.
     [Amended: see Implementation notes 6]
  7. The transaction: `quotas/{uid}` (daily cap), media `LoadForPost` (owned, READY or READY_UNSCREENED,
     unattached; no `Attach`), then `Create` the scheduled doc and reserve `quotas.schedules`. An AlreadyExists at
     commit is a concurrent first call: read the doc once more and answer as in step 4.
     [Amended: see Implementation notes 6]

  A retry that arrives after the 2-min lead has passed, or after the caps filled, therefore still gets its stored
  item, and the client never re-schedules under a new key (which would double-publish).

  Known limit (CMP-D3 review m1): a duplicate that arrives while the first call is still committing runs steps 4 to 6
  before the doc exists, so it can answer LIMIT_REACHED or QUOTA_EXCEEDED instead of the stored item. The client must
  keep the same `idempotency_key` and retry after any cap error; the retry returns the stored item. Closing the gap
  would cost one more `GetScheduled` read on each cap-rejection path (budgets 3 / 4 / 5 become 4 / 5 / 6) and was
  not done.
  [Amended: see Implementation notes 6]
- **Exactly-once publish.** *Plan error (CMP-D4, follow-on (b)):* a "deterministic post id derived from the scheduled
  id" **does not fit the code**.
  - Post ids are Snowflakes whose millisecond is `createdAt`, drawn per transaction attempt. An id fixed at schedule
    time carries a createdAt days in the past. Clients already past that `since` watermark would never see the post,
    and feeds would sort it wrongly. A hash is not a valid Snowflake at all.
  - What we do instead: the **publish transaction first re-reads `users/{uid}/scheduled/{id}` and requires
    `status == PENDING`**. It creates the post with a fresh Snowflake and sets `status=PUBLISHED, postId` in the same
    commit.
  - A concurrent or retried sweep loses the race, retries, reads PUBLISHED and does nothing.
  - The scheduled doc is the idempotency record, so there is no `idempotency/*` doc.
- **Idempotency of the user RPCs (bend of rule 4; same pattern as ADR-0018's founder-approved bend; founder item 3).**
  - SchedulePost's doc id is the first 32 hex characters of `SHA-256(uid|"SchedulePost"|idempotency_key)`, as for
    `reports/*`.
  - Its `requestHash` covers the effective text, media ids, alt texts, policy (absent for EVERYONE), both bools and
    the truncated `publish_at`. The same key with a different time gives IDEMPOTENCY_KEY_REUSED.
  - CancelScheduledPost is idempotent by state. An already-terminal item costs 0 writes. Its `idempotency_key` is
    **unused but still format-validated** (VALIDATION when malformed), so clients keep one code path and a later
    change can start using it.
  - Neither stores a TTL'd idempotency doc, which saves 1 write and 1 TTL delete per call.

## Proto diff (proposal; additive only, `buf breaking` clean)
| File | Change |
|---|---|
| `common/v1/common.proto` | `ErrorReason`: `ERROR_REASON_REPLY_NOT_ALLOWED = 16; // PERMISSION_DENIED; metadata["policy"]` |
| `posts/v1/posts.proto` | new `enum ReplyPolicy { REPLY_POLICY_UNSPECIFIED = 0; REPLY_POLICY_EVERYONE = 1; REPLY_POLICY_FOLLOWING = 2; REPLY_POLICY_MENTIONED_ONLY = 3; REPLY_POLICY_FOLLOWING_OF_FOLLOWING = 4; /* rejected: not available */ REPLY_POLICY_VERIFIED = 5; /* rejected */ }` |
| | new `enum ReplyPermission { REPLY_PERMISSION_UNSPECIFIED = 0; /* older server: treat as allowed */ REPLY_PERMISSION_ALLOWED = 1; REPLY_PERMISSION_NOT_ALLOWED = 2; REPLY_PERMISSION_UNKNOWN = 3; }` |
| | `CreatePostRequest`: `ReplyPolicy reply_policy = 7; bool paid_partnership = 8; bool made_with_ai = 9;` |
| | `Post`: `ReplyPolicy reply_policy = 18; /* effective, inherited on replies */ bool paid_partnership = 19; bool made_with_ai = 20;` |
| | `EmbeddedPost`: `bool paid_partnership = 7; bool made_with_ai = 8; ReplyPolicy reply_policy = 9;` |
| | `PostView`: `ReplyPermission viewer_reply_permission = 4;` |
| | new `enum ScheduledPostStatus` (prefix `SCHEDULED_POST_STATUS_`): `UNSPECIFIED = 0; PENDING = 1; PUBLISHED = 2; CANCELLED = 3; FAILED = 4;` |
| | new `enum ScheduledPostFailure` (prefix `SCHEDULED_POST_FAILURE_`): `UNSPECIFIED = 0; MEDIA_UNAVAILABLE = 1; QUOTA_EXCEEDED = 2; ACCOUNT_RESTRICTED = 3; INVALID_CONTENT = 4; EXPIRED = 5; INTERNAL = 6; UNSUPPORTED = 7;` |
| | new `message ScheduledPost { string scheduled_id = 1; /* 32 hex */ string text = 2; /* empty once PUBLISHED or CANCELLED */ repeated dzeroth.common.v1.MediaRef media = 3; /* incl. alt; list thumbnails; empty once PUBLISHED or CANCELLED */ ReplyPolicy reply_policy = 4; bool paid_partnership = 5; bool made_with_ai = 6; google.protobuf.Timestamp publish_at = 7; /* UTC, whole minute */ ScheduledPostStatus status = 8; string post_id = 9; /* PUBLISHED */ ScheduledPostFailure failure = 10; /* FAILED */ google.protobuf.Timestamp created_at = 11; }` |
| | `message SchedulePostRequest { string idempotency_key = 1; string text = 2; repeated string media_ids = 3; repeated string media_alt_texts = 4; ReplyPolicy reply_policy = 5; bool paid_partnership = 6; bool made_with_ai = 7; google.protobuf.Timestamp publish_at = 8; }` → `SchedulePostResponse { ScheduledPost scheduled_post = 1; }` |
| | `message ListScheduledPostsRequest { int32 page_size = 1; /* 0 => 20, max 50 */ string page_token = 2; /* opaque, HMAC-bound to "scheduled|<uid>" */ }` → `ListScheduledPostsResponse { repeated ScheduledPost scheduled_posts = 1; string next_page_token = 2; }` |
| | `message CancelScheduledPostRequest { string idempotency_key = 1; /* unused, format-validated */ string scheduled_id = 2; }` → `CancelScheduledPostResponse { ScheduledPost scheduled_post = 1; /* current state; PUBLISHED = too late, not an error */ }` |
| | `PostService`: `rpc SchedulePost`, `rpc ListScheduledPosts` (`NO_SIDE_EFFECTS`), `rpc CancelScheduledPost`, each with a budget comment from the table below |

**Rules for the three new RPCs:**
- All three need FEATURE_POSTS (`FEATURE_DISABLED` with 0 reads when off). SchedulePost also needs FEATURE_SCHEDULED_POSTS on
  for the caller; ListScheduledPosts and CancelScheduledPost only need it **not globally off** (`feature="scheduled_posts"`
  on refusal), so a user who is outside the allowlist or percent bucket, or was removed from it, can still list and cancel
  what they already scheduled (security review L-A, option b; `flags.Registry.GloballyOff`).
- SchedulePost also applies the media, reply-audience and disclosure sub-feature checks, and requires a verified email
  as CreatePost does.
- Error mapping:
  - the pending cap → `LIMIT_REACHED` (`limit=scheduled_pending`);
  - the window cap → `LIMIT_REACHED` (`limit=scheduled_window`);
  - the daily cap → `QUOTA_EXCEEDED` (`quota=schedules`);
  - an unknown id, including any id belonging to another user → NOT_FOUND;
  - an id that does not match `^[0-9a-f]{32}$` → VALIDATION.
- A replay of a SchedulePost whose item is now PUBLISHED or CANCELLED, and a Cancel of such an item, return the item
  **without text or media** (the draft is cleared, §Firestore model). The client keeps its own copy for display.
- List and Cancel build the path from the token uid and never look an id up through the collection-group index.

**CreatePost `requestHash`.** Append `|policy=…|pp=…|ai=…` **only when the effective values are not the defaults**
(EVERYONE and UNSPECIFIED both count as absent; a reply's request carries no policy, and the policy it inherits is
never hashed), so a CreatePost retried across the deploy (within the 24 h TTL) still hashes the same.
Exact bytes, appended to the existing base string in this order and each only when non-default: `|policy=<NAME>`
(the enum name, e.g. `|policy=FOLLOWING`), then `|pp=1`, then `|ai=1`; `|policy=` always comes before `|pp=1`.

## Firestore model
**`posts/{postId}`** gets new fields. Each is absent by default, there is no backfill, and an absent field means the
old behaviour:
- `replyPolicy`: `FOLLOWING` | `MENTIONED_ONLY`; absent = EVERYONE; on replies, the inherited value.
- `paidPartnership`, `madeWithAi`: bools.
- `embedded.{paidPartnership, madeWithAi, replyPolicy}`.

**`users/{uid}/scheduled/{scheduledId}`** (owner: posts; collection group `scheduled`):
| Field | Notes |
|---|---|
| `schemaVersion` | 1 |
| `draft` | map: `text` (normalised at schedule time), `media[]` (MediaRef copies from `LoadForPost`, with alt), `replyPolicy`, `paidPartnership`, `madeWithAi`. Index-exempt. **Present only while PENDING** (cleared on PUBLISHED, CANCELLED and FAILED) |
| `publishAt` | timestamp, UTC, minute precision |
| `status` | `PENDING`, `PUBLISHED`, `CANCELLED`, `FAILED` |
| `failure` | reason name when FAILED |
| `attempts` | transient publish failures so far |
| `postId` | when PUBLISHED |
| `requestHash` | index-exempt; a one-way digest kept for replay |
| `createdAt`, `updatedAt` | |
| `expireAt` | set on entering a terminal state: now + `SCHEDULED_TERMINAL_TTL` (7 d). TTL policy |

**Status transitions.** Every transition is conditional on the doc existing and being PENDING (FAILED for the
dismiss); none uses `Set` (§Sweep "State writes").
- PENDING → PUBLISHED: the publish transaction. **Clears `draft`** in the same commit.
- PENDING → CANCELLED: the user cancels, or the sweep finds the account DELETING or gone. **Clears `draft`.**
- PENDING → FAILED: a permanent cause, expiry, a recovered panic, or `attempts ≥ SCHEDULED_MAX_ATTEMPTS`. Clears
  `draft` (founder, 2026-10-24: failed items are not rescheduled).
- FAILED → CANCELLED: the user dismisses it. **Clears `draft`.**
- A FAILED item holds no draft, so the client cannot reschedule from it: the user dismisses it (cancel) and re-enters the post.
- A PUBLISHED or CANCELLED doc keeps only `status`, `postId`, `failure`, `requestHash`, `publishAt` and timestamps
  for its 7-day TTL: enough for a replay and for Cancel's "too late" answer (review L-2).

**Media.**
- Media are **validated, not reserved**. At schedule time `MediaAttacher.LoadForPost` runs in the schedule transaction
  without `Attach`; at publish it reloads and attaches. An image used elsewhere in between fails the item
  `MEDIA_UNAVAILABLE`.
- READY media docs carry no TTL (`media/service.go`: only PENDING and REJECTED docs expire), so a 60-day horizon is
  safe.
- **Scheduled images are public by link before publish** (review L-9). As before (ADR-0005), a READY image that is not
  attached to a post is already at its public-bucket URL `m/<mediaId>.<ext>`
  (`lifecycle_collections_guard_test.go:107`). For a scheduled post that lasts up to 60 days. Anyone holding or
  guessing the Snowflake-named URL can fetch it, and it cannot be reported because no post exists yet.
  - The schedule dialog must say so: "Images are uploaded now and can be reached by anyone with the link before the
    post goes out."
  - Private-until-attach would be an ADR-0005 amendment (founder item 5).

**Indexes (`firebase/firestore.indexes.json`).**
| Scope | Fields | Serves |
|---|---|---|
| `scheduled`, **COLLECTION_GROUP** | `status ASC, publishAt ASC` | the sweep: `status == PENDING && publishAt <= now ORDER BY publishAt LIMIT 50` |
| `scheduled`, **COLLECTION** | `status ASC, publishAt ASC` | the list: `status in [PENDING, FAILED] ORDER BY publishAt, __name__ ASC LIMIT page`, cursor `(publishAt, id)`; and the window `count()` (`status == PENDING`, `publishAt` range). A collection-group index is not relied on for a collection query |

- The pending `count()` uses the automatic single-field index on `status`.
- fieldOverrides exempt `scheduled.draft`, `scheduled.requestHash` and `posts.replyPolicy`.
- TTL: a new `ttl_fields` entry `scheduled_expire_at` (`collection = "scheduled"`, `field = "expireAt"`) in
  `infra/terraform/modules/firestore/variables.tf`.
- Rules: `firebase/firestore.rules` stays deny-all (`{document=**}` covers the subcollection).

**Right to delete.** *Plan error (CMP-D2):* "under users/{uid} so the right-to-delete path covers it" is false.
Deleting `users/{uid}` does **not** delete its subcollections, and the T11 guard would fail `make ci`. Needed:
1. A new eraser step `scheduled` (`posts.ScheduledEraser.PurgeUser`): pages of ≤ 500, 1 read and 1 delete per doc,
   registered `BeforeIdentity` after the existing steps (as engagement and reports are).
   - The order does not matter for safety. The publish transaction reads the author's status itself (§Sweep), so a
     DELETING account never publishes, and no sweep write can recreate a doc the eraser deleted (§Sweep "State
     writes").
   - Update the pinned order in `lifecycle_wiring_test.go:178`.
2. A T11 row: `{Name: "scheduled", Sub: true, Disposition: erasedByStep, Step: "scheduled", Section: "scheduled",
   Owner: "posts", Cite: "ADR-0021"}`.
3. An export section `scheduled` that lists **every** scheduled doc (status, `publishAt`, `postId`, failure,
   timestamps) and includes the draft wherever one is still held, which is PENDING only. Since PUBLISHED, FAILED and
   CANCELLED docs no longer hold a draft, no user content sits outside the export: a published post's text lives
   only in `posts`, which is exported there and gone once the user deletes the post.
4. No residue: these docs hold only the owner's data, and D2 copies no other user's uid.

## Sweep (`posts.Scheduler.Sweep`, route of D1)
1. **No-op cases.** If `FEATURE_SCHEDULED_POSTS` is `off`, or `FEATURE_POSTS` is globally `off`, or
   `DEGRADED_MODE=readonly`, return 204 with **0 reads** (`outcome=flag_off|degraded`).
   - In allowlist or percent mode the sweep processes every due doc, because only enabled users could create them.
   - Per-user flags are not re-evaluated at publish: they gated creation.
2. **Query and dispatch.**
   - Run the collection-group query from the index table with `Limit SCHEDULED_SWEEP_LIMIT` (50, clamped ≤ 50).
     Repeat up to `SCHEDULED_SWEEP_MAX_PAGES` (2) times while at least 6 s of the 25 s remain.
   - **Path shape (review L-7).** Accept only results whose ref is exactly `users/{uid}/scheduled/{id}`: the parent
     collection is `scheduled`, its parent is a top-level `users` doc, `ids.ValidUID(uid)`, and `id` matches
     `^[0-9a-f]{32}$`. Take the uid from the path. Skip anything else and count it as `skipped_bad_path` (no path in
     the log). A skipped doc is re-read every run (1 read each), so the count alerts.
   - **Per author (review L-3).** Group the due items by uid in query order. Each author gets one worker, which runs
     at most `SCHEDULED_PER_AUTHOR_PER_RUN` (3) of their items **one after another**. The rest wait for the next tick
     without a write. At most `SCHEDULED_SWEEP_CONCURRENCY` (4) workers run at once (a semaphore plus a WaitGroup, or
     a plain `errgroup.Group`; **never `errgroup.WithContext`**, whose first error would cancel the others).
     - The author queues and counts span both pages: a page-2 item joins its author's existing queue (and counts
       toward the cap) instead of starting a second worker.
     - Within a run no two items of one author overlap, so publishes do not contend on that author's `quotas/{uid}`
       and `users/{uid}`. Across overlapping runs (a retry plus the next tick) only the transaction serializes them.
     - Why the schedule-time window cap matters: the query breaks `publishAt` ties on `__name__`, which on a
       collection group is the full path, so one minute's items cluster by uid. A 50-item page can hold as few as 2
       authors. With a per-run cap alone, throughput collapses to about 12 publishes per run, and the deferred items
       are re-read at the head every run, which makes a flood **worse** (see Lateness). The window cap keeps each
       author at ≤ 3 per 5-minute span, so in steady state nothing is deferred.
   - **Per-item contexts (review M-2).** Each item runs on its own context derived from the run's 25 s deadline (no
     group cancellation). A new item is started only while at least 6 s remain. The publish transaction keeps its
     own 5 s bound (`repo_create.go:36`).
3. **Each item, cheapest and most decisive check first (review L-4):**
   1. **Expiry.** If `now − publishAt > SCHEDULED_MAX_LATENESS` (6 h), mark it FAILED `EXPIRED`. 0 reads (the query
      returned the doc). This is the catch-up bound: after an outage, stale posts are not dumped onto feeds hours
      late. The user re-enters the post (the draft is cleared).
   2. `schemaVersion` above 1 → FAILED `UNSUPPORTED`. The text parse (rules may have tightened) → FAILED
      `INVALID_CONTENT`. Both are CPU only, 0 reads.
   3. **The publish transaction** (`posts.service.publishScheduled`). It reuses the CreatePost draft builder and
      `repo.Create` with a `CreateParams.Scheduled` guard in place of the idempotency doc, but **not** `Create`'s
      resolve-mentions-before-the-transaction order. Inside each attempt:
      1. Re-read the scheduled doc. It must exist and be PENDING; otherwise the attempt ends as a no-op (another run,
         a Cancel or the eraser won).
      2. **Account status, read inside the transaction (review L-7).** A new transaction-scoped read on the identity
         seam (for example `identity.TxProfiles.ProfileInTx(ctx, tx, uid)`, next to `Counters.AddPostsCount` at
         `repo_create.go:195` and `quota.Store.Get(ctx, tx, uid)`): posts never reads `users/{uid}` raw. It returns
         status, the author-snapshot fields and `createdAt`.
         - SUSPENDED → FAILED `ACCOUNT_RESTRICTED`. DELETING or missing → CANCELLED.
         - Both are written in this same transaction, so there is no second round trip.
         - The read replaces the directory author lookup, so worst-case reads are unchanged. It is never cached,
           however, so it costs +1 read wherever the directory would have hit warm (planning +1).
         - Why not the cached status as CreatePost does: an opsctl suspension writes `users/{uid}`, so this
           transaction conflicts and re-reads SUSPENDED. A DELETING write conflicts the same way. The guarantee no
           longer depends on the 75 s settle wait (`moderation.go:37`) or the 120 s start gate covering a sweep
           item, which could have read its status up to 25 s before committing.
      3. `quotas/{uid}`: the posts daily limit, including the new-account limit from the profile's `createdAt`. Over
         the limit → FAILED `QUOTA_EXCEEDED`, before any media or handle read.
      4. Media `LoadForPost`: READY or READY_UNSCREENED, owned and unattached. Otherwise → FAILED
         `MEDIA_UNAVAILABLE`.
      5. **Mention resolution last** (handles may have changed): `directory.ResolveHandles`, cache-first. It is a
         non-transactional read inside the callback; handle docs need no isolation here.
      6. Draw the Snowflake, create the post, bump `users.postsCount`, reserve the quota, attach the media, and set
         the scheduled doc to PUBLISHED with `postId` and `expireAt`, clearing `draft`.

      After the commit, the cache updates and `PostEvents.Created` (mention notifications, ADR-0017) run as for
      CreatePost.
   - **Checks that run at schedule time only:** verified email (there is no auth context at publish) and the
     sub-feature flags.
   - **No second SafeSearch call.** SafeSearch is not part of the create path: it ran at FinalizeUpload (ADR-0005).
     A re-run would bill a second Vision unit for the same bytes. READY_UNSCREENED keeps the ADR-0005 handling.
   - **Mentions at publish** (review I-5): if a mentioned user renames and someone else claims the old handle before
     publish, the claimant gets the mention, its notification and MENTIONED_ONLY reply rights. Accepted, as on X.
     The draft never stores uids, which would be residue.
4. **State writes (review L-7; applied differently for writes outside the transaction).**
   - Inside the publish transaction (step 3): the doc was read there as PENDING, so the write is conditional by
     construction.
   - Outside it (expiry, UNSUPPORTED, INVALID_CONTENT, transient `attempts++`, FAILED after the attempts limit or a
     panic): an `Update` with `firestore.LastUpdateTime(<the query snapshot's UpdateTime>)`, the same pattern as
     `SetExportStatus` (`repo_lifecycle_firestore.go:218-229`, used at `lifecycle_jobs.go:527`).
     - The precondition fails on a missing doc and on any change since the query read it as PENDING. It therefore
       gives the "exists and still PENDING" guarantee with 0 reads instead of the 1 a transaction would spend.
     - A failed precondition is a no-op: someone else moved the item on.
   - **Never `Set` or merge.** A write after the `scheduled` eraser ran therefore fails instead of recreating a doc
     under a purged user (ADR-0011 Q10).
5. **Errors and panics (review M-2).**
   - Permanent outcomes: FAILED with the reason, as above.
   - Transient (deadline, UNAVAILABLE, ABORTED exhausted): `attempts++`. At `SCHEDULED_MAX_ATTEMPTS` (3): FAILED
     `INTERNAL` plus `mw.ReportError`.
   - **Recover in two places.**
     - Inside the transaction callback: convert a panic into a returned sentinel error (`errPublishPanic`). The
       Firestore client then rolls back (`transaction.go:208-241`) instead of leaving a transaction open that holds
       the author's `users` and `quotas` docs until the server expires it. The item wrapper maps that sentinel to
       FAILED `INTERNAL`, **never** to the transient branch, so a panic still retires the item in one run.
     - Around each item in its worker: a recovered panic marks the item FAILED `INTERNAL` and calls
       `mw.ReportError` with the panic **type** only (`fmt.Errorf("panic of type %T", v)`, as
       `lifecycle_jobs.go:100` does).
     - A panic after the commit (cache update, `PostEvents.Created`) finds the doc already PUBLISHED. The FAILED
       write's precondition then fails, which is correct; do not "fix" it with an unconditional write.
   - **Bookkeeping writes use a short detached context**: `context.WithTimeout(context.WithoutCancel(itemCtx),
     3*time.Second)`. An item that hit the 25 s run deadline can still be counted, and `WithoutCancel` keeps the
     budget counter and trace values.
   - **Bounds, corrected.** The earlier "a poison item cannot block the head of the queue for more than 3 runs" was
     false for panics. Now:
     - a returned error retires the item within 3 runs;
     - a Go panic retires it in 1 run;
     - a **fatal runtime error** (concurrent map write, stack exhaustion), an OOM kill or an instance kill cannot be
       recovered, and `attempts` never moves. Such an item crashes the instance once per run, killing up to 80
       requests in flight on it, until the 0-read expiry check retires it after 6 h (at most 72 runs).
     - Runbook: the crash shows in Cloud Run logs and Error Reporting, and the last `scheduled_item_start` line
       (§Sweep 7) before it names the item. No operator cancel path exists today (CancelScheduledPost is user-only),
       so the bound is the 6 h expiry; pausing the job stops the crashes but also stops everyone's publishing.
     - Follow-ups outside this ADR: an `opsctl scheduled cancel` command, and, if such a loop is ever observed, "claim
       before publish" (`attempts++` before the work, +1 read +1 write per publish), which bounds even fatal crashes
       to 3 runs.
   - **Scrubbing (review L-8).** Every error that leaves the sweep, whether logged, reported or returned, goes through
     `logger.ScrubErr(err, uid)`. One request touches many users, and Firestore error text carries
     `documents/users/<uid>/scheduled/<id>` paths, so a single-uid `RedactErr` is not enough. Our own error messages
     never include a uid or a scheduled id.
6. **Response.** 204 even when some items fail; 500 only when the query fails, so Cloud Scheduler retries
   (`retry_count = 3`). Overlapping runs, such as a retry and the next tick, are safe because of the PENDING guard.
7. **Logging.**
   - One `scheduled_sweep` line per run: due, published, failed{reason}, cancelled, expired, transient, deferred
     (author cap), `skipped_bad_path`, `max_lateness_ms`, `fs_reads`, `fs_writes`, outcome, trace id.
   - One `scheduled_item_start` debug line per item, written **before** its transaction, with `uid_hash`
     (`logger.HashUID`) and the scheduled id (a one-way hash). It is the only trace an unrecoverable crash leaves.
     At Stage 0 volume (about 15 items per day) the log cost is negligible.
   - One `scheduled_author_reads` warning, with `uid_hash`, for an author whose items spent more
     than `SCHEDULED_AUTHOR_READS_WARN` (40) reads in one run (review L-4). These reads sit outside the per-user read
     budget by design.
   - Error Reporting fires on a 500, on INTERNAL and on a recovered panic. `draft.text` is never logged.

**Lateness.**
- Steady state: at most the 5 min cadence plus the run time and any retries.
- A backlog drains at up to 100 items per run, 1,200 per hour. The per-author cap stretches one user's backlog: 25
  items need 9 runs (45 min). The Stage 0 ceiling of about 15 users × 25 pending = 375 items, all due at once after an
  outage, takes 9 runs at 45 per run (≈ 45 min), well inside the 6 h EXPIRED bound.
- **Flood (review L-3 (b)).**
  - Starving other users' items past the 6 h EXPIRED bound needs a backlog of 72 runs × 100 = 7,200 items ahead of
    them.
  - With the window cap, one account adds at most 3 items per 5 minutes and 25 pending in total. A same-minute burst
    therefore needs about 2,400 verified accounts.
  - Spreading 25 items each over about 45 minutes needs about 300 aged accounts, or about 630 new ones at 10 per
    day. The backlog grows by (3A − 100) per run for about 9 runs.
  - For comparison: about 290 accounts with no per-author handling, and about 36 with a per-run cap alone.
  - Runbook lever: raise `SCHEDULED_SWEEP_MAX_PAGES` while draining; the posts daily quota still applies at publish.

## Cost impact
Per-operation Firestore cost. "Cold" includes the account-status interceptor's caller read.
| Operation | Reads worst cold | Reads typical | Writes | Deletes |
|---|---|---|---|---|
| CreatePost root with policy and/or disclosure | +0 (14 / 17 with images, unchanged) | +0 (2) | +0 (4) | +0 |
| Reply, conversation EVERYONE / UNSPECIFIED | +0 (15 unchanged) | +0 (3) | +0 (5) | 0 |
| Reply, MENTIONED_ONLY, parent = root / deeper | +0 / +3 (root post, root author profile, caller graph if the caller wrote the parent) | +0 | +0 | 0 |
| Reply, FOLLOWING, parent = root / deeper | +1 / +4 (as above + root author graph) | +0 (60 s caches) | +0 | 0 |
| Reply refused (NOT_FOUND root unusable, or REPLY_NOT_ALLOWED) | as above | as above | 0 | 0 |
| Timelines `viewer_reply_permission` | +0 | +0 | 0 | 0 |
| GetPost (root) / GetThread permission (FOLLOWING, viewer ≠ root author) | +1 | +0 | 0 | 0 |
| GetPost (reply in a restricted conversation) | +0 (UNKNOWN) | +0 | 0 | 0 |
| SchedulePost [Amended: see Implementation notes 6] | 9 (interceptor 1, scheduled doc 1, pending count 1, window count 1, quotas 1, media ≤ 4); +1 on a concurrent-duplicate AlreadyExists | 4 | 2 (scheduled doc, `quotas.schedules`) | 0 |
| SchedulePost replay / at pending cap / at window cap / at daily cap [Amended: see Implementation notes 6] | 2 / 3 / 4 / 5 | 1 / 2 / 3 / 4 | 0 | 0 |
| ListScheduledPosts | 1 + page (21 at 20, 51 at 50) | 1 + items (min 1) | 0 | 0 |
| CancelScheduledPost | 2 | 1 | 1 (0 if already terminal) | +1 TTL after 7 d |
| Sweep run, flag off / readonly | 0 | 0 | 0 | 0 |
| Sweep run, nothing due | 1 | 1 | 0 | 0 |
| Sweep run, N due | N (query, ≤ 100; deferred and skipped items are re-read next run) + per item | | per item | |
| Publish one item | 17 (scheduled 1, `users` in-txn 1, quotas 1, media 4, handles 10) | 3 (planning 4: the in-txn `users` read is never cached) | 4 (post, postsCount, quotas, scheduled) + n media ≤ 8 | +1 TTL after 7 d |
| Expire / UNSUPPORTED / INVALID_CONTENT / transient / panic (outside the txn) | 0 (`LastUpdateTime` precondition) | 0 | 1 | +1 TTL after 7 d (terminal only) |
| Cancel / fail inside the publish txn (status, quota, media) | 2 to 7 (the reads up to that check) | 2 to 3 | 1 | +1 TTL after 7 d |
| Account deletion, `scheduled` step | 1 per doc (min 1) | 1 | 0 | 1 per doc (≤ 25 + ≤ 7 d of terminal docs) |
| Account export, `scheduled` section | 1 per doc (min 1) | 1 | 0 | 0 |

A publish writes as many docs as a CreatePost: no `idempotency/*` doc (−1 write, −1 TTL delete), plus the scheduled-doc
update (+1). Clearing `draft` rides in the transition's existing write.

**Daily budget at the Stage 0 target (300 DAU).**

Assumptions, per DAU per day:
- 0.05 SchedulePost;
- 0.1 list opens returning 3 items;
- 0.01 cancels;
- 0.05 publishes, at planning 4 reads (with the never-cached in-transaction `users` read), 1 for media or handles
  and 1 for the query share;
- 0.3 replies, 20% of them in restricted conversations, at 2 cold reads on average;
- 2 GetThread calls, 10% of them at 1 cold read.

Reads per DAU = 0.05×4 + 0.1×4 + 0.01 + 0.05×6 + 0.3×0.2×2 + 2×0.1 = 0.20 + 0.40 + 0.01 + 0.30 + 0.12 + 0.20
= **1.23 ≈ 1.2** (was 1.07: +0.05 window count, +0.05 in-transaction status read, +0.06 root check on deep replies).

| Daily total at 300 DAU | Arithmetic | Result | Share |
|---|---|---|---|
| Reads | 1.2 × 300 + sweep 288 (24 × 12) | **648** | 1.3% of 50k; +0.9% over the ~69.3k baseline |
| Writes | (0.05×2 + 0.01 + 0.05×4) = 0.31 per DAU, × 300 | **93** | 0.5% of 20k |
| TTL deletes | ≈ 0.06 per DAU, × 300 | **18** | negligible |

| Quota | Feature use | Runs out at (feature alone) | $/month at 2× (600 DAU) | at 10× (3,000 DAU) |
|---|---|---|---|---|
| Firestore reads 50k/day | 288 + 1.2/DAU | (50,000−288)/1.2 ≈ 41k DAU. The whole product already passes it at about 216 DAU (cost-model) | 1,008/day ≈ 30k/month ≈ $0.02 | 3,888/day ≈ 117k/month ≈ $0.07 |
| Firestore writes 20k/day | 0.31/DAU | ≈ 64k DAU (whole product ≈ 630 DAU) | ≈ $0 | 930/day ≈ 28k/month ≈ $0.05 |
| Firestore deletes 20k/day | 0.06/DAU | ≈ 330k DAU | $0 | $0 |
| Cloud Run requests 2M/month | 8,640 sweep + ~4.8/DAU | ≈ 415k DAU | $0 | $0 |
| Cloud Run vCPU-s 180k/month | sweep: 8,640 × 0.2 s warm = 1,728; worst all-cold 8,640 × 2 s = 17,280 (9.6%). GiB-s: 864 to 8,640 of 360k (≤ 2.4%) | n/a (DAU-independent) | $0 | $0 |
| Cloud Scheduler 3 jobs/billing account | 2 of 3 | n/a | $0 | $0 (a 4th job would be about $0.10/month) |
| Logging 50 GiB | about 5 MB/month | n/a | $0 | $0 |
| Vision, GCS, Pub/Sub | +0 (no re-screen, no new objects; mention notifications unchanged per post) | | | |

Prices are the cost-model upper bounds: reads about $0.06 per 100k, writes about $0.18–0.20 per 100k. A side effect:
the 5-min ping tends to keep one instance warm, so users hit fewer cold starts, and idle instance time is not billed
under request-based billing.

- **Fixed monthly cost added: $0**, provided the billing account has no Cloud Scheduler jobs outside `dzeroth-dev`
  (0) and `dzeroth-prod` (1, becoming 2). The repo cannot show other projects on the account (founder item 1). If a
  third job exists elsewhere, this one is the 4th (about $0.10/month) and needs `# cost-approved: ADR-0021`.
- **The dev IAM grant** (D1) is free.
- **Trigger that justifies it:** none needed; it is pay-per-use inside the free tier.
- **Cadence.** Move to a 1 min cadence (1,440 empty reads/day, 2.9% of the quota) only if users complain about
  lateness. The window cap stays ±4 min; with a 1 min cadence the per-run cap would defer more, so revisit both
  together.

## Security and abuse
- **Authz.**
  - The three RPCs touch only `users/{caller}/scheduled`, so no path reaches another user's docs. List and Cancel
    build the path from the token uid. The List cursor is HMAC-bound to `scheduled|<uid>` like `threadBinding`.
  - They pass the normal interceptors: Firebase ID token, verified identity, ACTIVE status, rate limits and the read
    budget. **App Check is monitor-only in both envs** (`envs/{dev,prod}/main.tf`; review I-2), so it is not counted
    as a control here.
  - The sweep route sits behind `protectInternal` (OIDC audience plus SA email allowlist). Outside `ENV=local`,
    startup already fails without that configuration (apiserver.go:401). The allowlist is not per route (D1, I-1).
- **Quotas.** The posts daily quota is charged **at publish**, so scheduling cannot bypass it.
- **Content rules unchanged.** Text, mention, hashtag and media rules run at schedule time and again at publish.
- **Privacy.** `draft.text` is never logged. The draft is cleared on PUBLISHED and CANCELLED. Deletion and export are
  covered in §Firestore model.

| Abuse case | Mitigation |
|---|---|
| Scheduling spam / schedule-cancel churn | 25 pending (soft), 3 per ±4 min (soft) [Amended: see Implementation notes 6], 50 schedules/day (10 for new accounts; exact, `quotas`), 10/min bucket, posts quota at publish, allowlist rollout |
| A burst of one user's posts landing at once (L-3 a) | ≤ 3 per 5-min span at schedule time; ≤ 3 per author per run, processed one after another |
| Many users schedule the same minute (L-3 b) | ≤ 100 per run; the window cap makes a 6 h starvation need ~300+ verified accounts (§Lateness); per-user quotas unchanged; far below per-collection write limits |
| Sweep reads outside the per-user read budget (L-4) | cheapest-first checks (a quota-bound item costs 3 reads, not 17); new-account schedule cap; `scheduled_author_reads` warning |
| Schedule, then delete the account | the publish transaction reads DELETING → CANCELLED; the eraser step deletes the docs; no sweep write can recreate one |
| Schedule, then get suspended | the publish transaction reads SUSPENDED → FAILED `ACCOUNT_RESTRICTED`; unsuspension does not revive the item |
| Mention spam through MENTIONED_ONLY | only root mentions grant access (≤ 10, existing quotas, notifications filtered by blocks per ADR-0017); replies cannot widen it |
| Evading the policy deep in a thread | inherited policy checked against the root, after the "R usable" predicate |
| Learning "the root author blocked me" (M-1) | any unusable root, including a block in either direction or an overflow, answers NOT_FOUND before the policy runs; GetPost's hint on a deep reply is UNKNOWN |
| Probing follow state via REPLY_NOT_ALLOWED | equivalent to the public `ListFollowing` while following lists stay public (I-4) |
| False disclosure labels | user assertion; reportable via ReportContent (ADR-0016) |
| Swapping media between schedule and publish | revalidated at publish (owner, READY, unattached) |
| Viewing a scheduled image before release (L-9) | accepted at Stage 0 and disclosed in the dialog copy (founder item 5) |
| A poison item crashing instances (M-2) | two-level recover; FAILED `INTERNAL` with a precondition; fatal errors bounded by the 0-read expiry |
| Stolen founder gcloud credentials in dev (L-5) | OpenID-only role, dev SA only, expires after 30 days |

## Consequences
**Positive:**
- Three features with 0 timeline reads, no new GCP service and no fixed cost.
- Exactly-once publishing without new infrastructure, and an exact status guarantee at publish.
- Reply restrictions survive the flag being switched off.

**Negative:**
- Up to 5 min of lateness; up to about 45 min for one user's full backlog after an outage.
- A 6 h outage fails items as EXPIRED instead of posting them late.
- A follow change can take up to 60 s to affect FOLLOWING (cache TTL).
- The pending and window caps are soft.
  [Amended: see Implementation notes 6]
- Deep replies in restricted conversations cost up to +4 cold reads; the plan's "+0 / +1" holds only for direct
  replies to the root.
- A caller who blocked a restricted conversation's root author, or who has more than 10,000 blockers, cannot reply
  in it (NOT_FOUND).
- Rule 4 is bent for SchedulePost and CancelScheduledPost.
- Scheduled images are public by link before publish.
- A fatal runtime error in the publish path can crash an instance once per run for up to 6 h (§Sweep 5).
- A SchedulePost replay or Cancel of a PUBLISHED or CANCELLED item returns no text or media.
- **Rollback hazard:** a revision from before this ADR does not enforce policies. Replies written while it runs also
  lose the inherited field, and later replies copy the missing field, so those sub-threads stay open for good. It
  also resets `quotas.schedules` (I-3). Once `FEATURE_REPLY_AUDIENCE` has left `off`, roll forward; do not roll back.

**Revisit when:**
- users complain about lateness (1 min cadence, +1,152 reads/day, and re-check the window and per-run caps);
- a third Scheduler job is needed (fold the jobs into one tick route);
- 2-hop or Verified reply tiers are wanted (new ADR: graph cost, verification);
- editing a scheduled post or a reply policy is wanted;
- a sweep crash loop is observed (claim before publish, §Sweep 5);
- private accounts arrive (I-4: FOLLOWING refusals and hints);
- embargoed images matter (L-9: ADR-0005 private-until-attach).

## Rollout, tests, runbook
- **Flags** (`flag-rollout`). Wire names `content_disclosure`, `reply_audience` and `scheduled_posts`, reported in
  `GetMe.enabled_features`, all `off` by default.
  - Build and ship in this order: disclosure, then reply audience, then scheduling.
  - Each goes off → allowlist (dev first) → percent 5/25/100 → on, with a cost-model headroom check at each step.
  - **100% rule (review L-1).** `FEATURE_REPLY_AUDIENCE`, `FEATURE_CONTENT_DISCLOSURE` and `FEATURE_SCHEDULED_POSTS`
    leave `off`, even for the allowlist, only after **100% of traffic** is on a revision that stores and enforces
    them.
    - Why: during a 10/90 split GetMe (new revision) can list a feature while the CreatePost lands on an old revision.
      Proto3 drops the unknown field 7, and the post is open to everyone without any error.
    - For scheduling, a Scheduler tick routed to an old revision hits `PlaceholderHandler` and gets a silent 202.
    - The rule also keeps old revisions from resetting `quotas.schedules` (I-3).
  - **Client echo check (L-1).** After CreatePost, the client compares the returned `Post.reply_policy`,
    `paid_partnership` and `made_with_ai` with what it sent, treating UNSPECIFIED and EVERYONE as equal. On a
    mismatch it warns ("Your reply setting was not applied") and offers delete-and-repost.
  - Scheduling additionally needs the prod job applied before the prod allowlist, and dev tested through the D1 curl.
- **Kill switches.**
  - Disclosure off: no new labels; existing labels stay.
  - Reply audience off: no new policies; enforcement stays. Never roll back a revision (see Consequences).
  - Scheduling off: the RPCs return FEATURE_DISABLED and the sweep is a no-op. Pending items wait, then EXPIRE after
    6 h unless `SCHEDULED_MAX_LATENESS` is raised before re-enabling.
- **Config** (env vars plus Terraform variables):
  - `SCHEDULED_MAX_PENDING=25`, `SCHEDULED_HORIZON=1440h`, `SCHEDULED_MIN_LEAD=2m`
  - `QUOTA_SCHEDULES_PER_DAY=50`, `QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY=10` (window: the existing
    `QUOTA_NEW_ACCOUNT_WINDOW`)
  - `SCHEDULED_PER_AUTHOR_PER_RUN=3` (also the ±4 min window cap), `SCHEDULED_AUTHOR_READS_WARN=40`
  - `SCHEDULED_SWEEP_LIMIT=50`, `SCHEDULED_SWEEP_MAX_PAGES=2`, `SCHEDULED_SWEEP_CONCURRENCY=4`
  - `SCHEDULED_MAX_LATENESS=6h`, `SCHEDULED_MAX_ATTEMPTS=3`, `SCHEDULED_TERMINAL_TTL=168h`
  - Terraform `publish_scheduled_schedule="*/5 * * * *"`; dev `cron_test_invoker` (principal) and
    `cron_test_invoker_expiry` (RFC 3339)
- **Tests (CMP-B4, C4, D7).**
  - *Clock-injected unit tests, no sleeps:*
    - `publish_at` bounds and truncation;
    - `requestHash` stability: UNSPECIFIED and EVERYONE hash equal; 10:00:59 and 10:00:00 hash equal; a CreatePost
      with default values hashes as before;
    - the policy matrix: author, follower, non-follower, mentioned, REPOST parent, deep reply, root gone, and
      - **mentioned + blocked by the root author → NOT_FOUND** (direct and deep reply), never REPLY_NOT_ALLOWED;
      - **the caller blocks the root author → NOT_FOUND**; caller `blockedByOverflow` → NOT_FOUND;
      - **R hidden (takedown) or R's author SUSPENDED / DELETING → NOT_FOUND**;
      - an EVERYONE conversation spends +0 reads and never loads R;
      - the GetPost hint on a deep restricted reply is UNKNOWN; a REPOST row's hint uses `embedded.replyPolicy`
        (I-6);
    - the sweep's path-shape filter (a `scheduled` collection at another depth is skipped);
    - a panic inside the publish callback: the wrapper returns `errPublishPanic`, `RunTransaction` returns non-nil
      (so the client rolled back), no panic escapes, and the item maps to FAILED `INTERNAL`, not `attempts++` (M-2);
    - `ScrubErr` on a Firestore-shaped error naming **two** uids
      (`documents/users/<uidA>/scheduled/<id>` plus `<uidB>`): neither survives in the log line (L-8).
  - *Emulator tests:*
    - schedule, list (cursor bound to the caller, `in`), cancel, replay, key reuse, all three caps;
    - **a replay arriving after the lead time and at the caps returns the stored item** (L-6);
    - Cancel's malformed `idempotency_key` → VALIDATION; Cancel/List never reach another user's doc (I-7);
    - the sweep: publish, skip cancelled, two concurrent sweeps give one post, media reused gives FAILED, suspended,
      DELETING gives CANCELLED, expiry, the attempts limit, flag off gives 0 reads;
    - **a panicking item becomes FAILED `INTERNAL`, the process survives, and the other items in the run publish**
      (M-2);
    - **a sweep write after the eraser deleted the doc fails and recreates nothing** (L-7);
    - **a suspension committed between the query and the publish transaction → FAILED `ACCOUNT_RESTRICTED`, no
      post** (L-7);
    - per author: 5 due items of one author → 3 published one after another, 2 deferred to the next run;
    - PUBLISHED, CANCELLED and FAILED docs hold no `draft`; the export lists every doc with the draft of each PENDING one;
    - the deletion residue sweep and the T11 row;
    - budget assertions.
  - *Other:* Flutter widget tests for the sheet, dialogs and list, and the echo-mismatch warning; `buf breaking`.
- **Runbook** (`docs/runbooks/posts.md`, a new "Scheduled posts sweep" section).
  - Symptoms: 500s on `scheduled_sweep`, `max_lateness_ms` > 600k, a spike in a FAILED reason, `skipped_bad_path` >
    0, `scheduled_author_reads` warnings, an instance crash every 5 min.
  - Manual run: prod `gcloud scheduler jobs run publish-scheduled --location asia-south1`; dev the D1 curl.
  - Pause: `gcloud scheduler jobs pause` (a paused job still counts toward the 3).
  - Also: the kill switch, draining a backlog (`SCHEDULED_SWEEP_MAX_PAGES`), raising max lateness before recovering
    from an outage, isolating a crash-looping item, and the roll-forward-only rule.

## Security review
Source: `docs/reviews/security-review-adr-0021.md` (2026-10-23, APPROVE WITH CHANGES). Every finding:
| Id | Disposition |
|---|---|
| M-1 | applied in D2 "The root R and R usable", "Viewer hint", tests. Applied wider than asked: GetPost's hint on deep restricted replies is UNKNOWN, and the cost rises to +3 / +4 cold |
| M-2 | applied in §Sweep 2 and 5, tests. Also recovers inside the transaction callback (the Firestore client rolls back only on a returned error), and states the fatal-error bound the review did not cover |
| L-1 | applied in §Rollout "100% rule" and "Client echo check", extended to `FEATURE_SCHEDULED_POSTS` |
| L-2 | applied in §Firestore model (status transitions, right to delete item 3), proto comments |
| L-3 | applied differently in D4 Limits and §Sweep 2: the per-run cap alone worsens head-of-line blocking (`__name__` tie order), so a schedule-time ±4 min window cap is added (founder item 4) |
| L-4 | applied in §Sweep 3 (check order), D4 Limits (`QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY`, renamed to the existing convention), §Sweep 7 (reads warning) |
| L-5 | applied in D1 "The grant", Handoff production-deployer; I-1 recorded as a follow-up |
| L-6 | applied in D4 "SchedulePost order" and idempotency bullets |
| L-7 | applied in §Sweep 2 (path shape), 3 "Account status, read inside the transaction" (+1 planning read), 4 (state writes; `LastUpdateTime` precondition instead of a transaction outside the publish path, same guarantee at 0 reads) |
| L-8 | applied in §Sweep 5 "Scrubbing", tests |
| L-9 | applied in §Firestore model "Media" and the dialog copy; accepted risk at Stage 0, founder item 5 |
| I-1 | accepted for now: not exploitable today; follow-up in D1 (separate cron SA, per-route allowlist, `iss` and `email_verified` checks) |
| I-2 | applied in §Security and abuse "Authz" |
| I-3 | applied in D4 Limits (bound stated) and the L-1 rule |
| I-4 | applied in D2 "Follow-state disclosure", Revisit |
| I-5 | accepted risk (as on X): §Sweep 3 "Mentions at publish" |
| I-6 | applied in D2 "Viewer hint", D3 "Rendering", tests |
| I-7 | applied in the RPC rules, §Security and abuse "Authz", tests |

## Founder decisions
Recorded 2026-10-23: the founder accepted this ADR and accepted all five items below **as written in this ADR** (the
proposals, not the alternatives). Where an item names a condition, the condition still stands.

1. **Approve the second Cloud Scheduler job in prod** (2 of 3 free), and confirm that no other project on the billing
   account uses Scheduler jobs. Only then is the fixed cost $0.
2. **Reply policy together with a schedule.** This ADR allows it; X disables the control while a schedule is set.
   Mirroring X would be a client-only change plus a VALIDATION rule.
3. **Rule-4 bend.** SchedulePost uses its natural-key doc as the idempotency record, and CancelScheduledPost is
   idempotent by state. Neither stores a TTL'd idempotency doc. This is the same pattern as ADR-0018's bend, which
   the founder approved on 2026-10-17.
4. **The per-author window cap** (new from the security review). A user cannot schedule more than 3 posts within
   ±4 min of each other (LIMIT_REACHED), which X does not visibly limit. It costs +1 read per SchedulePost.
   Alternatives:
   - only the per-run cap: about 36 accounts can starve the queue for 6 h;
   - no per-author handling: about 290 accounts, plus bursts and same-author contention.
5. **Scheduled images public by link before publish** (review L-9). Accept at Stage 0 with the dialog copy (this ADR's
   proposal), or ask for an ADR-0005 amendment that keeps unattached images private until attach (new signed-read
   path and more Class A/B operations).

Resolution of each item:
1. **Approved**: the `publish-scheduled` job (2 of 3 free) goes ahead in prod only. Condition kept: the billing account
   must have no other Scheduler jobs outside this repo. If a third job exists elsewhere, this one becomes a paid job
   (about $0.10 a month) and needs a `# cost-approved: ADR-0021` marker before apply. The deployer checks the billing
   account's jobs before `terraform apply`.
2. **As written**: reply policy is allowed together with a schedule. Mirroring X (reject the combination) stays a
   cheap follow-up: a client change plus one VALIDATION rule, with no proto change.
3. **Approved**: the rule-4 bend for SchedulePost and CancelScheduledPost.
4. **Approved**: the per-author window cap (3 posts within +/-4 min, +1 read per SchedulePost).
5. **Approved**: scheduled images stay public by link before publish at Stage 0, with the dialog copy. An ADR-0005
   private-until-attach amendment is not requested.

Accepting this ADR does not approve any apply or traffic shift: prod applies, flag ramps and releases still go through
the normal gates (ADR-0019).

## Handoff
- **architect (on Accept):** the proto diff; the index, fieldOverride and TTL entries; a `firestore-data-model` skill
  row for `users/{uid}/scheduled` and the new post fields.
- **backend-developer:**
  - D2:
    - the shared "R usable" helper extracted from `threadContext` (`service_thread.go:204-225`), used by GetThread
      and by reply enforcement after `replyParent`;
    - enforcement only for restricted parents;
    - `viewer_reply_permission` in the converters (UNKNOWN for GetPost of a deep restricted reply, `embedded` for
      REPOST rows).
  - D3: the new fields in `toDoc` and `snapshotOf`.
  - `posts.Scheduler`: Schedule (L-6 order), List, Cancel and Sweep, plus `ScheduledEraser` and the export section
    (every doc, drafts where held).
  - The sweep:
    - per-author dispatch;
    - per-item contexts;
    - recover inside the transaction callback and per item;
    - `LastUpdateTime` preconditions, never `Set`;
    - the path-shape filter;
    - `ScrubErr` on every error;
    - `posts`' own recover wrapper for the route.
  - The `CreateParams.Scheduled` guard, publish-order checks (status → quota → media → mentions) and draft clearing.
  - A transaction-scoped identity read for status plus snapshot fields (a new small interface next to
    `identity.Counters`; posts never reads `users` raw).
  - `quota.Schedules`: the `Kind`, the `Record` field, and the `valueFor` / `increment` cases (`quota.go:26-125`).
  - Config `QUOTA_SCHEDULES_PER_DAY`, `QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY` and the `SCHEDULED_*` keys; add them to
    the env list in `config_test.go`.
  - The route in `apiserver.go`; register the eraser and update the pinned order in `lifecycle_wiring_test.go:178`;
    add the T11 row.
  - Rate-limit mapping: SchedulePost and Cancel use the CreatePost bucket.
  - The pending and window `count()` aggregations are charged to `budget.Counter` by hand, because the store wrappers
    do not see them.
- **frontend-developer:**
  - The "Who can reply?" sheet (3 options), the disclosure dialog, and labels on `PostCard` and embeds (each label on
    its own content).
  - The echo check after CreatePost, with a mismatch warning (L-1).
  - The schedule dialog with platform pickers, sending UTC, and the "images are reachable by link" copy (L-9).
  - The Scheduled list: PENDING and FAILED items, cancel or dismiss (a FAILED item has no draft, so no reschedule); and the "Schedule" button
    state.
  - Handle `LIMIT_REACHED` `scheduled_window` and `scheduled_pending`, and replay/Cancel responses without text.
  - Gate everything on `enabled_features`, and never send poll fields together with a schedule.
- **production-deployer:**
  - Add `publish-scheduled` to `envs/prod` jobs only, with the schedule as a variable. Update the job-count comments
    in both envs and fix dev's `gcloud scheduler jobs run` note.
  - **Dev only:** a `google_service_account_iam_member` granting `roles/iam.serviceAccountOpenIdTokenCreator` on the
    dev pubsub-push SA, with the member from a variable and a `condition { expression = "request.time <
    timestamp(\"<expiry>\")" }` 30 days out. Test the D1 gcloud command and keep the IAM Credentials fallback in the
    runbook. **Never in prod**, and never `serviceAccountTokenCreator`. (A separate cron-invoker SA is a follow-up,
    not this ticket.)
  - The `scheduled_expire_at` TTL field, the `FEATURE_*`, `QUOTA_*SCHEDULES*` and `SCHEDULED_*` env vars, and both
    indexes.
  - Flip the three flags only after 100% of traffic is on the enforcing revision (L-1).
- **tester:** the outline above.
- **sre-performance:** CMP-D8. Feed the cost rows into `docs/reviews/cost-model.md` and add `scheduled_sweep` and
  `scheduled_author_reads` to `make cost`.
- **security-auditor:** re-check M-1 and M-2 against the implementation (the R-usable helper, both recover sites)
  and the dev grant's condition.

## Note (ADR-0022, 2026-10-23; decisions above unchanged)
Note (ADR-0022): superseded in part until 2026-12-26: `publish-scheduled` may run every minute until 2026-12-22 (+1,152 reads/day, +34,560 requests/month, $0 Scheduler), then back to */5.

## Implementation notes (2026-10-26)
Pending 2.17, written after the media hold (#291) and the exact window cap (#292) merged. Each note records where the
scheduled-posts code as built differs from the text above. The text above is left as accepted, so the history stays
readable, and no decision of this ADR changes. Code locations are `file: function` under `backend/internal/posts`
unless a path is given (line numbers rot). Numbers taken from tests, smoke runs or other records name their source;
they were not re-measured for these notes.

1. **Publish transaction** (Sweep step 3.3; Handoff "The `CreateParams.Scheduled` guard"). Implemented as built;
   differs from the text above in how the transaction is built. The publish is a SIBLING of CreatePost's
   `repo_create.go: createAttempt`, not a reuse of `repo.Create`: `service_sweep_item.go: sweepItem` calls
   `repo_publish_scheduled.go: FirestoreRepo.PublishScheduled`, whose attempt body is `publishAttempt`. There is no
   `CreateParams.Scheduled` field and no `posts.service.publishScheduled`. The sibling reuses CreatePost's write helpers
   (`toDoc`, `mediaWithAlts`, `quota.CheckAndReserve`, the `identity.Counters` seam, the media claim) and keeps the
   order of step 3.3: the scheduled doc, the account inside the transaction, quotas, media, mentions last. A post-id
   collision at commit redraws the Snowflake, up to `maxIDCollisionRetries` times, as `Create` does. **Permanent
   failures commit, they do not roll back:** a DELETING or missing account (CANCELLED), any other non-ACTIVE account,
   the posts quota reached, or `ErrMediaNotReady` (FAILED with the reason) stages the one terminal transition on the
   transaction batch (`stageEnd`) and returns nil, so the transaction commits exactly 1 write. That is the cost the row
   "Cancel / fail inside the publish txn" already states. Any other error rolls the attempt back and takes the
   transient path.
2. **`scheduled_item_start` level** (Sweep 5 "Bounds", Sweep 7 "Logging"). Implemented as built; differs from the
   text above in the level. The line is logged at INFO, not debug (`service_sweep_item.go: sweepItem`): the process
   logger drops DEBUG, and the crash-isolation runbook step reads this line. It is written when a dispatched item
   starts, before the expiry and content checks and so before its transaction. Held items (note 5) and deferred
   items get none. The log cost stays negligible at Stage 0 volume.
3. **Fatal-crash bound** (Sweep 5 "Bounds"; Consequences "A fatal runtime error ... for up to 6 h"). Implemented as
   built; differs from the text above in the count. A fatal runtime error, an OOM kill or an instance kill fails the
   request, and Cloud Scheduler retries a failed attempt: `retry_count = 3` for every job
   (`infra/terraform/modules/scheduler/main.tf`); the prod `publish-scheduled` entry in
   `infra/terraform/envs/prod/main.tf` only adds `attempt_deadline_seconds = 60`. One tick can therefore crash up to
   4 times (the tick and its 3 retries), so the 6 h `SCHEDULED_MAX_LATENESS` bound allows up to 72 ticks × 4 = **288
   crashes per poison item at the `*/5` cadence, not 72**. The bound scales with the cadence: at the every-minute
   cadence the ADR-0022 note above allows until 2026-12-22 it is up to 360 × 4 = 1,440 (arithmetic, not measured).
   `attempts` still never moves on such a crash; "claim before publish" (Revisit) remains the follow-up. Terraform sets
   no retry backoff, so Cloud Scheduler's default applies. Operator steps: `docs/runbooks/posts.md` section 12,
   "Isolating a crash-looping item".
4. **When the route answers 500** (Sweep 6; Sweep 7 "Error Reporting fires on a 500"). Implemented as built; differs
   from the text above in which query failure answers 500. `service_sweep.go: service.Sweep` fetches every due page
   before any item runs and returns an error only when the FIRST page fails (nothing was processed);
   `sweep_http.go: NewSweepHandler` then answers 500, and the Cloud Scheduler retry is harmless. When a LATER page
   fails, the pages before it are processed, the error comes back as `SweepResult.LaterPageErr`, and the route
   answers **204**: a 5xx would make Scheduler re-run the sweep within seconds and burn the 3-attempt ladder
   (`SCHEDULED_MAX_ATTEMPTS`) of any item that had just failed transiently. The failed page's items are due again
   next tick. Both cases write the `scheduled_sweep` line at WARN with `outcome=error` plus a separate Error Reporting
   entry that carries only the scrubbed error, so Error Reporting also fires on that 204.
5. **Media hold** (Sweep 1 "Per-user flags are not re-evaluated at publish"; Sweep 3 "Checks that run at schedule time
   only: ... the sub-feature flags"; pending 2.15, #291). Implemented as built; differs from the text above in one
   exception, decided by the founder on 2026-10-26. While the global `FEATURE_MEDIA` kill switch is `off`
   (`flags.Registry.GloballyOff("media")`, asked once per run, 0 reads; `allowlist` and `percent` are rollouts and hold
   nothing, and neither does `DEGRADED_MODE=nomedia`), the sweep HOLDS every image-carrying PENDING item: no publish
   transaction, 0 writes, no `attempts` bump, `updatedAt` untouched, counted as `held_media` (inside `due`, not
   `deferred`). Each held item still costs its 1 due-query read on every run. `service.Sweep` takes held items out
   BEFORE the per-author cap (`service_sweep_item.go: heldForMedia`), so a held item does not use one of its author's
   3 slots. `heldForMedia` shares `precheck` with `sweepItem`, so expiry (`SCHEDULED_MAX_LATENESS`), UNSUPPORTED and
   INVALID_CONTENT still retire an image-carrying item as before, and a hold cannot keep content past the lateness
   bound. The verdicts only the publish transaction gives (ACCOUNT_RESTRICTED, CANCELLED, QUOTA_EXCEEDED,
   MEDIA_UNAVAILABLE) wait until the item is released, or become EXPIRED if the hold outlasts the bound. **Known
   limit**, accepted for now and pinned by `TestSweepMediaHold_KnownLimit_HeldItemsFillTheWindow`: held items keep
   their place at the head of the 100-item due window, so about 100 of them (for example 4 aged accounts with 25 each)
   stop other users' due posts from being read until the held ones expire. While the switch is off this also weakens
   §Lateness "Flood": a few accounts, not about 300, can stall the queue. Pending 2.21 tracks adaptive paging; the
   numbers come from pending 2.15 and `docs/runbooks/posts.md` section 12.
6. **Exact window cap** (D4 "Limits", "SchedulePost order" steps 6 and 7 and its "Known limit (CMP-D3 review m1)",
   the SchedulePost cost rows, the abuse table, Consequences; pending 2.16, #292). Implemented as built; differs from
   the text above in where the window cap is decided. The cap of `SCHEDULED_PER_AUTHOR_PER_RUN` (3) PENDING items
   within ±4 min is decided INSIDE the schedule transaction and is **exact**: `repo_scheduled.go:
   FirestoreRepo.CreateScheduled` reads `quotas/{uid}` and then runs `countQuery(ctx, windowQuery(...), tx)` (an
   aggregation count, `Limit(cap + 1)`, 1 read), re-run on every attempt. Every schedule by one account reads and
   writes `quotas/{uid}`, so of two racing calls only one commits, and the loser's retry counts the winner's committed
   document. The count must stay after the quotas read. Inside the transaction the order is: quotas, the window count
   (plus 1 read of this key's own document when the window is full), the daily cap, media, then the 2 writes. The
   pending cap (`SCHEDULED_MAX_PENDING`, 25) stays soft and outside the transaction on purpose
   (`service_scheduled.go: service.Schedule` step 6, `CountPending`): reading up to 26 documents inside it would blow
   the read budget, and the overshoot stays bounded by the exact daily quota and the rate bucket's burst.
   - **Concurrency mode.** Dev and prod Firestore run `OPTIMISTIC` (`concurrency_mode` in
     `infra/terraform/modules/firestore/main.tf`); the emulator is lock-based, so the emulator race tests are not
     proof for prod. Per pending 2.16, a smoke on the real dev Firestore on 2026-10-26 (ten simultaneous calls per
     run, with and without an existing `quotas/{uid}` document) stored exactly 3 and rejected 7 every time. That smoke
     called the service and repository directly, not the deployed HTTP path, and did not touch prod.
   - **Duplicates.** A full window that holds this key's own document (a concurrent first call of the same
     `idempotency_key` committed it) is answered as a replay, not as `scheduled_window`. That closes the CMP-D3 m1
     known limit on the window path only: a concurrent duplicate can still get `LIMIT_REACHED`
     (`limit=scheduled_pending`) or `QUOTA_EXCEEDED`, and the client rule (retry with the same key after any cap
     error) stands.
   - **Reads**, including the interceptor's cold read: typical 5 (4 the service's own), worst 9 with four images;
     replay / at pending cap / at window cap / at daily cap 2 / 3 / **6** / 5 worst and 1 / 2 / **5** / 4 typical (the
     window cap was 4 worst, 3 typical). A transaction retry under contention re-reads quotas, the window count and the
     media (up to 6 more reads per retry). Writes are unchanged. The daily budget in §Cost impact is unchanged: it
     counts no cap rejections.
   - The sentences above that call the window cap soft or count it outside the transaction carry the pointer
     "[Amended: see Implementation notes 6]".
7. **Smaller differences found while verifying** (scheduled posts only). Implemented as built; each differs from the
   text above in a detail, and none changes a decision.
   - **Fetch, then dispatch** (Sweep 2). `service.Sweep` fetches every due page before any item runs. A page after
     the first is fetched only while `sweepMinRemaining` (6 s) of the 25 s run deadline (`sweep.go:
     sweepRunDeadline`) remain, and an author worker starts an item only under the same rule. The deadline chain is
     handler 25 s < Cloud Run request timeout 30 s < the job's `attempt_deadline_seconds = 60`
     (`infra/terraform/envs/prod/main.tf`), which the text above does not state.
   - **Workers** (Sweep 2 "Per author"). One worker per author (`service_sweep.go: sweepAuthor`) on an
     `errgroup.Group` with `SetLimit(SCHEDULED_SWEEP_CONCURRENCY)`, never `WithContext`, as the text allows. Each
     worker has its own `budget.Counter`, folded into the run's counter when it ends; `scheduled_author_reads`
     compares that per-author counter with `SCHEDULED_AUTHOR_READS_WARN`.
   - **Recover sites** (D1 "The route", Sweep 5). Four, not two: the route (`mw.RecoverHTTP` from
     `pkg/platform/mw`, used in `sweep_http.go: NewSweepHandler`; a shared helper, not the posts-own wrapper D1 and
     the Handoff describe), each author worker (`sweepAuthor`), each item (`sweepItemSafe`, plus a guard in
     `itemPanicked` that logs a second panic as `scheduled_item_second_panic`, type only), and the transaction
     callback (`repo_publish_scheduled.go: guardPublishPanic`).
   - **Account status in the publish transaction** (Sweep 3.3 step 2). Any status other than ACTIVE or DELETING,
     including one this revision does not know, fails closed as FAILED `ACCOUNT_RESTRICTED`, not only SUSPENDED
     (`publishAttempt`).
   - **INVALID_CONTENT** (Sweep 3 step 2) also covers a missing draft and a reply policy or media shape this revision
     does not accept, besides text that no longer parses (`service_sweep_item.go: publishParams`).
   - **No media attacher wired** for a draft with images is a wiring error: it takes the transient path (then FAILED
     `INTERNAL` with an Error Reporting entry on the last attempt), never a user-visible `MEDIA_UNAVAILABLE`
     (`PublishScheduled`).
   - **After the commit** (Sweep 3 "After the commit"; `service_sweep_item.go: settle`). Besides the cache updates
     and `PostEvents.Created` (run on `context.WithoutCancel`, so the run deadline cannot cancel the notification
     publish of a committed post), the sweep calls `directory.Forget(uid)` and `SweepDeps.RecordAuthorAge(uid,
     createdAt)` with the `createdAt` the publish transaction read (0 reads). The wiring
     (`backend/internal/apiserver/apiserver.go`) points it at `actorAges.Record`, which the per-actor notification
     recipient cap (N-1) consults. Without it a sweep-published post, which has no authenticated request behind it,
     would charge a first-day author to the established tier.
   - **Undecodable due documents** are counted as `undecodable` and skipped, like `skipped_bad_path`, and are
     re-read every run (`repo_scheduled.go: DueScheduled`). Retiring them is pending 2.18.
   - **The `scheduled_sweep` line** (Sweep 7) also carries `held_media`, `noop`, `write_failed`, `undecodable`,
     `failed_total`, `fs_deletes` and `latency_ms`, and is written at WARN when a page failed (note 4). Further WARN
     lines name an item by `uid_hash` and `scheduled_id`: `scheduled_item_transient`,
     `scheduled_item_bookkeeping_failed` and `scheduled_item_second_panic` (`docs/runbooks/posts.md` section 12).
   - **Config ranges** (Rollout "Config"). `backend/pkg/platform/config/scheduled.go: loadScheduled` range-checks
     every `SCHEDULED_*` key at startup and fails the boot outside its range (typo guards, not product rules). The
     ranges: `SCHEDULED_SWEEP_LIMIT` 1 to 1,000, then clamped to 50; `SCHEDULED_SWEEP_MAX_PAGES` 1 to 10, so the
     §Lateness lever "raise `SCHEDULED_SWEEP_MAX_PAGES`" tops out at 500 due reads a run; `SCHEDULED_SWEEP_CONCURRENCY`
     1 to 4 and `SCHEDULED_MAX_PENDING` 1 to 50 (founder, 2026-10-24, pending 2.2); `SCHEDULED_PER_AUTHOR_PER_RUN`
     1 to 10; `SCHEDULED_MAX_ATTEMPTS` 1 to 10; `SCHEDULED_AUTHOR_READS_WARN` 1 to 1,000; `SCHEDULED_MAX_LATENESS`
     1 min to 168 h; `SCHEDULED_TERMINAL_TTL` 1 h to 720 h; `SCHEDULED_HORIZON` 1 h to 8,760 h; `SCHEDULED_MIN_LEAD`
     1 min to 24 h and shorter than the horizon. The defaults are those in §Rollout "Config".
   - **Dev manual run** (D1 "Testing in dev"). Found on dev on 2026-10-26 (pending 1.20, #293; procedure in
     `docs/runbooks/posts.md` section 12 "Manual run"), not from the code: the primary
     `gcloud auth print-identity-token --impersonate-service-account` command does not work with the OpenID-only role,
     because it asks for `getAccessToken`, so the IAM Credentials `generateIdToken` fallback is the working path. The
     token's audience must be the service's `INTERNAL_OIDC_AUDIENCE` (the verifier checks that value:
     `pubsubpush.NewVerifier(cfg.InternalOIDCAudience, ...)` in `backend/internal/apiserver/apiserver.go`), not the
     `*.a.run.app` URL, and curl needs an explicit empty body. The
     grant stays dev-only, 30-day and OpenID-only, as D1 says.
