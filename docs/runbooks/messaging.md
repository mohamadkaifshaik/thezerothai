# Runbook: direct messages (ADR-0027)

Owner module: `backend/internal/messaging`. Plan: `docs/plans/ui-w7-messaging.md` (W7-5 SendMessage, W7-6 lifecycle and this runbook;
W7-7 and W7-8 the lists and mark-read, W7-9 accept and delete; W7-10 push; W7-11 badge; W7-12 report). Flag: `FEATURE_MESSAGING` (wire name `messaging`, default
`off`; dev ceiling allowlist 3, no prod raise before W7-22 and W7-23 pass in dev).

What exists on `main` after W7-5, W7-6, W7-7 and W7-8: SendMessage, ListConversations, ListMessages, MarkConversationRead, the `messaging` account-deletion step and the `messages` export section. The other
two RPCs (AcceptMessageRequest, DeleteConversation) answer `Unimplemented` after the
flag gate until W7-9; the push is emitted by the send but dropped by notifications until W7-10 adds the `message` type. Sections that
describe those later pieces say so.

Data (all index-free, no composite index; fieldOverrides `indexes: []` for `messages.text`, `messages.requestHash`, `dmInbox.peer`,
`dmInbox.last`, `dmRequests.peer`, `dmRequests.last`, deployed with `firebase deploy --only firestore:indexes` **before `messaging` leaves `off` in a project**, or message text is indexed):
`conversations/{convId}` (id = first 32 hex of SHA-256 of the two uids; guessable, authorization never relies on it), its `messages/{msgId}`
subcollection (id = first 32 hex of SHA-256 of sender, "SendMessage", idempotency key: the message IS the idempotency record), and the per-user
entries `users/{uid}/dmInbox/{convId}` and `users/{uid}/dmRequests/{convId}`. `quotas/{uid}.dmNew` counts new conversations per IST day. Client
rules stay deny-all. Messages are **not end-to-end encrypted**: the server holds the text (ADR-0027 D2).

## 1. Kill switch
`FEATURE_MESSAGING=off` (Terraform `var.feature_messaging`), then deploy; no data migration.
- **Off globally:** every RPC answers `FAILED_PRECONDITION FEATURE_DISABLED feature=messaging` with 0 reads past the account-status
  interceptor's one. The clients hide the destination, the routes and the profile Message button (they read `GetMe.enabled_features`).
  `GetMe.unread_conversation_count` is 0 reads (W7-11).
- **Rollout, not a stop:** `allowlist` with a user outside it, or `percent` 0, is a rollout. SendMessage and AcceptMessageRequest need the flag
  on **for the caller and for the recipient** (a recipient outside the cohort answers `CANNOT_MESSAGE`, byte-identical to a block). The four
  list, read, mark-read and delete RPCs only need it **not globally off**, so a user dropped from the allowlist can still read and clean up.
  Because both people need the flag, a `percent` step means "works between enabled users only"; the likely ramp is allowlist straight to `on`.
- **What stays on after `off`:** stored conversations, entries and messages (they come back with the flag), and, never flag-gated, the
  account-deletion step and the export section: cleanup and right-to-delete must run after the flag is off.
- **Push:** the fan-out sends a `message` push only when `messaging` **and** `notifications` are on for the recipient (W7-10). The send itself
  never waits for it.
- **`DEGRADED_MODE=readonly`:** the interceptor refuses SendMessage (`UNAVAILABLE DEGRADED_MODE`, retry after 60 s) before any read; the lists stay up.

## 2. A stuck eraser step (`messaging`)
The step runs after `follow_requests` and before `identity` (`docs/runbooks/account-deletion.md` section 6 is the job's operations guide; its
stuck-job procedure applies). Its name is persisted in `deletionJob.step`: never rename it.

Each call is one bounded unit of work (at most 500 documents) and the checkpoint is ids and counters only (`after`, `conv`, `phase`, `msg`,
`both`, `entry`, `conversations`, `tombstoned`, `entriesDeleted`). For each conversation of the user, in `__name__` order:
1. `phase ""`: pick the next conversation (`participants array-contains uid ORDER BY __name__ LIMIT 1`) and, in **one transaction**, add the uid to
   `gone` (so a send can no longer rewrite the deleted user's entries: the send transaction reads that document) and rewrite the peer's entry to the
   "Deleted account" placeholder (`peerId` = `deleted`), with the snippet "Message deleted" when the user's message was the last (peer already gone: no entry read).
2. `phase tombstone`: 500 per call, the user's messages (`senderId == uid`): `senderId` = `deleted`, and for a VISIBLE one text and `requestHash` emptied, `state = DELETED_ACCOUNT`. The peer's messages are never touched.
3. `phase finish`: delete the user's own `dmInbox` or `dmRequests` entry.
4. `phase rewrite`, when the peer lives: one transaction replaces the uid by `deleted` in `participants`, `gone`, `requestFrom`, `requestTo` and drops `clearedAt.<uid>`.
   **It is last on purpose**: the cursor query finds the conversation through `participants`, so every earlier step keeps it findable and is idempotent, and after the rewrite there is nothing left to do.
   `gone` is never empty in between, so sends stay refused; the peer's own eraser finds the conversation by the peer's uid and sees `deleted` in `gone`.
   `phase tree`, instead, only when the peer is gone too: the messages 500 per call, then the conversation document last.

Cost for the reference account (20 conversations, 300 own messages, peers alive): about 380 reads (21 cursor queries, 20 conversation and 20
peer-entry reads, 20 conversation reads in the rewrites, 300 messages), 360 writes (20 gone marks, 20 peer entries, 300 tombstones, 20 rewrites), 20 deletes. A repeat after completion is one empty query. A step repeated after a crash re-does at most one unit and never leaves a half-erased
conversation (the crash matrix `TestAccountLifecycle_MessagingCrashAtEverySideEffect` kills the job after each of its side effects).

| Symptom | Likely cause | What to do |
|---|---|---|
| The job sits at `step=messaging`, `account_job` retries | A failed batch, or `NotFound` on a tombstone batch because the peer's eraser deleted the tree at the same moment | Both are retried by the lifecycle (`maxStepErrors`) and the redelivery sees the finished state. Look at the `messaging: ...` error in the job's log line (uids and conversation ids are redacted to hashes). If it persists, check Firestore status, then the checkpoint in `users/{uid}.deletionJob.checkpoint` |
| A conversation is still listed for a deleted user's peer, with their messages as "Message deleted" | By design (F3): the peer keeps the conversation read-only (`gone` is non-empty); it is deleted when the peer's account is deleted too | Nothing |
| `conversations/*` or `messages` documents remain after **both** accounts are deleted | The second eraser crashed after its `gone` mark and was never resumed (the lifecycle backstop re-runs the step) | Re-run the account's deletion; or delete the tree by hand: the messages (500 per batch), then `conversations/{convId}` last |
| The deleted user's uid is found in a surviving peer's conversation | Should not happen: the step ends each conversation by replacing the uid with the fixed placeholder `deleted` (`messaging.DeletedUID`) in `participants`, `gone`, `requestFrom` / `requestTo`, drops the `clearedAt` entry, and sets the tombstones' `senderId` and the peer entry's `peerId` to it (ADR-0027 D11). The T11 residue sweep runs on this case with no allowlist entry. A hit is a code defect or a step that never finished: re-run the account's deletion | Treat `deleted` as "Deleted account" in any reader; it resolves to no profile |

The `messaging_purge_done` line carries `conversations`, `messages_tombstoned`, `entries_deleted` and `uid_hash` (never a peer uid) when the step finishes.

**Export** (`messages` section, appended after the existing sections): `{"conversations":[...]}` newest conversation first, each with the peer's
handle **at export time** (empty and `peerDeleted: true` when the peer is gone), the state, the time stamps, and its messages newest first. Own messages carry their
full text; received ones are a time and `"received"` only (the peer's words are the peer's data, F5). No peer uid, conversation id or message id appears. Cost: one read per conversation and per message of
both sides (the section orders them), about 620 for the reference account, plus at most one directory read per 50 peers.

## 3. Abuse levers
Every limit is config (rule 11); each is per instance unless it says exact, so the ceiling is x `max-instances` (3).

| Lever | Default | Effect when hit | Where |
|---|---|---|---|
| `RATE_LIMIT_MESSAGES_SEND_PER_MIN` | 20 | `RATE_LIMITED` (60/min at 3 instances) | in memory, ratelimit interceptor |
| `MESSAGES_SENDS_PER_DAY` | 300 | `RATE_LIMITED limit=messages_daily`, retry after IST midnight (900/day at 3) | in memory, interceptor |
| `MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY` | 50 | same limit name, for accounts younger than `QUOTA_NEW_ACCOUNT_WINDOW` | in memory, the send service |
| `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY` / `QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY` | 20 / 5 | `LIMIT_REACHED limit=dm_new_daily` | exact, `quotas/{uid}.dmNew`, in the send transaction |
| `MESSAGES_REQUEST_MAX_UNANSWERED` | 3 | `LIMIT_REACHED limit=request_unanswered` on the requester's 4th message until the recipient replies or accepts | exact, `conversations.requestCount`, in the send transaction |
| `RATE_LIMIT_MESSAGES_READ_PER_MIN` | 30 | the list and poll bucket (W7-7, W7-8) | in memory |
| `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` | 20 | pushes are skipped, messages still stored (W7-10) | in memory |
| Per-uid read budget | 2,000 reads/uid/day per instance | `RATE_LIMITED limit=read_budget_daily` | in memory |

Worst case for one sender: about 900 messages a day, of which at most 20 new conversations x 3 request messages reach strangers.
- **Block, mute and report are the user's levers.** A block either way is `CANNOT_MESSAGE` with the same bytes as a deleted account and a recipient with messaging off (no oracle). A muted sender is delivered **silently**
  (no push, no unread increment; the conversation still appears for the recipient). Requests from blocked, blocking or muted accounts are hidden from the Requests list (W7-7). Report a message: `ReportContent` with target type MESSAGE (W7-12).
- **Moderator takedown of a message** is `opsctl` (W7-12: tombstones the message, `state = REMOVED`, text emptied; the report evidence keeps that one message). It does not exist before W7-12. Until then the only lever on an abusive account is
  `opsctl suspend-user` (`docs/runbooks/moderation.md`): a SUSPENDED sender is refused by the account-status interceptor and a SUSPENDED recipient answers `CANNOT_MESSAGE`.
- **Turn one lever down without a deploy:** none; limits are env vars on the `api` service, a Terraform change plus a release. Fast stop for a spam wave: `FEATURE_MESSAGING=off`, or remove the offender from the allowlist.
- **Log queries** (request line, rpc `/dzeroth.messaging.v1.MessagingService/SendMessage`): `jsonPayload.limit_name` (`messages_daily`, `request_unanswered`, `dm_new_daily`), `jsonPayload.refused_reason`
  (`blocked`, `recipient_inactive`, `recipient_flag_off`, `gone`: the wire answer is always `CANNOT_MESSAGE`), `jsonPayload.state` (`accepted`, `request`, `new`), `jsonPayload.silent`, `jsonPayload.replay`.
  Never present: message text, snippets, peer uids, conversation ids in clear (`conversation_hash` and `uid_hash` only).

## 4. The polling cost trigger and how to read it
Delivery is pull (ADR-0027 D7): a visible thread polls ListMessages with `since_token` (web 15 s hot, Android 30 s hot, 45 s quiet, stopped after 5 min idle or hidden), the Inbox refreshes by
`since` on open, resume and after a push. Polling is the largest W7 cost line at 3,000 DAU (about INR 262 of INR 480 a month for CPU), so the realtime step on the stage ladder watches it.

The trigger (stage ladder row "Delivery to an open thread", **sustained 7 days**): message polls **above 25 % of all Cloud Run requests**, **or** poll vCPU-seconds above **INR 300 a month**,
**or** p95 send-to-render on an open web thread above 20 s with user complaints. Each poll per DAU per day is about INR 28 a month at 3,000 DAU (21 CPU, 3.5 requests, 3.6 reads), about 0.4 at 300.

Measure it (read-only). A poll is a ListMessages request line with `kind=poll` (W7-8; before W7-8 there are no polls and the share is 0). Cloud Logging (the same shape as `docs/runbooks/bookmarks.md`):
```
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.message="request"' \
  --project=dzeroth-prod --freshness=1d --limit=200000 --format=json \
| jq '[.[].jsonPayload] | {requests: length, polls: (map(select(.rpc == "/dzeroth.messaging.v1.MessagingService/ListMessages" and .kind == "poll")) | length)} | . + {share_pct: (100 * .polls / (.requests // 1))}'
```
For the CPU line, take the ListMessages p50 `latency_ms` of `kind=poll` lines times the poll count (billed vCPU-seconds, 0.1 s minimum per request at the worst), multiply by the vCPU-second price in `docs/reviews/cost-model.md`
section 7, and compare with INR 300. Cross-check against the Cloud Run `request_count` and `container/cpu/allocation_time` metrics for the revision. The per-uid read budget bounds one client: a web hot thread is about 288 reads an hour, so about
7 hot hours or 22 quiet hours a day, and a forgotten open thread costs at most about 11 polls. Seven consecutive days over a threshold is an ADR (owner-only Firestore listeners behind a rules ADR, then SSE); do not tune the
intervals first without the founder.

Send cost is the other measured line: SendMessage reads 5 worst cold (2.5 planning) and writes 3 (accepted), 4 (request), 5 (new conversation); the request line's `fs_reads` / `fs_writes` must stay inside those.
A new revision that exceeds them is a code defect (the budget assertions in `internal/apiserver/messaging_chain_integration_test.go` fail first).

## 5. Test push in dev
Prerequisites: `FEATURE_MESSAGING` and `FEATURE_NOTIFICATIONS` both `allowlist` with the **same** three dev uids (both people need both flags), the `messaging` Firestore field overrides deployed to
`dzeroth-dev`, the notifications fan-out subscription healthy (`docs/runbooks/notifications.md`), and one Android handset or emulator signed in as the recipient with a registered device (RegisterDevice; web and iOS get no push, ADR-0017 D11).
1. Make the two accounts follow each other (a stranger's first message is a **request**, which never pushes), or have the recipient reply once so the request is accepted.
2. Send from account A to B (the app, or `SendMessage` with A's token). Expect the response, B's `dmInbox` entry with `unreadCount` 1, and **one** `notification_delivery` line with `type=message` (`pushed=1`) in Cloud Logging for the fan-out
   (`jsonPayload.event="notification_delivery"`). The handset shows the generic "New message" with the conversation id as its only data: no sender, no text.
3. Negative checks: a request (non-mutual) pushes nothing; a recipient who muted the sender gets the message with no push and no unread; `FEATURE_NOTIFICATIONS=off` for the recipient drops it; 21 messages inside an hour show `push_throttled` once
   `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` (20) is reached while every message is still stored.
4. **Until W7-10 ships**, step 2 cannot happen: the send emits its event, but `notifications` has no `message` type, so the producer drops it before publishing (0 cost) and a fan-out that received one would count it as `dropped` and acknowledge it
   (`unknown_type`, ADR-0027 D9). A send still succeeds and stores everything; only the push is missing. Check the send path alone with the request line (`kind=send`, `state`, `silent`, `fs_reads`, `fs_writes`).
5. On the emulators (`make dev`), `NOTIFICATIONS_DELIVERY=inline` delivers in-process; the push goes to `LogSender`, so look for the `notification_push_local` log line instead of a handset.

## 6. Other failure modes
| Symptom | Likely cause | What to do |
|---|---|---|
| Users see `CANNOT_MESSAGE` for someone they should reach | A block either way, the recipient outside the flag cohort, the recipient not ACTIVE, or a `gone` conversation. The wire answer is the same on purpose; the log's `refused_reason` says which | Check the two accounts' graph docs and the flag cohort; a block applies at once on the instance that handled it and within 60 s elsewhere (graph snapshot cache, ADR-0027 A8) |
| `LIMIT_REACHED request_unanswered` for a user whose first messages were delivered | The requester sent 3 messages and the recipient has not replied or accepted (W7-9) | Expected. The recipient's reply accepts it. A retry of the 3rd message (a lost response) replays, it is never refused |
| `messaging_txn_contention` WARN (`txn_attempts` above 3) or `UNAVAILABLE busy, please retry` | Lock contention on one conversation document while it is a REQUEST (each request message updates it), or two people opening a conversation at the same moment | Expected to be rare; the client retries with the same idempotency key (a replay). A sustained rate means one pair is exchanging many request messages: the cap of 3 bounds it |
| The Inbox or Requests list is short or empty but has a `next_page_token` | Expected: ListConversations filters after the page query (REQUESTS hides entries whose peer the caller blocks or mutes or who blocks the caller), so the client keeps following the token (ADR-0027 D4). A hidden request still counts in `request_count` | Nothing to fix. The request line (`kind=list_conversations`, `folder`, `results`, `dropped_blocked`, `dropped_muted`, `dropped_blocked_by`, `fs_reads`) shows how many were dropped per cause; a first INBOX page reads at most 23 (1 + 20 + graph 1 + count() 1), a `since` refresh 2 + the entries returned |
| `VALIDATION since_token` / `page_token` on the list | The token is older than 30 days, belongs to another user, folder or token kind, or was edited; the secret `CURSOR_HMAC_KEY` changed (every sealed token fails to open) | The client drops it and lists with no token. Nothing is read for a rejected token. A burst of these after a deploy means the cursor key was rotated |
| A conversation shows "Deleted account" in the list | The other person's account was erased: the eraser wrote `peerId = deleted` and a placeholder snapshot into this user's entry (D8). The list never looks the placeholder up and sets `can_reply = false` | Expected. The entry stays until its owner deletes it |
| A thread poll (`since`) returns the newest message again | Expected: the `since` token trails the newest message by the 5 s settle window so a message committed a moment later by another instance is not missed; the client dedupes by id (ADR-0027 D7). An empty poll therefore reads 1 document | Nothing to fix |
| A poll response has `gap_page_token` | The refresh page was full (more new messages than `page_size` since the token). The client keeps its cache and pages `gap_page_token` (bounded below by the old `since` position) | Expected after a long absence; the request line shows `kind=poll`, `results` = page size |
| `NOT_FOUND conversation not found` on a thread the user believes exists | Same answer for an unknown id, a conversation the caller is not in, and a deleted one (D11). The request line has `conversation_hash` only | Compare the hash with `logger.HashUID(convId)` of the id from the client; never log the id |
| Messages the user deleted for themselves reappear on one instance, or an Inbox badge keeps its old count | The conversation cache holds `clearedAt` for 60 s per instance (D14) and the badge cache is evicted on the instance that handled the mark-read only | Converges within the cache TTL (60 s thread, 30 s badge); no action. `cache_hit=true` on `kind=list_messages` shows the cached read |
| `MarkConversationRead` succeeds but nothing changes | The caller has no entry in either folder (unknown id, non-participant, deleted for the caller): success with 0 writes by design | `kind=mark_read` has `entry_found=false` and `fs_writes=0` |
| A message was sent twice | It was not: the message id derives from sender and key, so a retry replays. Two ids means two keys | Check the client generates one key per composed message |
| `VALIDATION idempotency_key` on a retry | The same key was reused with other text or another conversation | A client bug: a new message needs a new key |
