# UI W7: Messaging v1 (direct messages)
Plan owner: planner · Date: 2026-10-27 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **New backend surface:**
- a `messaging` module and a new `dzeroth.messaging.v1.MessagingService` (seven RPCs);
- three new collections: `conversations/{id}` with a `messages` subcollection, and two per-user subcollections, `users/{uid}/dmInbox` and `users/{uid}/dmRequests`;
- one push-only notification type (`message`);
- one additive `GetMe` field;
- one additive report target.

No composite index, no new GCP service, no fixed cost, **no realtime channel, no E2E** · Flags: new `FEATURE_MESSAGING`; existing `notifications` (push), `reports` (report a message), `graph` (picker), `search` (optional picker search, W4), `ui_shell` (nav destination)

Source:
- `docs/plans/roadmap.md`: W7 row ("Messaging v1 | messaging module; pull + FCM push | realtime and E2E are the cost cliffs; E2E is a future ADR"), the section 5 capture row "W7 Conversation view; new-message flow", founder decision 2026-10-22 ("DMs v1 = server-mediated pull + push, no E2E");
- `docs/x_research/01_screen_inventory.md` §09 (the chat area sat behind a passcode gate, so no inbox or conversation UI was captured), `05_component_library.md` row 17 (list/chat row), `06_interaction_behaviors.md` (Chat inbox is a `listbox`; preview prefixes "You:"; muted marker; relative time). All three are local and git-ignored;
- `.claude/skills/stage-ladder` (Real-time row: "DMs v1 = pull + push, no E2E");
- ADR-0003, ADR-0008 (D2 blockedBy, D6 flags), ADR-0010 (D5 read budget, D9 text rules), ADR-0011 (lifecycle, T11 guard), ADR-0016 (reports), ADR-0017 (D2 Emitter, D5 suppression, D6 push payload, D11 no web push), ADR-0021 (deterministic-id precedent), ADR-0022 (credit window), ADR-0023 (flag-not-globally-off precedent);
- `docs/plans/ui-w3-profile-graph-completion.md` and `docs/plans/ui-w4-discovery-search.md` (format, shared files, ADR numbering).

Branches: `feat/ui-w7-N-<slug>` off `main` (not stacked); one ticket per PR; merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks the ADR or proto tickets)
**Decided 2026-10-28: the founder accepted every default, F1 to F11.** They are recorded with options and INR lines in ADR-0027 ("Founder decisions F1–F11"). The text below is kept as the question record.
- **F1. Images in messages?** **Default: text only in v1.** Images would reuse the media pipeline (signed upload, SafeSearch at 2 Vision units per image) with a new `MEDIA_PURPOSE_MESSAGE`. They need private-read objects, because media objects are public-read today (`CLAUDE.md`), and a public URL for a private photo is a leak. They also add Vision spend inside the shared cap. That is its own ADR (Out of scope, with its trigger).
- **F2. Who can message whom.** **Default:**
  - Mutual follows land directly in the Inbox.
  - Everyone else (signed-in, ACTIVE, not blocked either way) lands in the recipient's **Message requests**.
  - Until the recipient accepts, the sender may send at most **3** messages (`MESSAGES_REQUEST_MAX_UNANSWERED`).
  - A sender may open at most **20 new conversations a day**, or **5** for accounts inside the existing new-account window (`quotas/{uid}`, exact).
  - The recipient can Accept, Delete or Block. A Delete is never revealed to the sender.

  There is no per-user "who can message me" setting in v1; Block covers it.
  Alternatives:
  - (b) followers of the recipient go to the Inbox (X's default), everyone else to Requests;
  - (c) mutual follows only, no requests at all (the cheapest, but it blocks first contact);
  - (d) add an "Allow message requests from: Everyone / No one" setting (one field, small).
- **F3. Account deletion and the other participant's copy.** **Default: tombstone.**
  - The deleted user's messages keep their place in the thread with the text cleared, and the peer sees "Message deleted".
  - The peer's own messages stay.
  - The conversation turns read-only, and the deleted user's name becomes "Deleted account".
  - When both participants are gone, the whole conversation tree is deleted.

  Alternative: erase the user's messages outright (the same cost, 1 read + 1 delete per message instead of 1 read + 1 write). The peer then sees gaps, and their replies lose context.
- **F4. Read receipts and typing indicators.** **Default: neither in v1.** A receipt is a write per read that the peer must poll for, and typing needs realtime. The server keeps `lastReadAt` on the reader's own inbox entry (for unread state only) and never shows it to the peer. A later receipt feature can expose it additively.
- **F5. Data export section `messages`.** **Default:**
  - every conversation the user is in: the peer's handle at export time, the state and timestamps;
  - the user's **own** messages in full;
  - for received messages, only the time and "received", never the text.

  The other person's words are their content. Alternative: both sides in full, as X's archive does. The security review (W7-22) records whichever you choose.
- **F6. Kill-switch semantics.** **Default:**
  - **Sending needs the flag for the caller, and also for the recipient.** A recipient outside the rollout answers with the same "can't message this account" error as any other refusal, so it reveals nothing.
  - The read RPCs and the clean-up RPCs need only "not globally off" (`Registry.GloballyOff`, the ADR-0023 / ADR-0021 precedent). The read RPCs are list, get, poll and mark-read; the clean-up RPCs are delete conversation and accept or delete a request. A user dropped from an allowlist can therefore still read, clean up and report.
  - `FEATURE_MESSAGING=off` (global) hides everything, and every RPC answers FEATURE_DISABLED with 0 reads.

  Alternative: off for the caller hides the inbox too.
- **F7. Push for messages.** **Default:**
  - One FCM push per message to the recipient, Android only (iOS push waits for the Apple launch, and web push is out of scope per ADR-0017 D11).
  - The lock-screen text is generic, "New message" / "You have a new message", with **no sender and no text** (ADR-0017 D6: a lock screen is public).
  - No push for message requests, and none when the recipient muted the sender.
  - Messages create **no row** in the Notifications list and do not move its badge.
- **F8. Message length.** **Default: the post grammar unchanged:** 280 code points, at most 10 lines, NFC, no control or bidi characters (ADR-0010 D9, the shared `testdata` fixtures). Alternative: 1,000 code points (a constant change; about 3 KB more per long message).
- **F9. Muted accounts.** **Default:** muting someone does not refuse their messages (refusing would tell them they are muted). Their messages arrive silently: no push, and the unread count does not grow. Requests from muted or blocked accounts are hidden from the Requests list.
- **F10. Navigation.** **Default: a "Messages" destination in the bar and rail (envelope icon, with an unread-conversations badge).** With W4's Explore that makes Home, Explore, Notifications, Messages, Profile: exactly the 5-item cap of the phone bar (`08_navigation_flows.md`). Profile stays in the bar; History and Settings stay in the drawer.
- **F11. Report a message.** **Default: yes, through the existing reports path.** The report doc copies **only the reported message's text** as evidence, which you then read in `opsctl reports`. This means private content reaches the operator, so ADR-0016 gets a dated note (W7-12). `opsctl` gains a "take down a message" action (tombstone, reason `REMOVED`).

## What exists already (verified on `main` d2ff011)
| Piece | State | W7 delta |
|---|---|---|
| Messaging module, proto, collections | **none** (roadmap section 2) | new `backend/internal/messaging`, `proto/dzeroth/messaging/v1`, three collections |
| Text grammar | `backend/internal/posts/text` is a pure leaf package: `Normalize`/`Parse`, D9 rules, 280 code points / 10 lines. `imports_test.go` pins "no `internal/` imports" so that other modules can import it without a cycle | messaging calls `text.Normalize` (architect A6) |
| Graph | `graph.Reader.Snapshot` (60 s cache): Following, Blocked, Muted, Requested, BlockedBy (+overflow). The **recipient's** snapshot answers "follows the sender", "blocked the sender" and "muted the sender" authoritatively, with no overflow case | the send path reads both snapshots |
| Push | `notifications.Emitter` → Pub/Sub `notifications-fanout` → `Fanout.Deliver`. Today every event `Create`s a row in `users/{uid}/notifications`; `validateEvent` needs a post id for every type except follow; the collapse key is the type (N-2); the per-recipient limiter is 10 pushes/hour across all types; the recipient needs `notifications` on; the payload is generic text (D6); there is no web push (D11) | a **push-only** `message` type: no row, `conversationId` in `data`, its own limiter bucket (W7-10) |
| Badge | `GetMe.unread_notification_count` = `count()` aggregation, cached 30 s; `UnreadBadgeCubit` is fed by GetMe and by foreground pushes | additive `GetMe.unread_conversation_count` through a consumer-side interface; a separate client badge cubit |
| Reports | `ReportTargetType` POST = 1, ACCOUNT = 2; evidence is copied into `reports/{id}` | `REPORT_TARGET_TYPE_MESSAGE = 3` (additive) |
| Lifecycle | `lifecycle_collections_guard_test.go` (T11) fails on any collection without a row; erasers register as steps before `identity` | a `messaging` step plus export section `messages` that ship **in the same PR as the first write path** (W2-3/W2-5 precedent) |
| People lists | `GraphService.ListFollowing` + `UserListRow` + `PagedUserList` exist; W4's `SearchRepository` (handle prefix) is planned, not built | the picker uses Following now, and handle search once `search` is on (no hard W4 dependency) |
| Client | `UserListRow` (component row 17 "reuse for future Lists/DM"), `AppTabBar`, `AppEmptyView`, `AppBackHeader`, `CharacterCounter`, `analyzePostDraft`, `RateLimitHold`, `ServiceFeatureGate`, drift `AppDatabase`, `SessionEpoch`, `PushCubit.onOpen`, `notificationLocation`, `AppRouter.deepLinkTarget` (W2-9 allowlist: `/post/<19 digits>`, `/u/<x>`, `/profile/<x>`) | messages feature folder, `/messages`, `/messages/:id`, `/messages/new`, nav entry, badge, push routing, one new allowlist pattern |
| Captures | **conversation view and new-message flow NOT VERIFIED** (passcode gate); the inbox is A11Y only | X-conformant defaults with our own copy; a capture is optional and adjusts them later |

## Goal & user value
People can talk privately one to one. Mutual follows message each other directly, and anyone else can send a polite, capped request. Messages arrive within seconds on Android (push, then pull) and within one poll interval on an open thread anywhere, web included. Abusers are stopped by block, mute, report and hard send caps. It is the main retention loop after Home and Notifications, and X users expect it.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **Conversations.**
  - 1:1 only, with a deterministic conversation id per pair.
  - Two folders, Inbox and Message requests.
  - Accept or delete a request; "Delete conversation" (for me only).
  - An unread-conversations badge.
- **Messages.**
  - Text with the post grammar (F8), with links shown as links. Mentions and hashtags are plain text: nobody is notified, and there is no tap-through.
  - Rule-4 idempotent send, ordered by commit time, cursor-paged, with a `since` refresh.
- **Delivery.**
  - Pull-on-read: an inbox page, a thread page, and a `since` poll on a **visible** thread at a bounded, backing-off interval.
  - One FCM push per message to Android recipients.
- **Safety.**
  - Block and mute are enforced on send and on read.
  - Report a message (F11).
  - Per-minute, per-day and new-conversation caps, plus the request cap.
- **Lifecycle.** An eraser step (tombstone, F3), export section `messages` (F5), no retention limit in v1.
- **Client.**
  - Inbox screen, conversation screen, new-message flow (people picker).
  - A "Message" button on another user's profile.
  - Request actions, a nav destination with a badge, push deep links.

**Stage 0 choice, seam and Stage 2/3 target (proposed `stage-ladder` row "Direct messages", added by the ADR PR, W7-1):**
| Concern | Stage 0 (this plan) | Seam to protect now | Stage 2/3 target (ADR) | Trigger (measured, sustained 7 days) |
|---|---|---|---|---|
| Delivery to an open thread | client `since` poll: 15 s hot, 45 s warm, stop after 5 min idle or when hidden; a push triggers an immediate pull | `MessagingService.ListMessages(since_token)` + an opaque, settle-windowed token; the client `ThreadPoller` behind one interface; every message event through `notifications.Emitter` | **owner-only Firestore listeners** on `users/{uid}/dmInbox` and the messages of conversations the user is in (a rules ADR: claims- or path-scoped `allow read`, still deny-all writes), then **SSE on an instance-billed service** | message polls > 25 % of all Cloud Run requests, **or** the vCPU-s attributable to polls > INR 300/month, **or** measured p95 send-to-render on an open web thread > 20 s with user complaints (`stage-ladder` Real-time: "a latency requirement under ~5 s with measured demand") |
| Group conversations | none (1:1 only) | `conversations/{id}.participants[]` is an array and the inbox entry is per user, so a group adds entries without changing callers; `ConversationKind` enum in the proto | groups up to 50 members: one inbox entry per member written per message, a **bounded write fan-out**, which is exactly what rule 2 forbids at Stage 0 without an ADR | founder demand **and** messaging DAU > 30 % of DAU **and** the write model shows the fan-out fits (writes/message × members) |
| Images in messages | none (F1) | `Message` has an optional `media` slot reserved in the ADR (field number not reused) | private-read objects (signed GET per view) + SafeSearch | founder request plus ≥ 1 % of reports citing missing images; its own ADR (Vision and egress line) |
| End-to-end encryption | **none** (roadmap: a future ADR) | message text only ever passes through `messaging.Service` (no other module reads `messages`), so a ciphertext body later changes only that module and the client | E2E (per-device keys, a key directory, passcode-protected key backup as X does) | founder decision; it needs its own ADR because: (1) key management (multi-device, lost devices, key backup and recovery: X's 4-digit passcode gate is that problem); (2) moderation, because a report can no longer copy evidence the server cannot read (client-side reporting with message franking); (3) attachments need client-side encryption and a separate key per object, which doubles the media work; (4) search and export of encrypted history become client-only |
| Retention | none in v1 (messages live until deleted) | `createdAt` on every message; the eraser already pages a conversation | a TTL policy or a "messages older than N months" sweep (TTL deletes are billed) | messaging storage > 0.5 GiB, or the founder sets a retention policy |

**Out of scope:**
- realtime of any kind: WebSocket, SSE, Firestore client listeners, typing indicators, presence (F4);
- E2E encryption (above);
- groups (above);
- images, GIFs, voice, video, calls (W8 shells cover calls; F1);
- reactions, replies-to-message, editing and unsend (an "unsend for everyone" is a later additive RPC);
- per-conversation snooze, pin, archive, search inside messages;
- read receipts (F4);
- a "who can message me" setting (F2 d);
- web push (ADR-0017 D11) and iOS push (paused for the Apple launch);
- message requests from signed-out users;
- link previews in messages (a W-later SSRF-safe fetcher);
- a retention policy.

## Non-functional targets (Stage 0, 0–300 DAU; credit mode to ~3k DAU changes no target)
- **Latency (warm, server):**
  - SendMessage p95 < 500 ms (the post-create target);
  - ListConversations p95 < 400 ms;
  - ListMessages page p95 < 400 ms;
  - `since` poll p95 < 200 ms.

  Cold start < 1.5 s. No target depends on credit mode's min instance (ADR-0022).
- **Delivery (send commit to the recipient seeing it), Stage 0 bounds, not SLOs:**
  - thread open and the conversation hot (activity in the last 2 min): ≤ 15 s + one request;
  - thread open but quiet: ≤ 45 s;
  - Android with the app in the background: FCM normal priority, typically seconds (can be minutes under Doze);
  - web with no open thread: the next inbox refresh or GetMe.

  W7-23 measures p95 on dev (the Stage 2 trigger above).
- **Staleness bounds (every cached read):**
  | Cached read | Bound |
  |---|---|
  | `conversations/{id}` per instance (membership, state, `clearedAt`, `gone`) | membership is immutable in 1:1. State and `clearedAt` are updated in place on the writing instance; other instances converge within **60 s** (a cleared history can show for up to 60 s on another instance). **Send never trusts the cache:** it re-reads the doc inside its transaction |
  | Caller and recipient `graph` snapshots (60 s) | a new Block applies at once on the instance that handled it and within **60 s** elsewhere (architect A8: a fresh read instead costs +1 read per send) |
  | Peer snapshot stored on an inbox entry (name, handle, avatar) | refreshed on every message in either direction; between messages it can be as stale as the peer's last rename. The thread header uses `identity.Directory` (60 s) |
  | `unread_conversation_count` in GetMe | 30 s server cache (shared with the notifications count), evicted on this instance by a send to or a mark-read by that user; the client moves the badge locally on a foreground push and on open |
  | Client | the inbox and the last 200 messages per conversation are cached in drift per uid and wiped on sign-out (`SessionEpoch`); polls fetch only `since` |
- **Per-uid read budget (ADR-0010 D5: 2,000 reads/uid/day per instance) against polling:**
  - A hot thread polls every 15 s, which is 240 polls an hour at about 1.2 reads, so 288 reads an hour.
  - At that rate the budget allows about 7 hot hours a day, or about 22 hours of warm (45 s) polling.
  - Polling stops after 5 min without input or new messages, and whenever the tab or app is hidden, so an open-but-forgotten thread costs at most about 7 + 4 polls.
  - A RATE_LIMITED answer pauses polling through the shared `RateLimitHold`.

## Data model (proposal for ADR W7-1; the architect decides)
No composite index. Every query runs on an automatic single-field index of one collection, and no collection-group query is used.

| Path (owner: messaging) | Shape | Written when | Queries |
|---|---|---|---|
| `conversations/{convId}` | `convId` = first 32 hex of SHA-256(`"dm1|" + lowUid + "|" + highUid`) (deterministic, so "open a conversation with X" needs no lookup query; no uid in URLs, push data or logs); `kind` (`DIRECT`); `participants` [lowUid, highUid]; `state` (`REQUEST` / `ACCEPTED`); `requestFrom`, `requestTo`, `requestCount` (messages sent while REQUEST); `clearedAt` {uid: ts} (delete for me); `gone` [uid] (erased participants); `createdAt`, `updatedAt` | first message, accept, a request message (count +1), delete-for-me, the eraser. **Not on every message** (no hot doc) | get by id; eraser: `participants array-contains uid` (automatic array index), paged by `__name__`, Limit ≤ 100 |
| `conversations/{convId}/messages/{msgId}` | `msgId` = first 32 hex of SHA-256(`senderUid | "SendMessage" | idempotency_key`) (technique 5: `Create`, AlreadyExists = replay; no `idempotency` doc, no TTL delete); `senderId`; `text` (NFC; **index-exempt**); `state` (`VISIBLE` / `DELETED_ACCOUNT` / `REMOVED`); `requestHash` (one-way digest of the request, for a same-key-different-body check; **index-exempt**); `createdAt` (commit time, set in the send transaction) | SendMessage; the eraser and `opsctl` tombstone (`text` cleared, `state` set) | thread: `createdAt DESC, __name__ DESC` Limit ≤ 50 (single-field index); `since`: `createdAt > t` with a 5 s settle window (ADR-0017 pattern, client dedupes by id); eraser: `senderId == uid` Limit 500 |
| `users/{uid}/dmInbox/{convId}` | `peerId`; `peer` {handle, displayName, avatarThumbUrl, verified} (**index-exempt**); `lastMessageAt`; `last` {messageId, fromSelf, snippet ≤ 100 code points, state} (**index-exempt**); `unreadCount` (`FieldValue.Increment`, rule 3: one writer per message); `silent` (the owner muted the peer); `lastReadAt` (never shown to the peer, F4); `createdAt` | every send writes both participants' entries (sender's and recipient's): a **bounded constant of 2 writes**, not a follower fan-out (rule 2 concerns timelines; groups would make it N, see the ladder); mark-read; accept (created); the eraser | inbox: `lastMessageAt DESC, __name__ DESC` Limit ≤ 50; `since`: `lastMessageAt > t`; badge: `count()` of `unreadCount > 0`, Limit 100 |
| `users/{uid}/dmRequests/{convId}` | same shape as `dmInbox` | a request message to a non-mutual (recipient side only; the sender's own entry is in the sender's `dmInbox`, as on X) | requests list: `lastMessageAt DESC, __name__ DESC` Limit ≤ 50; `count()` for the "Message requests (N)" row |
| `quotas/{uid}.dmNew` | daily count of conversations opened (F2: 20, new accounts 5) | first message of a new conversation only | — |

- **Index exemptions (no composite index, but still a gate-file change):** fieldOverrides `indexes: []` for `messages.text`, `messages.requestHash`, `dmInbox.peer`, `dmInbox.last`, `dmRequests.peer`, `dmRequests.last`. They follow the "exempt large text fields" convention (`firestore-data-model`) and save index storage and write cost. They go in **`firebase/firestore.indexes.json` plus the `firebase/field-overrides.ack` hash: both founder-gated (CODEOWNERS)**, W7-3.
- **Why not one shared conversation doc with the participants array (the brief's first shape):** an inbox query `participants array-contains uid orderBy lastMessageAt` needs a composite index, and a per-user Requests filter or "delete for me" needs another one, or in-memory filtering with short pages. The per-user entries cost +1 write per message (3 instead of 2), need no index file entry, and are the shape groups need anyway. Architect A1 confirms or reverses.

## Cost (required)
Method: `free-tier-budget` §2 and the marginal method of `docs/reviews/cost-model.md` §5 (W2 lines): baseline with W2 = **248.7 reads, 33.5 writes, 8.4 deletes, 37.7 requests per DAU per day**. Free reads are exhausted at about **201 DAU**, so **every W7 read is billed at 300 DAU and above**. Writes are free to about 597 DAU before W7. W3–W6 increments are not yet in the model; they are each small next to W7's (W3 Part A +0.06 writes, W4 ≈ 0).

Prices (§7):
- Firestore asia-south1: $0.035 / $0.104 / $0.012 per 100k reads / writes / deletes;
- Cloud Run: $0.40 per million requests, $0.000024 per vCPU-s;
- egress to India: $0.12/GiB;
- INR 95 per USD.

**FCM is free; Pub/Sub uses about 0.27 GB a month at 3,000 DAU of the free 10 GiB; Vision units 0 (text only, F1).**

**Per-RPC.** Worst-case reads include the account-status interceptor. Every call is charged to the per-uid read budget (ADR-0010 D5).

| RPC | Reads worst (cold) | Reads planning | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| SendMessage, accepted conversation | 5 (interceptor 1, caller graph 1, recipient graph 1, recipient `users` via Directory 1, conversation doc in the txn 1) | 2.5 | 3 (message `Create`, 2 inbox entries) | 0 | +1 write while REQUEST (`requestCount`) |
| SendMessage, new conversation | 7 (above + fresh recipient status read, architect A7 + `quotas` in the txn) | — | 5 (message, conversation doc, sender entry, recipient entry, `quotas.dmNew`) | 0 | 0.05 of the 1.5 sends |
| SendMessage, replay (same key, AlreadyExists at commit) | +1 (read the stored message to return it) | — | 0 | 0 | same key with a different body → VALIDATION `idempotency_key` |
| SendMessage, refused (blocked, flag off for the recipient, request cap, gone) | ≤ 5 | — | 0 | 0 | one error code, "can't message this account" |
| Push delivery (Pub/Sub push to `/internal`, `message` type, no row) | 9 (actor and recipient `users` fresh 2, recipient graph 1, devices ≤ 5, +1 actor graph on overflow) | 3.5 | 0 | 0 | lever (architect A4): skip the 2 fresh profile reads for push-only events → 1.5 |
| ListConversations, first page 20 (INBOX) | 23 (interceptor 1, query 20, caller graph 1, `count()` of requests 1) | 9 (about 6 conversations) | 0 | 0 | REQUESTS folder the same without the `count()` |
| ListConversations `since` refresh | 3 (interceptor, query min 1, graph) | 2 | 0 | 0 | |
| ListMessages first page 20 / 50 (and older pages) | first page 25 / 55 since W7-27 (interceptor 1, conversation doc 1, query, peer `users` 1, caller graph 1 for `can_reply`, the caller's entry 1); older pages 24 / 54 | 15 (16 with the entry) | 0 | 0 | non-participant or unknown id → NOT_FOUND after ≤ 2 reads, byte-identical |
| ListMessages `since` poll | 3 cold (interceptor, conversation doc, query min 1); **a `since` response omits `conversation`** (no peer or graph read) | 1.2 | 0 | 0 | + 1 read per new message returned |
| MarkConversationRead | 1 (interceptor) | 0.3 | 1 (entry `unreadCount = 0`, `lastReadAt`; `Exists` precondition) | 0 | the client calls it only when it holds unread > 0 |
| AcceptMessageRequest | 3 (interceptor, conversation, request entry) | 2.5 | 2 (conversation state, `dmInbox` entry) | 1 (`dmRequests` entry) | |
| DeleteConversation (for me; also "delete request") | 3 | 2.5 | 1 (`clearedAt`) | 1 | |
| `GetMe` badge (`unread_conversation_count`) | +1 (`count()`, 1 read per 1,000 matches, min 1) | +0.75 per GetMe | 0 | 0 | 0 reads when `messaging` is off for the caller |
| ReportContent, MESSAGE | 6 (as the POST row: interceptor, conversation, message, report doc, quotas, caller graph) | 3 | 2 (report, quotas) | 0 | existing quota (20/day) |
| Eraser step `messaging` (reference: 20 conversations, 300 sent messages) | 1 per conversation + 1 per own message + 1 per peer entry | **381** (was 340: W7-20 measured 81 step calls; the plan left out `MarkGone`'s second read and the closing step's read and write, +1 read and +1 write per conversation) | 1 per message (tombstone) + 1 per peer entry + 1 per conversation: **360** (was 340) | 1 per own entry: 20 | resumable, pages ≤ 500 |
| Export section `messages` (same reference) | 1 per conversation + 1 per message (both sides read, own text exported) | ~620 | 0 | 0 | |

**Calls per DAU per day (assumptions, averaged over all DAU; W7-23 replaces them with measurements):**
| Call | Calls/DAU | Planning reads | Reads/DAU | Writes/DAU |
|---|---|---|---|---|
| SendMessage (messages sent per DAU per day, the main sensitivity) | **1.5** | 2.5 | 3.75 | 4.65 (3.1 average: 3 + request and new-conversation extras) |
| Push delivery (1 per message; Android recipients send FCM, every message is one internal request) | 1.5 | 3.5 | 5.25 | 0 |
| ListConversations (0.5 first page + 1.5 `since` refresh) | 2.0 | 9 / 2 | 7.5 | 0 |
| ListMessages open (0.5 first page + 1.0 `since` resume from the drift cache) | 1.5 | 15 / 2 | 9.5 | 0 |
| ListMessages `since` polls on a visible thread (web has no push; Android hot interval 30 s) | **5** | 1.2 | 6.0 | 0 |
| New messages read once by the recipient | 1.5 messages | 1 | 1.5 | 0 |
| MarkConversationRead | 1.0 | 0.3 | 0.3 | 1.0 |
| GetMe badge `count()` (4 GetMe/DAU, about 75 % miss the 30 s cache) | +0 requests | 0.75 | 3.0 | 0 |
| Accept / delete / report / eraser / export | 0.05 | — | 0.2 | 0.1 |
| **Total W7** | **≈ 12.6 requests** | | **≈ 37.0 reads** | **≈ 5.8 writes, ≈ 0.05 deletes** |

**Wave total (Stage 0 as configured; W7 increment at the margin of the W2 baseline):**
| INR per month | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (37.0 × 30.42 = 1,126 per DAU-month, all billed) | 11.2 | 37.4 | 112.3 |
| Firestore writes (5.8 per DAU per day; billed once the product passes 20k/day) | 0 (11.8k/day with W7) | 17.4 | 52.3 |
| Firestore deletes | 0 | 0 | ≈ 0.1 |
| Cloud Run requests (+383 per DAU-month) | 0 | 0 (1.51M of 2M) | 43.7 |
| Cloud Run vCPU-s (12.6 × 0.1 s = 38.3 per DAU-month, the model's 0.1 s per request) | 0 | 0 (153k of 180k) | **262.0** (about 179 if a poll bills 20 ms) |
| Egress to India (≈ 10 KB/DAU/day) | 1.0 | 3.3 | 10.0 |
| **W7 total** | **≈ 12** | **≈ 58** | **≈ 480 (upper bound; ≈ 400 with 20 ms polls)** |
| Stage 0 bill with W2 + W7 (INR) | 441 → **≈ 453** | 1,653 → **≈ 1,711** | 3,498 → **≈ 3,978** |

- **Quota crossovers that move (the headline):**
  - Firestore writes reach the free 20k/day at about **509 DAU** (was 597). At 3 messages/DAU/day it is 456, at 5 it is 399.
  - Cloud Run requests reach the free 2M/month at about **1,322 DAU** (was 1,743).
  - Cloud Run vCPU-s reach the free 180k/month at about **1,174 DAU** (was 1,566).
  - Reads are already billed.
- **Sensitivity:**
  - Each poll per DAU per day costs about INR 28/month at 3,000 DAU (21 CPU, 3.5 requests, 3.6 reads) and about INR 0.4 at 300 DAU.
  - Each extra message per DAU per day costs about INR 16/month at 1,000 DAU (7 reads, 3.1 writes, 2 requests).
  - At 3,000 DAU polling is the largest line. That is why the realtime trigger watches it.
- **Storage:**
  - About 1 KB per message with its index entries (text exempt) plus 2 entry updates.
  - At 1.5 messages/DAU/day: about 0.16 GiB a year at 300 DAU and 1.6 GiB a year at 3,000 DAU. The latter passes the shared free 1 GiB within the year, then costs about INR 10–20/month. That is the retention trigger.
  - **W7-23 (2026-10-29), derived with Firestore's size rules:** a message is about 1.26 KB with its six index entries, and a DAU adds about 2.2 KB a day with the conversations and entries, so the 0.5 GiB messaging trigger is reached in about 815 / 245 / 82 days at 300 / 1,000 / 3,000 DAU (`cost-model.md` §4 and §6).
- **Measured by W7-23 (2026-10-29; `cost-model.md` §14, emulators, two runs):**
  - Every per-RPC read count is at or under the table above: first pages 23 (inbox) and 24 / 54 (thread) cold and 21 / 20 / 50 warm, MarkConversationRead 0 to 1 read and 1 write, a send 1 read warm and 7 / 5 on a new conversation.
  - **The poll is the one line above its planning value: mean 1.41 reads over 9,000 polls against 1.2 (+17%)**, so the calls table totals **38.05 reads** (was 37.0), 5.8 writes, 12.6 requests.
  - The eraser row above is corrected to 381 reads and 360 writes.
  - The Wave total is **INR 12.5 / 59 / 484** at 300 / 1,000 / 3,000 DAU (the table says 12 / 58 / 480), and 13 / 61 / 490 once W7-27 and W7-33 add 2.0 reads a day.
  - A poll of a quiet thread returns the newest message again (1 read, never empty); a poll inside a busy conversation returns up to a page.
- **No new GCP service, no Scheduler job, no Pub/Sub topic** (the existing `notifications-fanout` carries the event), **no fixed cost.** Credit window: nothing depends on ADR-0022 items.

## Flags
- `FEATURE_MESSAGING` (wire name `messaging`):
  - **Per caller:** SendMessage (new and existing conversations) and AcceptMessageRequest. The recipient must also be enabled (F6).
  - **Not globally off:** ListConversations, ListMessages, MarkConversationRead and DeleteConversation, plus the report path for MESSAGE targets.
  - **The push hook:** the fan-out sends a `message` push only when `messaging` and `notifications` are both on for the recipient.
  - **GetMe:** `unread_conversation_count` is computed only when `messaging` is on for the caller (0 reads otherwise).
  - **Client:** it gates the nav destination, the routes and the profile "Message" button on `enabled_features`.
- **Ceiling.** `scripts/promotion/flag-ceiling.json` gets `MESSAGING` in `flags` and a dev entry `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`, **with no prod raise. Founder-gated file (CODEOWNERS)**: W7-4's PR needs your review. Proposed prod ceiling for the MVP launch, decided by you then: allowlist only until W7-22 and W7-23 have passed in dev and the realtime trigger is instrumented.
- **Terraform.** `feature_messaging`, `_allowlist` and `_percent` in `envs/dev` and `envs/prod`, default `off`, plus the config env vars (copy `feature_bookmarks`). Nothing is applied.
- **Ramp.** Dev allowlist (3 uids, who must also have `notifications` on to test push) → your MVP launch decision for prod: allowlist → percent 5 → 25 → 100 → `on`. Each step is a Terraform change plus a tagged revision (ADR-0019). Messaging needs both people in the rollout, so a percent step means "messaging works between enabled users only". The client shows "This account can't receive messages yet", and the server answers like any refusal. Consider staying on allowlist then going straight to `on` (founder at ramp time).
- **Kill switch:** `off` (global) hides and refuses everything. See Rollout.

## Abuse & security surface
- **New private reads.** The caller must be a participant. A non-participant, an unknown id, or a malformed id answers a byte-identical NOT_FOUND (`conversation_id`, 32 hex only; anything else is VALIDATION with 0 reads). Deterministic ids are guessable from two uids, so authorization never relies on secrecy. Tokens are sealed and bound to `(uid, conversation, kind)`, with a 30-day TTL (the ADR-0017 codec); a foreign or tampered token is VALIDATION with 0 reads.
- **New writes and their caps (config, rule 11).** The in-memory limits are per instance, so the effective limit is × 3 instances (`stage-ladder`).
  | Config | Default | Effective at 3 instances | Store |
  |---|---|---|---|
  | `RATE_LIMIT_MESSAGES_SEND_PER_MIN` | 20 | 60/min | memory |
  | `MESSAGES_SENDS_PER_DAY` (`ratelimit.DailyCap`, `limit_name` `messages_daily`) | 300 (50 inside the new-account window) | ≤ 900/day | memory |
  | `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY` / `QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY` | 20 / 5 | exact | `quotas/{uid}.dmNew` |
  | `MESSAGES_REQUEST_MAX_UNANSWERED` | 3 | exact (in the send txn) | `conversations.requestCount` |
  | `RATE_LIMIT_MESSAGES_READ_PER_MIN` (List*, polls) | 30 | 90/min | memory |
  | `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` (own bucket, not the shared 10/h) | 20 | 60/h | memory |
  | Read budget (ADR-0010 D5) | 2,000 reads/uid/day | binds first for readers | memory |

  Worst case for one sender: about 900 messages a day, of which at most 20 new conversations × 3 request messages reach strangers. A spam ring needs many verified accounts (residual R1, `cost-model.md` §4).
- **Grammar:** the post grammar (F8), validated before any read; 0 reads on rejection. Links render as links with the existing safe-link rules (`launchPostLink`: http(s) only, no userinfo, punycode hosts).
- **Block and mute (server-side, on send and on read):**
  - **On send:** if either side blocks the other (the caller's `Blocked`, the recipient's `Blocked`, which is authoritative and needs no `blockedBy` overflow read), the send is refused with **the same error and bytes as "account not found or not accepting messages"**, so it is no block oracle beyond what GetProfile's NOT_FOUND already reveals.
  - A recipient who muted the sender: delivered silently (F9).
  - **On read:** conversations with a blocked peer stay in the Inbox, read-only with `can_reply = false` (the user may still want to report them). Requests from blocked, blocking or muted accounts are hidden from the Requests list (short pages allowed, `next_page_token` follows the query).
  - **Block from the thread** reuses `GraphService.Block`. It does not delete the conversation.
- **Report** (F11) goes through `ModerationService.ReportContent`, `target_type = MESSAGE`, `target_id = "<convId>:<msgId>"`:
  - only a participant may report, and only the peer's message (your own → VALIDATION);
  - the evidence is that one message's text, the sender handle and its time;
  - the 20/day report quota applies;
  - `opsctl` can tombstone the message (`REMOVED`) and suspend the sender (existing).
- **Push privacy:**
  - the FCM `data` carries `type=message` and `conversationId` only (no uid, no text);
  - the lock-screen text is generic;
  - no push for requests (F7).
- **Logging:** never message text, snippets, peer uids or conversation ids in clear. Log `conversation_hash` (a hash of the id), `kind` (send / list / poll), `state`, `results`, `fs_reads`, `fs_writes`, `refused_reason` (a fixed enum) and `uid_hash`.
- **Enumeration and scraping:** no list of other people's conversations; the picker is your own Following list (existing limits) or W4 search (W4's caps). Nothing new is public.
- **Right to delete and privacy (`CLAUDE.md` rule 10):** message bodies are user content, not PII. Participants (uids) are personal data: they are never in URLs, push data or logs (hashed id), and are erased or replaced by the eraser.
  - **Eraser ordering:** the eraser first marks each conversation `gone` (1 write). The send transaction reads that doc, so no send can rewrite the deleted user's entries afterwards.
  - It then tombstones the user's messages (F3) and rewrites the peer's entry (snapshot → "Deleted account", snippet → "Message deleted" when the last message was theirs).
  - It deletes the user's own entries, and deletes the whole tree when both are gone.
  - A brand-new conversation created in the milliseconds between a fresh status read and the commit is the residual race that ADR-0017's fan-out already accepts. The account-lifecycle backstop re-runs the step (architect A7).
- **Degraded mode:** SendMessage, MarkConversationRead, Accept and Delete are mutating RPCs, so `DEGRADED_MODE=readonly` refuses them automatically. The reads stay up, and the client shows the read-only banner.

## Dependencies & open questions
**Dependencies:**
- The founder's answers to F1–F11 (each has a default; nothing blocks W7-1 to W7-3).
- **W4 (optional):** the picker's handle search appears only when `search` is on and W4-13's `SearchRepository` exists. Without it, the picker is the Following list plus "type a handle" resolved by `IdentityService.GetProfile` (1 call, existing).
- **W3:**
  - W7-17's profile "Message" button edits `profile_header.dart`, so it merges after W3-14.
  - W3 Part B (`private_accounts`, ADR-0025) does not change messaging: a protected account can still receive requests. If ADR-0025 lands first, the picker shows protected accounts like any other.
- **Capture (optional, does not block):** the roadmap section 5 row "W7 Conversation view; new-message flow" was not captured because X's chat sat behind a passcode gate. The UI tickets use X-conformant defaults with our own copy and say so per ticket; a capture adjusts them in a follow-up PR. **UNKNOWN until captured:** bubble shapes and colours, timestamp grouping, the composer layout, the new-message dialog, request cards, empty states.

**Questions for @architect (ADR W7-1):**
- **A1. Data model.** The per-user `dmInbox` / `dmRequests` entries (default, index-free, +1 write per message) vs one shared conversation doc with participant-keyed maps and composite indexes (gate file). Confirm that the badge `count()` on `unreadCount > 0` and the eraser's `participants array-contains` run on automatic single-field indexes (emulator check in W7-5).
- **A2. Message ids.** A deterministic `hash(uid, "SendMessage", key)` with `Create` (default: no idempotency doc, no TTL delete; ordering by `createdAt, __name__`) vs a Snowflake id plus `idempotency.Store` (+1 read, +1 write, +1 TTL delete per send). Rule 1 (Snowflake) names posts and media; ADR-0021 already bent rule 4 the same way for scheduled posts. Record the choice.
- **A3. Conversation id.** 32 hex of SHA-256 over the sorted pair with a version prefix (default). Any group later gets a random 32-hex id and `kind = GROUP`.
- **A4. Push path.** A push-only `message` type in `notifications`:
  - no row and no `validateEvent` post requirement;
  - `ConversationID` on `Event` and the wire event (additive, `v` stays 1; an older revision drops an unknown type as invalid and acknowledges it);
  - the collapse key and Android tag `message` (type-level, as N-2; default) vs per conversation;
  - its own limiter bucket;
  - whether to skip the fresh actor and recipient profile reads (they protect row writes from the purge race, and a push-only event writes nothing): 3.5 → 1.5 reads per message.
- **A5. Badge.** `GetMeResponse.unread_conversation_count` (additive) through a consumer-side `identity.MessageBadge` interface implemented by messaging (the `BlockChecker` / `PinChecker` pattern), cached with the notifications count. Alternative: a separate `GetMessagingState` RPC (+1 request per app start).
- **A6. Text grammar.** Import the pure leaf `internal/posts/text` (`Normalize`) from messaging (default: its no-internal-imports guard exists so other modules can import it) vs promote it to `pkg/platform/text`. Either way the shared `testdata` fixtures stay the single grammar.
- **A7. Purge race.**
  - The eraser marks `gone` on each conversation first, and the send transaction reads that doc.
  - A new conversation re-reads the recipient's status fresh (`Directory.Forget` + read, +1 read, rare).
  - The residual window is documented.
  - Name the step's order relative to `notifications` and `identity`.
- **A8. Block freshness on send.** A cached recipient snapshot (60 s, default) vs a fresh read (+1 read per send, about +1.5 reads/DAU, about INR 0.5/month at 300 DAU). Security review W7-22 weighs in.
- **A9. Since-token settle window** (5 s) and token TTL (30 days): reuse the notifications codec.
- **A10. Report target.** `MESSAGE = 3`, `target_id = "<32 hex>:<32 hex>"`. Moderation reaches messaging only through a consumer-side `moderation.MessageLookup`. Add a dated ADR-0016 note: evidence may hold private message text, it carries the existing `expireAt` (resolved + 90 d), and the `reporterId` erasure applies.
- **A11. The `stage-ladder` row "Direct messages"** (the table in Scope) and `firestore-data-model` rows for the three collections, both edited in the ADR PR.

## Milestones
1. **M7.1 Contract:** W7-1 (ADR, accepted by your merge), W7-2 (proto), W7-3 (index exemptions, founder-gated).
2. **M7.2 Messaging backend:** W7-4 to W7-9 (W7-5 and W7-6 in one PR), then W7-27 (the ListMessages unread count, before W7-24). Flags off; dev check by allowlist.
3. **M7.3 Cross-module hooks:** W7-10 (push), W7-11 (badge), W7-12 (report).
4. **M7.4 Client:** W7-13 to W7-19.
5. **M7.5 Verify and roll:** W7-20 to W7-24. Dev allowlist only; prod waits for the held prod apply (`pending.md` 1.2) and your MVP launch decision.

| ID | Ticket | Owner | Size | Depends | Parallel with W3–W6? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W7-1 | ADR-0027 "Messaging v1: pull + push, no realtime, no E2E" | architect | M | — | **yes, start now** (new file) | Done: ADR-0027 accepted by the founder's merge of #400 (2026-10-28) |
| W7-2 | `proto/dzeroth/messaging/v1/messaging.proto` + additive fields (`GetMeResponse.unread_conversation_count`, `NotificationType` MESSAGE for push data, `REPORT_TARGET_TYPE_MESSAGE`) with per-RPC cost comments | architect | M | W7-1 drafted | new proto yes; the three additive edits serialise with W3-2 / W3-3 (identity, notifications) and any W5 report target | Done (#402): `GetMeResponse.unread_conversation_count = 7`, `NOTIFICATION_TYPE_MESSAGE = 9`, `REPORT_TARGET_TYPE_MESSAGE = 3`, `ERROR_REASON_CANNOT_MESSAGE = 18` |
| W7-3 | Index exemptions: six fieldOverrides in `firebase/firestore.indexes.json` + `firebase/field-overrides.ack`; `firestore-data-model` rows | architect | S | W7-1 drafted | **founder-gated files**; merge one wave's index PR at a time (W3-2, W4-9) | Done (#401): six exemptions, ack updated (42 overrides); the `firestore-data-model` rows came with ADR-0027 (#400) |
| W7-4 | `make proto`; `FEATURE_MESSAGING`, config, rate limits, `DailyCap`, quota fields, ceiling, Terraform vars; `internal/messaging` skeleton with flag-guarded handlers; wiring | backend-developer | M | W7-2 | logic yes; shared files serialise (`config.go`, `apiserver.go`, `ratelimit_config.go`, `quota.go`, `flag-ceiling.json`, Terraform vars) | Done (#412) |
| W7-5 | SendMessage: repo, conversation create, accepted / request / new paths, block, mute and flag rules, caps, `Emitter.Emit` | backend-developer | M | W7-4 | yes (messaging module only); **same PR as W7-6** | Done (#416) |
| W7-6 | Lifecycle: eraser step `messaging` (tombstone per F3), export section `messages` (F5), T11 guard rows, runbook `docs/runbooks/messaging.md` | backend-developer | M | W7-4 | lifecycle wiring in `apiserver.go` and `lifecycle_collections_guard_test.go` serialise with W3-32 and any W5/W6 eraser | Done (#416) |
| W7-7 | ListConversations (Inbox / Requests, `since`, request count, read-time block and mute rules) | backend-developer | M | W7-5 | yes | Done (#431) |
| W7-8 | ListMessages (page + `since`, `clearedAt`, participant check) and MarkConversationRead | backend-developer | M | W7-5 | yes | Done (#438) |
| W7-9 | AcceptMessageRequest and DeleteConversation | backend-developer | S | W7-5 | yes | Done (#443) |
| W7-10 | notifications: push-only `message` type, own limiter bucket, generic text, `conversationId` data; messaging Emit adapter | backend-developer | M | W7-4, W7-5 | `fanout.go` / `fcm.go` / `api.go` serialise with W3-31 (Part B notification types) | Done (#429) |
| W7-11 | identity: `GetMe.unread_conversation_count` via `identity.MessageBadge` | backend-developer | S | W7-4, W7-7 | `identity/service.go` and the `apiserver.go` wiring line serialise with W3-6 | Done (#437) |
| W7-12 | moderation: report a message (`MessageLookup`, evidence), `opsctl` message takedown, ADR-0016 dated note | backend-developer | M | W7-8 | `moderation` files; serialise with any W5 report target | Done (#445) |
| W7-13 | Client data layer: `MessagingRepository`, drift tables, `kFeatureMessaging`, `ThreadPoller` (pure, fake clock) | frontend-developer | M | poller: — ; repository: W7-4 | **poller yes, start now** | Done (#406, #413) |
| W7-14 | Inbox screen `/messages` (Inbox / Requests) | frontend-developer | M | W7-13 | yes | Done (#414) |
| W7-15 | Conversation screen `/messages/:id`: message list, polling, mark read, read-only states | frontend-developer | M | W7-13 | yes | Done (#421) |
| W7-16 | Conversation composer: send, optimistic bubble, retry with the same key, errors | frontend-developer | S | W7-15 | yes | Done (#426) |
| W7-17 | New-message flow `/messages/new` (people picker) + profile "Message" button | frontend-developer | M | W7-13; W3-14 for the profile button | picker yes; `profile_header.dart` after W3-14; W4 search optional | Done (#435) |
| W7-18 | Request actions (Accept / Delete / Block / Report) and the report-message sheet | frontend-developer | S | W7-14, W7-15 | yes | Done (#442) |
| W7-19 | Shell: Messages destination + badge cubit, push routing (`notificationLocation`), deep-link allowlist `/messages/<32 hex>`, foreground-push rules | frontend-developer | M | W7-14, W7-15 | **shared:** `main_shell.dart`, bar / rail / drawer, `app_router.dart`, `notification_location.dart` serialise with W4-17 and any W5/W6 nav or route change | Done (#441) |
| W7-20 | Backend tests: flag matrix, authz, block oracle, caps, budgets, eraser, export, push hook | tester | M | W7-5 to W7-12 | yes | In review (PR #453) |
| W7-21 | Client tests: responsive matrix, polling with a fake clock, flows, deep link | tester | S | W7-14 to W7-19 | yes | Done (#447) |
| W7-22 | Security review (mandatory: private content) | security-auditor | M | W7-5 to W7-12, W7-19 | yes | Done (#446) |
| W7-23 | Cost report: `cost-model.md` rows, emulator load smoke (polling and send burst), delivery-latency measurement, triggers | sre-performance | S | W7-8, W7-10 | yes | In review (PR #455) |
| W7-24 | Dev rollout: targeted Terraform plan, fieldOverrides deployed, allowlist, two-account smoke incl. Android push | production-deployer | S | W7-20, W7-22, W7-23, ADR merged | serialise dev applies with W3 / W4 rollouts | Open |
| W7-25 | Request state for the sender: the requester's pending request reads REQUEST in the Inbox list (follow-up from the PR #442 review) | architect, then backend-developer | S | W7-7, W7-9 | after W7-9 | Open |
| W7-26 | Client honours F6(a) for the clean-up RPCs when `messaging` is off for the caller only (follow-up from the PR #442 review) | architect, then frontend-developer | S | W7-14, W7-15 | yes | Open |
| W7-27 | ListMessages first page returns `unread_count` (so a cold-opened thread can mark itself read in the badge) | architect, then backend-developer | S | W7-8 | yes (messaging module and the proto comment only); **must land before W7-24** | In review (PR #459) |
| W7-28 | H-1: non-participant conversation-cache isolation (`conversationHit`), from the W7-22 review | backend-developer | S | — | yes (messaging only) | Done (#448) |
| W7-29 | M-1: daily caps for MarkConversationRead and Accept/Delete (`messages_mark_read_daily`, `messages_mutation_daily`) | backend-developer | S | — | yes (rate-limit config) | Done (#451) |
| W7-30 | M-2: frozen peer snapshot when the peer blocked the caller (thread header and export) | backend-developer | S | W7-27 | with W7-27 | In review (PR #459): thread header part; the export part stays Open |
| W7-31 | M-3: "Messages are not end-to-end encrypted" copy (Inbox, new message, request banner) | frontend-developer | XS | — | yes | Done (#450) |
| W7-32 | M-4: custom read role for the `tf-plan` CI identity (no `datastore.entities.*`) | production-deployer, founder decision | S | — | Terraform; founder-gated | Open |
| W7-33 | L-1 (A8) recipient graph read in the send transaction, L-3 `ProfileInTx` for the recipient, L-8 verified-email gate | architect (note), then backend-developer | S | — | messaging + graph seam | Open |
| W7-34 | L-2 erasure placeholder `_deleted` (+ dev migration), L-7 keyed `conversation_hash` and peer-uid redaction | backend-developer | S | — | messaging + logger | Open |
| W7-35 | L-4 owner-stamped drift wipe, L-5 Android backup exclusion, L-9 links in request threads | frontend-developer | S | — | yes | Open |
| W7-36 | L-6: open MESSAGE reports clear their copied text after 180 days even if untriaged (founder decision 2026-10-29) | backend-developer | S | — | moderation only | Open |

Order:
1. W7-1, then W7-2 ‖ W7-3.
2. W7-4.
3. W7-5 + W7-6 (one PR), then W7-7 ‖ W7-8 ‖ W7-9 ‖ W7-10 ‖ W7-11, then W7-12.
4. Client: W7-13's poller at once; the rest of W7-13 after W7-4; then W7-14 ‖ W7-15 ‖ W7-17, then W7-16, W7-18 and W7-19.
5. W7-20 to W7-24, with W7-22 and W7-23 done before the flag leaves `off` in dev.

**Can start right away (no dependency, new files only):**
- W7-1 (ADR);
- W7-3's draft (it merges after the ADR);
- W7-13's `ThreadPoller` (a pure Dart class with tests);
- the X capture session (optional, yours).

**Shared files that must serialise (one PR at a time; the second merges `origin/main`):**
| Shared file | W7 ticket | Also touched by |
|---|---|---|
| `backend/pkg/platform/config/config.go`, flag registry in `apiserver.go`, `ratelimit_config.go`, `quota/quota.go`, Terraform `feature_*` vars, `scripts/promotion/flag-ceiling.json` (**gate**) | W7-4 | W3-4, W3-25, W4-3, W5/W6 flag tickets |
| `firebase/firestore.indexes.json`, `firebase/field-overrides.ack` (**gate**) | W7-3 | W3-2, W4-9 |
| `backend/internal/notifications/{api,fanout,fcm}.go` (send path) | W7-10 | W3-31 |
| `backend/internal/identity/service.go` (GetMe), `identity/api.go` | W7-11 | W3-6, W4-4, W4-11 |
| `backend/internal/apiserver/apiserver.go` lifecycle step registration, `lifecycle_collections_guard_test.go` | W7-6 | W3-32, W5/W6 erasers |
| `proto/dzeroth/{identity,notifications,moderation}/v1/*.proto`, and `proto/dzeroth/common/v1/common.proto` if a new `ErrorReason` is needed | W7-2 | W3-2, W3-3, W4-2, W5 (community reports) |
| `app/lib/core/router/main_shell.dart`, `app_bottom_bar.dart`, rail, `app_drawer.dart` (nav and badge) | W7-19 | W4-17, W5 Lists |
| `app/lib/core/router/app_router.dart` (routes and the `deepLinkTarget` allowlist) | W7-19 (and W7-14/15/17 add routes through it) | W3-18, W4-15/17 |
| `app/lib/features/notifications/domain/notification_location.dart`, `PushCubit` | W7-19 | W3-33 (Part B types) |
| `app/lib/features/profile/presentation/widgets/profile_header.dart` | W7-17 | W3-13, W3-14, W4 (B-04) |
| `app/lib/core/storage/app_database.dart` (schema version bump) | W7-13 | any wave adding drift tables |

**Definition of done per ticket:**
- Backend: Go unit tests plus emulator integration (`make test-int`, `budgettest.Assert` on every RPC).
- Client: widget tests in light and dark at 360 / 600 / 1200 via `test/support/theme_harness.dart`, and text scale 1.0 / 1.3 / 2.0, for every new screen or widget. Pixel goldens deferred (B-01).
- `make ci` green.
- `docs/code-map.md` / `docs/ui-catalog.md` updated.
- This table's Status and `docs/pending.md` row 3.16 updated in the PR.

## Tickets

### W7-1 — ADR "Messaging v1"  [owner: architect] [size: M] [depends: —]  Status: Done (ADR-0027, accepted 2026-10-28, #400)
- **Description.** ADR-0027: the highest existing was 0026 (the W8 shells took it, not W4), so W7 takes 0027 and W5 and W6 take the next free numbers when theirs open. It decides:
  - the data model (A1, the table above), message and conversation ids (A2, A3);
  - the delivery model: pull, the poll intervals, the `since` codec (A9), the push-only type (A4);
  - the who-can-message rules and caps (F2), block, mute and read rules (F9, A8);
  - the badge (A5), the grammar reuse (A6), the purge race and eraser (A7, F3), the export (F5);
  - the report target (A10, F11);
  - the flag semantics (F6), the per-RPC budget table, the stage-ladder row and triggers (A11);
  - **why no E2E** (the Scope table: key management, moderation, attachments, search and export) and **why no realtime** (Cloud Run bills held connections; client listeners need a rules ADR).

  In the same PR:
  - the `stage-ladder` "Direct messages" row;
  - `firestore-data-model` rows;
  - a dated note on ADR-0017 (D2 and D6: a push-only `message` type writes no row, its text is generic, D11 unchanged);
  - a dated note on ADR-0016 (message evidence), unless W7-12 carries it.
- **Acceptance criteria.**
  - Given the ADR, when you read it, then F1–F11 each have options, a default and an INR line at 300 / 1,000 / 3,000 DAU that cites `cost-model.md`.
  - Given the data model, then it states "no composite index" and names the fieldOverrides and the two gate files.
  - Given the stage ladder, then each Stage 2/3 target has a measured trigger and a seam.
- **Test notes.** None (docs). `code-reviewer` checks the seam and trigger lines.
- **Observability.** The ADR lists the log fields (`conversation_hash`, `kind`, `state`, `results`, `refused_reason`, `fs_reads`, `fs_writes`, `poll`, `push_throttled`).
- **Budget.** Its table is the source for W7-5 to W7-12.
- **Flag.** None (docs); it names `FEATURE_MESSAGING` and its dev ceiling.
- **Seam.** It defines `messaging.Service` (Send, ListConversations, ListMessages, MarkRead, Accept, Delete), `messaging.Eraser`, `messaging.Exporter`, `identity.MessageBadge`, `moderation.MessageLookup` and `notifications.Event.ConversationID`.
- **Done in the ADR PR (2026-10-28).** ADR-0027 records F1–F11 (all defaults) and decides A1–A11 at this plan's defaults, with this plan's cost figures unchanged (about INR 12 / 58 / 480 a month at 300 / 1,000 / 3,000 DAU; writes free to about 509 DAU). Same PR: the `stage-ladder` "Direct messages" rows, the `firestore-data-model` rows, and the dated notes on ADR-0016 and ADR-0017 (so W7-12 needs no ADR-0016 note).

### W7-2 — Proto `dzeroth.messaging.v1` and additive fields  [owner: architect] [size: M] [depends: W7-1 drafted]  Status: Done (#402)
- **Description.**
  - **New `proto/dzeroth/messaging/v1/messaging.proto`**, with `MessagingService`:
    - `SendMessage(idempotency_key, oneof {conversation_id, recipient_user_id}, text)` → `Message`, `Conversation`;
    - `ListConversations(folder INBOX|REQUESTS, page_size 0→20 max 50, page_token, since_token)` → `repeated Conversation`, `next_page_token`, `since_token`, `request_count`. `NO_SIDE_EFFECTS`;
    - `ListMessages(conversation_id, page_size 0→20 max 50, page_token, since_token)` → `repeated Message` (newest first), `conversation` (set on a first or older page, **unset on a `since` response** so a poll reads no peer profile or graph), `next_page_token`, `since_token`, `gap_page_token`. `NO_SIDE_EFFECTS`;
    - `MarkConversationRead(idempotency_key, conversation_id)`;
    - `AcceptMessageRequest(idempotency_key, conversation_id)`;
    - `DeleteConversation(idempotency_key, conversation_id)`.
  - **Messages:**
    - `Conversation {id, kind, peer (common.AuthorSnapshot), state, folder, last_message (snippet, from_self, state, created_at), unread_count, can_reply, silent, updated_at}`;
    - `Message {id, conversation_id, from_self, text, state, created_at}`. The message carries no sender uid, only `from_self`; the peer is on `Conversation`;
    - an enum `MessageState {VISIBLE, DELETED_ACCOUNT, REMOVED}`;
    - a reserved number for future media (F1).
  - **Error contract:**
    - VALIDATION `field=text|conversation_id|recipient_user_id|page_token|since_token|idempotency_key`;
    - `FEATURE_DISABLED feature=messaging`;
    - NOT_FOUND (one message);
    - FAILED_PRECONDITION `ERROR_REASON_CANNOT_MESSAGE` (one reason for blocked / recipient off / gone / not ACTIVE) and `ERROR_REASON_LIMIT_REACHED` with `limit_name=request_unanswered|dm_new_daily`;
    - RATE_LIMITED.

    If a new `ErrorReason` value is needed, it is additive in `common.proto`.
  - **Additive edits:**
    - `identity.proto` `GetMeResponse.unread_conversation_count` at the next free number when the PR opens (7 today: W3-25a took 6 for `pending_follow_request_count`, and W5-2's `home_tabs` may take 7 first). The GetMe cost comment, "reads 2/1 (+1 for a protected caller, cached 30 s)" since W3-25a, gains "+1 `count()` of unread conversations with `messaging` on, cached 30 s", and the `cost-model.md` GetMe row with it (W7-23);
    - `notifications.proto` `NOTIFICATION_TYPE_MESSAGE` at the next free number when the PR opens (9 today: W3-25a took 7 and 8 for `FOLLOW_REQUEST` and `FOLLOW_ACCEPTED`), push data only and never in ListNotifications (comment);
    - `moderation.proto` `REPORT_TARGET_TYPE_MESSAGE = 3`, with the target-id shape in the comment.

  Every RPC comment carries its reads and writes from W7-1. `buf lint` and `buf breaking` are clean.
- **Acceptance criteria.**
  - Given `make proto`, then Go and Dart code generates.
  - Given `buf breaking` against `main`, then no break.
  - Given the comments, then each RPC states worst and planning reads, writes, caps and the flag rule (per caller vs not globally off).
- **Test notes.** `buf breaking`; a golden check that `NOTIFICATION_TYPE_MESSAGE` is documented as never listed.
- **Observability.** —
- **Budget.** Copied from W7-1.
- **Flag.** None (contract); the comments name `messaging`.
- **Seam.** Opaque tokens and ids; `ConversationKind` and `MessageState` are enums (additive); `from_self` keeps uids off the wire.

### W7-3 — Index exemptions (founder-gated)  [owner: architect] [size: S] [depends: W7-1 drafted]  Status: Done (#401)
- **Description.**
  - fieldOverrides `indexes: []` at COLLECTION scope for `messages.text`, `messages.requestHash`, `dmInbox.peer`, `dmInbox.last`, `dmRequests.peer`, `dmRequests.last`.
  - The `firebase/field-overrides.ack` hash is regenerated by the repo's ack step.
  - **No composite index.**
  - `firestore-data-model` rows for the three collections and the query list.
  - **Both files need your review (CODEOWNERS).**
- **Acceptance criteria.**
  - Given the promotion validators, then the fieldOverrides acknowledgement check passes.
  - Given the emulator, then the thread, inbox, requests, badge `count()` and eraser queries run with no "index required" error (W7-5 confirms).
- **Test notes.** The `scripts/promotion` fieldOverrides check; a JSON lint.
- **Observability.** —
- **Budget.** 0 reads; it saves index writes per message.
- **Flag.** None (deployed with `firebase deploy --only firestore:indexes` by the dev deploy; prod with the held release, before `messaging` leaves `off` there).
- **Seam.** No query depends on an exempted field.

### W7-4 — Generate, flag, config, module skeleton  [owner: backend-developer] [size: M] [depends: W7-2]  Status: Done (#412)
- **Description.**
  - `make proto` (generated Go and Dart committed).
  - Register `FEATURE_MESSAGING` in `config.go` and `flags.NewRegistry` (follow `FEATURE_BOOKMARKS`).
  - Add the config values with bounds and their `config_test.go` env list entries: `RATE_LIMIT_MESSAGES_SEND_PER_MIN` 20, `MESSAGES_SENDS_PER_DAY` 300 / new 50, `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY` 20 / new 5, `MESSAGES_REQUEST_MAX_UNANSWERED` 3, `RATE_LIMIT_MESSAGES_READ_PER_MIN` 30, `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` 20, `CACHE_MESSAGING_CONVERSATION_ENTRIES` 5,000.
  - The `quota.Record.DMNew` field with its `valueFor` / `increment` cases (ADR-0021 I-3: `CheckAndReserveN` `Set`s the whole record).
  - `ratelimit_config.go` mappings.
  - `flag-ceiling.json` `MESSAGING` dev allowlist 3 (**founder-gated**).
  - Terraform vars in `envs/dev` and `envs/prod`, default `off`, not applied.
  - `internal/messaging` with `api.go` (interfaces), a Connect server whose six handlers check the flag (per caller or `GloballyOff` per F6) and return Unimplemented, and the wiring in `apiserver.Build`.
- **Acceptance criteria.**
  - Given `FEATURE_MESSAGING` unset, when any RPC is called, then FAILED_PRECONDITION `FEATURE_DISABLED feature=messaging` with 0 reads.
  - Given an allowlisted uid, then `GetMe.enabled_features` contains `messaging` for that uid only.
  - Given allowlist mode and a caller outside it, then ListConversations reaches Unimplemented (not globally off), while SendMessage is FEATURE_DISABLED.
  - `check-flag-registry.sh` passes; the guard test sees every RPC in the read budget.
- **Test notes.** Flag modes off / allowlist / percent / on per RPC class; config bounds (reject 0 and negatives); the quota record round trip.
- **Observability.** The startup `feature_flags` line lists `messaging`.
- **Budget.** 0 reads on rejection paths.
- **Flag.** Adds `FEATURE_MESSAGING` (default `off`; dev ceiling allowlist 3).
- **Seam.** Handlers call only `messaging.Service`; the flag check lives in the service layer (`flags.Guard`), so a later split keeps it.

### W7-5 — SendMessage  [owner: backend-developer] [size: M] [depends: W7-4]  Status: Done (#416)
- **Description.** `messaging.Service.Send`, step by step:
  1. Validate the key (≤ 64), the target, and the text (`text.Normalize`, A6; 0 reads on rejection). Apply the per-minute limit and `messages_daily`.
  2. Resolve the conversation. For `recipient_user_id`: self → VALIDATION; compute `convId`. For `conversation_id`: the participant check against the cached conversation doc.
  3. Read the caller graph and the recipient graph (cached).
     - Either side blocks the other → `CANNOT_MESSAGE`.
     - The recipient muted the caller → silent.
     - The recipient follows the caller and the caller follows the recipient → mutual.
  4. The recipient must be ACTIVE, with `messaging` on for them (F6). Otherwise `CANNOT_MESSAGE`, with the same bytes as for a block.
  5. **Transaction:**
     - read `conversations/{convId}`; `gone` → `CANNOT_MESSAGE`;
     - if missing: create it (`ACCEPTED` if mutual, else `REQUEST` with `requestFrom` / `requestTo`), after a fresh recipient status read (A7) and `quotas.dmNew` (`CheckAndReserve`);
     - if `REQUEST` and the caller is `requestFrom`: `requestCount < MAX` or `LIMIT_REACHED request_unanswered`, then +1;
     - if `REQUEST` and the caller is `requestTo`: sending a reply accepts it (as X does);
     - `Create` the message (deterministic id; AlreadyExists at commit → replay, read and return it; a different `requestHash` → VALIDATION `idempotency_key`);
     - set the sender's `dmInbox` entry: last, `lastMessageAt`, peer snapshot, `unreadCount` unchanged;
     - set the recipient's entry in `dmInbox` (accepted) or `dmRequests` (request): last, `lastMessageAt`, the caller's snapshot, `unreadCount` `Increment(1)` unless silent.
  6. After the commit, call `Emitter.Emit(message, actor = caller, recipient, conversationId)` only when the recipient side is accepted and not silent (F7); a request never pushes.
  7. Evict the badge cache for both participants on this instance.

  Emulator check first: the thread, inbox and badge queries need no composite index. If one does, stop and return to the architect (gate file).
- **Acceptance criteria.**
  - Given mutual follows, when A sends to B, then B's `dmInbox` entry exists with `unreadCount` 1 and one `message` event is emitted.
  - Given non-mutuals, then B's entry is in `dmRequests` and no event is emitted.
  - The 4th request message → `LIMIT_REACHED request_unanswered`.
  - The 21st new conversation in a day → `LIMIT_REACHED dm_new_daily` (5 for a new account).
  - B blocks A: A's send → `CANNOT_MESSAGE`, with response bytes identical to a send to a deleted account and to a recipient with `messaging` off.
  - B muted A: delivered, `silent`, no unread increment, no event.
  - The same key twice: one message, the second call returns it with 0 writes.
  - The same key with other text → VALIDATION.
  - A `gone` conversation → `CANNOT_MESSAGE`.
  - `DEGRADED_MODE=readonly` → refused by the interceptor.
- **Test notes.** Flag matrix (caller and recipient); `budgettest` 5 / 7 cold, planning 2.5; writes 3 / 4 / 5; replay; concurrency (two senders on one new conversation create one conversation doc); a fuzz test of the text through the shared fixtures.
- **Observability.** One slog line: `kind=send`, `conversation_hash`, `state` (accepted / request / new), `refused_reason`, `silent`, `fs_reads`, `fs_writes`, `uid_hash`. **Never the text or the peer uid.** Error Reporting on internal errors.
- **Budget.** Reads 5 / 7 worst, 2.5 planning; writes 3 (accepted), 4 (request), 5 (new); 0 deletes.
- **Flag.** `messaging`, per caller and per recipient (F6).
- **Seam.** `messaging.Service.Send`; the push leaves only through `notifications.Emitter` (`stage-ladder` Real-time seam); inbox entries sit behind a repo interface, so a group fan-out or a listener-backed store changes no caller.

### W7-6 — Messaging lifecycle: eraser, export, guard rows, runbook  [owner: backend-developer] [size: M] [depends: W7-4]  Status: Done (#416)
- **Description.**
  - **`messaging.Eraser` step `messaging`.** It is resumable, registered before `identity` (the order relative to `notifications` per A7), with pages ≤ 500 and a checkpoint (conversation cursor, phase).
    1. Page `conversations where participants array-contains uid`. For each conversation: set `gone += uid` (1 write).
    2. Tombstone the user's messages (`senderId == uid`; text cleared, `state = DELETED_ACCOUNT`), or delete them if F3 = erase.
    3. Rewrite the peer's entry (snapshot → "Deleted account" placeholder, snippet → "Message deleted" when the last message was the user's).
    4. Delete the user's own `dmInbox` / `dmRequests` entries. Delete the whole conversation tree when both participants are gone.
  - **Export section `messages`** (F5): per conversation, the peer handle at export time, state and timestamps; own messages with text; received messages as time + "received" (or full text if F5 = both sides). Newest first, appended after `bookmarks`.
  - **`lifecycle_collections_guard_test.go` rows:** `conversations`, `messages` (Sub), `dmInbox` (Sub), `dmRequests` (Sub), all `erasedByStep: messaging`, sections `messages`; `quotas.dmNew` is covered by the existing `quotas` row.
  - **Runbook `docs/runbooks/messaging.md`:**
    - kill switch semantics;
    - a stuck eraser step;
    - the abuse levers (caps, `opsctl` takedown);
    - the polling cost trigger and how to read it;
    - how to test push in dev.
- **Acceptance criteria.**
  - Given A (deleted) and B with 5 messages each, when the step runs, then B's thread shows A's 5 as `DELETED_ACCOUNT` with empty text, B's 5 intact, B's entry reads "Deleted account", A's entries are gone, and a send by B → `CANNOT_MESSAGE`.
  - Given both deleted, then no doc remains under `conversations/{convId}`.
  - Given a crash at every page boundary, then a re-run completes with no duplicate or missing work (the existing crash harness).
  - Given an export, then the section matches the golden file, and contains no peer uid and no received text (default F5).
  - The guard test passes and fails if any of the four rows is removed.
- **Test notes.** Emulator integration with the lifecycle crash harness (`lifecycle_crash_test.go` pattern); `budgettest` per page; the export golden.
- **Observability.** The existing `account_job` line with `step=messaging`, `conversations`, `messages_tombstoned`, `entries_deleted`; no uid of the peer.
- **Budget.** The reference account (20 conversations, 300 own messages): about 340 reads, 340 writes, 20 deletes; the export about 620 reads.
- **Flag.** Never flag-gated (right to delete, ADR-0011).
- **Seam.** `messaging.Eraser` / `messaging.Exporter` behind identity's `StepEraser` and exporter interfaces.

### W7-7 — ListConversations  [owner: backend-developer] [size: M] [depends: W7-5]  Status: Done (#431)
- **Description.**
  - The folder INBOX or REQUESTS from the caller's own subcollection (the path comes from the token uid; no user id parameter).
  - `lastMessageAt DESC, __name__ DESC`, Limit; a `since` refresh with a 5 s settle; sealed tokens bound to `(uid, folder)`.
  - Read-time rules from the caller graph (cached): REQUESTS drops entries whose peer the caller blocks or mutes, or who blocks the caller; INBOX keeps every entry with `can_reply = false` when either side blocks; `silent` comes from the entry.
  - `request_count` = `count()` on `dmRequests` (first INBOX page only).
  - `next_page_token` follows the query, not the filtered count.
- **Acceptance criteria.**
  - Given 25 conversations, then pages of 20 + 5, newest activity first.
  - Given a `since` token and 1 new message, then exactly that entry returns.
  - Given a request from a blocked account, then it is absent and the token still advances.
  - Given a foreign or tampered token, then VALIDATION with 0 reads.
  - Given `messaging` allowlist-off for the caller (not globally off), then the list still works.
- **Test notes.** `budgettest` 23 cold first page, 3 refresh; the block and mute matrix; token binding.
- **Observability.** `kind=list_conversations`, `folder`, `results`, `dropped` by cause, `fs_reads`.
- **Budget.** 23 worst / 9 planning cold page; 2 refresh; writes 0.
- **Flag.** Not globally off (F6).
- **Seam.** `messaging.Service.ListConversations`; the folder is an enum, so an "archived" folder is additive.
- **Built (note added with W7-18, PR #442).** `conversationOf` derives the state from the folder (the entry holds none, and a conversation read per row would break the budget): `dmRequests` is REQUEST, `dmInbox` is ACCEPTED. So a sender's own pending request, which lives in their `dmInbox`, reads ACCEPTED in their Inbox list. `ListMessages.conversation` (W7-8) does carry REQUEST with folder INBOX for the sender, on a first or older page only. Tracked as W7-25.

### W7-8 — ListMessages and MarkConversationRead  [owner: backend-developer] [size: M] [depends: W7-5]  Status: Done (#438)
- **Description.**
  - **ListMessages.**
    - The participant check (conversation doc, per-instance cache 60 s; NOT_FOUND byte-identical for unknown, malformed-after-validation and non-participant).
    - Messages `createdAt DESC, __name__ DESC`, Limit, excluding `createdAt <= clearedAt[caller]`.
    - A `since` refresh with a 5 s settle window and `gap_page_token` when a refresh page is full (ADR-0017 contract).
    - Tombstones return with empty text and their state.
    - On a first or older page, `conversation` carries the live peer snapshot (`Directory`, 60 s) and `can_reply` (caller graph, 60 s). A `since` response leaves it unset, so a poll reads neither.
  - **MarkConversationRead.** A field update of the caller's entry (`unreadCount = 0`, `lastReadAt = now`) with an `Exists` precondition (0 reads), and badge cache eviction on this instance. A missing entry → success, 0 writes.
  - A per-uid read limiter (`RATE_LIMIT_MESSAGES_READ_PER_MIN`) covers the polls.
- **Acceptance criteria.**
  - Given 45 messages, then 20 / 20 / 5.
  - Given a poll with 0 new, then 1 query read (+ the interceptor and conversation doc when cold).
  - Given a non-participant, then the same bytes as an unknown id.
  - Given `clearedAt` set, then older messages are not returned.
  - Given 31 polls in a minute, then RATE_LIMITED.
  - Given MarkConversationRead, then the badge `count()` drops on the next GetMe from this instance.
- **Test notes.** `budgettest` 24 / 54 cold, 3 poll cold, 1.2 planning; settle-window duplicate delivery (the client dedupes by id); a tombstone render.
- **Observability.** `kind=list_messages|poll`, `results`, `fs_reads`, `cache_hit`; `kind=mark_read`, `fs_writes`.
- **Budget.** As the per-RPC table; mark-read 1 write.
- **Flag.** Not globally off (F6).
- **Seam.** `ListMessages(since_token)` is the one delivery seam a listener or SSE replaces (`stage-ladder`).

### W7-9 — AcceptMessageRequest and DeleteConversation  [owner: backend-developer] [size: S] [depends: W7-5]  Status: Done (#443)
- **Description.**
  - **Accept** (the `requestTo` side only): the transaction sets `state = ACCEPTED`, moves the entry `dmRequests` → `dmInbox` (create + delete), keeps `unreadCount`, emits nothing. Already accepted → success, 0 writes.
  - **DeleteConversation:** deletes the caller's entry (either folder) and sets `clearedAt[caller] = now`. A request deleted this way stays a REQUEST for the sender, whose cap still applies. A later message recreates the caller's entry showing only newer messages.
  - Per caller for Accept, not globally off for Delete (F6).
- **Acceptance criteria.**
  - Given B accepts, then both see the conversation in Inbox and B's next reply pushes to A.
  - Given A calls Accept on its own request, then NOT_FOUND.
  - Given B deletes, then B's inbox lacks it, and A's next message (if under the cap) re-creates B's request entry with only that message visible.
- **Test notes.** `budgettest` 3 / 2 writes / 1 delete; replay; races (accept vs delete).
- **Observability.** `kind=accept|delete`, `fs_writes`, `fs_deletes`.
- **Budget.** Reads ≤ 3; writes 2 / 1; deletes 1.
- **Flag.** Accept per caller; Delete not globally off.
- **Seam.** `messaging.Service`.

### W7-10 — Notifications hook: push-only `message` type  [owner: backend-developer] [size: M] [depends: W7-4, W7-5]  Status: Done (#429)
- **Description.**
  - `notifications.TypeMessage` (`"message"`). `Event.ConversationID` and `wireEvent.conversationId` are additive, and `v` stays 1. `validateEvent` requires a 32-hex conversation id and no post for this type.
  - `Fanout.Deliver` for `message`:
    - no `Repo.Create`, no `ForgetUnread`;
    - D5 suppression unchanged (recipient blocks / mutes / is blocked by the actor);
    - the recipient needs `notifications` **and** `messaging`;
    - its own `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` limiter bucket (keyed `uid|message`).
    - Per A4: skip the fresh profile `GetAll` for push-only events, or keep it.
  - `pushText(message)` = "New message" / "You have a new message"; the collapse key and tag per A4 (default `message`); `data` = `type`, `conversationId` (no actor id, no post).
  - A redelivery sends at most one more push (collapsed on the device).
  - The messaging adapter in `apiserver` implements messaging's `Pusher` over `notifications.Emitter`. `ListNotifications` never returns a `message` row (none exists).
- **Acceptance criteria.**
  - Given a `message` event, then 0 notification rows, 1 FCM send per registered device, and `pushed=1`.
  - Given the recipient muted the actor, then `suppressed=1`, no send.
  - Given 21 message pushes in an hour, then the 21st is `push_throttled` while like or follow pushes still go out.
  - Given an older revision receiving the event, then it is dropped and acknowledged (`unknown_type`) with no error.
  - The FCM payload contains no handle, text or uid (a payload golden test).
- **Test notes.** Fanout unit tests with fakes; the `buildMessage` golden; emulator delivery via the inline path; the flag matrix (`notifications` × `messaging`).
- **Observability.** The existing `notification_delivery` line with `type=message`; `push_throttled`.
- **Budget.** 3.5 planning / 9 worst reads, 0 writes per message (1.5 if A4 skips the profile reads).
- **Flag.** `notifications` + `messaging` for the recipient.
- **Seam.** `notifications.Emitter` stays the only push path (`stage-ladder` Real-time).

### W7-11 — GetMe unread conversations badge  [owner: backend-developer] [size: S] [depends: W7-4, W7-7]  Status: Done (#437)
- **Description.**
  - A consumer-side `identity.MessageBadge` interface (`UnreadConversations(ctx, uid) (int64, error)`), implemented by messaging as a `count()` of `users/{uid}/dmInbox where unreadCount > 0`, Limit 100.
  - The result is cached 30 s in identity's cache next to the notifications count.
  - `GetMe` fills `unread_conversation_count` only when `messaging` is on for the caller (0 reads otherwise).
  - messaging calls `Directory.ForgetUnread`-style eviction for the badge after a send and a mark-read.
  - Wiring in `apiserver.go` (`identity.WithMessageBadge`).
- **Acceptance criteria.**
  - Given 3 unread conversations, then 3.
  - Given 150, then 100 (the cap; the client shows "99+").
  - Given the flag off, then 0 and 0 extra reads.
  - Given a mark-read on this instance, then the next GetMe recounts.
- **Test notes.** Unit tests with a fake badge; `budgettest` GetMe 3 cold (was 2).
- **Observability.** `unread_conversations_cache_hit` on the GetMe line.
- **Budget.** +1 read on a cache miss.
- **Flag.** `messaging` per caller.
- **Seam.** `identity.MessageBadge`: identity never imports messaging.

### W7-12 — Report a message  [owner: backend-developer] [size: M] [depends: W7-8]  Status: Done (#445)
- **Description.**
  - `ReportContent(target_type = MESSAGE, target_id = "<convId>:<msgId>")`. The moderation module asks a consumer-side `moderation.MessageLookup` (implemented by messaging) whether the caller is a participant and the message is the peer's and VISIBLE, and gets the evidence `{text, senderHandle, createdAt}`.
  - Otherwise NOT_FOUND (one message); your own message → VALIDATION `target_id`.
  - Quotas and duplicates as today.
  - `opsctl reports` shows MESSAGE targets.
  - `opsctl messages takedown <convId:msgId>` tombstones a message (`REMOVED`, text cleared, the peer entry snippet updated) with the usual confirmation prompt.
  - A dated note on ADR-0016: private message text may be copied as evidence and is kept until resolved + 90 d. `reporterId` erasure is unchanged.
- **Acceptance criteria.**
  - Given B reports A's message, then a report with that message's text exists and `already_reported` on a repeat.
  - Given a non-participant reporting by guessing ids, then NOT_FOUND, with the same bytes as an unknown message.
  - Given a takedown, then both participants see "This message was removed".
- **Test notes.** `budgettest` 6 cold; participant matrix; `opsctl` dry-run test.
- **Observability.** The existing report line with `target_type=MESSAGE` (no text); the `opsctl` audit line.
- **Budget.** Reads 6 / 3; writes 2.
- **Flag.** `reports` (existing) + `messaging` not globally off.
- **Seam.** `moderation.MessageLookup`: moderation never reads `conversations` directly.
- **Built (PR #445, 2026-10-29).**
  - Report: `MessageLookup` is implemented by `messaging.ReportableMessage` and bound in `apiserver` by `lateMessageLookup`. Measured: 6 reads cold / 3 warm / 2 writes; a repeat at most 5 reads (2 warm); a refusal 2 or 3 cold. One NOT_FOUND for every cause, asserted byte for byte through the real chain. Founder-confirmed: a sender who is no longer ACTIVE, a message after delete-for-me and a blocked peer's message stay reportable; a takedown cannot be undone.
  - Takedown (`opsctl messages takedown`): 4 reads, 4 writes. Review fix B1 (ADR-0027 note 2026-10-29): it also bumps `conversations.rev`, sets `messages.removedAt` and each rewritten entry's `changedAt`, so devices that cached the thread or the inbox converge (thread `since_token` retired after at most 2 reads; inbox `since` now orders by `changedAt`, binding kind `since-changed`). The eraser's `RewriteConversation` / `MarkGone` and Accept carry `rev` / `changedAt` at +0 reads, +0 writes. Deferred: mark-read and delete-for-me on the user's other devices.
  - Owed before W7-24: one dev-Firestore run of the `changedAt DESC, __name__ DESC` + `EndBefore` query (the emulator does not enforce indexes).

### W7-13 — Client data layer  [owner: frontend-developer] [size: M] [depends: — (poller); W7-4 (repository)]  Status: Done (#406, #413)
- **Description.**
  - **`ThreadPoller`** (pure Dart, injectable clock):
    - 15 s while hot (input or a new message within 2 min), 45 s while warm, stop after 5 min idle;
    - paused while the app or tab is hidden (`AppLifecycleState`, `visibilitychange` on web);
    - an immediate pull on a push for that conversation or on resume;
    - an Android hot interval of 30 s when push is registered;
    - stops while the shared `RateLimitHold` is set.
  - **`MessagingRepository`** over the generated client:
    - through a `messaging` `ServiceFeatureGate` that distinguishes per-caller sends from not-globally-off reads (F6);
    - friendly mapping of `CANNOT_MESSAGE`, `LIMIT_REACHED`, RATE_LIMITED, FEATURE_DISABLED and degraded mode.
  - **Drift tables** `ConversationEntries`, `MessageEntries` (the newest 200 per conversation), `MessagingStateEntries` (tokens) in `AppDatabase`, with a schema bump. They are written under `SessionEpoch` and wiped by `clearAll` on sign-out.
  - `kFeatureMessaging`.
- **Acceptance criteria.**
  - Given a fake clock, then the poll schedule is 15 s → 45 s → stop at 5 min, and a hidden app sends 0 polls.
  - Given RATE_LIMITED, then polling holds until the hold clears.
  - Given sign-out, then no message or conversation row remains.
  - Given a `since` response with a duplicate id, then one row.
- **Test notes.** Unit tests only (fake clock, fake repository, in-memory drift).
- **Observability.** Crashlytics non-fatal on unexpected errors via `UnexpectedErrorReporter` (never message text).
- **Budget.** The poll schedule bounds the 5 polls/DAU of the cost table.
- **Flag.** `messaging` (client gate).
- **Seam.** `ThreadPoller` behind an interface, so a listener or SSE client later replaces it without touching screens; `MessagingRepository` is the only RPC caller.

### W7-14 — Inbox screen  [owner: frontend-developer] [size: M] [depends: W7-13]  Status: Done (#414)
- **Description.**
  - `/messages`: `AppTopBar` "Messages" with a "New message" action (envelope-plus icon).
  - A "Message requests" row with its count when > 0, opening the Requests folder (`/messages/requests`).
  - Conversation rows: a **`ConversationRow`** built on `UserListRow` (component row 17: 48 dp avatar, bold name, muted handle and relative time, snippet on the second line with the "You: " prefix for own messages, unread = bold snippet + accent dot + spoken "unread", a muted marker for `silent`, 72 dp pitch, no dividers).
  - Pull-to-refresh with `since`, prefetch paging, `AppEmptyView` ("Welcome to your inbox" / "Start a conversation", our own copy).
  - Desktop ≥ 1200: list in the main column (master-detail is out of scope for v1).
  - It refreshes on open, on resume and on a message push; no periodic poll.
- **Capture.** The inbox is A11Y only (listbox, preview prefixes, muted marker); the visuals are X-like defaults.
- **Acceptance criteria.**
  - Given cached conversations, then they render before the network answers.
  - Given an unread conversation, then bold + dot + "unread" in semantics.
  - Given `messaging` off for everyone, then the route redirects Home.
  - Given requests, then the row shows "Message requests (2)".
- **Test notes.** Widget tests 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0; listbox semantics.
- **Observability.** —
- **Budget.** 2 ListConversations per DAU (cost table).
- **Flag.** `messaging` (route); `ui_shell` for the shell placement.
- **Seam.** `ConversationsCubit` over `MessagingRepository`; `ConversationRow` is presentational (added to `docs/ui-catalog.md`).

### W7-15 — Conversation screen  [owner: frontend-developer] [size: M] [depends: W7-13]  Status: Done (#421)
- **Description.**
  - `/messages/:id`: an `AppBackHeader` with the peer avatar, name and handle (tap → profile) and an info action (Block, Report conversation peer, Delete conversation).
  - The messages list is reversed (newest at the bottom), with bubbles: own on the accent `#1d9bf0` with white text, the peer's on the raised surface; grouped by sender with a time under the last of a group; day separators. Links use `parsePostText` link spans only.
  - Tombstones are italic muted ("Message deleted" / "This message was removed").
  - Older pages load on scroll to the top. `ThreadPoller` runs while visible. MarkConversationRead runs on open and on new messages while visible, only when unread > 0.
  - Read-only states replace the composer: "You can't reply to this conversation" (blocked either way, gone) or the request banner (W7-18).
- **Capture.** **The conversation view is NOT VERIFIED (UNKNOWN).** Bubble shape, colours, grouping and timestamps are X-like defaults with our own copy; the founder's capture may adjust them.
- **Acceptance criteria.**
  - Given 45 messages, then the newest 20 show and scrolling up loads more.
  - Given a poll with a new message, then it appears without a jump if the user is at the bottom, otherwise as a "New messages" pill.
  - Given the app hidden, then 0 polls.
  - Given `can_reply = false`, then no composer and the explanatory line.
  - Given a deep link to a conversation the caller is not in, then "This conversation isn't available".
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales; a poller integration with a fake clock; semantics (each bubble reads "You said …" / "<name> said …, <time>").
- **Observability.** —
- **Budget.** 1.5 opens + 5 polls per DAU (cost table).
- **Flag.** `messaging` (reads need only not-globally-off).
- **Seam.** `ThreadCubit` depends on `MessagingRepository` and `ThreadPoller` only.

### W7-16 — Conversation composer  [owner: frontend-developer] [size: S] [depends: W7-15]  Status: Done (#426)
- **Description.**
  - A bottom composer (multi-line field, `CharacterCounter` near the limit, `DraftProblemHint`, Send icon button) reusing `analyzePostDraft` (the same D9 rules as posts, F8).
  - One idempotency key per intent, reused on retry; an optimistic dimmed bubble ("Sending…"), replaced by the server message (deduped by id); a "Not sent. Tap to retry" bubble on failure.
  - Friendly errors: `CANNOT_MESSAGE` → read-only state; `LIMIT_REACHED request_unanswered` → "You can send more once they accept your request"; `dm_new_daily`, rate limit, degraded mode, offline.
  - Enter sends on desktop and web; Shift+Enter adds a newline.
- **Acceptance criteria.**
  - Given a retry after a timeout, then the same key, and one message on the server.
  - Given 281 code points, then Send is disabled and the counter is red.
  - Given degraded readonly, then the composer shows the banner and Send is off.
- **Test notes.** Widget tests incl. the key reuse (fake repository) and keyboard handling.
- **Observability.** —
- **Budget.** 1.5 sends per DAU.
- **Flag.** `messaging` per caller (the composer is hidden when off for the caller).
- **Seam.** `MessageComposerCubit` mirrors `ComposerCubit`'s intent rules; no second text validator.

### W7-17 — New-message flow and profile "Message" button  [owner: frontend-developer] [size: M] [depends: W7-13; W3-14 for the profile button]  Status: Done (#435)
- **Description.**
  - **`/messages/new`:** full screen under 600 dp, a 600 dp dialog above, with a "To:" search field.
    - Empty: the caller's **Following list** (`GraphRepository.listFollowing`, paged, `UserListRow` without a FollowButton).
    - Typing: when `search` is on (W4), handle typeahead through W4's `SearchRepository` (W4's caps). Otherwise a local filter of the loaded Following rows plus "Message @handle", resolved with `GetProfile` on tap.
    - Picking a person opens `/messages/<convId>` if a conversation exists in the cache, else a draft thread that sends with `recipient_user_id`.
  - **Profile:** a round "Message" (envelope) button left of Follow on another user's profile when `messaging` is on for the caller. It is hidden when the viewer blocks, or is blocked by, the target.
- **Capture.** **The new-message flow is NOT VERIFIED.** X-like default.
- **Acceptance criteria.**
  - Given `search` off, then the picker never calls SearchService.
  - Given `search` on, then typing "ab" makes ≤ 1 SearchPeople call (W4 debounce).
  - Given a blocked target, then no Message button.
  - Given a person with an existing conversation, then it opens that conversation (no duplicate).
- **Test notes.** Widget tests at 3 widths; flag combinations (`messaging` × `search` × `graph`).
- **Observability.** —
- **Budget.** ListFollowing pages (the existing graph row) about 0.1 per DAU; W4's typeahead line when on.
- **Flag.** `messaging` per caller; `search` optional; `graph` for the Following list.
- **Seam.** `RecipientPicker` depends on a `PeopleSource` interface (Following now, search when present), so the W4 dependency is optional.

### W7-18 — Request actions and the report-message sheet  [owner: frontend-developer] [size: S] [depends: W7-14, W7-15]  Status: Done (#442)
- **Description.**
  - In a request thread, a bottom banner "<name> wants to message you" with **Accept**, **Delete** and **Block**. Accept calls AcceptMessageRequest; Delete calls DeleteConversation and returns to the list; Block uses the existing `showBlockConfirmationDialog` + `GraphRepository.block`.
  - A long press or overflow on a peer bubble → "Report message" (the existing report sheet with `target_type = MESSAGE`; only when `reports` is on).
  - The sender side of a pending request shows "Waiting for them to accept. You can send up to 3 messages."
- **Acceptance criteria.**
  - Given Accept, then the conversation moves to Inbox and the composer appears.
  - Given Report, then a confirmation toast and no change to the thread.
  - Given `reports` off, then no Report item.
- **Test notes.** Widget tests; the flag matrix (`reports`).
- **Observability.** —
- **Budget.** About 0.05 per DAU.
- **Flag.** `messaging` (Accept per caller, Delete not globally off), `reports`.
- **Seam.** Reuses the report sheet and the block dialog; no second implementation.
- **Built (W7-18, PR #442).** `request_banner.dart` (`RequestBanner`, `SentRequestNote`, `ThreadRequestActions`), `report_conversation.dart`, `ThreadCubit.acceptRequest`, `MessagingRepository.conversationsChanged` and `dropBlockedRequest`, `MessageBubble.onReport` (long press, secondary click, Shift+F10, the context-menu key, Enter, and an assistive action), `BrowserContextMenuGuard`, `ReportSheet.detail` and `ReportOutcome.alreadyReported`. Founder answers of 2026-10-29: the Delete confirmation stays (wording: "They won't be told. If they still can, they may message you again."), there is no "Request accepted" toast (the composer appearing is the answer), "Request deleted" stays, and the sender's waiting note ships as best effort. **Gap (W7-25):** the note is drawn for REQUEST in INBOX, which only the `ListMessages` header reports (first or older page), never `ListConversations`. It therefore disappears when the sender reopens the thread (the cached row reads ACCEPTED) and stays after the peer accepts (a `since` poll carries no header). **F6(a) gap (W7-26):** the whole screen is hidden when `messaging` is off for the caller, so Delete and Report are not reachable for such a caller.
  **Follow-up (PR #442 R1, no ticket yet):** after `dropBlockedRequest` a reopened thread (web back/forward or a typed URL) has no header, so it shows no Delete or Report and the composer appears; a full reload brings the row back into Requests. Suggested fix: rewrite the row with `canReply = false` instead of deleting it, and have `readConversations(FOLDER_REQUESTS)` skip `!canReply` rows.

### W7-19 — Shell, badge, push routing, deep link  [owner: frontend-developer] [size: M] [depends: W7-14, W7-15]  Status: Done (#441)
- **Description.**
  - A "Messages" destination in `MainShell` (F10): the bar, the rail and its position after Notifications, with a filled glyph when selected. It needs `messaging` + `ui_shell`; the legacy chrome gets an entry in Settings only.
  - **`MessagesBadgeCubit`**, separate from `UnreadBadgeCubit`: seeded from `GetMe.unread_conversation_count`, incremented locally by a foreground message push for a conversation that is not open, cleared per conversation on open. **A message push never touches `UnreadBadgeCubit`.**
  - `notificationLocation` maps `type=message` → `/messages/<conversationId>`. `PushCubit.onOpen` routes there. A foreground push for the visible conversation triggers a poll, not a banner.
  - **`AppRouter.deepLinkTarget` gains exactly `^/messages/[0-9a-f]{32}$`.** This is a fixed-length, lower-hex pattern, deliberately tighter than the `/u/[^/]+` and `/profile/[^/]+` patterns (W7-22 checks it), with no query or fragment, so a cold-opened push or shared link survives sign-in.
  - `/messages`, `/messages/requests` and `/messages/new` are not deep-link targets.
- **Acceptance criteria.**
  - Given `messaging` + `ui_shell` on, then 5 bar items at 360 dp (with W4's Explore) and no overflow at text scale 2.0.
  - Given a message push tapped from a cold start, then the app lands in that conversation after sign-in.
  - Given `/messages/ABC`, `/messages/<33 hex>` or `/messages/<id>?x=1`, then no stash (Home).
  - Given a message push in the foreground on Notifications, then the notifications badge is unchanged and the Messages badge +1.
- **Test notes.** Widget tests at 360 / 600 / 1200; a `deepLinkTarget` table test; push routing with a fake `PushCubit`.
- **Observability.** —
- **Budget.** 0 RPCs of its own (GetMe already happens).
- **Flag.** `messaging` + `ui_shell` (destination), `notifications` (push).
- **Seam.** Routes are built only through `AppRouter.messagePath(convId)`; the allowlist stays the one `deepLinkTarget` list.

### W7-20 — Backend tests  [owner: tester] [size: M] [depends: W7-5 to W7-12]  Status: In review (PR #453)
- **Description.** Emulator integration:
  - flag modes off / allowlist / percent / on for caller × recipient, and the not-globally-off reads;
  - the authz matrix (non-participant, guessed ids, foreign tokens) with byte-identical NOT_FOUND;
  - the block and mute matrix on send and read (both directions, `blockedByOverflow` accounts), with the refusal bytes identical across causes;
  - caps: per minute, daily, new conversations (new accounts), request unanswered;
  - idempotency (replay, same key different body, concurrent first messages);
  - `budgettest` on every RPC per the table;
  - the eraser (tombstone, both gone, crash resume) and export golden;
  - push hook (no row, suppression, the own limiter, payload golden);
  - the GetMe badge;
  - report MESSAGE;
  - `DEGRADED_MODE=readonly`.

  Coverage on `internal/messaging` ≥ 70 %.
- **Acceptance criteria.** Every acceptance criterion in W7-4 to W7-12 has a named test; `make test-int` is green.
- **Test notes.** Load shapes with W7-23: 50 sends/s into one conversation (the counter contention trigger, rule 3) and 300 concurrent pollers.
- **Observability.** —
- **Budget.** 0 (emulators).
- **Flag.** Under test: `messaging` (caller × recipient) × `notifications` × `reports`.
- **Seam.** —
- **Built (W7-20, PR #453, 2026-10-29).** A traceability audit first: all 45 explicit acceptance criteria of W7-4 to W7-12 already had a named test; the traceability table (criterion to `file:TestName`) is `docs/reviews/test-report-w7.md` section 3, with the budgets per RPC in section 4. Added 18 tests for 13 gaps (the read RPCs' budgets, NOT_FOUND bytes, flag classes, limiter and badge through the interceptor chain; a mid-range percent; degraded mode for MarkConversationRead; the send caps of an established account; suspended recipient and the caller's own mute; blockedByOverflow on send; concurrent first messages; the reference-account eraser and export budgets). Coverage on `internal/messaging` 93.7 %. Two Low defects are filed as skipped tests (`W720_RUN_DEFECTS=1` reproduces): D-1, a `blockedByOverflow` caller's list and thread ignore the blockers that dropped out of `blockedBy` (a blocker's request stays listed, `can_reply` true); D-2, `ListMessages` on a conversation whose participant list is not a pair answers INTERNAL, not the unknown-id NOT_FOUND. Measured against the plan: the eraser for the reference account costs 381 reads, 360 writes, 20 deletes (the plan says about 340 / 340 / 20; the code matches its per-call documentation, so the plan figure and `cost-model.md` need correcting in W7-23). The load shapes stay with W7-23.

### W7-21 — Client tests  [owner: tester] [size: S] [depends: W7-14 to W7-19]  Status: Done (#447)
- **Description.** The cross-screen matrix:
  - inbox → thread → compose → request accept → report → block;
  - polling across lifecycle changes (fake clock);
  - sign-out wipes the drift tables;
  - deep link and push routing;
  - the flag combinations (`messaging` × `ui_shell` × `search` × `reports` × `notifications`);
  - text scale 2.0 overflow.
- **Acceptance criteria.** All new widgets are covered at 360 / 600 / 1200, light and dark; no overflow at 2.0; polls are 0 while hidden.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** As above.
- **Seam.** —
- **Built (PR #447, 2026-10-29).** Test-only (no change under `app/lib`). Audit first, then only the gaps; the full table is in the PR body. Client section for any combined W7 test report: the files below.
  - **Already covered (cited, nothing added):** deep link and push routing (`app_router_deep_link_test`, `app_router_messages_test`, `app_widget_messages_test` "a tapped message push"); polls are 0 while hidden (`timer_thread_poller_test`, `thread_poller_integration_test`, `thread_screen_test` "app hidden: 0 polls; visible again: one at once"); the 2.0 matrix of the inbox, rows, bubbles, composer, thread, request banner, report sheet, picker, shell destination and profile button.
  - **Added:** `app/test/support/messaging_flow_rig.dart` (`MessagingFlowRig`, `FakeMessagingServer`: the real router and repositories over a fake wire); `messaging_flow_test` (inbox → requests → accept → send → report a message → block, Delete, sign-out with the thread open); `messaging_sign_out_test` (`wipeSessionData(messagingRepository:)` empties the three drift tables, an answer in flight is dropped); `messaging_flag_matrix_test` (all 32 combinations of `messaging` × `ui_shell` × `search` × `reports` × `notifications`); `messaging_matrix_gaps_test` (Message requests folder, empty inbox and requests, sender waiting note and the draft thread at 360 / 600 / 1200 × light / dark × 1.0 / 1.3 / 2.0).
  - **Defect (found here, fixed in a follow-up):** `DraftThreadScreen`'s empty state (`AppEmptyView` in an `Expanded`, `draft_thread_screen.dart`) overflows at text scale 2.0 on 360 × 640 (first state) and by 39 px on 360 × 800 after a `CANNOT_MESSAGE` refusal. Four tests named `defect: DraftThreadScreen …` in `messaging_matrix_gaps_test.dart` are skipped until it is fixed; the fix is a frontend-developer follow-up (make the empty state scroll or shrink).
  - **Fixed (PR #452):** draft empty-state overflow fixed in PR #452 (`AppEmptyView` scrolls in a bounded-height box; the four `defect:` tests are un-skipped).

### W7-22 — Security review (mandatory: private content)  [owner: security-auditor] [size: M] [depends: W7-5 to W7-12, W7-19]  Status: Done (#446)
- **Description.** A threat model for the first private-content feature:
  - authz on every read and write (participant checks, guessable deterministic ids, token binding);
  - the block oracle (refusal bytes; cached-graph freshness, A8);
  - spam and harassment (caps × 3 instances, request cap, new-account tier, sockpuppet rings, report and block flows);
  - push privacy (lock screen, `data` keys);
  - logs (no text, hashed ids);
  - report evidence of private text and operator access (ADR-0016 note);
  - right to delete (eraser ordering, the purge race A7, tombstones, peer entries) and export contents (F5);
  - the `deepLinkTarget` pattern;
  - drift storage on shared devices (sign-out wipe);
  - link rendering in messages (phishing; the same rules as posts);
  - degraded mode;
  - the decision record for "no E2E" in user-facing copy (Privacy Policy: messages are not end-to-end encrypted; the Terms draft `pending.md` 3.9 needs the line).

  Findings are fixed or ticketed before any dev allowlist.
- **Acceptance criteria.** A report in `docs/reviews/` with no open Critical or High findings, and an explicit verdict on A8 and F5.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Reviews the `messaging` gates (per caller vs not globally off).
- **Seam.** Checks the `stage-ladder` rate-limit multiplication and that `messages` is read only by `messaging.Service` (the E2E seam).

### W7-23 — Cost report  [owner: sre-performance] [size: S] [depends: W7-8, W7-10]  Status: In review (PR #455)
- **Description.**
  - Add the W7 rows (≈ +37.0 reads, +5.8 writes, +12.6 requests per DAU) to `docs/reviews/cost-model.md` §1–§5 as an additive block like W2's.
  - Run `make loadtest SCENARIO=messaging` on emulators: a send burst, 300 pollers at 15 s, first pages cold and warm.
  - Measure the response sizes behind the 10 KB/DAU/day egress line and the server time of an empty poll (to replace the 0.1 s CPU upper bound).
  - Measure send-to-render p95 on dev with two accounts (web, 15 s hot).
  - Name the triggers: polls > 25 % of requests, poll vCPU > INR 300/month, p95 delivery > 20 s, messaging storage > 0.5 GiB, any `ABORTED` on an inbox entry.
- **Acceptance criteria.** The model is updated with measured reads per call (within ± 25 % of this plan, or this table corrected); a k6 script under `loadtest/`; the Logs Explorer queries for `kind=poll` share and `fs_reads` in `cost-model.md` §9 (no new log-based metric or alert policy).
- **Test notes.** —
- **Observability.** As above.
- **Budget.** 0 (emulators, plus a handful of dev reads).
- **Flag.** n/a.
- **Seam.** —

### W7-24 — Dev rollout  [owner: production-deployer] [size: S] [depends: W7-20, W7-22, W7-23, ADR merged]  Status: Open
- **Description.**
  - Show the founder a **targeted** dev Terraform plan (`pending.md` 3.10: a full dev apply is unsafe) for `feature_messaging*` and the messaging config env vars.
  - The fieldOverrides deploy with the dev deploy workflow after the W7-3 merge; for prod they wait for the held release (`pending.md` 1.2) and must be deployed before `messaging` leaves `off` there.
  - Apply only on OK, allowlist 3 test uids (with `notifications` on for at least one Android device).
  - Smoke:
    - a mutual pair sends both ways;
    - a non-mutual request, accept, delete;
    - block refusal;
    - web polling;
    - an Android push and its deep link;
    - report a message;
    - account deletion of a throwaway test user (tombstone).
  - Prod: no change (on hold).
- **Acceptance criteria.** The dev smoke passes; the flag is back to its planned state; `pending.md` 3.16 updated.
- **Test notes.** —
- **Observability.** Check the `kind=send|poll` lines, `notification_delivery type=message` and the `account_job step=messaging` line in dev logs.
- **Budget.** A few hundred reads inside the dev project's free quota.
- **Flag.** Dev: `feature_messaging` allowlist (3 uids); prod stays `off`.
- **Seam.** —

### W7-25 — Request state for the sender  [owner: architect, then backend-developer] [size: S] [depends: W7-7, W7-9]  Status: Open
- **Description.**
  - Problem: `ListConversations` reports every `dmInbox` entry as ACCEPTED, so the sender's pending request reads ACCEPTED in their Inbox list. The W7-18 waiting note ("Waiting for them to accept. You can send up to 3 messages.") needs REQUEST in INBOX, which only the `ListMessages` header carries, on a first or older page. The note disappears when the sender reopens the thread and stays after the peer accepts.
  - Options for the architect: store `state` on the requester's `dmInbox` entry (+1 write on Accept, to flip it), or return it in `ListConversations`.
  - Then the client reads the state from the list row and the header alike (no new client heuristic).
- **Acceptance criteria.**
  - Given a pending request, then the sender's Inbox row and thread header both read REQUEST, also after a reopen.
  - Given the peer accepts, then the sender's next refresh reads ACCEPTED and the note goes.
- **Test notes.** A contract test on the list and the header; a client test that the note follows the row.
- **Observability.** —
- **Budget.** Decided by the architect (the first option adds 1 write per Accept).
- **Flag.** `messaging`.
- **Seam.** `messaging.Service`; `conversationOf` stays the one mapper.

### W7-26 — Client honours F6(a) for the clean-up RPCs  [owner: architect, then frontend-developer] [size: S] [depends: W7-14, W7-15]  Status: Open
- **Description.**
  - Problem: the app hides all of Messages when `messaging` is off for the caller (the `/messages` routes redirect Home, the thread shows "Messages aren't available yet"), but F6(a) says list, read, mark-read, delete and report need only "not globally off". `GetMe` lists the flag per caller, so the client cannot tell "off for me" from "off for everyone".
  - The architect decides: a contract signal (for example an additive `GetMe` field), or trying the call through `MessagingFeatureGate.runRead`. Then fix the W7-14 and W7-15 routing and screen gates.
- **Acceptance criteria.**
  - Given `messaging` off for the caller but not globally, then the caller can still open an existing conversation to delete it or report a message, and cannot send or accept.
  - Given `messaging` off for everyone, then Messages stays hidden.
- **Test notes.** Widget tests on the routes and the thread for both cases.
- **Observability.** —
- **Budget.** 0 (client only), unless the contract signal adds a field.
- **Flag.** `messaging` (per caller and globally).
- **Seam.** `MessagingFeatureGate`.

### W7-27 — ListMessages first page returns unread_count  [owner: architect, then backend-developer] [size: S] [depends: W7-8]  Status: In review (PR #459)
- **Why.** Found in the #441 review (W7-19 F-5). `ListMessages` carries the conversation header (identity, peer, state, folder, `can_reply`) but not the caller's entry, so a thread opened cold (a push tap, a deep link, nothing cached) cannot tell that the conversation was unread. The client then cannot take it out of the Messages badge, which keeps its number until the next Inbox load or `GetMe`. The client side is already in W7-19: the cold open merges the header into the cached row, so a cached `unread_count` survives.
- **Description.**
  - **architect:** a one-line additive proto comment and field use: `Conversation.unread_count` is filled on the first page of `ListMessages` (not on a `since` or older page), from the caller's `dmInbox` entry. No new field, no renumbering (rule 9). A short ADR-0027 dated note.
  - **backend-developer:** read the caller's `users/{uid}/dmInbox/{conversationId}` entry on the first page and fill `unread_count`.
- **Acceptance criteria.**
  - Given a conversation with 3 unread, then the first `ListMessages` page has `conversation.unread_count = 3`.
  - Given a `since` refresh or an older page, then `unread_count` stays 0 (unset) and the read count is unchanged.
  - Given a non-participant or unknown id, then NOT_FOUND byte-identical as before (the entry read happens after the participant check).
- **Test notes.** `budgettest` first page 25 worst / 55 at limit 50 (was 24 / 54); poll and older pages unchanged.
- **Observability.** `fs_reads` on `kind=list_messages` rises by 1 on a first page.
- **Budget.** **+1 read on a first page** (worst case 24 → 25). A first page is opened once per thread open, so the cost is about one read per thread open per DAU.
- **Flag.** Not globally off (F6).
- **Seam.** `messaging.Service.ListMessages`. `mergeThreadHeader` already lets a header `unread_count` above 0 win over the cached row, but it keeps the cached count when the header says 0. Once this lands a first-page 0 is authoritative (read on another device), so a small client follow-up (frontend-developer, right after the backend PR) goes with this ticket: take the first-page header count as it is, so a stale unread cached row does not lower the badge or send a needless mark-read.
- **Implementation note (2026-10-29, PR #459).** Backend, proto comment and ADR-0027 note are in one PR. New `Repo.GetEntry` (1 read, folder from `entryFolder`: `dmRequests` only for the recipient of an unaccepted request, else `dmInbox`; never a probe of both), run in the existing errgroup (limit 4) after the participant check, first page only. Measured in the chain test `TestMessagingChain_ReadBudgetTable`: first page 25 at page 20 and 55 at page 50, older page 24, poll 3. **W7-30 header part rides along** (about 40 lines): `BlockedBy[peer]` or `BlockedByOverflow` shows the entry's frozen peer snapshot, never the live profile; an older page and a first page with no entry read "Deleted account". The rule is: erased peer is the placeholder; else a block decides (frozen only if the entry names this peer), whatever the directory says, so a blocked caller learns nothing about the blocker's account status; else a peer the directory does not list is the placeholder; else live. The directory lookup is kept, in parallel with the graph read, for latency (no serial wait) and for liveness in the unblocked case, not to match read counts. Deviation from the review text: `BlockedByOverflow` is treated as blocked (0 reads, fail closed, security audit accepted) instead of reading the peer's graph, and `canReply` is false for it too. Complete only with W7-33 (a send in the 60 s stale-graph window can refresh the frozen snapshot). **Not in this PR:** the W7-30 export part (needs a graph dependency in `NewExporter` and apiserver wiring), and the client follow-up (`mergeThreadHeader` takes the first-page header count as authoritative, including 0), a separate frontend PR.


### W7-28 to W7-35 — Security-review follow-ups (W7-22)  Status: Open
Source: `docs/reviews/security-w7-messaging.md` (2026-10-29). Each ticket's description, attack scenario, fix and gate are
in that report (finding ids in brackets); acceptance is "the finding's fix is in place with a test, and the report's
scenario no longer works".
- **W7-28 (done, #448) [H-1]** non-participant cache isolation. Gate: before any user outside the 3 team uids. Budget: a
  non-participant probe costs exactly 1 read whether the conversation exists or not; participants +0.
- **W7-29 (done, #451) [M-1]** daily caps. Gate: before the flag leaves the dev allowlist. Config only (rule 11).
- **W7-30 [M-2]** (thread header part: in review, PR #459, with W7-27; export part still Open) frozen peer snapshot when blocked. Gate: before prod. +0 reads on the first page with W7-27; export +1
  graph read.
- **W7-31 (done, #450) [M-3]** no-E2E copy. Gate: before any non-team user. Plus the founder's Privacy Policy and Terms lines.
- **W7-32 [M-4]** `tf-plan` custom read role. Gate: founder decision before prod messaging.
- **W7-33 [L-1 A8, L-3, L-8]** fresh recipient graph in the send transaction (+1 read per send, ADR-0027 note), recipient
  `ProfileInTx`, verified-email gate. Gate: before prod percent / on.
- **W7-34 [L-2, L-7]** placeholder and log pseudonyms. Gate: before prod.
- **W7-35 [L-4, L-5, L-9]** client hardening. Gate: before prod.
- **W7-36 [L-6]** a 180-day limit on the copied text of OPEN MESSAGE reports (founder decision 2026-10-29). Gate: before prod.
- **Founder decisions (2026-10-29):** start W7-28, W7-29 and W7-31 now (before the dev rollout); M-4 → the custom read
  role (W7-32; Terraform PR by Claude, prod plan and apply by the founder); A8 → flip to the fresh recipient graph read
  (W7-33, ADR-0027 note); L-6 → 180-day TTL (W7-36).
- Not ticketed: L-10 (the F2(d) requests setting, planner follow-up).

## Rollout plan
- **Dev.** Allowlist (3 uids).
- **Prod.** Your MVP launch decision: allowlist → percent 5 → 25 → 100 → `on`, or allowlist straight to `on` (Flags, because both participants need the flag). Each step is a Terraform change plus a tagged revision (ADR-0019). Before each step, check the `cost-model.md` headroom (writes cross the free quota at about 509 DAU with W7), the poll share and the error rate.
- **Rollback triggers:**
  - the error rate on messaging RPCs above 2 % for 15 min;
  - messaging reads per DAU above twice the W7-23 model for a day;
  - poll requests above 35 % of all Cloud Run requests for a day;
  - a spam or harassment wave in reports (first lower the caps by config deploy, then the flag);
  - any authz finding.
- **Kill switches:**
  - `FEATURE_MESSAGING=off`: every RPC is FEATURE_DISABLED with 0 reads, the client hides the destination, the routes and the profile button, and the push hook drops `message` events.
  - Allowlist removal of one user: that user can still read, clean up and report, but not send (F6).
  - `DEGRADED_MODE=readonly` refuses all sends product-wide.

  All need a deploy. No data migration: the data stays and is still erased by the account-deletion step whatever the flag (ADR-0011).
- **Client-only pieces** roll back with the flag or by revert.

## Risks
| Risk | Mitigation |
|---|---|
| Polling cost grows with DAU (CPU at 0.1 s per request is the largest line at 3,000 DAU) | backing-off poller that stops when hidden or idle; Android push wakes pulls; the stage-ladder trigger (poll share, poll vCPU INR, p95); W7-23 measures the real poll time |
| Users expect realtime chat and typing indicators | honest delivery bounds; immediate pull on push; the Stage 2 listener ADR when the trigger fires |
| Users assume messages are private like WhatsApp | in-app line "Messages are not end-to-end encrypted" in the inbox empty state and the Privacy Policy (W7-22) |
| DM spam and harassment from fresh accounts | requests folder, 3-message cap, 20/5 new conversations per day, mute = silent, block refusal, report and takedown, verified-email gate (existing) |
| A block applied on one instance lets messages through on another for up to 60 s | stated bound; A8 option of a fresh read (+1 read per send) |
| Writes become the binding free quota earlier (509 DAU instead of 597) | per-use cents, no step; the sensitivity rows; deterministic ids already removed the idempotency write |
| Private text copied into reports | only the reported message, ADR-0016 note, the existing TTL after resolution |
| Purge race recreates a deleted user's entry | `gone` mark serialised with sends, a fresh status read on new conversations, the backstop re-run (A7) |
| Uncaptured visuals (conversation view, new-message flow) | X-like defaults stated per ticket; a founder capture adjusts them in a follow-up PR |
| Merge conflicts with W3–W6 in shared files | the shared-file table; one PR at a time (`pending.md` rules) |
| ADR number clash | resolved: W7 is ADR-0027 (2026-10-28) |
| 5-item bar is full once Explore and Messages land | F10 fixes the order; Lists (W5) go in the drawer |
