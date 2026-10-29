# Security review: W7 Messaging v1 (W7-22)

**Reviewer:** security-auditor · **Date:** 2026-10-29 · **Reviewed:** `origin/main` at `60f1e353` (read-only)
**Scope:** the 12 binding items of the W7-22 ticket (`docs/plans/ui-w7-messaging.md`), the stage-ladder rate-limit
multiplication, the E2E seam, and the items handed over by the W7-8 to W7-19 code reviews.
**Code read:** `backend/internal/messaging/*`, `backend/internal/moderation/{message,service,server}.go`,
`backend/internal/apiserver/{moderation_messages,messaging_wiring,ratelimit_config}.go`, `backend/cmd/opsctl/messages.go`,
`backend/pkg/platform/cursor/rev.go`, `backend/internal/notifications/{fanout,fcm}.go`, `pkg/platform/{degraded,logger}`,
`app/lib/features/messages/**`, `app/lib/features/notifications/**`, `app/lib/core/router/app_router.dart`,
`app/lib/core/storage/app_database.dart`, `app/lib/app/{bootstrap,session_wiring}.dart`,
`app/lib/shared/widgets/browser_context_menu_guard.dart`, `firebase.json`, `infra/terraform/modules/iam/main.tf`,
`app/android/app/src/main/AndroidManifest.xml`.
**Not run:** tests, `govulncheck`, `osv-scanner`. W7-20 and W7-21 (tester) were still open, so no authz test results
were available. Every finding comes from reading the code.

## 1. Threat model (STRIDE)

Assets: message text (private content); who talks to whom (conversation existence and timing); participant uids;
block, mute and request state; report evidence; the cost budget (ADR-0022 credit cap INR 25,000; Firestore free
writes 20k a day).

| STRIDE | Threat | Control in the code | Result |
|---|---|---|---|
| Spoofing | Acting as another participant; forged since or page tokens | Firebase ID token gives the uid. The message id is `H(senderUid\|op\|key)`, so a key is scoped per user. Tokens are AEAD-sealed and bound to `(uid, conversation, kind)` with a 30-day TTL; revision tokens use their own AEAD domain (`rev.go:12`). | Holds |
| Tampering | Rewriting someone else's entry or message; replaying a key with a new body | Entry paths come from the token uid only (MarkRead, Delete). `Create` plus `requestHash` gives VALIDATION on a reused key. Takedown and eraser use field-level `Update`, never `Set`. `LastUpdateTime` guards the tombstone pages. | Holds |
| Repudiation | A moderator action with no trace; a forged report | `opsctl` prints an audit line with hashed ids (`messages.go:88`). Report evidence is copied server-side, so a reporter cannot fabricate text. | Holds |
| Information disclosure | A non-participant reads a thread; a conversation-existence oracle; a block bypass; push or lock-screen content; logs; a shared device; operator or CI access | Participant check on every read and write; byte-identical NOT_FOUND; generic push with `data = {type, conversationId}`; the sign-out wipe | **H-1**, **M-2**, **M-4**, L-4, L-5, L-6, L-7 |
| Denial of service / cost | Send floods, polling, write amplification | Send bucket, daily caps, exact `dmNew` and request cap, read budget, max-instances 3, degraded mode | **M-1** |
| Elevation of privilege | Becoming a participant of someone else's conversation; reading erased conversations | Membership is immutable in 1:1; `gone` blocks sends | L-2 |

### Effective limits (per instance × 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| SendMessage bucket | 20/min | 60/min | memory |
| `messages_daily` | 300/day | 900/day | memory |
| New-account send tier (`newSends`, `service.go:89`) | 50/day | **150/day** (ADR D13 says "50"; doc fix) | memory |
| `dmNew` | 20/day, new accounts 5 | exact | `quotas` |
| Request cap | 3 | exact | in the transaction |
| ListConversations + ListMessages bucket | 30/min | 90/min | memory |
| Read budget | 2,000/day | 6,000 reads/uid/day | memory |
| Pushes per recipient | 20/h | 60/h | memory |
| ReportContent | 5/min | 15/min; quota 20/day exact | memory / `quotas` |
| MarkConversationRead, AcceptMessageRequest, DeleteConversation | default 60/min, **no daily cap** | **180/min = 259,200 calls/day** | memory (M-1) |

## 2. Findings

### H-1 (High): "Does A talk to B" oracle through the shared conversation cache
**Where.** `backend/internal/messaging/service_send.go:229-242`: `conversationHit` calls `putConv` (line 240) on any
document it finds, before any participant check. The callers check participation afterwards: `service_messages.go:138-142`
(ListMessages), `report.go:59-63` (ReportContent MESSAGE), `service_send.go:122-129` (SendMessage by `conversation_id`).

**Attack.**
1. Uids are public (`AuthorSnapshot.user_id`, `/u/<uid>`), and `ConversationID(a, b)` is a public function of two uids.
2. The attacker calls `ListMessages(conversation_id = ConversationID(A, B))` twice.
3. If the conversation exists, the first call reads and caches it and the second is answered from memory (about 0 ms).
4. If it does not exist, nothing is cached and every call pays a Firestore point read (about 5–20 ms in asia-south1).
5. Both answers are the identical NOT_FOUND, but the latency differs. The probe warms the cache itself, so the signal
   is not weak. A random 32-hex control id calibrates jitter; 90 probes a minute per account cover several pairs a
   minute. With credit-mode min-instances 1 at low traffic, most probes hit the same instance.
6. A fast first probe also shows that a participant was active on that instance in the last 60 s.
7. ListMessages needs only "not globally off" (F6), so any signed-in account can probe once the flag is on anywhere.

**Impact.** Relationship metadata of any pair of users (stalking, outing, an abuser checking a victim's contacts). No
content leaks; no response header carries `cache_hit` or `fs_reads` (checked), so the channel is timing only.

**Fix.** In `conversationHit`, use a cached copy only when the caller is in its `participants`. On a cache hit where
the caller is not a participant, or on any miss, do a fresh `GetConversation`, and never put a document into the shared
cache from a request whose caller is not a participant. Every non-participant probe then costs exactly 1 Firestore read
whether the conversation exists or not; participants' hot paths are unchanged (+0 reads). Test with a fake repo that
counts repo calls. **Ticket W7-28.**

### M-1 (Medium, cost amplification): MarkConversationRead is an unbounded writer
**Where.** `backend/internal/apiserver/ratelimit_config.go:105-112, 154-156, 177`: MarkConversationRead,
AcceptMessageRequest and DeleteConversation fall to the 60/min default bucket with no `DailyCap`.
`service_messages.go:306-331` and `repo_firestore.go:450-464`: each call with an existing entry is 1 write. The
account-status interceptor read is cached, so the ADR-0010 D5 read budget never binds.

**Attack.** One verified account sends one message (creating its own `dmInbox` entry), then loops MarkConversationRead
on it: 180 calls/min across 3 instances, 259,200 writes/day. Accept and Delete write nothing on repeat; MarkRead writes
every time. Same class as W2-14 M-1 (bookmarks) and W3-22 L-4 (UpdateProfile), both since capped.

**Cost scenario** (INR 95/USD, `cost-model.md` §7 prices): 7.89M writes, 7.89M requests and CPU per account-month.

| Line | INR / account-month |
|---|---|
| Firestore writes (7.89M × $0.104/100k) | 779 |
| Cloud Run requests | 300 |
| vCPU at 20 ms / 0.1 s per call | 360 / 1,800 |
| **Total** | **≈ 1,440 to 2,880** |

Ten sockpuppets reach INR 14k–29k a month, the whole ADR-0022 credit cap. One account uses the free 20k writes/day in
about 2 hours.

**Fix.** A per-uid `DailyCap` `messages_mark_read_daily` (e.g. 500; the client calls it only with unread > 0), so
1,500 writes/day at 3 instances (about INR 4.5 per account-month). Accept and Delete under one shared
`messages_mutation_daily` cap, as graph mutations do. Config only (rule 11). **Ticket W7-29.**

### M-2 (Medium): a blocked user still sees the blocker's current profile
**Where.** `service_messages.go:180-188` (peer profile from the directory with no block check);
`service_messages.go:266-284` (`threadConversation` returns the live handle, display name, avatar and verified flag even
when `snap.BlockedBy[peer]`); `export.go:134-156` (`peerHandles` puts the peer's current handle in the export).

**Attack.** A victim blocks a harasser and renames their handle. The harasser opens the old thread; the header shows
the new handle and avatar, and `can_reply = false` confirms the block. Everywhere else a blocker's profile is hidden
(GetProfile NOT_FOUND; ADR-0027 D4 relies on it). The account export leaks the same.

**Fix.** When the caller's snapshot has `BlockedBy[peer]` (or `BlockedByOverflow`, then the peer's snapshot), do not look
the peer up; return the frozen snapshot from the caller's own entry (W7-27 already adds that read on the first page, so
+0 reads there). For older pages, omit the header or use the same snapshot. In the export, skip the directory lookup for
peers in `Blocked` / `BlockedBy` (1 graph read per export). **Ticket W7-30.**

### M-3 (Medium): the "not end-to-end encrypted" disclosure is missing
**Where.** `app/lib/features/messages/presentation/conversations_screen.dart:313-318`: the Inbox empty state reads
"Welcome to your inbox / Start a conversation"; no string containing "encrypt" exists in `app/lib` outside generated
code. ADR-0027 D11 (lines 288-289) and the plan's risk table require the line. No Privacy Policy and no Terms draft are
on `main` (`pending.md` 3.9; PR #149 closed unmerged).

**Scenario.** Users assume WhatsApp-style privacy and share sensitive content that operators, CI identities (M-4) and
lawful-access requests can read. A transparency obligation (DPDP Act s.5 notice; GDPR Art. 13) and a deceptive-design risk.

**Fix.** Show "Messages are not end-to-end encrypted" in the Inbox empty state, and persistently after the first
conversation (subtitle on `/messages/new` and in the request banner). Founder: the policy lines in section 4.
**Ticket W7-31.**

### M-4 (Medium, re-raises the accepted v0.1.0 M4): the CI plan identity can read every DM in prod
**Where.** `infra/terraform/modules/iam/main.tf:223-227` (`tf-plan` SA has `roles/viewer`, which includes
`datastore.entities.get/list`); `:332-336` (the plan pool accepts any `pull_request` or `workflow_dispatch` in this repo,
no workflow pin); `:349-353` (binding). `docs/reviews/release-v0.2.0-readiness.md:168`: M4 accepted, expiring "when a
second collaborator is added".

**Attack.** A same-repo PR runs workflow files from its own head; a PR that edits a workflow gets an OIDC token before
review, impersonates `tf-plan` in prod and lists `conversations/*/messages`, `reports.evidence`, `users/{uid}/private`.
The assistant's GitHub App identity is arguably the "second collaborator" that ends the acceptance.

**Impact.** Bulk read of all private messages. **Fix.** Replace `roles/viewer` with a custom read role without
`datastore.entities.*` and `firebaseauth.users.*` (plan needs metadata only, e.g. `datastore.databases.get`,
`datastore.indexes.list`). Pinning `job_workflow_ref` alone does not help. **Ticket W7-32; founder decision before prod
messaging.** Dev holds only test data.

### L-1 (Low): A8, stale block window on send
**Where.** `service_send.go:140-147, 165, 172, 182`: both graph snapshots cached 60 s; `messaging.Social` (`api.go:66-68`)
exposes only `Snapshot`. After a block, a harasser on another instance can send for up to 60 s (about 60 messages across
3 instances), each moving the badge and possibly pushing. A stale `Following` can also make a conversation "mutual"
(skips Requests, the 3-message cap, and pushes) for up to 60 s after an unfollow.
**Fix.** A graph seam `graph.Reader.SnapshotInTx(tx, uid)` (precedent: identity `ProfileInTx`, ADR-0025 D6); the send
transaction reads the recipient's graph inside the transaction so a concurrent Block serialises with the send. +1 read
per send (about INR 0.5 / 1.6 / 4.7 a month at 300 / 1,000 / 3,000 DAU). Needs an ADR-0027 note. **Ticket W7-33.**

### L-2 (Low): the erasure placeholder `deleted` is a valid uid
**Where.** `model.go:46` (`DeletedUID = "deleted"`) passes `ids.ValidUID`; `hasParticipant` (`model.go:149-156`) is the
membership test for ListMessages, ReportableMessage, MarkRead and Delete. An account with uid `deleted` would be a
participant of every conversation whose other side was erased. Prod needs an Admin-SDK or operator-created uid; the auth
emulator lets anyone create one. **Fix.** A placeholder `ValidUID` refuses (ADR-0008 A3: uids never contain `_`, so
`_deleted`), plus a dev data migration, or reject the reserved value in authn. **Ticket W7-34.**

### L-3 (Low): purge race A7, fresh status read outside the transaction
**Where.** `service_send.go:246-256`, `repo_firestore.go:226-236`: `FreshRecipient` is a directory read outside the
transaction's read set. A new-conversation send that reads status before DELETING and commits after the eraser's cursor
passed leaves a real uid in `participants` and an entry under the deleted user; the backstop does not re-run once
`users/{uid}` is gone. **Fix.** Read the recipient's `users` doc with identity `ProfileInTx` in the send transaction
(+0 reads; replaces the fresh read). **Ticket W7-33.**

### L-4 (Low): the drift cache is not tied to its owner
**Where.** `app/lib/core/storage/app_database.dart:185-231` (messaging tables have no uid column, although
`messaging_store.dart:10-12` says "per uid"); `app/lib/app/bootstrap.dart:258-279` (the wipe runs only on an observed
user → null change, `unawaited`). If the process dies during sign-out or the auth stream goes A → B directly, B sees A's
cached snippets and threads until the refresh. **Fix.** Stamp the owner uid; when the session uid differs or there is no
stamp, await `clearAll()` before any cache read; await the wipe in sign-out. **Ticket W7-35.**

### L-5 (Low): Android Auto Backup copies cached messages off the device
**Where.** `AndroidManifest.xml:4-7`: no `android:allowBackup`, so it defaults to true; the drift database (with message
text) goes to Drive backup and device transfer and outlives account deletion. **Fix.** `android:allowBackup="false"`, or
`dataExtractionRules` / `fullBackupContent` excluding `databases/`. **Ticket W7-35.**

### L-6 (Low, founder): unresolved reports keep private text with no TTL
ADR-0016 D5 (`:54, :163`) sets `expireAt` only at resolution, so an untriaged MESSAGE report keeps the text indefinitely,
including after the sender's erasure. **Fix.** Enforce the 48 h triage SLA and state the indefinite case in the Privacy
Policy, or give OPEN MESSAGE reports a TTL (e.g. `createdAt + 180 d`) or clear `evidence.text` when stale. Founder.

### L-7 (Low): log pseudonyms can be reversed by guessing
`pkg/platform/logger/logger.go:106-112`: `HashUID` is unsalted SHA-256 truncated to 64 bits, and `conversation_hash =
HashUID(convID)` where `convID` is itself an unsalted hash of two public uids, so anyone with `logging.viewer` (including
`tf-plan`, M-4) can compute it for any pair. `service_messages.go:289-291`: `messagesErr` does not redact the peer uid.
**Fix.** HMAC `conversation_hash` with a key derived from `CURSOR_HMAC_KEY` (HKDF; no new secret version); pass the peer
uid to the redact list. **Ticket W7-34.**

### L-8 (Low, defence in depth): SendMessage has no explicit verified-email gate
`service_send.go:64-77`. A user who changes to an unverified email keeps sending; posts, likes, reposts and reports check
again. **Fix.** `authn.RequireVerifiedEmail(ctx, allowAnonymous, "messaging")` in Send and Accept. **Ticket W7-33.**

### L-9 (Low): links from strangers are tappable before the request is accepted
`message_bubble.dart:119-123, 364-372`, `thread_screen.dart:351`. The post link rules apply and are fine for accepted
threads; requests are the phishing channel. **Fix.** Plain text, or an "Open link to `<host>`?" confirmation, in REQUEST
threads until accepted. **Ticket W7-35.**

### L-10 (Low, product): no backstop against inbound request rings
A ring of N accounts delivers 3N messages a day into Requests (no push, F7; blocked one by one). **Fix.** The F2(d)
setting "Allow message requests from: Everyone / No one" (+0 reads, rides on the recipient `users` read). Follow-up.

### Info (verified, no finding)
- **NOT_FOUND bytes** are identical for a missing conversation and a non-participant (`errors.go:53`); a malformed id is
  VALIDATION with 0 reads; every refusal is the one `cannotMessage()` (`errors.go:41`), with block checked before caps.
- **Retired since token:** `since_retired` uses the same `apierr.Validation("since_token", "invalid or expired
  since_token")` as a decode failure (`service_messages.go:123`, `:158`), after the participant check.
- **`requestHash`:** no extra exposure (same document as the plaintext; never on the wire, in exports or logs; cleared on
  takedown `repo_moderation.go:145` and erasure `repo_lifecycle.go:174`).
- **`clearedKey`:** a digest of a random client key; erased with `clearedAt` (`repo_lifecycle.go:237-242`). The T11
  map-key sweep follow-up is already in `pending.md` 3.16.
- **Push:** generic title and body; `data` is `{type, conversationId}` only (`fcm.go:40, 128`); no push for requests or
  muted senders; fan-out suppresses blocked actors (`fanout.go:252-286`).
- **N6:** a tray push from a previous account cold-opens to "isn't available" with generic text; sign-out unregisters and
  deletes the token (`push_cubit.dart:268-292`). Optional: cancel displayed notifications on sign-out.
- **Deep link:** `^/messages/[0-9a-f]{32}$`, query or fragment rejects (`app_router.dart:421-444`); `%61` normalises to the
  same id (benign); `notificationLocation` validates the raw id first.
- **Referrer:** `Referrer-Policy: strict-origin-when-cross-origin` (`firebase.json:33`).
- **Report identifiers:** the reports export's `targetId` and the reporter residue were accepted by the founder (ADR-0016
  addendum 2026-10-29). The reporter's own export holds no evidence text.
- **Degraded mode:** only the two list RPCs are `NO_SIDE_EFFECTS`; all four mutations are refused (`degraded.go:43`).
- **E2E seam:** holds. Only `internal/messaging` builds paths into the three collections. Two plaintext copies live
  outside message documents and an E2E ADR must replace both: `reports.evidence.text` (F11) and the entries'
  100-code-point `last.snippet`.
- **Logs:** no text, snippets or clear ids in request lines; `failure()` redacts uid, conversation, peer and message id
  (`service_send.go:304, 333`), apart from L-7.

## 3. Verdicts

**A8 (block freshness on send): flip to a fresh read of the recipient's graph inside the send transaction** (L-1). About
INR 0.5 / 1.6 / 4.7 a month at 300 / 1,000 / 3,000 DAU, a small graph seam and an ADR-0027 dated note. It also corrects a
stale `Mutual`. Not a dev-allowlist blocker; do it before prod leaves allowlist.

**F5 (export contents): PASS as decided, with one fix.** `export.go:102-131` exports the user's own messages in full with
their state; received messages as `direction: received` plus a time, never the text; the peer's handle at export time
with no peer uid and no conversation or message ids; and `state`, `createdAt`, `clearedAt`. Messages before `clearedAt`
are included, which is correct (still held). The gap is a blocker's current handle (M-2). The Privacy Policy must say
received messages are exported as metadata only.

**Handed-over items:** the probe timing signal is not weak (H-1); `%61` and percent-encoded push data OK; N6 Info;
`targetId` and reporter residue accepted; `since_retired` bytes identical; `clearedKey` OK; `requestHash` no exposure.

## 4. Founder actions
1. **Privacy Policy** (before any non-team user; extends `pending.md` 3.18):
   - Direct messages are **not end-to-end encrypted**; they are stored on our servers (Google Cloud, Mumbai) with
     Google-managed encryption at rest.
   - A reported message is copied for moderators and kept until 90 days after the report is resolved (indefinitely while
     unresolved, L-6), even after the sender deletes their account. Staff with database access can technically read
     messages and do so only for safety or legal reasons; messages can be disclosed under lawful orders.
   - Messages stay until the account is deleted (no time limit in v1). "Delete conversation" removes it only from your
     inbox; the other person keeps their copy. After account deletion your messages show as "Message deleted" and their
     text is erased.
   - Push notifications carry no sender and no text.
   - The data export includes your sent messages in full and received messages as timestamps only.
2. **Terms of Service** (`pending.md` 3.9): acceptable use for messages (no spam, no harassment), the request limits,
   report and takedown (a takedown cannot be undone), and the no-E2E line.
3. **M-4:** re-decide the `tf-plan` `roles/viewer` acceptance, or approve the custom read role, before prod messaging.
4. **A8:** acknowledge the flip (an ADR-0027 note).
5. **L-6:** commit to the 48 h triage SLA, or approve a TTL for OPEN MESSAGE reports.
6. **Prod ceiling:** keep `messaging` allowlist-only in prod until H-1, M-1, M-2 and M-3 are fixed and M-4 is decided.

## 5. Tickets

| ID | Finding | Owner | Size | Gate |
|---|---|---|---|---|
| W7-28 | H-1 non-participant cache isolation in `conversationHit`, plus a test | backend-developer | S | ticketed before the dev allowlist; fixed before any user outside the 3 team uids |
| W7-29 | M-1 `messages_mark_read_daily` and `messages_mutation_daily` caps | backend-developer | S | before the flag leaves the dev allowlist |
| W7-30 | M-2 frozen peer snapshot when blocked (thread header and export) | backend-developer | S | before prod; can ride with W7-27 |
| W7-31 | M-3 "not end-to-end encrypted" copy (Inbox, new message, request banner) | frontend-developer | XS | before any non-team user |
| W7-32 | M-4 custom read role for `tf-plan` | production-deployer + founder | S | before prod messaging |
| W7-33 | L-1 A8 `SnapshotInTx` seam, L-3 `ProfileInTx` in the send transaction, L-8 verified-email gate | architect (note) + backend-developer | S | before prod percent / on |
| W7-34 | L-2 placeholder `_deleted` plus dev migration; L-7 HMAC `conversation_hash` and peer redaction | backend-developer | S | before prod |
| W7-35 | L-4 owner-stamped wipe, L-5 Android backup exclusion, L-9 request-thread links | frontend-developer | S | before prod |
| — | L-6 SLA or TTL; L-10 F2(d) setting | founder / planner | — | follow-up |

## Verdict

**SECURITY: BLOCKED for prod** — H-1 is a release blocker for prod; M-1 to M-4 must also be fixed or decided before prod.

**Dev allowlist: GO**, on these conditions:
1. H-1 is ticketed (W7-28) before `feature_messaging` leaves `off` in dev.
2. The dev allowlist stays at the 3 team test accounts (the flag ceiling `max_allowlist: 3` enforces it); no real-user data.
3. M-1 to M-4 and the Lows are ticketed per section 5.
4. Nothing moves in prod until H-1, M-1, M-2 and M-3 are fixed, M-4 is decided, and the section 4 Privacy Policy and
   Terms lines exist.
