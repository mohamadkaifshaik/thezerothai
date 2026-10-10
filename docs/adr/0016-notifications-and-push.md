# 0016. Notifications: in-app list, FCM push and the device-token model
Status: Proposed
Date: 2026-10-10
Deciders: lead (founder delegated product decisions 2026-10-10); founder accepts the ADR (CLAUDE.md)

> Numbering: 0012-0015 were left free for the slices running in parallel (P2-P5). Renumber on merge if a gap is unwanted.

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
- Firestore per DAU (derived in `docs/plans/notifications.md` section Cost): about 6.3 writes, 11.3 reads, 6 TTL
  deletes. At 300 DAU: 1.9k writes/day (9% of free), 3.4k reads/day (7%), 1.8k deletes/day (9%). Reads stay inside the
  ADR-0010 whole-product model (215 reads/DAU) with lever 6.1 applied.
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
later likes in that hour `Update` `actorIds` with `ArrayUnion` (idempotent), the latest `actor` and `createdAt`,
without a push. `actor_count` on the wire is `len(actorIds)`.

**D5. Suppression.** At consume time, from the recipient's cached `graph.Snapshot`: actor in `Blocked` (recipient
blocks actor), in `Muted`, or in `BlockedBy` (actor blocks recipient) => no notification and no push. Self => none.
Matrix test in the plan (T10).

**D6. Push payload.** FCM `data` only: `type`, `notificationId`, `postId`, `actorId`, a generic localized
title/body chosen by type ("New follower", "You were mentioned", ...). **No post text, no handle in the body of the
lock-screen notification**. Android channel `social`, iOS `apns-priority 5`. The app deep-links to `/post/:id` or the
actor's profile. A send error `UNREGISTERED`/`INVALID_ARGUMENT` for the token deletes that device and its index doc.

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
- Right-to-delete residue is nil for notifications (D10 step 3) apart from the 14-day backup window.
- The producer's flag and publish happen after commit, outside the transaction and its read budget.

## Handoff
- backend-developer: `backend/internal/notifications`, wiring in `apiserver`, `identity.FirestoreRepo.MarkNotificationsSeen`.
- frontend-developer: notifications tab, badge, permission flow, `firebase_messaging` behind the flag.
- production-deployer: Terraform `FEATURE_NOTIFICATIONS*` variables (default off), `NOTIFICATIONS_TOPIC`, the `api`
  service account's publish permission on `notifications-fanout` (`api_publish_topics`), the FCM send permission
  (`roles/firebasecloudmessaging.admin` is NOT needed: the Admin SDK uses the default service account's FCM API
  access; confirm on dev), the new Firestore index override. No prod apply.
- security-auditor: token handling, push payload, handler OIDC, cross-user token transfer.
