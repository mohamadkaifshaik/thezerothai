# 0021. Composer extras: reply audience, content disclosure, scheduled posts
Status: Proposed (draft; the founder accepts ADRs. Nothing here is binding until Accepted)
Date: 2026-10-23
Deciders: architect (proposal); founder (pending). Product defaults below were proposed by the founder's delegate in
`docs/plans/composer-w15-w6.md` "Answers to the open questions" (2026-10-23).

Plan: `docs/plans/composer-w15-w6.md` (gate ticket CMP-A1; tickets CMP-B1..B4, C1..C4, D1..D8).
Related: ADR-0003 (data model, quotas), ADR-0005 (media, SafeSearch), ADR-0008 (graph, D4, D10 start gate),
ADR-0010 (posts: D2 sub-feature flags, D13/D18 Snowflake createdAt), ADR-0011 (account lifecycle, T11 guard, cron),
ADR-0016 (moderation), ADR-0017 (notifications), ADR-0018 (engagement, rule-4 bend precedent).

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
  - In `common.proto`, the next `ErrorReason` value is 16.
  - Nothing named `reply_policy`, disclosure or schedule exists.
- `backend/internal/posts/service_create.go`: `Create` reads the author, then calls `replyParent` (line 93). That
  calls `resolveTarget`, which applies the GetPost visibility rules (including the caller graph) and resolves a
  REPOST to the original. Then it resolves mentions and calls `repo.Create`. `requestHash` (line 234) guards against
  IDEMPOTENCY_KEY_REUSED.
- `backend/internal/posts/repo_create.go` runs one transaction with a 5 s deadline. The **post id (a Snowflake) and
  createdAt are drawn inside every attempt** (line 167; ADR-0010 D13/D18), and the timeline `since` watermark depends
  on that.
- `backend/internal/graph/api.go`: `Reader.Snapshot(uid)` returns the whole `graph/{uid}`, cached 60 s.
- `backend/internal/apiserver/apiserver.go:404-416`:
  - `protectInternal` is an OIDC verifier: the audience must be the service URL, and the email must be in
    `INTERNAL_OIDC_ALLOWED_EMAILS` (the pubsub-push SA).
  - `/internal/cron/daily-maintenance` is served by `identity.Lifecycle.CronHandler` (`lifecycle_jobs.go:564`). It
    takes POST only, runs under a 25 s deadline with `budget.WithCounter`, and answers 204, or 500 so Cloud Scheduler
    retries.
- `infra/terraform/modules/scheduler/main.tf` creates one job per map entry: UTC, `retry_count = 3`, OIDC with the
  pubsub-push SA. Prod (`envs/prod/main.tf:308`) has 1 job, `daily-maintenance`; dev (`envs/dev/main.tf:317`) has
  `jobs = {}`. **The billing account uses 1 of its 3 free jobs.**
- `backend/pkg/platform/quota`: `quotas/{uid}` is a per-IST-day record. `Get` returns a fresh record on a new day and
  `CheckAndReserve` `Set`s the whole doc. It can hold a daily counter, but **not** a persistent one.
- Account deletion (`identity/lifecycle.go`):
  - Erasers run in registration order, all `BeforeIdentity`. `lifecycle_wiring_test.go:178` pins the order.
  - The start gate is 120 s, twice the 60 s cache TTL.
  - The T11 guard (`apiserver/lifecycle_collections_guard_test.go`) fails `make ci` for any collection without a row.

**Stage 0 requirements:**
- *Functional:* a root post or quote can carry a reply policy and two disclosure labels. A user can schedule a root
  post with up to 4 images for 2 min to 60 days ahead, then list and cancel it. Clients can show who may reply.
- *Non-functional:*
  - 0 extra timeline reads.
  - At most +2 cold reads on a reply.
  - At most 5 min of publish lateness.
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
  route directly with an OIDC token:
  `curl -X POST -H "Authorization: Bearer $(gcloud auth print-identity-token --impersonate-service-account=<dev pubsub-push SA> --audiences=<dev api_url> --include-email)" <dev api_url>/internal/cron/publish-scheduled`
  The comment at `envs/dev/main.tf:316` has the same problem for `daily-maintenance`. Fix both.
- **The route.** Mounted with `protectInternal` next to line 412. POST only, a 25 s context deadline,
  `budget.WithCounter` (system reads, never charged to a user's ADR-0010 D5 budget), and panic recovery.

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
  - Order: visibility (blocked or missing → NOT_FOUND, unchanged) → policy → transaction. A blocked caller never sees
    REPLY_NOT_ALLOWED, so the policy check cannot reveal a block.
- **The root R.** For a reply to the root itself (`parent.ConversationID == parent.ID`), R is the parent. Otherwise R is
  `posts.Get(parent.ConversationID)`, cache first: +1 cold read. If R is gone, the reply is refused (fail closed).
- **Who may reply.**
  - R's author: always.
  - **FOLLOWING:** `graph.Reader.Snapshot(R.AuthorID).Following[caller]`. 1 read cold, 0 warm (60 s cache), no N+1.
    A follow change can take up to 60 s to apply.
  - **MENTIONED_ONLY:** the caller must be in `R.Mentions[].UserID`. 0 reads beyond R. Only the root's mentions grant
    access, so a reply cannot widen the audience by mentioning more people.
  - Either restricted policy also refuses the caller when `snapshot.BlockedBy[R.AuthorID]` is set. The visibility
    check has already loaded that snapshot; on overflow this fails closed. It closes the deep-reply gap for users R's
    author blocked.
  - EVERYONE conversations keep today's reply rules.
- **Refusal.** `PERMISSION_DENIED` + new `ERROR_REASON_REPLY_NOT_ALLOWED = 16` with `metadata["policy"]`. Nothing is
  written and nothing is stored under the idempotency key.
- **Follow-state disclosure.** Under FOLLOWING, a refusal tells the caller whether R's author follows them. That is
  already public through `ListFollowing` (graph.proto:104, open to any caller the target has not blocked). Nothing
  new leaks, and ADR-0008 D4 is not bent.
- **Viewer hint.** `PostView.viewer_reply_permission` is ALLOWED, NOT_ALLOWED or UNKNOWN.
  - Timelines decide it with 0 reads **for root posts only**: EVERYONE, the viewer is the author, or MENTIONED_ONLY.
  - Reply rows in restricted conversations, and FOLLOWING roots, are UNKNOWN. The client shows the policy label and
    lets the server decide.
  - GetPost and GetThread may spend ≤ +1 cold read (R's author's graph). GetThread already reads R.
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
    `status == PENDING` with `Limit(SCHEDULED_MAX_PENDING + 1)` (rule 5; still 1 read).
  - At most `SCHEDULED_PER_DAY` (50) SchedulePost calls per IST day, counted in a new daily field
    `quotas.schedules`, read and written in the transaction. This exact cap bounds schedule/cancel churn.
  - The pending count runs **outside** the transaction, so the 25 cap is **soft**. Concurrent calls can overshoot it
    by at most the number in flight, which the 10/min CreatePost bucket bounds (SchedulePost and Cancel share it). A
    persistent counter cannot live on `quotas/{uid}`, which resets daily.
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
  - Its `requestHash` covers text, media ids, alt texts, `reply_policy`, both bools and `publish_at`. The same key
    with a different time gives IDEMPOTENCY_KEY_REUSED. The same hash is a replay: 0 writes.
  - CancelScheduledPost is idempotent by state. An already-terminal item costs 0 writes.
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
| | new `message ScheduledPost { string scheduled_id = 1; /* 32 hex */ string text = 2; repeated dzeroth.common.v1.MediaRef media = 3; /* incl. alt; list thumbnails */ ReplyPolicy reply_policy = 4; bool paid_partnership = 5; bool made_with_ai = 6; google.protobuf.Timestamp publish_at = 7; /* UTC, whole minute */ ScheduledPostStatus status = 8; string post_id = 9; /* PUBLISHED */ ScheduledPostFailure failure = 10; /* FAILED */ google.protobuf.Timestamp created_at = 11; }` |
| | `message SchedulePostRequest { string idempotency_key = 1; string text = 2; repeated string media_ids = 3; repeated string media_alt_texts = 4; ReplyPolicy reply_policy = 5; bool paid_partnership = 6; bool made_with_ai = 7; google.protobuf.Timestamp publish_at = 8; }` → `SchedulePostResponse { ScheduledPost scheduled_post = 1; }` |
| | `message ListScheduledPostsRequest { int32 page_size = 1; /* 0 => 20, max 50 */ string page_token = 2; /* opaque, bound to caller */ }` → `ListScheduledPostsResponse { repeated ScheduledPost scheduled_posts = 1; string next_page_token = 2; }` |
| | `message CancelScheduledPostRequest { string idempotency_key = 1; string scheduled_id = 2; }` → `CancelScheduledPostResponse { ScheduledPost scheduled_post = 1; /* current state; PUBLISHED = too late, not an error */ }` |
| | `PostService`: `rpc SchedulePost`, `rpc ListScheduledPosts` (`NO_SIDE_EFFECTS`), `rpc CancelScheduledPost`, each with a budget comment from the table below |

**Rules for the three new RPCs:**
- All three need FEATURE_POSTS and FEATURE_SCHEDULED_POSTS (`feature="scheduled_posts"`). If either is off they return
  FEATURE_DISABLED with 0 reads.
- SchedulePost also applies the media, reply-audience and disclosure sub-feature checks, and requires a verified email
  as CreatePost does.
- Error mapping:
  - the pending cap → `LIMIT_REACHED` (`limit=scheduled_pending`);
  - the daily cap → `QUOTA_EXCEEDED` (`quota=schedules`);
  - an unknown id, including any id belonging to another user → NOT_FOUND;
  - an id that does not match `^[0-9a-f]{32}$` → VALIDATION.

**CreatePost `requestHash`.** Append `|policy=…|pp=…|ai=…` **only when the values are not the defaults**, so a
CreatePost retried across the deploy (within the 24 h TTL) still hashes the same.

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
| `draft` | map: `text` (normalised at schedule time), `media[]` (MediaRef copies from `LoadForPost`, with alt), `replyPolicy`, `paidPartnership`, `madeWithAi`. Index-exempt |
| `publishAt` | timestamp, UTC, minute precision |
| `status` | `PENDING`, `PUBLISHED`, `CANCELLED`, `FAILED` |
| `failure` | reason name when FAILED |
| `attempts` | transient publish failures so far |
| `postId` | when PUBLISHED |
| `requestHash` | index-exempt |
| `createdAt`, `updatedAt` | |
| `expireAt` | set on entering a terminal state: now + `SCHEDULED_TERMINAL_TTL` (7 d). TTL policy |

**Status transitions.**
- PENDING → PUBLISHED: the publish transaction.
- PENDING → CANCELLED: the user cancels, or the sweep finds the account DELETING or gone.
- PENDING → FAILED: a permanent cause, expiry, or `attempts ≥ SCHEDULED_MAX_ATTEMPTS`.
- FAILED → CANCELLED: the user dismisses it.
- The client offers "reschedule" as a new SchedulePost built from the stored draft.

**Media.**
- Media are **validated, not reserved**. At schedule time `MediaAttacher.LoadForPost` runs in the schedule transaction
  without `Attach`; at publish it reloads and attaches. An image used elsewhere in between fails the item
  `MEDIA_UNAVAILABLE`.
- READY media docs carry no TTL (`media/service.go`: only PENDING and REJECTED docs expire), so a 60-day horizon is
  safe.
- As before (ADR-0005), READY images that are not attached to a post are already at their public-bucket URLs.

**Indexes (`firebase/firestore.indexes.json`).**
| Scope | Fields | Serves |
|---|---|---|
| `scheduled`, **COLLECTION_GROUP** | `status ASC, publishAt ASC` | the sweep: `status == PENDING && publishAt <= now ORDER BY publishAt LIMIT 50` |
| `scheduled`, **COLLECTION** | `status ASC, publishAt ASC` | the list: `status in [PENDING, FAILED] ORDER BY publishAt, __name__ ASC LIMIT page`, cursor `(publishAt, id)`. A collection-group index is not relied on for a collection query |

- The pending `count()` uses the automatic single-field index on `status`.
- fieldOverrides exempt `scheduled.draft`, `scheduled.requestHash` and `posts.replyPolicy`.
- TTL: a new `ttl_fields` entry `scheduled_expire_at` (`collection = "scheduled"`, `field = "expireAt"`) in
  `infra/terraform/modules/firestore/variables.tf`.
- Rules: `firebase/firestore.rules` stays deny-all.

**Right to delete.** *Plan error (CMP-D2):* "under users/{uid} so the right-to-delete path covers it" is false.
Deleting `users/{uid}` does **not** delete its subcollections, and the T11 guard would fail `make ci`. Needed:
1. A new eraser step `scheduled` (`posts.ScheduledEraser.PurgeUser`): pages of ≤ 500, 1 read and 1 delete per doc,
   registered `BeforeIdentity` after the existing steps (as engagement and reports are).
   - The order does not matter for safety. The 120 s start gate is longer than the 60 s status cache, so the sweep
     sees DELETING and stops publishing before any eraser starts (see Sweep).
   - Update the pinned order in `lifecycle_wiring_test.go:178`.
2. A T11 row: `{Name: "scheduled", Sub: true, Disposition: erasedByStep, Step: "scheduled", Section: "scheduled",
   Owner: "posts", Cite: "ADR-0021"}`.
3. An export section `scheduled` with PENDING and FAILED drafts. PUBLISHED items are already exported under `posts`.
4. No residue: these docs hold only the owner's data, and D2 copies no other user's uid.

## Sweep (`posts.Scheduler.Sweep`, route of D1)
1. **No-op cases.** If `FEATURE_SCHEDULED_POSTS` is `off`, or `FEATURE_POSTS` is globally `off`, or
   `DEGRADED_MODE=readonly`, return 204 with **0 reads** (`outcome=flag_off|degraded`).
   - In allowlist or percent mode the sweep processes every due doc, because only enabled users could create them.
   - Per-user flags are not re-evaluated at publish: they gated creation.
2. **Query.** Run the collection-group query from the index table with `Limit SCHEDULED_SWEEP_LIMIT` (50, clamped
   ≤ 50). Repeat up to `SCHEDULED_SWEEP_MAX_PAGES` (2) times while at least 6 s of the 25 s remain. Process items
   with an errgroup of `SCHEDULED_SWEEP_CONCURRENCY` (4), as the backstop does.
3. **Each item, oldest first:**
   - **Expiry.** If `now − publishAt > SCHEDULED_MAX_LATENESS` (6 h), mark it FAILED `EXPIRED`. This is the catch-up
     bound: after an outage, stale posts are not dumped onto feeds hours late. The user can reschedule.
   - **Author status** through `identity.Directory`, the same 60 s cache CreatePost's interceptor uses:
     - SUSPENDED → FAILED `ACCOUNT_RESTRICTED`.
     - DELETING or missing → CANCELLED.
     - The ADR-0008 D10 start gate (120 s) covers a publish already in flight when deletion starts. The opsctl
       suspend settle pass covers one in flight when a suspension starts, exactly as it does for CreatePost.
   - **Checks that re-run at publish:**
     - the text parse (rules may have tightened) → `INVALID_CONTENT`;
     - mention resolution (handles may have changed);
     - the posts daily quota, including the new-account limit → `QUOTA_EXCEEDED`;
     - media READY or READY_UNSCREENED, owned and unattached → `MEDIA_UNAVAILABLE`.
   - **Checks that run at schedule time only:** verified email (there is no auth context at publish) and the
     sub-feature flags.
   - **No second SafeSearch call.** SafeSearch is not part of the create path: it ran at FinalizeUpload (ADR-0005).
     A re-run would bill a second Vision unit for the same bytes. READY_UNSCREENED keeps the ADR-0005 handling.
   - **Publish transaction.** `posts.service.publishScheduled` reuses the CreatePost draft builder and `repo.Create`,
     with a `CreateParams.Scheduled` guard in place of the idempotency doc. Steps:
     1. Re-read the scheduled doc (must be PENDING, otherwise a no-op).
     2. Read `quotas/{uid}`.
     3. Load the media.
     4. Draw the Snowflake.
     5. Create the post.
     6. Bump `users.postsCount`, reserve the quota, attach the media.
     7. Set the scheduled doc to PUBLISHED with `postId` and `expireAt`.

     After the commit, the cache updates and `PostEvents.Created` (mention notifications, ADR-0017) run as for
     CreatePost.
   - **Errors.**
     - Permanent: FAILED with the reason, set in a transaction that requires PENDING.
     - Transient (deadline, UNAVAILABLE, ABORTED exhausted): `attempts++` with a PENDING precondition.
     - At `SCHEDULED_MAX_ATTEMPTS` (3): FAILED `INTERNAL` plus `mw.ReportError`. A poison item cannot block the head
       of the queue for more than 3 runs.
4. **Response.** 204 even when some items fail; 500 only when the query fails, so Cloud Scheduler retries
   (`retry_count = 3`). Overlapping runs, such as a retry and the next tick, are safe because of the PENDING guard.
5. **Logging.** One `scheduled_sweep` line per run: due, published, failed{reason}, cancelled, expired, transient,
   `max_lateness_ms`, `fs_reads`, `fs_writes`, outcome, trace id. Error Reporting fires on a 500 and on INTERNAL.

**Lateness.** At most the 5 min cadence plus the run time and any retries. A burst drains at 100 items per run, 1,200
per hour. The Stage 0 ceiling is about 15 users scheduling × 25 pending = 375 items, cleared within 4 runs.

## Cost impact
Per-operation Firestore cost. "Cold" includes the account-status interceptor's caller read.
| Operation | Reads worst cold | Reads typical | Writes | Deletes |
|---|---|---|---|---|
| CreatePost root with policy and/or disclosure | +0 (14 / 17 with images, unchanged) | +0 (2) | +0 (4) | +0 |
| Reply, conversation EVERYONE / UNSPECIFIED | +0 (15 unchanged) | +0 (3) | +0 (5) | 0 |
| Reply, MENTIONED_ONLY, parent = root / deeper | +0 / +1 (root post) | +0 / +0 | +0 | 0 |
| Reply, FOLLOWING, parent = root / deeper | +1 / +2 (author graph; + root) | +0 (60 s caches) | +0 | 0 |
| Reply refused (REPLY_NOT_ALLOWED) | as above | as above | 0 | 0 |
| Timelines `viewer_reply_permission` | +0 | +0 | 0 | 0 |
| GetPost / GetThread permission (FOLLOWING, viewer ≠ root author) | +1 | +0 | 0 | 0 |
| SchedulePost | 8 (interceptor 1, count 1, scheduled doc 1, quotas 1, media ≤ 4) | 3 | 2 (scheduled doc, `quotas.schedules`) | 0 |
| SchedulePost replay / at cap | 2 / 2 | 2 | 0 | 0 |
| ListScheduledPosts | 1 + page (21 at 20, 51 at 50) | 1 + items (min 1) | 0 | 0 |
| CancelScheduledPost | 2 | 1 | 1 (0 if already terminal) | +1 TTL after 7 d |
| Sweep run, flag off / readonly | 0 | 0 | 0 | 0 |
| Sweep run, nothing due | 1 | 1 | 0 | 0 |
| Sweep run, N due | N (query, ≤ 100) + per item | | per item | |
| Publish one item | 17 (scheduled 1, quotas 1, media 4, author 1, handles 10) | 3 | 4 (post, postsCount, quotas, scheduled) + n media ≤ 8 | +1 TTL after 7 d |
| Fail / expire / cancel by the sweep | 1 | 1 | 1 | +1 TTL after 7 d |
| Account deletion, `scheduled` step | 1 per doc (min 1) | 1 | 0 | 1 per doc (≤ 25 + ≤ 7 d of terminal docs) |

A publish writes as many docs as a CreatePost: no `idempotency/*` doc (−1 write, −1 TTL delete), plus the scheduled-doc
update (+1).

**Daily budget at the Stage 0 target (300 DAU).**

Assumptions, per DAU per day:
- 0.05 SchedulePost;
- 0.1 list opens returning 3 items;
- 0.01 cancels;
- 0.05 publishes;
- 0.3 replies, 20% of them in restricted conversations at 1 cold read;
- 2 GetThread calls, 10% of them at 1 cold read.

Reads per DAU = 0.05×3 + 0.1×4 + 0.01 + 0.05×5 + 0.3×0.2 + 2×0.1 = 0.15 + 0.40 + 0.01 + 0.25 + 0.06 + 0.20
= **1.07 ≈ 1.1**.

| Daily total at 300 DAU | Arithmetic | Result | Share |
|---|---|---|---|
| Reads | 1.1 × 300 + sweep 288 (24 × 12) | **618** | 1.2% of 50k; +0.9% over the ~69.3k baseline |
| Writes | (0.05×2 + 0.01 + 0.05×4) = 0.31 per DAU, × 300 | **93** | 0.5% of 20k |
| TTL deletes | ≈ 0.06 per DAU, × 300 | **18** | negligible |

| Quota | Feature use | Runs out at (feature alone) | $/month at 2× (600 DAU) | at 10× (3,000 DAU) |
|---|---|---|---|---|
| Firestore reads 50k/day | 288 + 1.1/DAU | (50,000−288)/1.1 ≈ 45k DAU. The whole product already passes it at about 216 DAU (cost-model) | 948/day ≈ 28k/month ≈ $0.02 | 3,588/day ≈ 108k/month ≈ $0.06 |
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
- **Trigger that justifies it:** none needed; it is pay-per-use inside the free tier.
- **Cadence.** Move to a 1 min cadence (1,440 empty reads/day, 2.9% of the quota) only if users complain about
  lateness.

## Security and abuse
- **Authz.**
  - The three RPCs touch only `users/{caller}/scheduled`, so no path reaches another user's docs.
  - They pass the normal interceptors: App Check, ID token, ACTIVE status, rate limits, read budget.
  - The sweep route sits behind `protectInternal` (OIDC audience plus SA email allowlist). Outside `ENV=local`,
    startup already fails without that configuration (apiserver.go:401).
- **Quotas.** The posts daily quota is charged **at publish**, so scheduling cannot bypass it.
- **Content rules unchanged.** Text, mention, hashtag and media rules run at schedule time and again at publish.
- **Privacy.** `draft.text` is never logged. Deletion and export are covered in §Firestore model.

| Abuse case | Mitigation |
|---|---|
| Scheduling spam / schedule-cancel churn | 25 pending (soft), 50 schedules/day (exact, `quotas`), 10/min bucket, posts quota at publish, allowlist rollout |
| Many users schedule the same minute | ≤ 100 per run, the rest at the next tick; per-user quotas unchanged; far below per-collection write limits |
| Schedule, then delete the account | sweep sees DELETING → CANCELLED; the eraser step deletes the docs; the 120 s start gate covers an in-flight publish |
| Schedule, then get suspended | FAILED `ACCOUNT_RESTRICTED`; unsuspension does not revive the item |
| Mention spam through MENTIONED_ONLY | only root mentions grant access (≤ 10, existing quotas, notifications filtered by blocks per ADR-0017); replies cannot widen it |
| Evading the policy deep in a thread | inherited policy checked against the root, plus the root-author block check |
| Probing follow state via REPLY_NOT_ALLOWED | equivalent to the public `ListFollowing`; a block still answers NOT_FOUND first |
| False disclosure labels | user assertion; reportable via ReportContent (ADR-0016) |
| Swapping media between schedule and publish | revalidated at publish (owner, READY, unattached) |

## Consequences
**Positive:**
- Three features with 0 timeline reads, no new GCP service and no fixed cost.
- Exactly-once publishing without new infrastructure.
- Reply restrictions survive the flag being switched off.

**Negative:**
- Up to 5 min of lateness.
- A 6 h outage fails items as EXPIRED instead of posting them late.
- A follow change can take up to 60 s to affect FOLLOWING (cache TTL).
- The pending cap is soft.
- Deep replies in restricted conversations cost +1 cold read; the plan's "+0" holds only for direct replies to the
  root.
- Rule 4 is bent for SchedulePost and CancelScheduledPost.
- **Rollback hazard:** a revision from before this ADR does not enforce policies. Replies written while it runs also
  lose the inherited field, and later replies copy the missing field, so those sub-threads stay open for good. Once
  `FEATURE_REPLY_AUDIENCE` has left `off`, roll forward; do not roll back.

**Revisit when:**
- users complain about lateness (1 min cadence, +1,152 reads/day);
- a third Scheduler job is needed (fold the jobs into one tick route);
- 2-hop or Verified reply tiers are wanted (new ADR: graph cost, verification);
- editing a scheduled post or a reply policy is wanted.

## Rollout, tests, runbook
- **Flags** (`flag-rollout`). Wire names `content_disclosure`, `reply_audience` and `scheduled_posts`, reported in
  `GetMe.enabled_features`, all `off` by default.
  - Build and ship in this order: disclosure, then reply audience, then scheduling.
  - Each goes off → allowlist (dev first) → percent 5/25/100 → on, with a cost-model headroom check at each step.
  - Scheduling additionally needs the prod job applied before the prod allowlist, and dev tested through the D1 curl.
- **Kill switches.**
  - Disclosure off: no new labels; existing labels stay.
  - Reply audience off: no new policies; enforcement stays. Never roll back a revision (see Consequences).
  - Scheduling off: the RPCs return FEATURE_DISABLED and the sweep is a no-op. Pending items wait, then EXPIRE after
    6 h unless `SCHEDULED_MAX_LATENESS` is raised before re-enabling.
- **Config** (env vars plus one Terraform variable):
  - `SCHEDULED_MAX_PENDING=25`, `SCHEDULED_PER_DAY=50`, `SCHEDULED_HORIZON=1440h`, `SCHEDULED_MIN_LEAD=2m`
  - `SCHEDULED_SWEEP_LIMIT=50`, `SCHEDULED_SWEEP_MAX_PAGES=2`, `SCHEDULED_SWEEP_CONCURRENCY=4`
  - `SCHEDULED_MAX_LATENESS=6h`, `SCHEDULED_MAX_ATTEMPTS=3`, `SCHEDULED_TERMINAL_TTL=168h`
  - Terraform `publish_scheduled_schedule="*/5 * * * *"`
- **Tests (CMP-B4, C4, D7).**
  - *Clock-injected unit tests, no sleeps:*
    - `publish_at` bounds and truncation;
    - `requestHash` stability;
    - the policy matrix: author, follower, non-follower, mentioned, blocked by the root author, REPOST parent, deep
      reply, root gone.
  - *Emulator tests:*
    - schedule, list (cursor and `in`), cancel, replay, key reuse, both caps;
    - the sweep: publish, skip cancelled, two concurrent sweeps give one post, media reused gives FAILED, suspended,
      DELETING gives CANCELLED, expiry, the attempts limit, flag off gives 0 reads;
    - the deletion residue sweep and the T11 row;
    - budget assertions.
  - *Other:* Flutter widget tests for the sheet, dialogs and list; `buf breaking`.
- **Runbook** (`docs/runbooks/posts.md`, a new "Scheduled posts sweep" section).
  - Symptoms: 500s on `scheduled_sweep`, `max_lateness_ms` > 600k, a spike in a FAILED reason.
  - Manual run: prod `gcloud scheduler jobs run publish-scheduled --location asia-south1`; dev the D1 curl.
  - Pause: `gcloud scheduler jobs pause` (a paused job still counts toward the 3).
  - Also: the kill switch, draining a backlog, raising max lateness before recovering from an outage, and the
    roll-forward-only rule.

## Not decided / needs founder
1. **Approve the second Cloud Scheduler job in prod** (2 of 3 free), and confirm that no other project on the billing
   account uses Scheduler jobs. Only then is the fixed cost $0.
2. **Reply policy together with a schedule.** This ADR allows it; X disables the control while a schedule is set.
   Mirroring X would be a client-only change plus a VALIDATION rule.
3. **Rule-4 bend.** SchedulePost uses its natural-key doc as the idempotency record, and CancelScheduledPost is
   idempotent by state. Neither stores a TTL'd idempotency doc. This is the same pattern as ADR-0018's bend, which
   the founder approved on 2026-10-17.

## Handoff
- **architect (on Accept):** the proto diff; the index, fieldOverride and TTL entries; a `firestore-data-model` skill
  row for `users/{uid}/scheduled` and the new post fields.
- **backend-developer:**
  - D2: enforcement after `replyParent` and `viewer_reply_permission` in the converters.
  - D3: the new fields in `toDoc` and `snapshotOf`.
  - `posts.Scheduler`: Schedule, List, Cancel and Sweep, plus `ScheduledEraser` and the export section.
  - The `CreateParams.Scheduled` guard and `quota.Schedules`.
  - The route in `apiserver.go`; register the eraser and update the pinned order in `lifecycle_wiring_test.go:178`;
    add the T11 row.
  - Rate-limit mapping: SchedulePost and Cancel use the CreatePost bucket.
  - The config keys.
  - The pending `count()` aggregation is charged to `budget.Counter` by hand, because the store wrappers do not see
    it.
- **frontend-developer:**
  - The "Who can reply?" sheet (3 options), the disclosure dialog, and labels on `PostCard` and embeds.
  - The schedule dialog with platform pickers, sending UTC.
  - The Scheduled list: PENDING and FAILED items, cancel, reschedule; and the "Schedule" button state.
  - Gate everything on `enabled_features`, and never send poll fields together with a schedule.
- **production-deployer:**
  - Add `publish-scheduled` to `envs/prod` jobs only, with the schedule as a variable. Update the job-count comments
    in both envs and fix dev's `gcloud scheduler jobs run` note.
  - Grant the founder `roles/iam.serviceAccountTokenCreator` on the **dev** pubsub-push SA for the D1 curl (a dev
    apply).
  - The `scheduled_expire_at` TTL field, the `FEATURE_*` and `SCHEDULED_*` env vars, and both indexes.
- **tester:** the outline above.
- **sre-performance:** CMP-D8. Feed the cost rows into `docs/reviews/cost-model.md` and add `scheduled_sweep` to
  `make cost`.
- **security-auditor:** the OIDC route, the D2 oracle analysis and the abuse table.
