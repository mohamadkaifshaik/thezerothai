# Runbook: notifications and push (P6, ADR-0017)

Owner: backend-developer / sre-performance. Flag: `FEATURE_NOTIFICATIONS` (wire name `notifications`, off by default).

## Switch it off
Set `FEATURE_NOTIFICATIONS=off` (Terraform `var.feature_notifications`). The four RPCs answer FEATURE_DISABLED, producers
stop publishing (0 cost), and the push handler acknowledges and drops events that are already queued. Rows already
written stay readable for 90 days (TTL). `DEGRADED_MODE=readonly` also makes the handler acknowledge and drop events
(no Firestore writes in that mode); those notifications are lost, by design.

## Failure modes
| Symptom | Likely cause | What to do |
|---|---|---|
| Dead-letter depth > 0 on `notifications-fanout-dlq` (alert) | A transient Firestore failure persisted for 5 deliveries, or a bug in the handler | Look at the `notification_delivery_failed` log lines (`message_id`, `delivery_attempt`, redacted `err`). Fix, then replay the DLQ messages: the handler is idempotent (deterministic ids), so replay never double-notifies |
| Mentions, replies, quotes or reposts from a protected account stop arriving (ADR-0025 D10, W3-31) | By design: the fan-out drops post-bearing rows (`suppressed_protected` on the `notification_delivery` line) when the recipient may not see the actor; likes, follows and the two request types are never suppressed. If the protected set is unavailable (past `PROTECTED_SET_MAX_STALE`) the delivery returns 5xx (`audience check` in the redacted `err`) and Pub/Sub retries; after 5 attempts the message dead-letters, so a long set outage shows as DLQ depth, not as leaked rows. Fix the set (see the posts runbook) and replay the DLQ: replay is idempotent. Never "fix" it by writing the row |
| `follow_request` row did not appear again after a withdraw and re-request | By design: the id `follow_request_{requester}` is deterministic and a withdraw does not delete the row, so within the 90 d TTL the re-request is AlreadyExists (no second row, no second push) | Nothing to do |
| Users report no push but the list shows rows | No registered device, token pruned, or the Cloud Run runtime service account cannot send through FCM | Check `notification_push_failed` and `notification_delivery` (`pruned`) counts. Look at `fcm_code` on `notification_push_failed`: `PERMISSION_DENIED` means the runtime service account lacks the custom role `fcmSend` (`cloudmessaging.messages.create`, `modules/iam`) or `fcm.googleapis.com` is not enabled (`modules/project-services`); `INVALID_ARGUMENT` is our payload or project config (the device is kept, never pruned); `UNREGISTERED` / `SENDER_ID_MISMATCH` prune the device. iOS also needs the APNs key uploaded in the Firebase console (**pending: iOS push is paused until the Apple launch, so iOS devices will not receive pushes yet; this is expected, not an incident**) |
| A user keeps getting pushes for an account that left the handset | Should not happen: a token registered by a second account is removed from the first (`deviceTokens` index) | Check `deviceTokens/{sha256(token)}`: `uid` must be the newest account. Do not hand-edit; ask the user to sign out and in |
| Reads spike on `users/*/notifications` | Clients polling without `since_token` | The app must send the `since_token` it was given. Rate limits: 60/min default plus the daily read budget |
| Dead-letter depth from a burst of likes on one post | The fold of a collapsed like is a transaction on one document per post per hour; a viral post contends and Pub/Sub retries exhaust | Expected under bursts; replay the DLQ (idempotent, an actor already folded in writes nothing) |
| Many `notification_push_failed` with `fcm_code=INVALID_ARGUMENT` | Bad or malformed tokens from a client bug (they are kept, never pruned, so the WARN repeats per push) | Find the client version registering bad tokens; if it is our payload or project config, fix that. Volume is bounded by the 5-device cap and one push per row |
| `notification_seen_daily` limit hits (200/uid/day) | A client calling MarkNotificationsSeen in a loop | Calls inside 10 s of the previous mark are no-ops with 0 writes; the client should mark seen once when the tab is shown |
| `notification_fanout_capped` WARN (fields `actor_hash`, `type`, `recipients`, `limit_per_day`, `new_account`) | An actor passed the per-actor daily recipient cap (200, 50 for accounts younger than the new-account window): mass-follow or mass-mention abuse, or a very active legitimate account | The event was dropped before publish (0 cost); nothing to replay. Look up the `actor_hash` for repeats across days (`jsonPayload.message="notification_fanout_capped"`); raise `NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY` only with a cost note (about 3 reads and 1 write per recipient) |
| `push_throttled` > 0 on `notification_delivery` | A recipient got more than 10 pushes in an hour (`NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR`), usually a targeted burst | Rows are still written and shown in-app; only the FCM send is skipped. Pushes also collapse per type on the handset (collapse key = type) |
| `notification_device_token_rejected` / users cannot register a device (INVALID_ARGUMENT `fcm_token`) | FCM's dry run says the token is not valid for this project (wrong Firebase project in the client config, stale token) | Check the app's Firebase project matches the backend's. `notification_token_validation_skipped` (with `fcm_code`) means the check could not run and the token was accepted: `PERMISSION_DENIED` again points at the `fcmSend` role |
| `notification_devices_daily` limit hits (10/uid/day) | A client registering on every foreground | RegisterDevice writes nothing when unchanged within 24 h, but each call still reads 2 docs (9 worst case when it evicts a sixth device); the client should register once per app start and on token refresh |
| Publish failures (`notification_publish_failed`) | Pub/Sub outage or the runtime service account is missing `roles/pubsub.publisher` on `notifications-fanout` (`runtime_publisher_topics`) | Producers drop the event and never fail the follow or the post. Fix the binding or wait; lost events are not replayed |

## Privacy
- Tokens live only in `users/{uid}/devices` and are hashed (`sha256`) in `deviceTokens`. They never reach logs, exports
  or API responses.
- A push carries a generic title/body and ids (`type`, `notificationId`, `postId`, `actorId`): no post text, no handle. The FCM collapse key is the notification type, not the id.
- The account export lists each notification as `type`, `actorHandle`, `postId`, `createdAt`: no row `id` (ids embed other accounts' uids, e.g. `follow_{actorUid}`).
- Account deletion removes the user's devices and token index, their own rows and the rows other users hold about
  them (`notifications` step, collection-group `array-contains` on `actorIds`; collapsed rows keep their other actors
  and are repointed). A row written by a delivery that raced the purge (milliseconds) outlives it until the 90-day TTL
  (ADR-0017 Consequences). Backups age out after 14 days.

## Cost watch
Per DAU about 23 reads (11 plus about 2 fresh profile reads per delivery), 7 writes and 6 TTL deletes (plan: `docs/plans/notifications.md`); about 7k reads/day at 300 DAU. Scale-up trigger: Firestore
reads over 40k/day or DLQ depth above 0 for an hour. FCM and the Pub/Sub volume (< 1 MB/day) are free.
