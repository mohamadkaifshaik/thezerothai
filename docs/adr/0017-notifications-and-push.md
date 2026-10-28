# 0017. Notifications: in-app list, FCM push and the device-token model
Status: Accepted (2026-10-18, founder)
Date: 2026-10-10 (amended 2026-10-17: D6 payload, cost impact, delete budget; founder approval 2026-10-17; accepted by the founder 2026-10-18)
Deciders: lead (founder delegated product decisions 2026-10-10); founder accepts the ADR (CLAUDE.md)

> Acceptance (founder approval 2026-10-17): the founder approved the recommendation to **accept after T11**. The
> status stayed Proposed until the security review T11 (`docs/plans/notifications.md`) passed and the delete-budget
> amendment (`docs/plans/account-deletion-export.md` T16) was signed off. Both are done: T11 passed, the T16 amendment
> was approved by the founder 2026-10-18, and the founder accepted this ADR on 2026-10-18. `FEATURE_NOTIFICATIONS` stays
> off (flag-rollout skill) and the Terraform changes remain plan-then-OK; acceptance is not a rollout or an apply.

> Numbering: first drafted as 0016; renumbered to 0017 because P7's ADR-0016 (reports, PR 116) was opened first. 0012-0015 stay free for the slices running in parallel (P2-P5).

## Context
Phase 1 slice P6 (`docs/plans/phase1.md`, `docs/plans/notifications.md`). Users must learn about follows, mentions,
replies, likes, reposts and quotes, in-app and by push. Already in place:

- `users/{uid}/notifications/{id}` is declared in ADR-0003 with a 90-day TTL on `expireAt` (Terraform policy exists).
- GetMe's badge is `count(createdAt > users/{uid}.notificationsSeenAt)` capped at 100 (`identity/repo_firestore.go`).
- graph exposes the post-commit hook `FollowEvents.Followed` (ADR-0008 D11) and posts exposes `PostEvents.Created`
  (ADR-0010), both no-ops.
- `notifications-fanout` topic + push subscription + DLQ exist in `infra/terraform/modules/pubsub` (path
  `/internal/pubsub/notifications-fanout`, OIDC).
- Cost model levers 6.1 (`since` cursor + client cache: -15 reads/DAU) and 6.4 (collapse likes per post per hour).
- Event sources land at different times: follows and mentions exist now, replies are P3, likes/reposts/quotes P5.

Open questions this ADR settles: where FCM tokens live, how fan-out is made idempotent, where block/mute suppression
runs, how likes collapse, and what a push may carry.

## Options
**Device tokens.** (a) in `users/{uid}/private` (a single doc with an array); (b) `users/{uid}/devices/{deviceId}`
documents; (c) a top-level `devices` collection keyed by token.
(a) is one read for all tokens but a shared hot doc written by every device refresh and needs array-of-map edits in a
transaction; (b) bounds the count with a Limit and lets one device be refreshed or removed alone; (c) loses the
"everything of a user lives under users/{uid}" property the Eraser and exporter rely on.

**Idempotent fan-out.** (a) an `idempotency/{messageId}` doc per delivery; (b) deterministic notification doc ids plus
`Create` (AlreadyExists = already delivered); (c) in-memory dedupe.
(c) is lost on restart. (a) doubles the writes of every notification (a 24 h TTL doc per delivery). (b) costs nothing
extra and makes the *push* idempotent too: the push is sent only by the call that created the document.

**Suppression (block/mute) placement.** (a) at the producer, inside the user's request; (b) at the consumer.
(a) puts a graph read in the request path of every like/follow and checks stale state; (b) runs once per delivery
off the request path against the recipient's cached snapshot.

## Cost impact
- FCM: $0 (no quota). Pub/Sub: a notification event is under 400 bytes, 6 per DAU per day is about 0.7 MB/day at 300
  DAU against a 10 GiB/month allowance. No new GCP resource, no fixed cost.
- Firestore per DAU (derived in `docs/plans/notifications.md` section Cost): about 6.3 writes, **~23 reads**, 6 TTL
  deletes. At 300 DAU: 1.9k writes/day (9% of free), **~7k reads/day (~14%)**, 1.8k deletes/day (9%). Reads stay
  inside the ADR-0010 whole-product model (215 reads/DAU) with lever 6.1 applied. (Corrected 2026-10-17: the first
  draft said 11.3 reads/DAU, 3.4k/day, 7%; the figure was revised in the 2026-10-13 amendment, "Budgets".)
- The `actorIds` collection-group index adds one index entry per notification (storage cents at Stage 0: about
  0.2 KB per notification, 90-day window).

## Decision
**D1. Data model.**
- `users/{uid}/notifications/{id}`: `type`, `actor{userId,handle,displayName,avatarUrl,verified}`, `actorIds[]`,
  `postId`, `createdAt`, `expireAt` (= createdAt + 90 d). The id is deterministic per logical notification:
  `follow_{actorUid}`, `mention_{postId}`, `reply_{postId}`, `quote_{postId}`, `repost_{postId}_{actorUid}`,
  `like_{postId}_{yyyymmddhh}` (UTC hour bucket).
- `users/{uid}/devices/{deviceId}`: `token`, `platform`, `createdAt`, `updatedAt`. At most 5 per user: a sixth
  registration evicts the least recently updated one (a new sign-in must never fail on an old phone).
- `deviceTokens/{sha256(token)}`: `uid`, `deviceId`, `updatedAt`. A reverse index so a token registered by a second
  account on the same handset is removed from the first account (otherwise user A keeps receiving user B's pushes
  after B signs in on A's old phone). Rejected alternative: relying on the client calling UnregisterDevice on
  sign-out (not enforceable; the app can be killed or uninstalled).
- Tokens never appear in the public `users` doc, in logs, in the export or in any RPC response.
- `firestore.rules` stays deny-all; all access is Admin SDK.

**D2. Emitter seam.** `notifications.Emitter.Emit(ctx, Event)` is the only call other slices make. Producers are
adapted in `apiserver` (never imported by notifications): graph `FollowEvents.Followed` and posts
`PostEvents.Created` (mentions) are wired now; replies (P3) and likes/reposts/quotes (P5) call `Emit` with
`TypeReply`/`TypeLike`/`TypeRepost`/`TypeQuote` when they land. Self-actions are dropped at the emitter (0 cost).

**D3. Fan-out.** `Emit` publishes one message on `notifications-fanout` (up to 10 recipients; one publish per
event). The push handler `/internal/pubsub/notifications-fanout` (OIDC, the existing `/internal/` middleware) decodes
the envelope, and per recipient: flag check, status ACTIVE (identity.Directory drops SUSPENDED/DELETING), block/mute
suppression (D5), actor snapshot, `Create` the notification (D1 ids), and only if the Create succeeded send the push.
Redelivery of the same Pub/Sub message therefore writes nothing new and sends no second push (idempotent by message
id through natural keys; the message id is logged). A transient failure returns 5xx so Pub/Sub retries and finally
dead-letters; a malformed message or a permanently invalid recipient is acknowledged (2xx). The `createdAt` is the
handler's commit time, not the event time, so `since` refreshes cannot miss a late-delivered row.

**D4. Likes collapse (lever 6.4).** One doc per post per UTC hour. The first like `Create`s it and sends one push;
later likes in that hour fold into it without a push: a small transaction reads the row and, only when the actor
is not already in `actorIds`, appends it, replaces `actor` and `createdAt` and increments `actorCount`.
`actorIds` keeps the **last 50** distinct actors (older ones are trimmed in the same transaction) so a viral post
cannot grow one document toward 1 MiB or hammer it past ~1 write/s sustained; `actorCount` keeps counting through
`FieldValue.Increment`, and `actor_count` on the wire is `max(actorCount, len(actorIds))` (rows written before the
field existed fall back to `len(actorIds)`). A redelivery or a repeat like by an actor still in the window writes
nothing (1 read for the failed `Create`, 1 for the fold's check). An actor who left the 50-window and likes again
is counted twice: `actor_count` beyond 50 is approximate by design.

**D5. Suppression.** At consume time, from the recipient's cached `graph.Snapshot`: actor in `Blocked` (recipient
blocks actor), in `Muted`, or in `BlockedBy` (actor blocks recipient) => no notification and no push. Self => none.
Matrix test in the plan (T10).

**D6. Push payload.** FCM `data` (`type`, `notificationId`, `postId`, `actorId`) **plus a
`messaging.Notification{Title, Body}`** with generic text chosen by type (`pushText`: "New follower" / "Someone
started following you", "New mention", ...) (amended 2026-10-17 to match `backend/internal/notifications/fcm.go:122`; the first draft said `data` only). **No post
content, no handle in the title or body of the lock-screen notification**. Android channel `social`, iOS `apns-priority 5`. The app deep-links to `/post/:id` or the
actor's profile. A send error `UNREGISTERED` or `SENDER_ID_MISMATCH` for the token deletes that device and its
index doc (only if the stored token still matches). `INVALID_ARGUMENT` does **not** prune: it can be our payload or
project misconfiguration, and pruning on it would silently delete every user's device. It is logged as
`notification_push_failed` with the redacted FCM error code (never the error text or the token) and the device is
kept.

**D7. Flag.** `FEATURE_NOTIFICATIONS` (wire name `notifications`, default off) gates the four RPCs and the producers
(`Emit` is a no-op, 0 publishes, when the flag is off for the recipient) and the handler (acknowledges and drops).
Retiring the flag follows ADR-0008 D6. Terraform variable default off; no prod apply in this slice.

**D8. Mark seen.** `MarkNotificationsSeen` writes `users/{uid}.notificationsSeenAt = now` through a method on the
identity repo (identity owns that field) and evicts the profile/unread cache entries (`Directory.Forget`).
`ListNotifications` returns `seen_at` so the client renders unread state without a count call.

**D9. Reads and quotas.** ListNotifications: `since` refresh reads only newer rows (lever 6.1); pages `Limit(page_size)`
(default 20, max 50). Tokens are the existing cursor Window codec, bound to the caller, 30-day TTL (same as the
timelines). RegisterDevice/UnregisterDevice share a per-uid 50/day call cap (`notification_devices_daily`).

**D10. Erasure and export.** `notifications.Eraser` (step `notifications`, registered before the identity step):
(1) the user's devices and their `deviceTokens` docs; (2) the user's own notification rows; (3) rows in *other* users'
lists whose `actorIds` contains the user, through a collection-group `array-contains` query (needs the
`notifications.actorIds` COLLECTION_GROUP index override). The export section `notifications` lists the user's own rows
(type, actor handle, postId, createdAt) and device platform/timestamps, never tokens. The T11 table row for
`notifications` becomes `erasedByStep`; `devices` and `deviceTokens` rows are added.

**D11. Out of scope.** Web push (needs a service worker and VAPID, tracked as a follow-up; the web client hides the
permission prompt), per-type notification preferences, digest emails, notification deletion by the user, notifying
on post delete.

## Consequences
- The module works with only follows and mentions today; each later slice adds a one-line `Emit`.
- A like and then an unlike leaves the like row (no retraction); acceptable at Stage 0 (documented in the plan).
- If the Pub/Sub publish fails the producer logs and drops the event (best effort; a lost notification is preferable
  to failing a follow or a post).
- Clock skew between instances is bounded by the 5 s settle window of `since_token`.
- Right-to-delete residue for notifications is **small but not nil**. The fan-out evicts the actor and recipients
  from the profile cache and re-reads them before writing, so a row is only written for an account that is ACTIVE
  at that read (cost: up to 1 + R reads per delivery, typically 2; R = recipients <= 10). The remaining race is the
  milliseconds between that read and the `Create` against a purge that has already swept the same subtree: such a
  row (and an orphan row under a just-deleted recipient) lives until its 90-day TTL and the 14-day backup window.
  The account-lifecycle backstop keys on `users/{uid}`, which is deleted last and so is already gone by then; a
  re-run of the purge's actor-row step (notifications step 2) is therefore not available without a new data model, and this ADR accepts the window.
- The producer's flag and publish happen after commit, outside the transaction and its read budget.

## Handoff
- backend-developer: `backend/internal/notifications`, wiring in `apiserver`, `identity.FirestoreRepo.MarkNotificationsSeen`.
- frontend-developer: notifications tab, badge, permission flow, `firebase_messaging` behind the flag.
- production-deployer: Terraform `FEATURE_NOTIFICATIONS*` variables (default off), `NOTIFICATIONS_TOPIC`, the `api`
  service account's publish permission on `notifications-fanout` (`api_publish_topics`), the FCM send permission
  (see the 2026-10-13 amendment: the runtime SA needs the custom role `fcmSend` with
  `cloudmessaging.messages.create`, and `fcm.googleapis.com` must be enabled; `roles/firebasecloudmessaging.admin`
  is too broad), the new Firestore index override. No prod apply.
- security-auditor: token handling, push payload, handler OIDC, cross-user token transfer.

## Amendment 2026-10-11 (implementation, P6 backend PR)
- **Delivery mode.** `NOTIFICATIONS_DELIVERY` = `pubsub` (publish on `NOTIFICATIONS_TOPIC`, Pub/Sub pushes back to
  `/internal/pubsub/notifications-fanout`; default everywhere except local) or `inline` (in-process, at most 8 goroutines,
  FCM replaced by a log line). `inline` is refused by `config.Load` outside `ENV=local`: it runs after the response, which
  Cloud Run throttles. Local dev and the emulator suite have no push subscription, which is why it exists.
- **FCM addressing.** Registration tokens (what `firebase_messaging.getToken()` returns) are sent with
  `messaging.Message.Token`. The Admin SDK marks `Token` deprecated in favour of `Fid` (the Firebase installation id), which
  is a different identifier; switching needs a client change and a new ADR. Staticcheck SA1019 is suppressed on that line.
- **Account lifecycle cost.** The registered `notifications` step costs 3 reads per deleted account when the account has
  nothing to erase (devices, own rows, rows naming the user: an empty query bills 1 read), plus one read and one delete
  per document. The export gains a `notifications` section: 2 reads when empty. The reference-account budgets in
  `backend/internal/apiserver/account_lifecycle_*_integration_test.go` move from 509 to 512 reads (delete job; ADR-0011
  formula 510 to 513 plus D) and from 703 to 705 reads (export job). These are P6-only values. With P7's `reports`
  step (+1, ADR-0016 Implementation notes) the asserted delete-job bounds are the plan T16 criterion **513 + D**
  (`planDeleteReads` = 509 + 3 + 1 at that point) and the ADR-0011 formula **514 + D** (`refDeleteReadsBase`) at that point; with P5's +3 and ADR-0016 amendment (b)'s +1 the asserted values are now **517 + D** and **518 + D** (corrected 2026-10-18), and the export is
  707 (with P4's media section) in `account_lifecycle_reference_integration_test.go` (reconciled 2026-10-17; sign-off
  the T16 amendment approved by the founder 2026-10-18). At 300 DAU and roughly 1 deletion per day this is
  immaterial; the reference numbers in ADR-0011 are otherwise unchanged.
- **Wiring.** graph gains `Deps.Events` (the `FollowEvents` implementation, nil = no-op); `Build` injects an adapter
  that calls `Emitter.Emit`. posts' `Events` is a mention adapter. Rate limits: the four RPCs use the 60/min default
  bucket and the read budget; RegisterDevice and UnregisterDevice share the per-uid `notification_devices_daily` cap
  (default 50/day, `NOTIFICATION_DEVICES_CALLS_PER_DAY`).
- **Status.** The flag stays off everywhere. Terraform: variables `feature_notifications*` (default `off`) and the env
  vars are declared in both environments, and `notifications-fanout` joins `runtime_publisher_topics` (an IAM binding on
  an existing topic, no new resource, no fixed cost). Nothing was applied.

## Amendment 2026-10-13 (review fixes, P6 backend PR)
- **FCM permission (corrects the Handoff above).** The Admin SDK sends with the Cloud Run runtime service account's
  token, and `messages:send` requires `cloudmessaging.messages.create`, which no existing grant carries; the
  `fcm.googleapis.com` API was not enabled either. Terraform adds the custom role `fcmSend` (that one permission) on the
  runtime SA (`modules/iam`) and `fcm.googleapis.com` to `modules/project-services`. No fixed cost. Until applied,
  every push fails with a logged `PERMISSION_DENIED` code and rows keep being written.
- **D4 amendment.** `actorIds` capped at the last 50 with a running `actorCount` (text in D4).
- **D6 amendment.** `INVALID_ARGUMENT` no longer prunes (text in D6).
- **D8 amendment.** `MarkNotificationsSeen` is a no-op returning the cached `seen_at` when that value is younger than
  10 s, and has its own per-uid daily cap `notification_seen_daily` (default 200/day, `NOTIFICATION_SEEN_CALLS_PER_DAY`):
  at most 200 writes per uid per day, 1% of the project's 20k/day for a single abusive uid, and 0 for a client that
  marks seen on every tab focus.
- **D5 amendment.** Suppression also runs at read time: `ListNotifications` filters rows through the caller's cached
  graph snapshot (0-1 read). A block or mute made after the row was written takes effect immediately. The page is
  filtered after the query, so a page can be short or empty; tokens are computed from the scanned rows and the client
  keeps paging while `next_page_token` is set. The fan-out's block check honors `blockedByOverflow` (the actor's own
  graph is read, +1 cached read, only for such recipients); the read-time filter does not (it would cost a graph read per
  distinct actor per page).
- **Fan-out ordering.** All rows of an event are committed (each with its own commit-time `createdAt`) before the
  first push, so FCM latency cannot push a row past the 5 s since-token settle window.
- **D10 amendment.** Notifications purge step 2 (rows in other users' lists) removes the erased user from collapsed rows with `ArrayRemove` and decrements `actorCount`
  when other actors remain, repointing the displayed `actor` at the newest remaining one (one `GetProfiles` per page of
  <= 500 rows); a row with no remaining actor, or whose replacement actor is gone, is deleted.
- **Budgets.** RegisterDevice worst case reads 8 to 9 (the evicted device's index is read so another account's index is
  never deleted); a collapsed like costs (1 + R) fresh profile reads + 2 reads (Create attempt + fold check) and 1 write, 0 writes on redelivery. Per DAU the notifications total is about 23 reads (was 11.3): about 7k reads/day at 300 DAU, 14% of the free quota.
- **Accepted behaviors (round 2).** (a) The GetMe unread badge counts rows by `createdAt > notificationsSeenAt` and
  does not apply the read-time filter, so it can exceed the visible rows after a block or mute; fixing it would add
  reads. (b) A collapsed row is hidden entirely when its newest (displayed) actor is blocked or muted, even if other
  actors are not; a later like shows it again. (c) Purge step 2 writes are conditioned on the update time seen by its
  query, so a like folding in concurrently fails that batch and the self-resuming step retries; a document liked
  continuously could delay the purge but never loses a fold. `Checkpoint.Deleted` counts documents processed
  (deleted or unfolded in place). (d) After their row commits (a Create, or a like folded into an existing row via AddActor, which moves its createdAt forward), the fan-out evicts only each recipient's cached unread count
  (`Directory.ForgetUnread`, no reads) so the badge is recounted; the freshly read profile stays cached.


## Implementation notes / follow-ups
**iOS push paused (founder decision 2026-10-18).** No macOS access is available, so the APNs authentication key is pending and iOS push is deferred to the Apple launch feature. The decision (FCM over APNs) is unchanged; Android push, the in-app list and the badge are unaffected. The client side (`Runner.entitlements`, `UIBackgroundModes`) is already in the repo. Resume steps are in `docs/plans/notifications.md` (T12 prerequisites).

Security audit of the P6 backend (plan ticket T11, hardening ticket T14, branch `fix/notifications-hardening`). This
section records implementation facts only; the ADR status is unchanged (Proposed).

| Finding | State | What changed |
|---|---|---|
| N-1 fan-out cost not charged to the actor | Done | `prepare`'s callers (`PubSubEmitter`, `InlineEmitter`) charge the surviving recipients to the actor in a `RecipientCap` (`ratelimit.DailyCap.AllowN`, all or nothing): default 200 recipients/day, 50 for accounts younger than `QUOTA_NEW_ACCOUNT_WINDOW`; env `NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY` / `NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY`, both validated > 0 at startup, set in `envs/*` Terraform. 0 reads: "new account" comes from a per-instance createdAt memo (`accountAges`, filled by the account-status adapter on every authenticated request, because graph Follow and post create evict the actor's cached profile just before they emit) with a profile-cache peek as fallback; an actor not seen by this instance counts as established. A non-positive limit means no cap (like the push limiter); `config.Load` rejects it in deployed builds. An over-cap event is dropped and logged as WARN `notification_fanout_capped` (hashed actor). The delivery log line gains `rpc=internal.NotificationsFanout` and `fanout_fs_reads` so `make cost` shows fan-out reads. Worst case per actor per day: 200 recipients x (1 + R fresh reads, typically 2, plus graph and <= 5 device reads) x 1 write. |
| N-2 no per-recipient inbound push limit | Done | `FanoutDeps.PushLimit`, a per-recipient token bucket (`ratelimit.NewLimiterWindow`, default 10 pushes/hour, `NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR`), consulted before `Repo.Devices`: rows are still written, the push is skipped and counted (`push_throttled`). FCM collapse key, Android tag and `apns-collapse-id` are now the notification type; `notificationId` stays in `data`. |
| N-3 export leaks uids through notification ids | Done | `exportedNotification` has no `id`; `exportRow` is the pure mapping, unit-tested with a uid-shaped actor id. |
| N-4 removal-log findings | Open here, owned by the moderation change | Not part of this branch (posts/timeline removal-log code and opsctl belong to the moderation change). |
| N-5 RegisterDevice accepts any string as an FCM token | Done | `TokenValidator` seam; `FCMSender.Validate` does an FCM dry-run send (`SendDryRun`, free) after the shape checks and before any Firestore operation, with a 2 s timeout. INVALID_ARGUMENT, UNREGISTERED and SENDER_ID_MISMATCH reject (INVALID_ARGUMENT on the RPC); every other outcome fails open with WARN `notification_token_validation_skipped` and the fixed code, so an unapplied `fcmSend` role (Amendment 2026-10-13) cannot block registration. Local and emulator (`NOTIFICATIONS_DELIVERY=inline`) wire `NopValidator`. `NOTIFICATION_DEVICES_CALLS_PER_DAY` default lowered from 50 to 10 in code and in `envs/*` Terraform (not applied). |

Residuals: the recipient and device caps are per Cloud Run instance lifetime (the accepted in-memory approximation); a
new account first seen by another instance (or after the memo's one hour) gets the established-tier allowance; a client that re-registers on every foreground
can now hit the 10/day devices cap (the runbook already asks for once per app start and on token refresh).

### Replies producer (T10, 2026-10-18; facts only)

- `postNotifier.Created` (`apiserver/notifications_wiring.go`) emits `TypeReply` to the parent post's author for a
  `Kind == REPLY` post, through the same `PostEvents` hook and `emitterSlot` as mentions and quotes. Id
  `reply_{replyPostId}` (D1), so a redelivery or an idempotent CreatePost replay (which never calls the hook) writes
  nothing new. Self-replies, a non-PUBLIC reply and an unknown parent author emit nothing; block/mute/ACTIVE
  suppression stays in the fan-out (D5). Replies to a REPOST resolve to the original, so its author is notified.
- The parent author comes from `Post.ReplyToAuthorID`, a **transient** field set by `applyReply` from the parent the
  reply validation already loaded. It is not persisted, not part of the data model and empty on any Post read back
  from Firestore. CreatePost therefore costs 0 extra reads and 0 extra writes; the fan-out cost is charged to the actor
  by the existing per-actor recipient cap (N-1: 1 recipient per reply).
- Precedence when a reply also @mentions the parent author: the reply row only (like quote beats mention): the parent
  author is removed from the mention event, other mentioned users still get `mention_{postId}`. A quote and a reply
  are mutually exclusive on one post.
- Tests: `TestPostNotifierReplies` (unit), `TestReplyNotifications` (emulator: reply row, replay, self, muted
  recipient, reply+mention collapse, CreatePost request line unchanged at 5 writes and <= 15 reads).

## Note (2026-10-28): a push-only `message` type (ADR-0027 D9, W7)
ADR-0027 (Messaging v1, Proposed) adds `TypeMessage` and an additive `Event.ConversationID`; the wire event's `v` stays 1.
It takes effect when ADR-0027 is accepted and W7-10 merges. D2 is unchanged (the event still goes through `Emitter`
after the commit). What differs for this one type:
- **Push-only:** no row in `users/{uid}/notifications`, no badge move, never returned by ListNotifications;
  `validateEvent` requires no post id for it.
- **D6 unchanged in spirit:** generic title and body ("New message"), `data` holds `type=message` and
  `conversationId` only (no sender, no text, no uid). Collapse key and Android tag `message` (type-level, as N-2).
- **Own limiter bucket** (`MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR`, 20), outside the shared 10/h.
- The fan-out's reads are unchanged for this type (fresh actor and recipient profiles, the recipient's graph for D5
  suppression, the devices).
- Sent only when `messaging` and `notifications` are both on for the recipient.
- **D11 unchanged:** no web push; iOS waits for the Apple launch.
No decision of this ADR changes.
