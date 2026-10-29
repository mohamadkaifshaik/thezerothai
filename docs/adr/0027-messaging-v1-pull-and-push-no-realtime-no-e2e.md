# 0027. Messaging v1: 1:1 direct messages, pull + push, no realtime, no E2E (W7)
Status: Accepted (founder, 2026-10-28, by merging PR #400)
Date: 2026-10-28
Deciders: architect (proposal); founder. The founder's answers to F1–F11 are recorded below (2026-10-28: every
default accepted). Merging this ADR is the founder's acceptance of the remaining architect decisions D1–D16.

Plan: `docs/plans/ui-w7-messaging.md`, ticket W7-1 (this ADR); W7-2 to W7-24 implement it. The plan asked for
"ADR-0029 or the next free number"; 0026 went to the W8 shells, so this is 0027. W5 and W6 planned 0027/0028 with the
same "or the next free number" rule and take the next free numbers when their ADRs open.

Related ADRs:
- ADR-0003: the data model this extends (three new collections, one `quotas` field).
- ADR-0008: D2 (`blockedBy`, overflow), D6 (flags are env vars).
- ADR-0010: D5 (per-uid read budget), D9 (text rules).
- ADR-0011: lifecycle (erasers, export, the T11 collections guard).
- ADR-0016: reports; a dated note in the same PR (D12).
- ADR-0017: D2 (`Emitter`), D5 (suppression), D6 (push payload), D11 (no web push); a dated note in the same PR (D9).
- ADR-0021: the deterministic-id precedent that bends rule 4 (and here rule 1).
- ADR-0022: the credit window. Nothing in this ADR depends on it.
- ADR-0023: "not globally off" read semantics, the appended eraser-step precedent.
- ADR-0025: protected accounts. They do not change messaging (D4).

## Context
People expect to talk privately one to one; on X it is the main retention loop after Home and Notifications. The
roadmap row W7 and the founder's decision of 2026-10-22 fix the shape: **server-mediated pull + FCM push, no E2E,
1:1 only**. The stage-ladder Real-time row already says "DMs v1 = pull + push, no E2E".

What exists on `main` (15975e5, 2026-10-28; the plan's table was checked on d2ff011 and re-checked here):
- No messaging module, proto or collection.
- `backend/internal/posts/text` is a pure leaf package (`Normalize`, D9 rules, 280 code points / 10 lines);
  `imports_test.go` pins "no `internal/` imports" so other modules can import it.
- `graph.Snapshot` (60 s cache) carries `Following`, `Blocked`, `Muted`, `Requested`, `BlockedBy`,
  `BlockedByOverflow`, `RecentFollowing`. The **recipient's** snapshot answers "follows / blocked / muted the sender"
  authoritatively, with no overflow case. W3 Part B (ADR-0025) added `Requested` and changes nothing here.
- `notifications.Event{Type, ActorID, RecipientIDs, PostID, At}` → Pub/Sub `notifications-fanout` → `Fanout.Deliver`.
  Every event writes a row; `validateEvent` needs a post id for every type except the follow family; one 10/h
  per-recipient push limiter is shared by all types; the payload is generic text (D6); no web push (D11).
- `GetMe.unread_notification_count` is a `count()` cached 30 s. `flags.Registry.GloballyOff` exists (ADR-0023).
  `ratelimit.DailyCap` exists. `identity.Directory.Forget` evicts a cached profile.
- Eraser steps are registered in `apiserver.Build`; the last appended steps run `scheduled` → `bookmarks` →
  `follow_requests`, all before `identity`.

**Measured numbers.** No production traffic yet. This ADR keeps the plan's cost baseline as the founder approved it
(`docs/reviews/cost-model.md` §5, W2 lines): 248.7 reads, 33.5 writes, 8.4 deletes, 37.7 requests per DAU per day; free
reads run out at about 201 DAU and writes at about 597; the Stage 0 bill is about INR 441 / 1,653 / 3,498 a month at
300 / 1,000 / 3,000 DAU. W3–W6 increments are not part of this baseline (the plan notes each is small next to W7's);
W7-23 restates the W7 rows on the cost model current when it runs.

## Founder decisions F1–F11 (recorded 2026-10-28: all defaults)
INR lines are the W7 increment at 300 / 1,000 / 3,000 DAU, computed with the `cost-model.md` §7 prices (INR 95/USD).
"Included" means the line is part of the Cost impact total below.

| # | Question | Options | Decision | INR / month at 300 / 1,000 / 3,000 DAU |
|---|---|---|---|---|
| F1 | Images in messages | **(a) text only**; (b) images through the media pipeline with private-read objects and SafeSearch | **(a)** | (a) 0. (b), not built: at 5 % of messages with an image, about 4.6 Vision units per DAU-month ≈ INR 197 / 656 / 1,967 before egress, inside the shared `VISION_MONTHLY_CAP`; its own ADR |
| F2 | Who can message whom | **(a) mutual follows → Inbox, everyone else → Requests; 3 messages until accepted; 20 new conversations a day (5 for new accounts)**; (b) followers of the recipient → Inbox; (c) mutual only, no requests; (d) (a) plus an "allow requests from Everyone / No one" setting | **(a)** | (a) included. (b) ±0. (c) about −0.2 / −0.6 / −1.8 (fewer request sends). (d) +0 reads (the field rides on the recipient `users` read already made) |
| F3 | Deleted account, the peer's copy | **(a) tombstone: "Message deleted", the peer's own messages stay, read-only, tree deleted when both are gone**; (b) erase outright | **(a)** | Both: one-off per deleted account (≈ 340 reads, 340 writes for the reference account); ≈ 0 / 0 / 0 at any plausible deletion rate |
| F4 | Read receipts, typing | **(a) neither**; (b) receipts (a write per read, the peer polls for it); (c) typing (needs realtime) | **(a)** | (a) 0. (b) about +1.5 writes/DAU/day ≈ 0 / 4.5 / 13.5. (c) not possible at Stage 0 (D7) |
| F5 | Export section `messages` | **(a) own messages in full, received ones as time + "received"**; (b) both sides in full | **(a)** | Same reads either way (both sides are read to order the export); ≈ 0 |
| F6 | Kill-switch semantics | **(a) send and accept need the flag for the caller and the recipient; list, read, mark-read, delete and report need only "not globally off"; `off` hides everything**; (b) off for the caller hides the inbox too | **(a)** | 0 |
| F7 | Push for messages | **(a) one generic FCM push per message, Android only, none for requests or muted senders, no Notifications row**; (b) (a) plus a push for requests | **(a)** | (a) included; its reads (3.5 per message, D9) ≈ 1.6 / 5.3 / 15.9, its requests and CPU sit in the Cloud Run lines. (b) about +0.1 more |
| F8 | Message length | **(a) the post grammar: 280 code points, 10 lines**; (b) 1,000 code points | **(a)** | (a) included. (b) ≈ +3 KB per long message; < 0.1 / 0.1 / 0.3 storage |
| F9 | Muted senders | **(a) delivered silently: no push, no unread increment; muted and blocked requests hidden**; (b) refused (reveals the mute) | **(a)** | 0 |
| F10 | Navigation | **(a) Messages is the 5th bar item (Home, Explore, Notifications, Messages, Profile) and a rail item, with an unread badge**; (b) drawer only | **(a)** | 0 server (the badge rides on GetMe, D10) |
| F11 | Report a message | **(a) yes, through ReportContent; the report copies only that message as evidence; `opsctl` can take a message down**; (b) no message reports | **(a)** | Included (≈ 0.05 calls/DAU/day); ≈ 0 |

## Options
### A. Data model
- **A1 (chosen). Per-user index entries.** `conversations/{convId}` with a `messages` subcollection, plus
  `users/{uid}/dmInbox/{convId}` and `users/{uid}/dmRequests/{convId}` written on every message for both participants.
  Pros: every query runs on an automatic single-field index of one collection; Inbox, Requests, "delete for me" and
  the unread badge are per-user queries; groups later add entries without changing callers. Cons: +1 write per
  message (3 instead of 2). Cost: idle 0; ≈ INR 0 / 17 / 52 of writes at 300 / 1,000 / 3,000 DAU.
- **A2. One shared conversation doc** with `participants[]` and participant-keyed maps. Pros: 2 writes per message.
  Cons: the inbox query `participants array-contains uid ORDER BY lastMessageAt` needs a composite index, Requests and
  "delete for me" need another or in-memory filtering with short pages; per-user unread state becomes a map on a doc
  both participants write. Cost: ≈ INR 0 / 13 / 39 of writes, plus two composite indexes (a gate-file change either way).

### B. Delivery
- **B1 (chosen). Pull + push.** A backing-off `since` poll on a visible thread, an inbox `since` refresh, and an
  Android FCM push that triggers an immediate pull. Pros: request-billed, scales to zero, reuses the timeline and
  notifications cursor codecs. Cons: delivery bounded by the poll interval on web (≤ 15 s hot, ≤ 45 s quiet). Cost:
  ≈ INR 12 / 58 / 480 (Cost impact).
- **B2. Firestore client listeners on owner-only docs.** Pros: sub-second delivery, no polling CPU. Cons: rules
  are deny-all to clients today; this needs a rules ADR (per-path `allow read` scoped to the uid), client SDK listeners
  on every platform, and re-architecting authz checks that the server makes today (block, mute, participant). Listener
  reads are billed per changed doc. Cost: comparable reads, far less CPU; the risk is authz moving into rules.
- **B3. WebSocket / SSE on Cloud Run.** Cons: a held connection is an always-on instance in disguise (request-billed
  Cloud Run bills the whole connection time), routing is not sticky across instances, and fan-out between instances
  needs a broker (Memorystore or Pub/Sub per instance). Cost: at 3,000 DAU with 10 % concurrently connected, about one
  instance busy all month ≈ INR 6,000 (1 vCPU, 512 MiB), a fixed-cost shape. Rejected at Stage 0.

### C. Message ids and idempotency
- **C1 (chosen). Deterministic id** = first 32 hex of SHA-256(`senderUid|"SendMessage"|idempotency_key`), `Create`
  in the send transaction; AlreadyExists at commit = replay. No `idempotency/*` doc, no TTL delete. Ordering by
  `createdAt DESC, __name__ DESC`. Bends rule 1 (Snowflake ids) and rule 4 (a TTL'd idempotency doc) exactly as
  ADR-0021 did for scheduled posts: the message doc is the idempotency record, and ordering never relies on the id.
- **C2. Snowflake id + `idempotency.Store`.** +1 read, +1 write, +1 TTL delete per send (≈ +INR 0.5 / 6.5 / 20 a month);
  time-ordered ids. No query needs id order, so C2 buys nothing.

### D. End-to-end encryption
- **D1 (chosen). None in v1.** The server holds the plaintext; Google-managed encryption at rest (rule 10).
- **D2. E2E now.** Rejected for v1, for four reasons, each an ADR of its own:
  1. **Key management:** per-device keys, a key directory, multi-device, lost devices, key backup and recovery. X's
     passcode gate in front of its chat is exactly this problem.
  2. **Moderation:** a report can no longer copy evidence the server cannot read; it needs client-side reporting
     with message franking.
  3. **Attachments:** client-side encryption with a separate key per object, doubling the media work (and F1 is
     text-only anyway).
  4. **Search and export** of encrypted history become client-only, and the export of ADR-0011 cannot include them.

  The seam that keeps D2 possible: message text is read and written **only** by `messaging.Service`; no other module
  reads `conversations/*/messages`, so a ciphertext body later changes only that module and the client.

## Decision
Ship 1:1 direct messages as a new `messaging` module in the monolith. It owns three collections: per-pair conversations
with a `messages` subcollection, and per-user `dmInbox` / `dmRequests` entries. Every query runs on automatic
single-field indexes; there is no composite index. Delivery is pull (paged reads plus a backing-off `since` poll on a
visible thread) and a generic, push-only FCM `message` notification on Android. Mutual follows land in the Inbox;
everyone else goes to capped Message requests. Block and mute are enforced on send and on read. Account deletion
leaves tombstones. Everything sits behind `FEATURE_MESSAGING`. There is no realtime channel and no E2E; both have a
seam and a measured trigger in the stage ladder. The details are D1–D16.

### D1. Collections (owner: messaging)
| Path | Shape | Written when | Queries |
|---|---|---|---|
| `conversations/{convId}` | `kind` (`DIRECT`); `participants` [lowUid, highUid]; `state` (`REQUEST` / `ACCEPTED`); `requestFrom`, `requestTo`, `requestCount` (messages sent while REQUEST); `clearedAt` {uid: ts} (delete for me) (+ `clearedKey` {uid: digest}, 2026-10-29 note); `gone` [uid] (erased participants); `createdAt`, `updatedAt` | first message; accept; each request message (`requestCount` +1); delete-for-me; the eraser; **not on every accepted message** (no hot doc) | get by id; the eraser: `participants array-contains uid` (automatic array index) paged by `__name__`, Limit ≤ 100 |
| `conversations/{convId}/messages/{msgId}` | `senderId`; `text` (NFC; **index-exempt**); `state` (`VISIBLE` / `DELETED_ACCOUNT` / `REMOVED`); `requestHash` (one-way digest of the request for the same-key-different-body check; **index-exempt**); `createdAt` | SendMessage (`Create`); the eraser and `opsctl` tombstone (`text` cleared, `state` set; field-level `Update`, never `Set`) | thread page `createdAt DESC, __name__ DESC` Limit ≤ 50; `since`: `createdAt > t` (5 s settle window); the eraser: `senderId == uid` Limit 500 |
| `users/{uid}/dmInbox/{convId}` | `peerId`; `peer` {handle, displayName, avatarThumbUrl, verified} (**index-exempt**); `lastMessageAt`; `last` {messageId, fromSelf, snippet ≤ 100 code points, state} (**index-exempt**); `unreadCount` (`FieldValue.Increment`, one writer per message, rule 3); `silent` (the owner muted the peer); `lastReadAt` (never shown to the peer, F4); `createdAt` | every send writes both participants' entries (a bounded constant 2, not a follower fan-out; rule 2 concerns timelines); mark-read; accept (created); the eraser | inbox `lastMessageAt DESC, __name__ DESC` Limit ≤ 50; `since`: `lastMessageAt > t`; the badge: `count()` of `unreadCount > 0`, Limit 100 |
| `users/{uid}/dmRequests/{convId}` | same shape as `dmInbox` | a request message to a non-mutual (recipient side only; the sender's entry is in the sender's own `dmInbox`, as on X) | requests list as the inbox; a `count()` for "Message requests (N)" |
| `quotas/{uid}.dmNew` | new conversations opened today (IST day, as every quota) | the first message of a new conversation only, in the send transaction | — (ADR-0021 I-3: `CheckAndReserveN` `Set`s the whole record, so the field is added to `quota.Record` in the same PR as its first writer) |

**Indexes.** No composite index and no collection-group query. Six fieldOverrides with `indexes: []` at COLLECTION
scope: `messages.text`, `messages.requestHash`, `dmInbox.peer`, `dmInbox.last`, `dmRequests.peer`, `dmRequests.last`
("exempt large text fields", `firestore-data-model`). They go in **`firebase/firestore.indexes.json` and the
`firebase/field-overrides.ack` hash, both founder-gated (CODEOWNERS)**, in W7-3. No query filters or orders on an
exempted field. W7-5 confirms on the emulator that the thread, inbox, requests, badge and eraser queries need no
composite index; if one does, the work stops and returns to the architect.

**Rules.** `firestore.rules` stay deny-all to clients; every access is through the API.

### D2. Ids (rule 1 and rule 4 bend, Option C1)
- `convId` = first 32 hex of SHA-256(`"dm1|" + lowUid + "|" + highUid`). Deterministic, so "open a conversation with
  X" needs no lookup query, and no uid appears in URLs, push data or logs. The id is guessable from two uids, so
  **authorization never relies on its secrecy** (D11). A future group gets a random 32-hex id and `kind = GROUP`.
- `msgId` per Option C1. Same key with a different body (`requestHash` mismatch) → VALIDATION `idempotency_key`.
  `createdAt` is the handler's clock inside the transaction attempt (the ADR-0017 D3 convention); the `since` settle
  window (D7) covers clock skew between instances and commit lag; clients dedupe by id.

### D3. Text (A6)
`messaging` imports the leaf package `internal/posts/text` (`Normalize`) directly. Its no-`internal/`-imports guard
exists for this; promoting it to `pkg/platform/text` is a refactor nobody needs yet. The shared `testdata` fixtures
stay the single grammar (F8). Text is validated before any read; a rejection costs 0 reads. Mentions and hashtags in
messages are plain text: no notification, no tap-through. Links render with the existing safe-link rules.

### D4. Who can message whom (F2, F9) and the send algorithm
1. Validate key (≤ 64), target and text; the per-minute limit and `messages_daily` (D13). 0 reads on rejection.
2. Resolve the conversation: `recipient_user_id` (self → VALIDATION; compute `convId`) or `conversation_id` (32 hex;
   the participant check against the cached conversation doc).
3. Read the caller and recipient graph snapshots (60 s cache, A8 below). Either side blocks the other →
   `CANNOT_MESSAGE`. The recipient muted the caller → silent. Both follow each other → mutual.
4. The recipient must be ACTIVE and have `messaging` on (F6), or `CANNOT_MESSAGE`.
5. Transaction: read `conversations/{convId}`; `gone` → `CANNOT_MESSAGE`. Missing → a fresh recipient status read
   (D8) and `quotas.dmNew`, then create it (`ACCEPTED` if mutual, else `REQUEST`). `REQUEST` and the caller is
   `requestFrom` → `requestCount < MESSAGES_REQUEST_MAX_UNANSWERED` or `LIMIT_REACHED request_unanswered`, then +1.
   `REQUEST` and the caller is `requestTo` → the reply accepts it (as on X). `Create` the message; set the sender's
   `dmInbox` entry; set the recipient's `dmInbox` (accepted) or `dmRequests` (request) entry with `unreadCount`
   `Increment(1)` unless silent.
6. After the commit: `Emitter.Emit` a `message` event only when the recipient side is accepted and not silent (F7).
7. Evict both participants' badge cache on this instance.

Every refusal (blocked either way, recipient not ACTIVE, recipient flag off, `gone`) is **one error,
`ERROR_REASON_CANNOT_MESSAGE`, with identical bytes**, so it is no oracle beyond what GetProfile's NOT_FOUND already
reveals. A protected account (ADR-0025) can receive requests like any other account; protection is about posts and
lists, not messages.

**A8, block freshness on send: the cached snapshot (60 s).** A new Block applies at once on the instance that handled
it and within 60 s elsewhere, the same bound every other graph read in the product has. A fresh read would cost
+1 read per send (≈ +1.5 reads/DAU, ≈ INR 0.5 / 1.6 / 4.7). W7-22 (security review) may flip this; the switch is one
call inside `messaging` and needs no ADR change, only a note.

**On read** (F9): conversations with a blocked peer stay in the Inbox, read-only (`can_reply = false`) so the user
can still report them. Requests from blocked, blocking or muted accounts are hidden from the Requests list (short
pages allowed; `next_page_token` follows the query). Block from a thread reuses `GraphService.Block` and does not
delete the conversation.

### D5. API (contract in W7-2)
`dzeroth.messaging.v1.MessagingService`, with the RPCs of plan ticket W7-2:
`SendMessage`, `ListConversations` (folder INBOX / REQUESTS), `ListMessages`, `MarkConversationRead`,
`AcceptMessageRequest`, `DeleteConversation` (for me; also "delete request"). Every mutation takes an
`idempotency_key`; every list takes `page_size` (default 20, max 50), an opaque `page_token` and a `since_token`.
`Message` carries `from_self`, never a sender uid; the peer is on `Conversation.peer` (`common.AuthorSnapshot`).
A `since` response of ListMessages omits `conversation`, so a poll reads no peer profile or graph. A reserved field
number holds the slot for future media (F1). Additive elsewhere: `GetMeResponse.unread_conversation_count`,
`NOTIFICATION_TYPE_MESSAGE` (push data only, never listed), `REPORT_TARGET_TYPE_MESSAGE = 3`. Field numbers are taken
at the next free number when W7-2 opens.

Errors: VALIDATION `field=…`; `FEATURE_DISABLED feature=messaging`; NOT_FOUND (one message, byte-identical for an
unknown id, a non-participant and a malformed-but-shaped id); `ERROR_REASON_CANNOT_MESSAGE`; `ERROR_REASON_LIMIT_REACHED`
with `limit_name=request_unanswered|dm_new_daily`; RATE_LIMITED. A new `ErrorReason` value is additive in `common.proto`.

### D6. Flag semantics (F6)
`FEATURE_MESSAGING` (wire `messaging`), default `off`.
- **Per caller and per recipient:** SendMessage and AcceptMessageRequest.
- **Not globally off** (`Registry.GloballyOff`, the ADR-0023 / ADR-0021 precedent): ListConversations, ListMessages,
  MarkConversationRead, DeleteConversation and ReportContent for MESSAGE targets. A user dropped from an allowlist
  can still read, clean up and report.
- **Push:** the fan-out sends a `message` push only when `messaging` and `notifications` are both on for the recipient.
- **GetMe:** `unread_conversation_count` is computed only when `messaging` is on for the caller (0 reads otherwise).
- **`off` globally:** every RPC is FEATURE_DISABLED with 0 reads; the push hook drops `message` events; the client
  hides the destination, the routes and the profile button.
- **Ceiling:** `scripts/promotion/flag-ceiling.json` dev `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`
  (W7-4, founder-gated), no prod raise. Prod: the founder's MVP launch decision, not before W7-22 and W7-23 pass in
  dev. Because both people need the flag, a percent step means "works between enabled users only"; going from
  allowlist straight to `on` is the likely ramp.

### D7. Delivery (pull) and the `since` codec (A9)
- **Thread poll** on a **visible** thread: web 15 s while hot (activity in the last 2 min), Android 30 s while hot
  (push covers the gap), 45 s while quiet, **stopped** after 5 min without input or new messages and whenever the
  tab or app is hidden. A push for that conversation triggers an immediate pull. A RATE_LIMITED answer pauses polling
  through the shared `RateLimitHold`.
- **Inbox:** refreshed by `since` on open, on resume and after a push; no background polling.
- **Tokens:** the ADR-0017 notifications codec reused: sealed, bound to `(uid, conversation, kind)`, 30-day TTL, a
  5 s settle window (`createdAt > t − 5 s`, client dedupes by id). A foreign or tampered token is VALIDATION with
  0 reads. When a `since` gap exceeds one page, the response carries `gap_page_token` and the client pages it.
- **Bounds (Stage 0, not SLOs):** open hot thread ≤ 15 s + one request; open quiet thread ≤ 45 s; Android background:
  FCM normal priority, typically seconds (minutes under Doze); web with no open thread: the next inbox refresh or GetMe.
- **Per-uid read budget** (ADR-0010 D5, 2,000 reads/uid/day per instance): a web hot thread is about 288 reads an
  hour, so about 7 hot hours or 22 quiet hours a day; a forgotten open thread costs at most about 11 polls.

**Why no realtime at Stage 0 (Option B):** Cloud Run bills a held connection for its whole life and does not route
stickily, so WebSocket/SSE is an always-on instance plus a broker; client listeners need rules that move the
participant, block and mute checks out of Go. The trigger that moves this (D16) is measured.

### D8. Lifecycle (A7, F3, F5)
- **Eraser step `messaging`**, registered after `follow_requests` and before `identity` (the appended-step precedent of
  ADR-0023 / ADR-0025), so it runs after the `notifications` step (which has nothing of ours to erase: `message` events
  write no row). Resumable, pages ≤ 500, checkpoint (conversation cursor, phase). Never flag-gated.
  1. Page `conversations where participants array-contains uid`; set `gone += uid` on each (1 write). The send
     transaction reads that doc, so no send can rewrite the deleted user's entries afterwards.
  2. Tombstone the user's messages (`senderId == uid`): `text` cleared, `state = DELETED_ACCOUNT`.
  3. Rewrite the peer's entry: snapshot → "Deleted account", snippet → "Message deleted" when the last message was
     the user's. The conversation turns read-only for the peer.
  4. Delete the user's own `dmInbox` / `dmRequests` entries; delete the whole conversation tree when both are gone.
- **Purge race:** a new conversation re-reads the recipient's status fresh (`Directory.Forget` + read, +1 read, rare).
  The residual window (a conversation created between that read and the commit, before the eraser's first page) is the
  one ADR-0017's fan-out already accepts; the account-lifecycle backstop re-runs the step and catches it.
- **Export section `messages`** (F5), appended after `bookmarks`: per conversation the peer's handle at export time,
  the state and timestamps; the user's own messages in full; received ones as time + "received". No peer uid.
- **T11 guard rows** (`lifecycle_collections_guard_test.go`): `conversations`, `messages` (Sub), `dmInbox` (Sub),
  `dmRequests` (Sub), all `erasedByStep: messaging`, section `messages`, cite ADR-0027. `quotas.dmNew` is covered by
  the `quotas` row. They ship in the same PR as the first write path (W7-5 + W7-6).
- **Retention:** none in v1 (D16 has the trigger).

### D9. Push (A4, F7): a push-only `message` type in `notifications`
- `notifications.Event` gains `ConversationID` (additive; the wire event's `v` stays 1). An older revision drops an
  unknown type as invalid and acknowledges it, so a mixed rollout loses at most a push, never a message.
- `TypeMessage` is **push-only**: no row in `users/{uid}/notifications`, no badge move, no post id required by
  `validateEvent`, never returned by ListNotifications.
- **Own limiter bucket**, `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` (20), so a chatty thread cannot starve follow or
  reply pushes, and vice versa.
- Collapse key and Android tag `message` (type-level, as N-2). With generic text a per-conversation tag adds nothing.
- Payload (ADR-0017 D6): generic title and body ("New message" / "You have a new message"); `data` carries
  `type=message` and `conversationId` only. No sender, no text, no uid. D11 unchanged: no web push; iOS waits for the
  Apple launch.
- The fan-out keeps its fresh actor and recipient profile reads for this type, as the plan's cost model assumes
  (9 reads worst, 3.5 planning per message). Skipping them for push-only events would save about 2 reads per message
  (≈ 3 reads/DAU/day); that is left as a measured lever for W7-23, not taken here.
- The recipient's graph is still read for suppression (ADR-0017 D5), and `notifications` must be on for the recipient.

### D10. Badge (A5)
`GetMeResponse.unread_conversation_count` through a consumer-side `identity.MessageBadge` interface implemented by
`messaging` (the `BlockChecker` / `PinChecker` pattern), cached 30 s with the notifications count, evicted on this
instance by a send to or a mark-read by that user. It is a `count()` of `dmInbox` entries with `unreadCount > 0`,
Limit 100 (1 read per 1,000 matches, minimum 1). Requests do not count (as on X; the Requests row shows its own N).
A separate `GetMessagingState` RPC was rejected: +1 request per app start for one integer.

### D11. Authorization and privacy
- Every read and mutation checks that the caller is a participant against the conversation doc. A non-participant,
  an unknown id and a deleted conversation answer one byte-identical NOT_FOUND after ≤ 2 reads; a malformed id is
  VALIDATION with 0 reads.
- Only `messaging.Service` reads or writes the three collections. Moderation reaches a message only through
  `moderation.MessageLookup` (D12); identity only through `MessageBadge`; notifications only receives events.
- Message bodies are user content, not PII. Participant uids are personal data: never in URLs, push data or logs.
- **Logging:** never message text, snippets, peer uids or conversation ids in clear. Fields: `conversation_hash`,
  `kind` (send / list / poll / read / accept / delete), `state`, `results`, `refused_reason` (fixed enum),
  `fs_reads`, `fs_writes`, `poll`, `push_throttled`, `uid_hash`. Error Reporting on internal errors.
- An in-app line "Messages are not end-to-end encrypted" in the inbox empty state, and the Privacy Policy says the
  same (W7-22 checks both).
- `DEGRADED_MODE=readonly` refuses the four mutations through the existing interceptor; reads stay up.

### D12. Report a message (A10, F11)
`ReportContent` with `target_type = REPORT_TARGET_TYPE_MESSAGE` (3), `target_id = "<convId>:<msgId>"` (32 hex each).
Only a participant may report, and only the peer's message (own → VALIDATION). The evidence is that one message's
text, the sender's handle and its time; nothing else from the conversation. The existing 20/day report quota applies.
`opsctl` gains "take down a message" (tombstone, `state = REMOVED`) next to the existing suspend. Moderation calls a
consumer-side `moderation.MessageLookup` implemented by messaging. A dated note on ADR-0016 records that report
evidence may now hold private message text; it keeps the existing `expireAt` (resolved + 90 d) and `reporterId`
erasure.

### D13. Caps (rule 11; config, reviewed like logic)
| Config | Default | Effective at 3 instances | Store |
|---|---|---|---|
| `RATE_LIMIT_MESSAGES_SEND_PER_MIN` | 20 | 60/min | memory |
| `MESSAGES_SENDS_PER_DAY` (`ratelimit.DailyCap`, `limit_name` `messages_daily`) | 300 (50 in the new-account window) | ≤ 900/day | memory |
| `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY` / `QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY` | 20 / 5 | exact | `quotas/{uid}.dmNew` |
| `MESSAGES_REQUEST_MAX_UNANSWERED` | 3 | exact (in the send transaction) | `conversations.requestCount` |
| `RATE_LIMIT_MESSAGES_READ_PER_MIN` (lists and polls) | 30 | 90/min | memory |
| `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` | 20 | 60/h | memory |
| `CACHE_MESSAGING_CONVERSATION_ENTRIES` | 5,000 | per instance | memory |
| Read budget (ADR-0010 D5) | 2,000 reads/uid/day | binds first for readers | memory |

Worst case for one sender: about 900 messages a day, of which at most 20 new conversations × 3 request messages
reach strangers. A spam ring needs many verified accounts (residual R1, `cost-model.md` §4).

### D14. Staleness bounds
| Cached read | Bound |
|---|---|
| `conversations/{id}` per instance | membership is immutable in 1:1; state and `clearedAt` converge on other instances within 60 s. **Send never trusts the cache:** it re-reads the doc in its transaction |
| Caller and recipient graph snapshots | 60 s (D4, A8) |
| Peer snapshot on an inbox entry | refreshed on every message either way; the thread header uses `identity.Directory` (60 s) |
| `unread_conversation_count` | 30 s server cache, evicted on this instance by a send or mark-read; the client moves the badge locally on a foreground push and on open |
| Client | the inbox and the last 200 messages per conversation in drift per uid, wiped on sign-out (`SessionEpoch`) |

### D15. Seams
`messaging.Service` (Send, ListConversations, ListMessages, MarkRead, Accept, Delete), `messaging.Eraser`,
`messaging.Exporter`, `identity.MessageBadge`, `moderation.MessageLookup`, `notifications.Event.ConversationID`.
The inbox entries sit behind a repo interface, so a group fan-out or a listener-backed store changes no caller. The
client `ThreadPoller` sits behind one interface, so a listener or SSE transport replaces it without touching screens.

### D16. Stage ladder (the `stage-ladder` "Direct messages" rows, added in this PR)
See "Stage ladder" below.

## Cost impact
- **Fixed monthly cost added: INR 0.** No new GCP service, no Scheduler job, no Pub/Sub topic (the existing
  `notifications-fanout` carries the event), no composite index. Nothing depends on ADR-0022 credit items.
- **Vision units:** 0 (text only, F1). **FCM:** free. **Pub/Sub:** about 0.27 GB a month at 3,000 DAU of the free 10 GiB.

**Per RPC** (worst-case reads include the account-status interceptor; every call is charged to the per-uid read budget):
| RPC | Reads worst (cold) | Reads planning | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| SendMessage, accepted conversation | 5 (interceptor, caller graph, recipient graph, recipient `users` via Directory, conversation doc in the txn) | 2.5 | 3 (message, 2 entries) | 0 | +1 write while REQUEST (`requestCount`) |
| SendMessage, new conversation | 7 (+ fresh recipient status, `quotas`) | — | 5 (message, conversation, 2 entries, `quotas.dmNew`) | 0 | 0.05 of the 1.5 sends |
| SendMessage, replay | +1 (read the stored message) | — | 0 | 0 | different body → VALIDATION |
| SendMessage, refused | ≤ 5 | — | 0 | 0 | one error |
| Push delivery (`/internal`, push-only, no row) | 9 (actor and recipient `users` fresh 2, recipient graph 1, devices ≤ 5, +1 actor graph on overflow) | 3.5 | 0 | 0 | D9 |
| ListConversations, first page 20 (INBOX) | 23 (interceptor, query 20, caller graph, requests `count()`) | 9 | 0 | 0 | REQUESTS the same without the `count()` |
| ListConversations `since` | 3 | 2 | 0 | 0 | |
| ListMessages first page 20 / 50 | 24 / 54 (interceptor, conversation, query, peer `users`, caller graph for `can_reply`) | 15 | 0 | 0 | NOT_FOUND after ≤ 2 reads |
| ListMessages `since` poll | 3 (interceptor, conversation, query min 1) | 1.2 | 0 | 0 | +1 per new message returned |
| MarkConversationRead | 1 | 0.3 | 1 (`Exists` precondition) | 0 | client calls it only with unread > 0 |
| AcceptMessageRequest | 3 | 2.5 | 2 | 1 | |
| DeleteConversation | 3 | 2.5 | 1 (`clearedAt`) | 1 | |
| GetMe badge | +1 (`count()`) | +0.75 per GetMe | 0 | 0 | 0 reads with `messaging` off for the caller |
| ReportContent, MESSAGE | 6 | 3 | 2 (report, quotas) | 0 | existing quota |
| Eraser step (20 conversations, 300 own messages) | ≈ 340 | — | ≈ 340 | ≈ 20 | resumable |
| Export section (same account) | ≈ 620 | — | 0 | 0 | |

**Per DAU per day** (assumptions; W7-23 replaces them with measurements): 1.5 messages sent, 1.5 pushes, 2.0 inbox
calls, 1.5 thread opens, **5 polls**, 1.0 mark-read, 4 GetMe → **≈ 12.6 requests, ≈ 37.0 reads, ≈ 5.8 writes,
≈ 0.05 deletes**.

| INR per month (W7 increment) | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (37.0 × 30.42 = 1,126 per DAU-month, all billed) | 11.2 | 37.4 | 112.3 |
| Firestore writes (5.8/DAU/day; billed once the product passes 20k/day) | 0 (11.8k/day with W7) | 17.4 | 52.3 |
| Firestore deletes | 0 | 0 | ≈ 0.1 |
| Cloud Run requests (+383 per DAU-month) | 0 | 0 (1.51M of 2M) | 43.7 |
| Cloud Run vCPU-s (12.6 × 0.1 s = 38.3 per DAU-month) | 0 | 0 (153k of 180k) | **262.0** (≈ 179 if a poll bills 20 ms) |
| Egress to India (≈ 10 KB/DAU/day) | 1.0 | 3.3 | 10.0 |
| **W7 total** | **≈ 12** | **≈ 58** | **≈ 480** (upper bound; ≈ 400 with 20 ms polls) |
| Stage 0 bill with W2 + W7 (INR) | 441 → **≈ 453** | 1,653 → **≈ 1,711** | 3,498 → **≈ 3,978** |

- **Quota crossovers that move:** Firestore writes reach the free 20k/day at about **509 DAU** (was 597; 456 at
  3 messages/DAU/day, 399 at 5). Cloud Run requests reach 2M/month at about **1,322 DAU** (was 1,743). vCPU-s reach
  180k/month at about **1,174 DAU** (was 1,566). Reads are already billed.
- **Sensitivity:** each poll per DAU per day ≈ INR 28/month at 3,000 DAU (21 CPU, 3.5 requests, 3.6 reads), ≈ 0.4 at
  300. Each extra message per DAU per day ≈ INR 16/month at 1,000 DAU (7 reads, 3.1 writes, 2 requests). At 3,000 DAU
  polling is the largest line, which is why the realtime trigger watches it.
- **Storage:** about 1 KB per message with index entries (text exempt) plus 2 entry updates: about 0.16 GiB a year at
  300 DAU, 1.6 GiB a year at 3,000 DAU (past the shared free 1 GiB within the year, then INR 10–20/month): the
  retention trigger.
- **Trigger that justifies it:** none needed (no fixed cost). The scale-up triggers are in the stage ladder.

## Stage ladder
| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger (measured, sustained 7 days) |
|---|---|---|---|---|
| Delivery to an open thread | client `since` poll (15 s web / 30 s Android hot, 45 s quiet, stop after 5 min idle or hidden); a push triggers a pull | `ListMessages(since_token)` with an opaque, settle-windowed token; the client `ThreadPoller` behind one interface; every message event through `notifications.Emitter` | owner-only Firestore listeners on `users/{uid}/dmInbox` and the user's conversations' messages (a rules ADR), then SSE on an instance-billed service | message polls > 25 % of all Cloud Run requests, **or** poll vCPU-s > INR 300/month, **or** p95 send-to-render on an open web thread > 20 s with user complaints |
| Group conversations | none (1:1) | `participants[]` is an array; entries are per user; `ConversationKind` enum | groups up to 50: one entry per member per message, a bounded write fan-out (rule 2 needs an ADR) | founder demand **and** messaging DAU > 30 % of DAU **and** the write model fits |
| Images in messages | none (F1) | reserved `media` field number on `Message` | private-read objects (signed GET per view) + SafeSearch | founder request plus ≥ 1 % of message reports citing missing images; its own ADR with Vision and egress lines |
| End-to-end encryption | none | message text only through `messaging.Service` | per-device keys, a key directory, passcode-protected backup, message franking for reports | founder decision; its own ADR (Option D2's four reasons) |
| Retention | none (until deleted) | `createdAt` on every message; the eraser already pages a conversation | TTL policy or an "older than N months" sweep (TTL deletes billed) | messaging storage > 0.5 GiB, or a founder retention policy |

## Consequences
**Positive.** Private 1:1 messaging with no fixed cost, no new service and no composite index; abuse bounded by
requests, caps, block, mute, report and takedown; right-to-delete and export from day one; every Stage 2 move is a swap
behind a named seam with a measured trigger.

**Negative.** Delivery on web is bounded by the poll interval, not instant. Polling is the largest cost line at
3,000 DAU. Writes become the binding free quota earlier (509 DAU instead of 597). Private text reaches an operator when
a message is reported. A block can lag up to 60 s on another instance. No read receipts, typing, images or groups.
Rules 1 and 4 are bent for message ids (as ADR-0021 did).

**Follow-up work.** W7-2 (proto), W7-3 (index exemptions, founder-gated), W7-4 to W7-24 per the plan. W7-23 measures
the real poll time and send-to-render latency. W7-22 may flip A8 to a fresh block read.

**Revisit when** any stage-ladder trigger fires; when W7-23 measures polls above twice the modelled share; when a
spam or harassment wave shows in reports; or when the founder asks for images, groups or E2E.

## Handoff
- **architect:** W7-2 proto per D5 with per-RPC cost comments from the table above; W7-3 fieldOverrides per D1.
- **backend-developer:** W7-4 flag, config (D13), `quota.Record.DMNew`, module skeleton; W7-5 + W7-6 in one PR (D4,
  D8, T11 rows); W7-7 to W7-9 lists and actions; W7-10 push-only type (D9); W7-11 badge (D10); W7-12 report (D12).
  Log fields per D11. Emulator-check the six queries before any other work in W7-5.
- **frontend-developer:** W7-13 `ThreadPoller` per D7 (pure, fake clock), drift cache per D14; W7-14 to W7-19 screens;
  F10 navigation; the "not end-to-end encrypted" line.
- **tester:** W7-20 flag matrix (D6), byte-identical refusals and NOT_FOUND (D4, D11), caps (D13), budgets (table
  above), eraser crash harness and export golden (D8), push hook (D9); W7-21 polling with a fake clock.
- **security-auditor:** W7-22: authz, the block oracle, A8, report evidence, logs, push payload, the E2E disclosure.
- **sre-performance:** W7-23: `cost-model.md` rows, the poll share and poll CPU, send-to-render p95, the triggers.
- **production-deployer:** W7-24: Terraform vars (default `off`), the fieldOverrides deploy, dev allowlist (3 uids
  with `notifications` on), two-account smoke incl. Android push. Nothing in prod without the founder (ADR-0019).

## Note: Idempotency for Accept, MarkConversationRead and DeleteConversation (founder decision 2026-10-29)
The decision text above is unchanged. Option C1 (D2) stores the idempotency key of SendMessage as the message id. The other
three mutations take an `idempotency_key` too (proto, W7-2); this note records what the server does with it, decided by the
founder on 2026-10-29 while W7-9 (#443) was in review. All three **validate the key's format** (`idempotency.KeyFormatValid`:
16-64 characters of `[A-Za-z0-9_-]`; VALIDATION `idempotency_key` with 0 reads past the account-status interceptor's,
before the conversation id is looked at) as ADR-0021 does for a key the RPC does not use ("unused but still
format-validated").

- **AcceptMessageRequest and MarkConversationRead: option (a), the key is not stored; both are idempotent by state.** This
  bends rule 4 (a TTL'd idempotency document) the way ADR-0018 and ADR-0021 did, and for the same reason: the budget
  (Accept 2 writes and 1 delete, mark-read 1 write) leaves no room for a document and its TTL delete.
  - Accept: `ACCEPTED` never returns to `REQUEST`, so a late retry finds the conversation accepted and writes nothing.
  - MarkConversationRead: the accepted risk is that a late retry can set `unreadCount` to 0 over a newer message. The badge
    and the Inbox then miss that one message until the next message or until the conversation is opened. The message itself
    is never lost.
- **DeleteConversation: option (c), the key's digest is stored on the conversation at no extra cost.** `clearedKey.{uid}` =
  the first 32 hex characters of SHA-256(`uid | "DeleteConversation" | idempotency_key`), the C1 construction (one
  `keyDigest` helper behind the message id as well), written in the **same field-level update** as `clearedAt.{uid}` and
  `updatedAt`: **+0 reads, +0 writes** (the conversation is already read in the transaction). `conversations/{convId}` gains
  the map `clearedKey` (see the data-model row in D1).
  - A retry whose digest equals the stored one is a **replay**: nothing is written and the call succeeds, **whatever
    happened since**. A newer message of the peer stays visible and the entry it recreated stays; the retry cannot hide that
    message, which a state-only rule could (the entry exists again, so a retry would look like a new delete). It is checked
    before the state rule (no entry and `clearedAt` set: also a replay, under any key). A delete under a new key that finds
    an entry is a real delete. The conversation id is part of the document path, so the digest needs nothing more.
  - A replay by key reads the conversation only (the entry is not read): 1 read in the transaction, 2 with the interceptor.
    A first delete stays 3 reads, 1 write, 1 delete.
  - Erasure (rule 10, D8): the `messaging` eraser's `RewriteConversation` deletes `clearedKey.{uid}` together with
    `clearedAt.{uid}` (the map key is the uid, so the placeholder rule is to drop it, not to rename it to `deleted`). The
    peer's own entries stay. The export does not list it: it is a one-way digest of a client-generated key, not user content
    (`clearedAt`, which the export does list, is the time the user cleared the conversation).
  - Indexing: like `clearedAt`, `clearedKey` has no fieldOverride; the map keys get the automatic single-field entries.
    An exemption for both is a founder-gated change to `firebase/firestore.indexes.json` and is not part of this note.

  Additions from the #443 re-review (2026-10-29; the decision text above is still unchanged):
  - **`createdAt` is stamped differently from D2's wording.** D2 says the time is taken "inside the transaction attempt".
    Now it is the handler's clock read before the transaction, raised past both participants' `clearedAt` as the
    transaction read it (`stampAfterClear`: `max(now, clearedAt + 1 µs)`, 0 extra reads). The difference is deliberate: a
    `DeleteConversation` that commits between the clock read and the transaction would otherwise leave a recreated entry
    with a preview and an unread count but an empty thread.
  - **Ties while clocks are skewed.** While two instances' clocks disagree by more than the gap between messages, several
    messages can share the stamp `clearedAt + 1 µs`. They then sort by `__name__` (the message id, a digest), so they appear
    in effectively random order among themselves for the length of the skew. No message is lost or hidden. This is within
    D14 (instances converge within the 60 s cache bound).
  - **Only the last Delete key per user is remembered.** `clearedKey.{uid}` holds one digest. A late retry of an older key
    that arrives after a newer delete is not recognised as a replay and counts as a new delete.

## Note (2026-10-29): Takedown reaches cached devices (founder decision 2026-10-29)

**Problem.** A takedown (D12, W7-12) rewrote the message and the inbox previews but moved neither the message's
`createdAt` nor the entry's `lastMessageAt`. A device that cached the thread or the inbox refreshes with `since`
(`createdAt > t`, `lastMessageAt > t`), and an active user's since token never expires (each refresh issues a new one),
so the tombstone never reached it. That broke W7-12's "both participants see 'This message was removed'". The founder
decided to fix it, at about +1 write per takedown and 0 reads on any hot path.

**Decision.**
1. **Thread: a revision on the conversation, sealed in the since token.** `conversations/{convId}.rev` (int, absent =
   0) is incremented by the takedown transaction, which already reads the conversation. ListMessages since tokens
   carry the rev the issuer saw (`cursor.EncodeRevAt` / `DecodeRevAtTTL`, their own AEAD domain; a token from before
   this note decodes as rev 0). The token is still decoded before any read (a foreign or tampered token is VALIDATION
   with 0 reads, D7 unchanged). After the participant check, a since token whose rev is lower than the conversation's
   is VALIDATION `since_token` (≤ 2 reads: interceptor, conversation; no query), with the same bytes as an expired
   token, and the client makes one cold open, as the token contract already says. A new since token carries
   max(token rev, conversation rev), so an instance whose 60 s copy (D14) is stale never moves a token backwards; it
   drops that copy instead. The rev is not in the binding: that would read the conversation before decoding and make
   instances with different copies reject each other's tokens. The eraser's `RewriteConversation` increments `rev` in
   the same write, so the surviving peer's cached thread picks up the DELETED_ACCOUNT tombstones the same way. The
   per-instance cache never replaces a copy with an older `updatedAt`, and with an equal `updatedAt` keeps the higher
   `rev`.
2. **Inbox: a change stamp on the entry drives `since`.** `dmInbox` / `dmRequests` entries gain `changedAt`. Every
   send writes it equal to `lastMessageAt` (same stamp, in the writes it already makes); the takedown sets it (server
   time) on each entry whose preview it rewrites. The ListConversations since query becomes `changedAt > t ORDER BY
   changedAt DESC, __name__ DESC`, on the automatic single-field index (no composite index, no exemption). First and
   older pages, `Conversation.updated_at` and the preview time stay on `lastMessageAt`, so the inbox order does not
   change. A since token trails the newest changed entry by the 5 s settle window; a first page issues "now − 5 s".
   The since binding's kind changed, so a since token from before this note is VALIDATION (0 reads) and each device
   cold-opens each folder once; this shipped while messaging was off in prod. A later change of the since field
   needs dual-write first. The eraser's peer-entry rewrite and Accept's moved entry set `changedAt`.
3. **Takedown writes.** The message `Update` also sets `removedAt` (server time), the durable record of a takedown made
   without `--report`. The conversation gets `rev` +1 and `updatedAt` moved strictly forward (so the per-instance cache,
   which never replaces a copy with an older `updatedAt`, cannot restore a pre-takedown copy). Entry `lastMessageAt` is
   never moved.
4. **Contract.** The `messaging.proto` header comment says that a ListMessages since token retired by a change in the
   thread is INVALID_ARGUMENT + VALIDATION `since_token` after at most 2 reads (interceptor, conversation). Comment
   only: no field, no wire change, `buf breaking` clean; the client's handling (drop the token, one call with no
   token) is unchanged.

**Known, deferred.** (c) A mark-read on one device does not reach the user's other devices' cached unread count until
the next message or a cold open (setting `changedAt` on mark-read would cost about +1 read per mark-read per device).
(d) A delete-for-me does not reach the caller's other devices' cached thread or inbox (a conversation-wide `rev` bump
would also make the peer's devices reload; deletes never surface in `since`). Both wait for a measured complaint or the
Stage 1 listener (D16).

**Rejected.** A per-user inbox revision folded into the since binding: ListConversations reads no per-user document on
a since refresh, so it would add 1 read to every inbox refresh (≈ +2 reads/DAU/day) and force a full first-page reload
on every device of both participants. Moving `lastMessageAt`: it reorders the inbox. A `changedAt`-driven thread since
query: its gap tokens and the `clearedAt` filter live in `createdAt` space.

**Data model (D1 additions).**
| Doc | Field | Written by | Indexing / lifecycle |
|---|---|---|---|
| `conversations/{convId}` | `rev` (int, absent = 0) | takedown and the eraser's `RewriteConversation` (`Increment(1)`); never by send, accept, delete or mark-read | automatic; not exported; deleted with the tree |
| `conversations/{convId}/messages/{msgId}` | `removedAt` (timestamp) | takedown, with `state = REMOVED` | automatic; not exported; erased with the message |
| `users/{uid}/dmInbox/{convId}`, `users/{uid}/dmRequests/{convId}` | `changedAt` (timestamp) | every send (= `lastMessageAt`); takedown on rewritten previews; the eraser's peer-entry rewrite; Accept's moved entry | automatic single-field, must stay indexed (the since query); not exported; deleted with the entry |

**D14 addition.** A moderation change or an account erasure reaches a cached thread on the first since request
answered with a conversation copy read after it (≤ 60 s + the next pull) and a cached inbox on its next since refresh
(no server cache).

**Cost impact.** Fixed cost INR 0. Takedown: reads 4 (unchanged), writes ≤ 4 (+1, the conversation). Eraser and
Accept: +0 reads, +0 writes. One-off per affected device: thread ≤ 2 reads (the refused poll) + a cold open (24 cold /
15 planning at page 20); inbox ≤ 2 reads. Hot paths +0 reads and +0 writes: SendMessage writes `changedAt` inside its
existing entry writes; the ListMessages poll reads the rev from the conversation it already reads; the
ListConversations since query costs what it did.

**Stage ladder.** `changedAt` is the per-user change feed an owner-only listener on `dmInbox` (D16, Stage 1+) would
order by; `rev` is the per-thread invalidation a listener or SSE transport would push. No caller changes.
