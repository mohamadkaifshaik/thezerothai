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

**D14 cache note (2026-10-29, W7-28, security review W7-22 H-1).** The `conversations/{id}` instance cache answers and learns from participants only: a cached copy is used only when the caller is in its `participants`, any other caller (a non-participant against a warm copy, or a miss) does one fresh read, and a document is put in the cache only by a request whose caller is a participant. A non-participant probe therefore costs exactly 1 read (2 with the interceptor) whether the conversation exists, is cached or is missing, so the shared cache is no existence oracle; participants' paths and the 60 s bound are unchanged.

## Note (2026-10-29): the first `ListMessages` page carries the caller's own entry (W7-27, with the header part of W7-30)

**Problem.** `ListMessages` returned the conversation header (identity, peer, state, folder, `can_reply`) but nothing from the caller's own entry, so a thread opened cold (a push tap, a deep link, nothing cached) could not tell that the conversation was unread and could not take it out of the Messages badge (found in the W7-19 review, F-5). The security review W7-22 (M-2) found a second gap in the same header: a blocked user saw the blocker's current profile, because the header's peer comes from the live directory.

**Decision (additive; D4/D5 wording unchanged).**
1. `Conversation.unread_count` and `Conversation.silent` are filled on the **first page** of `ListMessages` only (no token), from the caller's own entry: `users/{uid}/dmInbox/{convId}`, or `dmRequests/{convId}` for the recipient of an unaccepted request (the folder comes from the conversation document the call already read, the same rule as the header's `folder`). A missing entry (delete for me, or never created) is 0 / false. A `since` refresh and an older page leave both unset. No new field, no renumbering (rule 9): the proto change is comment-only and `buf breaking` is clean.
2. The entry is read **after** the participant check, so the byte-identical NOT_FOUND of D11 is unchanged (at most 2 reads, no entry read).
3. **Budget: +1 read on a first page** (worst case 24 → 25 at page 20, 54 → 55 at page 50, planning 15 → 16); older pages (24 / 54) and polls (3) are unchanged. A first page is one read per thread open, about +0.5 reads per DAU per day at the modelled usage. The Cost impact row "ListMessages first page 20 / 50 | 24 / 54" is superseded by 25 / 55; the planning column of the cost table keeps its 15 and adds this +0.5 line.
4. **Blocked peer (W7-30, header part).** When the caller's graph says the peer blocked them (`BlockedBy[peer]`), or `BlockedByOverflow` is set (the list cannot say, so fail closed), the header's `peer` is the snapshot **frozen on the caller's own entry** (what they already saw at the last message), never the live directory profile. The first page reuses the entry read above (+0 reads). The rule, in this order: (a) `peer == DeletedUID` is the "Deleted account" placeholder; (b) else, if blocked, the frozen snapshot only when the entry exists and its `peerId` names this peer, otherwise the placeholder (so an eraser's `MarkGone`, which rewrites the entry's `peerId` to `DeletedUID` before the participants, falls to the placeholder), **regardless of what the directory says about the peer**, so a blocked caller cannot tell an ACTIVE blocker from a suspended or deleting one (`GetProfile` hides it too); (c) else a peer the directory does not list as ACTIVE is the placeholder; (d) else the live profile. An older page reads no entry, so for a blocked caller it is the placeholder. The directory lookup is kept and runs in parallel with the graph read, for two reasons: no serial wait on the graph read (latency), and it supplies liveness for the unblocked case (c). Read-count equality with an unblocked caller is a consequence, not the reason: `can_reply = false` already reveals the block. `canReply` now also returns false for a `BlockedByOverflow` caller (fail closed, in ListConversations too), so an overflow caller gets a frozen header with `can_reply = false` on the first page, and "Deleted account" with `can_reply = false` on older pages or when the entry is gone; the send path stays authoritative and the client uses only the cold-open (first page) header. Treating `BlockedByOverflow` as blocked costs 0 reads and was accepted by the security audit. **The header guarantee is complete only with W7-33:** a harasser's send within 60 s of being blocked can still refresh the frozen snapshot on the harasser's own entry with the victim's current (for example renamed) handle, because Send's block check uses the 60 s-cached recipient graph; and that send's response carries the live profile. W7-33 (fresh recipient graph in the send transaction) closes it. The export half of M-2 (skip the directory lookup for blocked peers, +1 graph read once per export) stays Open with W7-30: W7-30 is "In review: header part; export part Open".

**D14 addition.** `unread_count` is as fresh as the entry (read per first page, no cache); the folder is resolved from the 60 s conversation copy, so an accept on another instance is seen within 60 s and a stale answer is a missing entry, which reads 0.

**Client.** `mergeThreadHeader` must take the first-page header count as authoritative, including 0 (a read on another device), instead of keeping the larger cached count. **One exception, up to 60 s:** after a request is accepted on another server instance, that instance's cached copy of the conversation can still point at `dmRequests`, so the entry read misses and answers 0 for a conversation that still has unread messages in `dmInbox`. A first-page 0 is therefore authoritative except within 60 s of an accept on another instance (an accept is by the recipient, who has just read the thread, so the window is rare and self-correcting at the next Inbox load). The client change is a separate frontend PR.

**Cost impact.** Fixed cost INR 0. +1 read per thread open; writes 0.

## Implementation note (W7-37), 2026-10-30: `request_count` on every INBOX refresh (founder decision 2026-10-30)

**Problem (found in the W7-24 dev smoke, leg 2, 2026-10-30 07:28 UTC).** C (not mutual with A) sent A three messages. The server was right (`state=new`, then `request` twice, the fourth refused `request_unanswered`), but A never saw "Message requests (N)". `ListConversations` filled `request_count` (the `dmRequests` `count()`) only on a first INBOX page (no token). The client cold-opens a folder only when it holds no since token, its token is rejected, or a since answer is a full page. Since tokens live 30 days and every refresh issues a new one, so the count stored on the device stayed at what the first open saw (0 for A, before C's request). Requests never push (F7), so nothing else could surface them. The Messages badge (D10, `unread_conversation_count`) is not involved.

**Decision (founder, 2026-10-30; additive, D4/D5/D7 wording unchanged).**
1. The server sets `request_count` on **every INBOX first page and every INBOX since refresh**, an empty since refresh included. It sets it on no older page (`page_token`) and never on REQUESTS (both stay 0). The `count()` runs in parallel with the folder query. A failed `count()` fails the call and never answers 0 in its place.
2. The client applies it from every INBOX since refresh as well, stored with the since token and emitted to the list. Accept and Delete keep their local −1 until the next refresh.
3. Contract: `request_count = 4` keeps its number and type. Only its two comments (the RPC comment and the field comment) change. `buf breaking` is clean (rule 9).

**Compatibility (architect).** proto3 `int64` cannot tell 0 from unset, so the client treats the INBOX value as authoritative, including 0. **No new field.**
- Rejected: `optional` on field 4. It changes the generated code and the field's presence, which the founder decision keeps unchanged.
- Rejected: a marker field (`bool request_count_set = 5`). It is additive and costs 0 reads, but it only guards a new client talking to a messaging-on server without W7-37a. Two rules remove that case:
  - (a) W7-37b (client) merges only after W7-37a serves dev. Merging deploys the dev web client.
  - (b) The first prod release that turns `messaging` on contains W7-37a, so a prod rollback below it lands on a revision with `messaging` off. `messaging` has never been on in prod.
- Residual risk in dev: a rollback to the pre-W7-37a revision that has `messaging` on (`api-00375-dx9`; the runbook fallback `api-00767-viv` has it off) hides the row until the first refresh after the re-deploy. No data is lost. Accepted for 3 testers.
- An installed app without W7-37b keeps the old behaviour, which is no regression. The app build that `messaging` is turned on for in prod carries W7-37b.

**Rejected alternatives to the decision.**
- A cold open of the Inbox on every open: 9 planning reads (23 worst) instead of +1.
- A denormalised request counter on a per-user doc maintained by send, accept, delete and the eraser: writes on every request path, plus a second source of truth.
- The count in `GetMe`: called about 4 times per DAU against 1.5 Inbox refreshes, and it would couple identity to request semantics.

**Known, made more visible by this note.** `count()` includes `dmRequests` entries that REQUESTS hides at read time (a peer the caller blocks or mutes, or who blocks the caller). Block and Mute delete no entry. The row can therefore promise a request the folder does not show, and after this note it can do so after any refresh, not only after a cold open. A fix (a graph-filtered count, or removing the entry on Block) is a follow-up for the planner and architect before prod.

**D14 addition.** "Message requests (N)" is as fresh as the last INBOX refresh. The `count()` is a strongly consistent aggregation with no server cache, capped at 1,000. On the device it is that value plus local Accept/Delete adjustments until the next refresh.

**Cost impact.** Fixed cost INR 0.
- `ListConversations` since refresh with one entry returned goes from 3 to **4** reads (5 when another conversation moved), and from 2 to 3 with no entry. Planning goes from 2 to **3**. Writes 0, requests +0.
- The client refreshes the Inbox only on open, pull to refresh, resume and a foreground push (resume and push throttled to once per 60 s). It has no timer. The W7-23 mix has 1.5 since refreshes per DAU per day across both folders, so the change is **at most +1.5 reads per DAU per day**: about INR 0.45 / 1.5 / 4.6 a month at 300 / 1,000 / 3,000 DAU.
- W7 with W7-27, W7-33 and W7-37 comes to about 41.55 reads per DAU (rollback line about 83.1). The free reads run out at about 154.1 DAU instead of 154.8. Writes, the binding free quota at about 506 DAU, are unchanged.
- The Cost impact table row "ListConversations `since` | 3 | 2" above is superseded by 4 / 3. The budget holds at 300, 1,000 and 3,000 DAU.

**Stage ladder.** The count stays a field of the list response behind `messaging.Service.ListConversations` and `MessagingRepository.refreshConversations`. A Stage 1 owner-only listener (D16) can later feed the same client value without changing a screen. Plan ticket W7-37 (W7-37a backend, W7-37b client) blocks prod messaging.

## Implementation note (W7-25), 2026-10-30: the requester's Inbox row carries REQUEST

**Problem (from the PR #442 review).** `ListConversations` maps every `dmInbox` entry to ACCEPTED. `conversationOf` takes the state from the folder because the entry has no state, and reading the conversation for every row would break the budget. A sender's pending request lives in the sender's own `dmInbox`, so their Inbox row reads ACCEPTED. Only the `ListMessages` header (first or older page) says REQUEST. The W7-18 waiting note ("Waiting for them to accept…") therefore disappears when the sender reopens the thread from the cache, and stays after the peer accepts, because a `since` poll carries no header.

**Options.**
- **(a) Chosen (default; founder may override): a `requestPending` flag on the requester's own `dmInbox` entry.** Send carries it in the entry writes it already makes, and Accept clears it. Cost: +1 read and +1 write per Accept. Accept is about 0.05 calls per DAU per day or fewer.
- (b) Read `conversations/{id}` for every INBOX row in `ListConversations`. That is up to +20 reads on a first page and +1 per row on a refresh, about +4 reads per DAU per day (≈ INR 12 a month at 3,000 DAU), for one bit. Rejected.
- (c) Keep the header as the only source and have the client remember the state. The client cannot see an Accept made on the peer's side without a header. Rejected.
- (d) A `state` field on every entry, both sides. It means nothing on the recipient's side, where the folder already says REQUEST, and it adds a field every writer must keep right. Rejected for (a)'s single-purpose flag.

**Decision (additive; D1, D4 and D5 wording unchanged).**
1. **Field.** `users/{uid}/dmInbox/{convId}.requestPending` (bool). It is true only on the requester's own entry while the conversation is `REQUEST`, and absent otherwise (absent = false). It is never set on `dmRequests`. It stays on the automatic single-field index: no query uses it, so no exemption and no gate-file change. It is not exported (the export already carries the conversation state).
2. **Writers.**
   - **SendMessage, +0 reads, +0 writes.** The sender's entry write sets `requestPending: true` when the conversation is `REQUEST` after this send (the requester's first to third message). Otherwise it sets `firestore.Delete` in the same `MergeAll` map. The recipient's entry write always sets `firestore.Delete`. So the reply that accepts a request clears the requester's flag in the write it already makes.
   - **AcceptMessageRequest, +1 read and +1 write.** Inside its transaction, after the request entry read and before any write, it reads the requester's `dmInbox/{convId}`. If the entry exists, one field-level `Update` deletes `requestPending` and sets `changedAt` to the accept stamp, so the requester's next INBOX `since` refresh returns the row. If the entry is missing (the requester deleted it for themselves), Accept writes nothing for it and never creates it. A blind `Update` would fail the whole transaction, and a `Set(MergeAll)` would create a ghost entry the `changedAt` query returns.
   - **The eraser's `MarkGone` peer-entry rewrite** deletes `requestPending` in the write it already makes (+0). A request whose recipient erased their account is read-only, never "waiting".
   - **DeleteConversation** is unchanged. A recipient's delete keeps the conversation `REQUEST`, so the requester's row keeps REQUEST and the requester's cap. A requester's delete removes their entry; their next request message recreates it with the flag. Takedown and MarkRead do not touch the flag.
3. **Read.** `conversationOf` maps an INBOX row with `requestPending` to state `REQUEST`, folder `INBOX`. That is the same pair the `ListMessages` header already returns for the requester. +0 reads. `ListMessages` and `SendMessage` keep the conversation document as their source.
4. **Contract.** Comments only, in `messaging.proto`: on `Conversation.state` (its source per RPC) and on `AcceptMessageRequest` (the cost line). The exact text is in plan ticket W7-25a. There is no new field and no renumbering (rule 9), and `buf breaking` stays clean. The implementer regenerates.
5. **Legacy entries.** Entries written before W7-25a have no flag and read ACCEPTED until the requester's next send or the Accept. Only dev holds them (messaging was never on in prod). No backfill.

**Client (W7-25b).**
- The waiting note follows the row. The thread takes `state` and `folder` from the cached row whenever the repository reports that the conversations changed.
- A `since` page that brings a peer message in a sent request means the peer replied. Only the recipient's reply can add a peer message, and that reply accepts the request (D4 step 5). So the thread marks the conversation ACCEPTED locally. This follows from a server invariant; it is not a guess.
- The note also requires `can_reply`.

**D14 addition.** The requester's Inbox row is as fresh as the requester's last INBOX refresh: an Accept and the accepting reply both move `changedAt`. After an accept made on another instance, the `ListMessages` header can read REQUEST for up to 60 s, because it comes from the cached conversation copy. The client converges at the next list refresh or poll.

**Contention.** Accept now also reads the requester's entry, which the requester's own send writes. A concurrent request message and Accept make one transaction retry (`messaging_txn_contention`). The requester is capped at 3 messages, so this is rare.

**Cost impact.** Fixed cost INR 0.
- AcceptMessageRequest: reads 3 → **4** worst (planning 2.5 → 3.5). Writes 2 → **3**, or 2 when the requester's entry is gone. Deletes stay at 1. A replay and NOT_FOUND are unchanged.
- SendMessage, ListConversations, ListMessages, the eraser and the export: +0.
- Per DAU: at most +0.05 reads and +0.05 writes a day. That is under INR 0.1 / 0.3 / 0.6 a month at 300 / 1,000 / 3,000 DAU.
- The free-writes crossover (about 506 DAU) moves by less than 1 DAU. Storage: one bool on pending senders' entries.
- The Cost impact row "AcceptMessageRequest | 3 | 2.5 | 2 | 1" is superseded by 4 / 3.5 / 3 / 1.

**Stage ladder.** The flag is a per-user entry field, like `unreadCount`. A group fan-out or an owner-only `dmInbox` listener (D16) carries it unchanged, and no caller changes. Plan ticket W7-25 (W7-25a backend, W7-25b client) blocks prod messaging.

## Implementation note (W7-26), 2026-10-30: the client honours F6(a) (read-only Messages for a caller outside the rollout)

**Problem (from the PR #442 review).** F6(a) and D6 say that list, read, mark-read, delete and report need messaging to be only "not globally off", so a user dropped from an allowlist can still clean up and report. The app instead hides all of Messages when `messaging` is missing from `GetMe.enabled_features`: the `/messages` routes redirect Home, and the thread says "Messages aren't available yet". `enabled_features` is per caller, so the client cannot tell "off for me" from "off for everyone".

**Options.**
- **(a) Chosen (default; founder may override): client-only.** The existing `MessagingFeatureGate.runRead`, an entry point scoped to the device cache, and one probe at session start. 0 server change.
- (b) An additive `GetMeResponse` field listing flags that are "not globally off" for the caller (`readable_features`). It costs 0 reads but cannot decide alone. During an allowlist or percent rollout it is true for every user outside the rollout. Showing an entry to all of them would put an empty Messages, with no way to send, in front of 95 % of users at percent 5, and every tap would cost a ListConversations. Deciding "this user has conversations" on the server needs a `count()` per GetMe for the whole user base: about 3 reads per non-enabled DAU, ≈ INR 9 a month at 3,000 DAU at percent 5. Rejected for now; it is the upgrade path if the population grows.
- (c) A ListConversations probe by every non-enabled user at every session start: +1 request and 2 to 4 reads per session across the whole user base. Rejected.

**Decision (client only; no proto change, no server change).**
1. **Three modes, decided by the client.**
   - `full`: `messaging` is in `enabled_features`, as today.
   - `readOnly`: messaging is not enabled for the caller, the local cache holds at least one conversation **for this owner** (the owner check is W7-35's L-4 stamp), **and a probe succeeded in this session**. Until the probe answers, the mode is `hidden`, so nothing flashes when the kill switch is thrown.
   - `hidden`: everything else, including after any FEATURE_DISABLED on a read, which means globally off.
2. **The probe.** At session start, after GetMe, and again when `enabled_features` changes, the client makes one INBOX `ListConversations` refresh through `runRead`. It does this only when messaging is not enabled and the owner's cache holds a conversation. Success means `readOnly`, and the cache is refreshed too. FEATURE_DISABLED means `hidden`.
3. **The read-only UI.**
   - Routes: `/messages`, `/messages/requests` and `/messages/<id>` open. `/messages/new` and `/messages/new/draft` redirect to `/messages`.
   - Entry point: a Settings row "Messages", in both chromes. The bar and rail destination stays `full` only, because F10's 5th slot is for people who can send.
   - The Inbox has no New message action.
   - The thread has no composer. It shows one line instead ("You can't send messages right now.", our copy).
   - The request banner shows Delete, Block and Report, without Accept.
   - Report a message, Delete conversation and mark-read work.
   - No Messages badge (GetMe computes the count only for enabled callers) and no profile Message button.
   - No push arrives, because the fan-out needs `messaging` on for the recipient. A push still in the tray opens its thread.
4. **Global off.** A FEATURE_DISABLED from any read while in `readOnly` switches to `hidden` at once and redirects Home. That is the existing gate behaviour.

**Staleness.** The mode is decided at session start and whenever GetMe's flag set changes. A kill switch reaches a `readOnly` client at its next read call or its next session.

**Security.** Nothing new is disclosed. The client binary already names the flag, and any read call already tells FEATURE_DISABLED apart from data. The entry depends on the device cache, which W7-35 L-4 ties to its owner, so W7-26 merges after W7-35.

**Cost impact.** Fixed cost INR 0, server +0.
- The probe runs only for users outside the rollout whose device holds one of their conversations: an allowlist removal or a ramp-down.
- It costs about 4 reads (an INBOX `since` refresh after W7-37). A cold open after the 30-day token TTL costs up to 23. When messaging is globally off it costs 1 (the interceptor's, usually cached). It runs once per session start. ≈ INR 0 at any modelled DAU.

**Stage ladder.** `MessagingFeatureGate` stays the one place that decides. Option (b) is the additive upgrade. Its trigger: a prod rollout that keeps a percent step for more than 30 days, or a founder request that every user outside the rollout can reach an inbox.

## Implementation note (W7-33), 2026-10-30: the recipient's graph and status are read inside the send transaction, plus a verified-email gate (security review L-1, L-3, L-8; A8 flipped by the founder 2026-10-29)

**Problem.**
- **L-1 (A8).** Send reads the recipient's graph from the 60 s cache. A Block made on another instance lets a harasser send for up to 60 s (about 60 messages across 3 instances). Each message moves the badge and may push. A stale `Following` can also make a new conversation "mutual", so it skips Requests, the 3-message cap and the no-push rule. It also lets a send within 60 s of a block refresh the frozen peer snapshot of W7-30 (the 2026-10-29 note, item 4).
- **L-3.** The purge-race check `FreshRecipient` is a directory read outside the transaction's read set.
- **L-8.** Send and Accept do not re-check a verified email themselves.

**Options for L-1.**
- **(a) Chosen.** Read `graph/{recipient}` **inside** the send transaction through a new graph seam, and **drop** the cached recipient snapshot read before the transaction. Worst cold stays 5; warm goes 1 → 2.
- (b) Keep the cached pre-check and add the read inside the transaction: worst cold 6. The transaction read is the authoritative one, so the extra cold read buys nothing. Rejected.
- (c) A fresh read before the transaction, outside it. The same +1 read, but it does not serialise with a concurrent Block, so the window shrinks only to the length of the transaction. Kept as the contention fallback (below).

**Decision (additive; D4 steps 3 to 5 now read as below, the D4 text stays as the record).**
1. **Seam.** `graph.TxReader` in `backend/internal/graph/api.go`: `SnapshotInTx(ctx context.Context, tx *firestore.Transaction, uid string) (Snapshot, error)`.
   - It makes 1 read through `tx`, charged to the context's `budget.Counter`, and never touches the 60 s cache (neither reads it nor fills it).
   - A missing document is an empty `Snapshot`, like `GetSnapshot`.
   - Error text names no uid.
   - It is implemented by graph's `FirestoreRepo`, the way identity's `FirestoreRepo` implements `TxProfiles`.
   - Messaging declares the consumer-side interface (`messaging.TxSocial`) and reuses `identity.TxProfiles`. `apiserver` wires both.
   - The only collection messaging reads through this seam is `graph`, which graph still owns.
2. **The send order.**
   - **Before the transaction (unchanged apart from one removal):**
     - validation, the flag and the verified-email gate;
     - the caps;
     - the caller's graph (cached);
     - the recipient's profile through the directory (cached; ACTIVE, the flag and the peer snapshot for the entry);
     - refusals: the caller blocks the recipient; the recipient is not ACTIVE; the recipient has the flag off.

     The cached recipient snapshot read is removed.
   - **In the transaction, in this order:**
     1. The conversation; `gone` → refused.
     2. The recipient's graph through `SnapshotInTx`. `Blocked[caller]` → CANNOT_MESSAGE, `refused_reason=blocked`. Mutual = the caller's cached `Following[recipient]` and the fresh `Following[caller]`. Silent = the fresh `Muted[caller]`.
     3. `decideSend`, which applies the request cap.
     4. For a new conversation only: `identity.TxProfiles.ProfileInTx(recipient)`, which **replaces** `FreshRecipient` (+0 reads). A status other than ACTIVE, or NotFound, is CANNOT_MESSAGE with `refused_reason=recipient_inactive`. Then `quotas.dmNew`.
     5. The writes.

     The block check still comes before every cap, so no cap reveals a block.
   - **`SendResult` returns `Silent` and `Mutual` as decided in the transaction.** `afterSend` uses them for the push decision, the `silent` log field and the response. It never uses the values computed before the transaction, so a mute made 59 s ago no longer pushes.
   - The caller's own graph stays cached. Its staleness is self-inflicted (the review's own reasoning).
3. **L-8.** `authn.RequireVerifiedEmail(ctx, allowAnonymous, "sending messages")` in Send, and `"accepting message requests"` in Accept.
   - It runs after the flag guard and before validation: 0 reads, FAILED_PRECONDITION `EMAIL_NOT_VERIFIED`.
   - `allowAnonymous` is `config.AuthEmulator`, passed through `messaging.Deps` as posts does.
   - It is defence in depth behind `authn.VerifiedIdentityInterceptor`.
4. **Contract.** Comments only, in `messaging.proto`: the SendMessage A8 sentence and its cost line. The exact text is in plan ticket W7-33. `buf breaking` stays clean, and the implementer regenerates.
5. **Not done (founder may override): `ProfileInTx` on every send.** It would cost +1 read per send (+1.5 per DAU, ≈ INR 0.5 / 1.5 / 4.6 a month) to close a 60 s window for a recipient suspended mid-conversation. Existing conversations already stop at `gone` for erased users, and a suspension's 60 s lag matches every other directory read.

**D14 change.** On send, the recipient's graph is **fresh** and serialised with Block, which writes `graph/{recipient}`. The caller's graph stays at 60 s. The push fan-out keeps its own cached snapshot for suppression (ADR-0017 D5), but a send refused in the transaction emits nothing.

**Contention signal and fallback.**
- The send transaction holds a read lock on `graph/{recipient}`. Every writer of that document conflicts with sends in flight to that recipient, and one side retries:
  - the recipient's own Block, Mute, Follow and Unfollow;
  - anyone's Block of the recipient, which writes `blockedBy`.
- Signals: `messaging_txn_contention` (attempts > 1 on `kind=send` lines), retries on the graph mutation lines, and p95 SendMessage > 500 ms.
- The rate is bounded by the send caps (60 a minute per sender across 3 instances).
- Latency: `graph/{uid}` can be about 566 KB at every cap, and a recipient with a large document costs that transfer on every send. Watch the SendMessage p95 for such recipients.
- Fallback when contention or latency is measured: option (c), at the same read cost.

**Cost impact.** Fixed cost INR 0.
- SendMessage, accepted conversation: reads stay at **5 worst cold** (the recipient's graph moves into the transaction). Warm goes 1 → **2**, planning 2.5 → **3.5**.
- New conversation: 7 (unchanged; `ProfileInTx` replaces `FreshRecipient`). Refused: at most 5. Replay: +1. Writes unchanged. Accept: +0.
- Per DAU: +1.5 reads a day (1.5 sends × 1), ≈ INR 0.5 / 1.5 / 4.6 a month at 300 / 1,000 / 3,000 DAU.
- **This is already counted** in the "41.55 reads per DAU" total of the W7-37 note, so that total is unchanged.
- The Cost impact row "SendMessage, accepted conversation | 5 | 2.5" now reads 5 / 3.5.

**Stage ladder.** `graph.TxReader` takes a `*firestore.Transaction`, as `identity.TxProfiles` does. That ties the send's block check to graph and messaging living in the same Firestore database. If an ADR moves either of them out of `(default)` (Stage 2: Cloud SQL, or a split service), replace this read with an optimistic version check: a `rev` on `graph/{uid}`, read before the transaction and re-checked at commit. That is the revisit trigger. Plan ticket W7-33 is gated before prod percent or `on`.
