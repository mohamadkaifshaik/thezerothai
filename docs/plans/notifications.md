# Notifications: in-app + FCM push (Phase 1 slice P6)
Plan owner: planner · Date: 2026-10-10 · Target release: **v0.4.0** (store-ready core, `docs/plans/phase1.md` §4) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, `docs/plans/phase1.md` (P6), `docs/reviews/cost-model.md` (levers 6.1, 6.4), `docs/plans/graph.md` (T5
FollowEvents), ADR-0003, ADR-0008 (D6, D11), ADR-0010, ADR-0011 (Q1, Q10), `backend/internal/{identity,graph,posts}`,
`backend/pkg/platform/{pubsubpush,pubsubpublish,cursor,flags,budget,store}`, `infra/terraform/modules/pubsub`,
`free-tier-budget`, `flag-rollout`, `reuse-first` skills.

New contracts: `proto/dzeroth/notifications/v1/notifications.proto` and **ADR-0017 (Accepted by the founder 2026-10-18)**.

## Decisions (delegated 2026-10-10)
The founder delegated product decisions to the lead; these were pre-made and are recorded here.
1. **FCM tokens** live in `users/{uid}/devices/{deviceId}`, never in the public `users` doc; max 5 per user (a sixth
   evicts the least recently updated); pruned on FCM `UNREGISTERED`. (ADR-0017 D1.)
2. **Reverse index** `deviceTokens/{sha256(token)}` so a handset shared by two accounts only pushes to the current one
   (architect addition, ADR-0017 D1).
3. **Event sources behind one interface**, `notifications.Emitter`; follows and mentions are wired now, replies (P3)
   and likes/reposts/quotes (P5) call `Emit` when they land.
4. **Likes collapse** per post per UTC hour (lever 6.4); one push per collapsed row.
5. **Suppression**: no notification or push if the recipient blocks or mutes the actor, or the actor blocks the
   recipient; none for self-actions; none for non-ACTIVE recipients.
6. **Push carries no post text** (privacy); generic title/body by type; the app deep-links via go_router.
7. **Web push is out of scope** (service worker + VAPID); the web build hides the permission prompt and uses the
   in-app list only.
8. **Residue**: no allowlist entry; the Eraser also removes rows in other users' lists whose `actorIds` contains the
   deleted user (collection-group `array-contains` + index override). The earlier T11 table row for `notifications`
   (pendingEraser) becomes `erasedByStep`.
9. **Failure mode**: a failed publish is logged and dropped (never fails a follow or a post); a failed delivery retries
   through Pub/Sub then dead-letters.
10. **Flag**: `FEATURE_NOTIFICATIONS`, default off everywhere (Terraform variable default off, no prod apply).

## Tickets
Status values: Open, In review (PR), Done (merged), Blocked, Manual.

| # | Ticket | Owner | Status |
|---|---|---|---|
| T1 | ADR-0017 + `notifications.v1` proto + this plan | architect | Done (proto `proto/dzeroth/notifications/v1/notifications.proto` and this plan on main; ADR-0017 Accepted 2026-10-18, #141; renumbered from ADR-0016) |
| T2 | Module: types, `Emitter`, Firestore repo (notifications, devices, token index), ids, cursor tokens | backend | Done (#122 merged, per `engagement.md` T9; `backend/internal/notifications/*` on main) |
| T3 | Fan-out push handler `/internal/pubsub/notifications-fanout`: decode, suppress, create, push, prune, DLQ semantics | backend | Done (#122 merged; `notifications.NewFanout` wired in `apiserver.go:214`) |
| T4 | ListNotifications (`since`/gap tokens) + MarkNotificationsSeen (identity method + cache evict) | backend | Done (#122 merged; `notifications/server.go` on main) |
| T5 | RegisterDevice/UnregisterDevice (cap 5, cross-user token transfer, daily call cap) | backend | Done (#122 merged; cap later hardened by T14, #139) |
| T6 | `notifications.Eraser` + exporter, T11 guard rows, `account-deletion.md` lists, index override | backend | Done (#122 merged; `notifRepo` registered in `registerLifecycleModules`, `apiserver.go:305`) |
| T7 | Wiring: config, flag, rate limits, `FollowEvents` + `PostEvents` adapters, Terraform variable | backend | Done (#122 merged; `apiserver/notifications_wiring.go`). Terraform variable: see T13 |
| T8 | Tests: unit, emulator integration with budget assertions, suppression matrix, idempotency, DLQ semantics | tester | Done (#122 merged; `apiserver/notifications_wiring_test.go`, `internal/notifications/*_test.go`) |
| T9 | Flutter: tab, list with drift cache, badge, permission flow, `firebase_messaging` behind the flag, deep links | frontend | Done (merged via integration PR #135; `app/lib/features/notifications/*`) |
| T10 | Replies (P3) and likes/reposts/quotes (P5) call `Emitter.Emit` | P3/P5 owners | Partly done: P5 likes/reposts/quotes are wired (`engagementNotifier`, `postNotifier` in `apiserver.go:246,264`; engagement T9, #135). The P3 reply producer is in progress; status unverified as of 2026-10-18 |
| T11 | Security review (token handling, payload, handler auth) | security-auditor | Done (findings N-1..N-5; N-1, N-2, N-3, N-5 fixed in `fix/notifications-hardening`, N-4 owned by the moderation/removal-log change) |
| T14 | Hardening from the T11 audit: per-actor recipient cap (N-1), per-recipient push limit + collapse by type (N-2), no row id in the export (N-3), FCM dry-run token validation + devices cap 10/day (N-5) | backend | Done (#139 merged) |
| T12 | **Manual (iOS half PAUSED until the Apple launch, 2026-10-18; Android half only for now):** push arrives on a real Android and iOS device and tapping deep-links to `/post/:id` / profile | founder/QA | Manual (needs device + APNs key in Firebase; prerequisites below) |
| T13 | Terraform: `runtime_publisher_topics` += `notifications-fanout`, `FEATURE_NOTIFICATIONS*` env on the api service | backend (declared) / deployer (apply) | Declared in PR 2, not applied (needs plan-then-OK) |

### Acceptance criteria
- ListNotifications returns newest first; `since_token` refresh reads only newer rows; an expired/foreign token is
  INVALID_ARGUMENT with 0 reads.
- The fan-out handler delivers the same Pub/Sub message twice and the result is one notification row and one push.
- The block/mute suppression matrix passes (recipient blocks actor, recipient mutes actor, actor blocks recipient,
  self, suspended recipient, flag off).
- Like collapse: N likes by distinct users within an hour produce one row with `actor_count = N` and one push.
- RegisterDevice: 6th device evicts the oldest; the same token registered by user B is removed from user A.
- `make ci` and the integration suite pass; coverage >= 70% on `internal/`; the T11 guard names `notifications`,
  `devices` and `deviceTokens` as erased by step `notifications`.
- Flutter widget tests for the notifications screen and the permission flow; analyze clean.

## Budget (reads/writes per request; Stage 0 targets)
| RPC / path | Reads worst / typical | Writes worst / typical | Notes |
|---|---|---|---|
| ListNotifications, cold or older page (20) | 20 + graph snapshot (0-1) / 21 | 0 | `seen_at` profile comes from the account-status cache; rows hidden by block/mute are still read |
| ListNotifications, `since` refresh | 1 + new / 1-5 | 0 | lever 6.1 (the 5 is the planning mean) |
| MarkNotificationsSeen | 0 / 0 | 1 / 1 (0 within 10 s of the last mark) | + 1 profile read next GetMe (cache evicted) |
| RegisterDevice | 9 / 2 | 5 / 2 | worst: device doc, token index, previous owner's device, device list of 5, evicted device's index. N-5: the FCM dry run is a Google API call (0 Firestore ops, 2 s timeout) and a rejected token costs 0 reads and 0 writes; cap 10 calls/uid/day, so at most 90 reads and 50 writes per uid per day |
| UnregisterDevice | 1 / 1 | 2 / 2 | device + index |
| Fan-out, one recipient (follow/mention) | 1 + R + 5 devices / 4 | 1 / 1 | N-2: a recipient past 10 pushes/hour skips `Devices` (0 device reads) and the FCM send, the row is still written; actor and recipients are evicted and re-read for a fresh ACTIVE check (1 + R, R <= 10, uncached by design), recipient graph (cached), devices <= 5 |
| Fan-out, collapsed like (not first) | (1 + R) + 2 / 4 | 1 / 1 (0 on redelivery) | fresh status reads, failed `Create` (1 read), fold transaction (1 read, 1 write only when the actor is new) |
| Producer publish | 0 | 0 | one Pub/Sub publish, outside the request transaction. N-1: the per-actor daily recipient cap (200, 50 for new accounts) is in memory, 0 reads; it bounds one actor to about 600 fan-out reads and 200 writes a day (3 and 1 per recipient). An over-cap event is dropped before publish |
| TTL | | | deletes, 6 per DAU, free |

Per DAU (cost-model rows): 2 ListNotifications (1 cold 21 + 1 refresh 5) + mark seen + 6 delivered notifications
(follow, mention, reply, likes collapsed): about **11.3 reads, 7.4 writes, 6 TTL deletes** before the fresh-status
fix. Each delivery now also re-reads its actor and recipient (about 2 reads, uncached by design, ADR-0017 Consequences),
so the honest figure is about **23 reads/DAU** (11.3 + 6 x 2), 7.4 writes, 6 deletes.

## Cost line
- FCM: **$0**. Pub/Sub: about 0.7 MB/day at 300 DAU vs 10 GiB/month free, **$0**. No new GCP resource.
- Firestore at 300 DAU: reads about 6.9k/day (about 14% of free; 3.4k before the fresh-status reads), writes 2.2k/day (11%), deletes 1.8k/day (9%).
- Whole-product reads stay at the ADR-0010 model (~215 reads/DAU, ~$0.26/month over free at 300 DAU) with lever 6.1
  applied; notifications' own contribution is about 23 reads (the model had 191 total before corrections), so the whole product is about 227 reads/DAU.
- Scale-up trigger: reads > 40k/day or Pub/Sub dead-letter depth > 0 for 1 h (alert exists in the pubsub module).

## Verification record
Emulator integration suite (`make test-int` equivalent, 2026-10-11), measured counters from the budget assertions:

| Path | Reads | Writes | Deletes | Test |
|---|---|---|---|---|
| Create (new row) | 0 | 1 | 0 | `TestIntegration_CreateIsIdempotentAndBudgeted` |
| Create replay (AlreadyExists) | 1 | 0 | 0 | same |
| AddActor (collapsed like; replay 1 / 0 writes) | 1 | 1 | 0 | `TestIntegration_AddActorFoldsAndMovesCreatedAt` |
| List page of 2 / older 3 / since 2 / empty | 2 / 3 / 2 / 1 | 0 | 0 | `TestIntegration_ListOrderBoundsAndBudget` |
| RegisterDevice new / fresh / refresh / token rotation | <= 3 / <= 2 / <= 2 / <= 2 | <= 2 / 0 / <= 2 / <= 2 | 0 / 0 / 0 / <= 1 | `..._RegisterDevice_BudgetsRefreshAndTokenRotation` |
| RegisterDevice sixth device (eviction) | <= 9 | <= 2 | <= 3 | `..._CapEvictsLeastRecentlyUpdated` |
| RegisterDevice token taken from another account | <= 8 | <= 2 | <= 3 | `..._TokenMovesToTheNewAccount` |
| RemoveDevice / stale token / unknown | <= 2 / <= 1 / <= 1 | 0 | <= 2 / 0 / 0 | `TestIntegration_RemoveDevice` |
| Fan-out follow, 2 devices / redelivery | <= 4 / <= 3 | <= 1 / 0 | 0 | `TestIntegration_FanoutBudgetsAndIdempotency` (includes the 2 fresh profile reads) |
| Fan-out first like / collapsed like / like redelivery | <= 4 / <= 4 / <= 4 | <= 1 / <= 1 / 0 | 0 | same |
| Account delete, notifications step (empty account) | 3 | 0 | 0 | `TestAccountLifecycle_ReferenceAccountBudgets` (job total 512 reads, was 509) |
| Account export, notifications section (empty) | 2 | 0 | 0 | same (job total 705 reads, was 703) |

Each cell is the asserted ceiling (`budgettest.Assert`), not a single measurement. End to end
(`backend/e2e/notifications_smoke_test.go`): flag off is FEATURE_DISABLED on every RPC; B follows A, A's list gets
`follow_<B>`, the GetMe badge goes 1 -> 0 after MarkNotificationsSeen, a foreign cursor is INVALID_ARGUMENT, device
register/unregister are idempotent.

### T12 prerequisites (founder credentials; the client code is ready)
- **PAUSED (founder decision 2026-10-18): iOS push is deferred to the Apple launch.** No macOS/Xcode access is available now, so the APNs key is not created or uploaded and iOS push is not verified. Android push, the in-app list and the badge are unaffected. Resume with the Apple launch feature (see the roadmap, "Later: Apple launch").
- **iOS (deferred, Apple launch):** upload the APNs authentication key (.p8, key id, team id) to the Firebase project (Project settings -> Cloud Messaging). The client side is in the repo: `ios/Runner/Runner.entitlements` (`aps-environment`, referenced by all three Runner build configurations) and `UIBackgroundModes: remote-notification` in `Info.plist`. The Push Notifications capability must also be enabled on the App ID in the Apple developer account, and a provisioning profile regenerated.
- **Android:** `google-services.json` for the app id (Firebase public config, not a secret). The `social` notification channel the backend names (`fcm.go` ChannelID) is created at startup in `MainActivity`, and `default_notification_channel_id` points at it; `POST_NOTIFICATIONS` is declared for Android 13+.
- **Both:** `FEATURE_NOTIFICATIONS` allowlisted for the tester account, a real device (simulators and emulators without Play services do not receive pushes).
- **Known client behaviour:** on iOS without an APNs token the FCM token is unavailable; the client treats `apns-token-not-set` as "not registered yet" and registers on the next token refresh.

## Open risks
- On-device push (T12) cannot be verified from CI. iOS push is paused until the Apple launch (no macOS now; APNs key **pending**, not created or uploaded). Android push can be verified on a real device.
- A like followed by an unlike leaves the notification (no retraction at Stage 0).
- Post deletion does not remove notifications that point at it (tap shows "post unavailable"); TTL clears them.
