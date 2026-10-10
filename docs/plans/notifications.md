# Notifications: in-app + FCM push (Phase 1 slice P6)
Plan owner: planner · Date: 2026-10-10 · Target release: **v0.4.0** (store-ready core, `docs/plans/phase1.md` §4) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, `docs/plans/phase1.md` (P6), `docs/reviews/cost-model.md` (levers 6.1, 6.4), `docs/plans/graph.md` (T5
FollowEvents), ADR-0003, ADR-0008 (D6, D11), ADR-0010, ADR-0011 (Q1, Q10), `backend/internal/{identity,graph,posts}`,
`backend/pkg/platform/{pubsubpush,pubsubpublish,cursor,flags,budget,store}`, `infra/terraform/modules/pubsub`,
`free-tier-budget`, `flag-rollout`, `reuse-first` skills.

New contracts: `proto/dzeroth/notifications/v1/notifications.proto` and **ADR-0016 (Proposed)**.

## Decisions (delegated 2026-10-10)
The founder delegated product decisions to the lead; these were pre-made and are recorded here.
1. **FCM tokens** live in `users/{uid}/devices/{deviceId}`, never in the public `users` doc; max 5 per user (a sixth
   evicts the least recently updated); pruned on FCM `UNREGISTERED`. (ADR-0016 D1.)
2. **Reverse index** `deviceTokens/{sha256(token)}` so a handset shared by two accounts only pushes to the current one
   (architect addition, ADR-0016 D1).
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
| T1 | ADR-0016 + `notifications.v1` proto + this plan | architect | In review (PR 1) |
| T2 | Module: types, `Emitter`, Firestore repo (notifications, devices, token index), ids, cursor tokens | backend | In review (PR 2) |
| T3 | Fan-out push handler `/internal/pubsub/notifications-fanout`: decode, suppress, create, push, prune, DLQ semantics | backend | In review (PR 2) |
| T4 | ListNotifications (`since`/gap tokens) + MarkNotificationsSeen (identity method + cache evict) | backend | In review (PR 2) |
| T5 | RegisterDevice/UnregisterDevice (cap 5, cross-user token transfer, daily call cap) | backend | In review (PR 2) |
| T6 | `notifications.Eraser` + exporter, T11 guard rows, `account-deletion.md` lists, index override | backend | In review (PR 2) |
| T7 | Wiring: config, flag, rate limits, `FollowEvents` + `PostEvents` adapters, Terraform variable | backend | In review (PR 2) |
| T8 | Tests: unit, emulator integration with budget assertions, suppression matrix, idempotency, DLQ semantics | tester | In review (PR 2) |
| T9 | Flutter: tab, list with drift cache, badge, permission flow, `firebase_messaging` behind the flag, deep links | frontend | In review (PR 3) |
| T10 | Replies (P3) and likes/reposts/quotes (P5) call `Emitter.Emit` | P3/P5 owners | Blocked (their slices) |
| T11 | Security review (token handling, payload, handler auth) | security-auditor | Open |
| T12 | **Manual:** push arrives on a real Android and iOS device and tapping deep-links to `/post/:id` / profile | founder/QA | Manual (needs device + APNs key in Firebase) |
| T13 | Terraform: `api_publish_topics` += `notifications-fanout`, `FEATURE_NOTIFICATIONS*` env on the api service (dev only) | deployer | Open (needs plan-then-OK) |

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
| ListNotifications, cold or older page (20) | 1 + 20 / 21 | 0 | `seen_at` profile comes from the account-status cache |
| ListNotifications, `since` refresh | 1 + new / 1-5 | 0 | lever 6.1 (the 5 is the planning mean) |
| MarkNotificationsSeen | 0 / 0 | 1 / 1 | + 1 profile read next GetMe (cache evicted) |
| RegisterDevice | 8 / 2 | 5 / 2 | worst: device doc, token index, previous owner's device, list of 6 |
| UnregisterDevice | 1 / 1 | 2 / 2 | device + index |
| Fan-out, one recipient (follow/mention) | 2 / 1.3 | 1 / 1 | users batch (actor, recipient, cached), devices <= 5 |
| Fan-out, collapsed like (not first) | 1 / 1 | 1 / 1 | `Create` AlreadyExists billed as a read, then `Update` |
| Producer publish | 0 | 0 | one Pub/Sub publish, outside the request transaction |
| TTL | | | deletes, 6 per DAU, free |

Per DAU (cost-model rows): 2 ListNotifications (1 cold 21 + 1 refresh 5) + mark seen + 6 delivered notifications
(follow, mention, reply, likes collapsed): about **11.3 reads, 7.4 writes, 6 TTL deletes**.

## Cost line
- FCM: **$0**. Pub/Sub: about 0.7 MB/day at 300 DAU vs 10 GiB/month free, **$0**. No new GCP resource.
- Firestore at 300 DAU: reads 3.4k/day (7% of free), writes 2.2k/day (11%), deletes 1.8k/day (9%).
- Whole-product reads stay at the ADR-0010 model (~215 reads/DAU, ~$0.26/month over free at 300 DAU) with lever 6.1
  applied; notifications' own contribution is the 11.3 reads above (the model had 191 total before corrections).
- Scale-up trigger: reads > 40k/day or Pub/Sub dead-letter depth > 0 for 1 h (alert exists in the pubsub module).

## Verification record
Filled in when each PR lands (measured counters from the emulator integration suite).

## Open risks
- On-device push (T12) cannot be verified from CI; iOS needs the APNs auth key uploaded to the Firebase project.
- A like followed by an unlike leaves the notification (no retraction at Stage 0).
- Post deletion does not remove notifications that point at it (tap shows "post unavailable"); TTL clears them.
