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
| Users report no push but the list shows rows | No registered device, token pruned, or the Cloud Run runtime service account cannot send through FCM | Check `notification_push_failed` and `notification_delivery` (`pruned`) counts. The Admin SDK uses the default credentials; no extra role is granted in Terraform, confirm on dev. iOS also needs the APNs key uploaded in the Firebase console |
| A user keeps getting pushes for an account that left the handset | Should not happen: a token registered by a second account is removed from the first (`deviceTokens` index) | Check `deviceTokens/{sha256(token)}`: `uid` must be the newest account. Do not hand-edit; ask the user to sign out and in |
| Reads spike on `users/*/notifications` | Clients polling without `since_token` | The app must send the `since_token` it was given. Rate limits: 60/min default plus the daily read budget |
| `notification_devices_daily` limit hits | A client registering on every foreground | RegisterDevice writes nothing when unchanged within 24 h, but each call still reads 2 docs; the client should register once per app start and on token refresh |
| Publish failures (`notification_publish_failed`) | Pub/Sub outage or the runtime service account is missing `roles/pubsub.publisher` on `notifications-fanout` (`runtime_publisher_topics`) | Producers drop the event and never fail the follow or the post. Fix the binding or wait; lost events are not replayed |

## Privacy
- Tokens live only in `users/{uid}/devices` and are hashed (`sha256`) in `deviceTokens`. They never reach logs, exports
  or API responses.
- A push carries a generic title/body and ids (`type`, `notificationId`, `postId`, `actorId`): no post text, no handle.
- Account deletion removes the user's devices and token index, their own rows and the rows other users hold about
  them (`notifications` step, collection-group `array-contains` on `actorIds`). Backups age out after 14 days.

## Cost watch
Per DAU about 11 reads, 7 writes and 6 TTL deletes (plan: `docs/plans/notifications.md`). Scale-up trigger: Firestore
reads over 40k/day or DLQ depth above 0 for an hour. FCM and the Pub/Sub volume (< 1 MB/day) are free.
