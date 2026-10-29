# Security review: W7 Messaging v1 (W7-22)

**Reviewer:** security-auditor · **Date:** 2026-10-29 · **Reviewed:** `origin/main` at `60f1e353`, a read-only snapshot. The local checkout was behind, at `e92ed5c9`.

**Scope:** the 12 binding items of the W7-22 ticket, the stage-ladder rate-limit multiplication, the E2E seam, and the items earlier code reviews handed over.

**Code read:**
- `backend/internal/messaging/*`
- `backend/internal/moderation/{message,service,server}.go`
- `backend/internal/apiserver/{moderation_messages,messaging_wiring,ratelimit_config}.go`
- `backend/cmd/opsctl/messages.go`
- `backend/pkg/platform/cursor/rev.go`
- `backend/internal/notifications/{fanout,fcm}.go`
- `pkg/platform/{degraded,logger}`
- `app/lib/features/messages/**` and `app/lib/features/notifications/**`
- `app/lib/core/router/app_router.dart`, `app/lib/core/storage/app_database.dart`, `app/lib/app/{bootstrap,session_wiring}.dart`
- `app/lib/shared/widgets/browser_context_menu_guard.dart`
- `firebase.json`, `infra/terraform/modules/iam/main.tf`, `app/android/app/src/main/AndroidManifest.xml`

**Not run:** tests, `govulncheck` and `osv-scanner`. W7-20 and W7-21 (tester) are still Open, so no authz test results were available to me. Every finding below comes from reading the code.

## 1. Threat model (STRIDE)

**Assets:**
- Message text, the private content.
- Who talks to whom: conversation existence and timing metadata.
- Participant uids.
- Block, mute and request state.
- Report evidence.
- The cost budget: INR 25,000 credit cap, Firestore free writes of 20k a day.

| STRIDE | Threat | Control in the code | Result |
|---|---|---|---|
| **S**poofing | Acting as another participant; forged since or page tokens | Firebase ID token gives the uid. The message id is `H(senderUid\|op\|key)`, so a key is scoped per user. Tokens are AEAD-sealed and bound to `(uid, conversation, kind)` with a 30-day TTL. Revision tokens use their own AEAD domain (`rev.go:12`). | Holds |
| **T**ampering | Rewriting someone else's entry or message; replaying a key with a new body | Entry paths are built from the token uid only (`MarkRead`, `Delete`). `Create` plus `requestHash` gives VALIDATION on a reused key. Takedown and eraser use field-level `Update` and never `Set`. `LastUpdateTime` guards the tombstone pages. | Holds |
| **R**epudiation | A moderator action with no trace; a forged report | `opsctl` prints an audit line with hashed ids (`messages.go:88`). Report evidence is copied server-side, so a reporter cannot fabricate text. | Holds |
| **I**nformation disclosure | A non-participant reads a thread; a conversation-existence oracle; a block bypass; push or lock-screen content; logs; a shared device; operator or CI access | Participant check on every read and write, and a byte-identical NOT_FOUND. Generic push with `data = {type, conversationId}`. The sign-out wipe. | **H-1** (existence oracle), **M-2** (blocker's profile), **M-4** (CI identity reads all DMs), L-4, L-5, L-6, L-7 |
| **D**enial of service / cost | Send floods, polling, write amplification | Send bucket, daily caps, exact `dmNew` and request cap, read budget, max-instances 3, degraded mode | **M-1** (MarkConversationRead writes have no daily cap) |
| **E**levation of privilege | Becoming a participant of someone else's conversation; reading erased conversations | Membership is immutable in 1:1. `gone` blocks sends. | L-2 (the placeholder uid `deleted` is a valid uid) |

### Effective limits (per instance × 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| SendMessage bucket | 20/min | 60/min | memory |
| `messages_daily` | 300/day | 900/day | memory |
| New-account send tier (`newSends`, `service.go:89`) | 50/day | **150/day** (ADR D13 says "50"; worth a doc fix) | memory |
| `dmNew` | 20/day, new accounts 5 | exact | `quotas` |
| Request cap | 3 | exact | in the transaction |
| ListConversations + ListMessages bucket | 30/min | 90/min | memory |
| Read budget | 2,000/day | 6,000 reads/uid/day | memory |
| Pushes per recipient | 20/h | 60/h | memory |
| ReportContent | 5/min | 15/min; quota 20/day exact | memory / `quotas` |
| MarkConversationRead, AcceptMessageRequest, DeleteConversation | **default 60/min, no daily cap** | **180/min = 259,200 calls/day** | memory (see M-1) |

## 2. Findings

### H-1 (High): "Does A talk to B" oracle through the shared conversation cache
**Where:**
- `backend/internal/messaging/service_send.go:229-242`: `conversationHit` calls `putConv` on any document it finds, at line 240, before any participant check.
- The callers check participation only afterwards: `service_messages.go:138-142` (ListMessages), `report.go:59-63` (ReportContent MESSAGE), `service_send.go:122-129` (SendMessage by `conversation_id`).

**Attack:**
1. Uids are public (`AuthorSnapshot.user_id`, `/u/<uid>`), and `ConversationID(a, b)` is a public function of two uids.
2. The attacker calls `ListMessages(conversation_id = ConversationID(A, B))` twice.
3. If the conversation exists, the first call reads and caches it, and the second call is answered from memory (about 0 ms server time).
4. If it does not exist, nothing is cached, so every call pays a Firestore point read (about 5–20 ms in asia-south1).
5. Both answers are the identical NOT_FOUND, but the latency differs. The probe warms the cache itself, so this is not the "weak" signal earlier reviews assumed.
6. A random 32-hex control id calibrates the jitter. 90 probes a minute per account are enough for several pairs a minute even on mobile networks. With credit-mode min-instances 1 at low traffic, most probes hit the same instance.
7. A first probe that comes back fast also shows that a participant was active on that instance in the last 60 s.
8. ListMessages needs only "not globally off" (F6), so any signed-in account can probe once the flag is on anywhere, including in dev.

**Impact:** relationship metadata of any pair of users: stalking, outing, an abuser checking whether a victim talks to someone. No message content leaks. No response header carries `cache_hit` or `fs_reads` (checked), so the channel is timing only.

**Cost scenario:** negligible. The probes are reads charged to the attacker's own budget, at most 6,000 a day, about INR 6 per account-month.

**Fix:** one change in `conversationHit`, which covers all three callers.
- Use a cached copy only when the caller is in its `participants`.
- On a cache hit where the caller is not a participant, or on any miss, do a fresh `GetConversation`.
- Never put a document into the shared cache from a request whose caller is not a participant.
- Every non-participant probe then costs exactly 1 Firestore read whether the conversation exists or not. Participants' hot paths are unchanged (+0 reads).
- Add a W7-20 test with a fake repo that counts repo calls: a non-participant pays one repo read per call, whether the conversation exists, is warm or is missing.

**Proposed ticket:** W7-28, backend-developer, S.

### M-1 (Medium, cost amplification): MarkConversationRead is an unbounded writer
**Where:**
- `backend/internal/apiserver/ratelimit_config.go:105-112, 154-156, 177`: MarkConversationRead, AcceptMessageRequest and DeleteConversation fall to the 60/min default bucket and have no `DailyCap`.
- `service_messages.go:306-331` and `repo_firestore.go:450-464`: each call with an existing entry is 1 write.
- The account-status interceptor read is cached, so the ADR-0010 D5 read budget never binds.

**Attack:**
1. One verified account sends one message, which creates its own `dmInbox` entry.
2. It then loops `MarkConversationRead` on that entry: 180 calls/min across 3 instances, which is 259,200 writes/day.
3. Accept and Delete are idempotent by state and write nothing on repeat. MarkRead writes every time.

This is the same class as the bookmark idempotency writes (W2-14 M-1) and UpdateProfile (W3-22 L-4), both since capped. This one is 2× and 43× worse than those two.

**Cost scenario (INR 95/USD, `cost-model.md` §7 prices, marginal):** per account-month, 7.89M writes, 7.89M requests and the CPU behind them.

| Line | Amount | INR / account-month |
|---|---|---|
| Firestore writes | 7.89M × $0.104/100k | 779 |
| Cloud Run requests | 7.89M | 300 |
| vCPU, 20 ms per call | | 360 |
| vCPU, the model's 0.1 s per call | | 1,800 |
| **Total** | | **≈ 1,440 to 2,880** |

- Ten sockpuppets reach INR 14k–29k a month: the whole ADR-0022 credit cap.
- One account alone uses the product's free 20k writes/day in about 2 hours.

**Fix:**
- A per-uid `DailyCap` `messages_mark_read_daily`, for example 500 (the client calls it only with unread > 0). Effective 1,500 writes/day at 3 instances, about INR 4.5 per account-month.
- Put Accept and Delete under one shared `messages_mutation_daily` cap, as graph mutations do.
- Optional: skip the write when the entry already has `unreadCount == 0`. That needs a read, so the cap is the cheaper control.
- Config only (rule 11).

**Proposed ticket:** W7-29, backend-developer, S. Fix before the flag leaves the dev allowlist.

### M-2 (Medium): a blocked user still sees the blocker's current profile
**Where:**
- `service_messages.go:180-188`: the peer profile comes from the directory with no block check.
- `service_messages.go:266-284`: `threadConversation` returns the live handle, display name, avatar and verified flag even when `snap.BlockedBy[peer]`.
- `export.go:134-156`: `peerHandles` puts the peer's current handle in the export with no block check.

**Attack:**
1. A victim blocks a harasser and renames their handle to get away. Renaming is the usual safety step.
2. The harasser opens their old thread (a ListMessages first page or an older page).
3. The header shows the new handle and avatar. `can_reply = false` confirms the block.
4. The product hides a blocker's profile everywhere else: GetProfile answers NOT_FOUND (ADR-0027 D4 relies on that).
5. The account export leaks the same thing, rate-limited by `account_ops_daily`.

**Impact:** a block-evasion bypass, a harassment safety issue. No cost.

**Fix:**
- When the caller's snapshot has `BlockedBy[peer]` (and on `BlockedByOverflow`, use the peer's snapshot), do not look the peer up.
- Return the frozen snapshot on the caller's own entry instead: what they already saw at the last message. W7-27 already adds the caller's entry read on the first page, so this costs +0 reads there.
- For older pages, omit the header or use the same frozen snapshot.
- In the export, skip the directory lookup for peers in the caller's `Blocked` / `BlockedBy`: 1 graph read per export.

**Proposed ticket:** W7-30, backend-developer, S. It can ride with W7-27.

### M-3 (Medium): the "not end-to-end encrypted" disclosure is missing
**Where:**
- `app/lib/features/messages/presentation/conversations_screen.dart:313-318`: the Inbox empty state reads "Welcome to your inbox / Start a conversation". No string containing "encrypt" exists in `app/lib` outside generated code.
- ADR-0027 D11 (lines 288-289) and the plan's risk table (line 979) require the line.
- No Privacy Policy is on `main`.
- The Terms draft is not on `main` either (`pending.md` 3.9; PR #149 was closed unmerged).

**Scenario:** users assume WhatsApp-style privacy and share sensitive content that operators, CI identities (M-4) and lawful-access requests can read. This is a transparency obligation under DPDP Act s.5 (notice) and GDPR Art. 13, and a deceptive-design risk.

**Fix:**
- Client: show "Messages are not end-to-end encrypted" in the Inbox empty state as the ADR says. Also show it persistently somewhere the user sees after the first conversation, for example as a subtitle on the new-message (`/messages/new`) screen and in the request banner. The empty state disappears for good once one conversation exists.
- Founder: the policy lines in section 4.

**Proposed ticket:** W7-31, frontend-developer, XS, plus founder actions. Must be done before any non-team user.

### M-4 (Medium, re-raises the accepted v0.1.0 M4): the CI plan identity can read every DM in prod
**Where:**
- `infra/terraform/modules/iam/main.tf:223-227`: the `tf-plan` SA has `roles/viewer`, which includes `datastore.entities.get/list`.
- `:332-336`: the plan pool accepts any `pull_request` or `workflow_dispatch` in this repo, with no workflow pin.
- `:349-353`: the binding.
- `docs/reviews/release-v0.2.0-readiness.md:168`: M4 was accepted, and the acceptance expires "when a second collaborator is added".

**Attack:**
1. Any same-repo PR runs the workflow file from its own head branch.
2. A PR that edits or adds a workflow gets an OIDC token before any review, impersonates `tf-plan` in prod, and lists `conversations/*/messages`, `reports.evidence` and `users/{uid}/private`.
3. CLAUDE.md says the assistant opens PRs through its own GitHub App identity. That is arguably the "second collaborator" that ends the acceptance, and any agent session, or a compromised App token, can do this.

**Impact:** bulk read of all private messages. Messaging turns an accepted PII risk into a private-content risk.

**Fix (production-deployer):**
- Replace `roles/viewer` with a custom read role without `datastore.entities.*` and `firebaseauth.users.*`. What plan needs is `datastore.databases.get`, `datastore.indexes.list` and similar metadata permissions.
- Pinning `job_workflow_ref` alone does not help, because a PR can edit the pinned file.

**Proposed ticket:** W7-32. Founder decision before prod messaging. Dev holds only test data.

### L-1 (Low): A8, a stale block window on send (verdict in section 3)
**Where:** `service_send.go:140-147, 165, 172, 182`: both graph snapshots are cached for 60 s. `messaging.Social` (`api.go:66-68`) exposes only `Snapshot`, and graph offers no fresh read through that seam.

**Scenario:**
- After a victim blocks, a harasser whose requests land on another instance can send for up to 60 s: at most about 60 messages across 3 instances. Each one moves the unread badge, and the push may go out too, because the fan-out instance's snapshot is just as stale.
- A stale `Following` can also make a new conversation "mutual". It then skips Requests, skips the 3-message cap and pushes, for up to 60 s after an unfollow.

**Fix:** a small graph seam such as `graph.Reader.SnapshotInTx(tx, uid)` (precedent: identity `ProfileInTx`, ADR-0025 D6). The send transaction reads the **recipient's** graph inside the transaction, so a concurrent Block serialises with the send (Block writes the recipient's graph). The recipient's `Blocked` is authoritative. The caller's own stale block is self-inflicted and can stay cached.

**Cost:** +1 read per send, about INR 0.5 / 1.6 / 4.7 a month at 300 / 1,000 / 3,000 DAU. This needs an ADR-0027 note plus the seam, not "one call".

### L-2 (Low): the erasure placeholder `deleted` is a valid uid
**Where:** `model.go:46` (`DeletedUID = "deleted"`) passes `ids.ValidUID` (`^[A-Za-z0-9-]{1,128}$`). `hasParticipant` (`model.go:149-156`) is the only membership test used by ListMessages (`:140`), ReportableMessage (`:61`) and MarkRead/Delete.

**Scenario:** an account whose uid is literally `deleted` counts as a participant of every conversation whose other side was erased. It can read every surviving peer's thread and report it; sends stay blocked by `gone`.
- In prod this needs an Admin-SDK or operator-created uid. Email, Google and Apple issue 28-character random uids.
- In the auth emulator anyone can create one.
- No other module uses a `"deleted"` placeholder (checked).

**Fix:** use a placeholder that `ValidUID` refuses. ADR-0008 A3 says a uid never contains `_`, so `_deleted` works. Migrate dev placeholder data; messaging was never on in prod. Alternatively, reject the reserved value in authn.

### L-3 (Low): purge race A7, the fresh status read is outside the transaction
**Where:** `service_send.go:246-256` and `repo_firestore.go:226-236`: `FreshRecipient` is a directory read, not part of the transaction's read set.

**Scenario:** a new-conversation send whose status read happens before `DeleteAccount` sets DELETING, and which commits after the eraser's cursor has passed that conversation id. The window is a few milliseconds up to the 5 s transaction timeout, and the `messaging` step runs many steps after DELETING. The residue is a real uid in `participants` and an entry under the deleted user. That is pseudonymous data, and the backstop does not re-run once `users/{uid}` is gone.

**Fix:** read the recipient's `users` document with identity `ProfileInTx` inside the send transaction. That closes the race at +0 reads, since it replaces the fresh read.

### L-4 (Low): the drift cache is not tied to its owner
**Where:**
- `app/lib/core/storage/app_database.dart:185-231`: the messaging tables have no uid column, although `messaging_store.dart:10-12` says "per uid".
- `app/lib/app/bootstrap.dart:258-279`: the wipe runs only on an observed in-process user → null change, and it is `unawaited`.

**Scenario:** the process dies during sign-out (the user swipes the app away), or an auth stream goes from A to B directly. User B then sees A's cached inbox snippets and threads until the network refresh.

**Fix:**
- Stamp the owner uid (`account:owner` setting).
- When a session's uid differs from the stamp, or there is no stamp, await `clearAll()` before any cache read.
- Await the wipe in the sign-out flow.

### L-5 (Low): Android Auto Backup copies cached messages off the device
**Where:** `AndroidManifest.xml:4-7`: there is no `android:allowBackup`, so the default is true. The drift database, which holds message text including the peer's, goes to Google Drive backup and to device-to-device transfer, and outlives account deletion.

**Fix:** `android:allowBackup="false"`, or `dataExtractionRules` / `fullBackupContent` that exclude `databases/`.

### L-6 (Low, founder): unresolved reports keep private text with no TTL
**Where:** ADR-0016 D5 (`:54, :163`): `expireAt` is set only at resolution. A MESSAGE report that nobody triages keeps the private text indefinitely, including after the sender's erasure (accepted in the 2026-10-29 addendum).

**Fix:** enforce the 48 h triage SLA (`docs/runbooks/moderation.md`) and state the indefinite case in the Privacy Policy. Or give OPEN MESSAGE reports a TTL (for example `createdAt + 180 d`), or clear `evidence.text` when they go stale.

### L-7 (Low): log pseudonyms can be reversed by guessing
**Where:**
- `pkg/platform/logger/logger.go:106-112`: `HashUID` is an unsalted SHA-256 truncated to 64 bits.
- `conversation_hash = HashUID(convID)`, and `convID` is itself an unsalted hash of two public uids.
- `service_messages.go:289-291`: `messagesErr` redacts only the caller uid and the conversation id, not the peer uid, which could appear in a directory error.

**Scenario:** anyone with `logging.viewer` (including `tf-plan`, see M-4) computes the conversation hash for any pair and reads when and how often those two users messaged.

**Fix:**
- Make `conversation_hash` an HMAC with a key derived from `CURSOR_HMAC_KEY` via HKDF. That needs no new Secret Manager version.
- Pass the peer uid to `messagesErr`'s redact list.

### L-8 (Low, defence in depth): SendMessage has no explicit verified-email gate
**Where:** `service_send.go:64-77`. CreateProfile requires a verified email and Send needs a profile. The gap is a user who changes their email to an unverified address afterwards; Firebase then sets `email_verified` to false. Posts, likes, reposts and reports each check it again.

**Fix:** `authn.RequireVerifiedEmail(ctx, allowAnonymous, "messaging")` in Send and Accept.

### L-9 (Low): links from strangers are tappable before the request is accepted
**Where:** `message_bubble.dart:119-123, 364-372` and `thread_screen.dart:351`. The post rules apply: http(s) only, no userinfo, ASCII host, the raw URL shown, the grammar strips bidi characters. They are fine for accepted threads. Requests are the phishing channel.

**Fix:** in REQUEST threads, render links as plain text until the request is accepted, or confirm with "Open link to `<host>`?".

### L-10 (Low, product): no backstop against inbound request rings
There is no cap on how many requests one recipient can receive. A ring of N accounts delivers 3N messages a day into Requests. No push is sent (F7), and each account has to be blocked one by one.

**Fix:** the F2(d) setting "Allow message requests from: Everyone / No one". It adds 0 reads, because it rides on the recipient `users` read the send already makes. Ticket it as a follow-up.

### Info (verified, no finding)
- **Non-participant answers:** NOT_FOUND bytes are identical for a missing conversation and a non-participant (`errors.go:53`). A malformed id is VALIDATION with 0 reads. Every refusal is the one `cannotMessage()` (`errors.go:41`), and the ordering puts block before the caps, so a cap never reveals a block.
- **Retired since token:** `since_retired` uses the same `apierr.Validation("since_token", "invalid or expired since_token")` as a decode failure (`service_messages.go:123` and `:158`), so the bytes are identical. It is checked after the participant check. A pre-revision token decodes as rev 0, so it is retired, never accepted.
- **`requestHash`:** no additional exposure. It lives in the same document as the plaintext, so anyone who can read it can already read the text. It is never on the wire, in exports or in logs, and it is cleared on takedown (`repo_moderation.go:145`) and on erasure (`repo_lifecycle.go:174`). Brute-forcing it gains nothing.
- **`clearedKey`:** a digest of a random client key. It carries no content and is erased with `clearedAt` (`repo_lifecycle.go:237-242`). The T11 sweep does not scan map keys; that follow-up is already recorded in `pending.md` 3.16.
- **Push:** title and body are "New message" / "You have a new message". `data` is `{type, conversationId}` only (`fcm.go:40, 128`). No push for requests or muted senders, and the fan-out suppresses blocked actors (`fanout.go:252-286`).
- **N6:** a tray push from a previous account cold-opens to "isn't available", and its text is generic. Sign-out unregisters the device and deletes the token (`push_cubit.dart:268-292`). Optional: cancel displayed notifications on sign-out.
- **Deep link:** `deepLinkTarget` uses `^/messages/[0-9a-f]{32}$`, and a query or fragment rejects the link (`app_router.dart:421-444`). `%61` is normalised by `Uri` to the same id, which is benign. `notificationLocation` checks the raw id before building the path, so an encoded id is dropped.
- **Referrer:** `Referrer-Policy: strict-origin-when-cross-origin` (`firebase.json:33`), so a conversation id never reaches the external sites links open.
- **Report identifiers:** the reports export emitting `targetId = convId:msgId`, and the reporter residue after erasure, were both accepted by the founder (ADR-0016 addendum 2026-10-29). The reporter's own export contains no evidence text.
- **Degraded mode:** `degraded.go:43` refuses everything not marked `NO_SIDE_EFFECTS`. Only the two list RPCs carry that marker, so all four mutations are refused and the reads stay up.
- **E2E seam:** it holds. Only `internal/messaging` builds paths into the three collections; moderation goes through `MessageLookup` and identity through `MessageBadge`. Two plaintext copies live outside the message documents, and an E2E ADR must replace both: `reports.evidence.text` (moderation, F11; needs franked client-side reports) and the 100-code-point `last.snippet` on the entries.
- **Logs:** no message text, snippets or clear ids in request lines. `failure()` redacts the uid, conversation id, peer and message id (`service_send.go:304, 333`), apart from the L-7 gap.

## 3. Explicit verdicts

**A8 (block freshness on send): flip to a fresh read of the recipient's graph inside the send transaction.** See L-1.
- It costs about INR 0.5 / 1.6 / 4.7 a month at 300 / 1,000 / 3,000 DAU.
- It needs a small graph seam (`SnapshotInTx`) and an ADR-0027 dated note, but no ADR change.
- It also corrects a stale `Mutual` (Inbox vs Requests, push vs none).
- Not a dev-allowlist blocker. Do it before prod leaves allowlist.

**F5 (export contents): PASS as decided, with one fix.** `export.go:102-131` exports:
- the user's own messages in full, with their state;
- received messages as `direction: received` plus a time, never the text;
- the peer's handle at export time, with no peer uid and no conversation or message ids;
- the state, `createdAt` and `clearedAt`.

Messages before `clearedAt` are included. That is correct: the data is still held, so the right of access covers it. The one gap is the current handle of a peer who blocked the user (M-2). Fix: use the frozen entry snapshot, or omit the handle when blocked. The Privacy Policy must say that received messages are exported as metadata only.

**Items handed over by earlier code reviews:**
- The probe timing signal is **not weak** (H-1).
- `%61` and percent-encoded push data: OK.
- N6: Info.
- `targetId` and reporter residue: accepted.
- `since_retired` bytes: identical, OK.
- `clearedKey`: OK.
- `requestHash`: no exposure while live.

## 4. Founder actions
1. **Privacy Policy, add these lines** (needed before any non-team user; extends `pending.md` 3.18):
   - Direct messages are **not end-to-end encrypted**. They are stored on our servers (Google Cloud, Mumbai) with Google-managed encryption at rest.
   - Who can read messages: a reported message is copied for moderators, kept until 90 days after the report is resolved (indefinitely while unresolved, see L-6), even after the sender deletes their account. Staff with database access can technically read messages and do so only for safety or legal reasons. Messages can be disclosed under lawful orders.
   - Retention: messages stay until the account is deleted; there is no time limit in v1. "Delete conversation" removes it only from your inbox, and the other person keeps their copy. After account deletion, your messages show as "Message deleted" to the other person and their text is erased.
   - Push notifications carry no sender and no text.
   - The data export includes your sent messages in full and received messages as timestamps only.
2. **Terms of Service** (`pending.md` 3.9; the draft is not on `main`): add acceptable use for messages (no spam or unsolicited bulk messages, no harassment), the message-request limits, report and takedown (a takedown cannot be undone), and the no-E2E line.
3. **M-4:** re-decide the `tf-plan` `roles/viewer` acceptance (its expiry condition is arguably met by the GitHub App identity), or approve the custom read role, before prod messaging.
4. **A8:** acknowledge the flip, which goes in an ADR-0027 note.
5. **L-6:** commit to the 48 h report triage SLA, or approve a TTL for OPEN MESSAGE reports.
6. **Prod ceiling:** keep `messaging` allowlist-only in prod until H-1, M-1, M-2 and M-3 are fixed and M-4 is decided.

## 5. Proposed tickets (the planner assigns final numbers; W7-27 is the highest existing)

| ID | Finding | Owner | Size | Gate |
|---|---|---|---|---|
| W7-28 | H-1 non-participant cache isolation in `conversationHit`, plus a W7-20 test | backend-developer | S | Ticketed before the dev allowlist; fixed before any user outside the 3 team uids |
| W7-29 | M-1 `messages_mark_read_daily` and `messages_mutation_daily` caps | backend-developer | S | Before the flag leaves the dev allowlist |
| W7-30 | M-2 frozen peer snapshot when blocked (thread header and export) | backend-developer | S | Before prod; can ride with W7-27 |
| W7-31 | M-3 "not end-to-end encrypted" copy (Inbox, new message, request banner) | frontend-developer | XS | Before any non-team user |
| W7-32 | M-4 custom read role for `tf-plan` | production-deployer + founder | S | Before prod messaging |
| W7-33 | L-1 A8 `SnapshotInTx` seam, L-3 `ProfileInTx` in the send transaction, L-8 verified-email gate | architect (note) + backend-developer | S | Before prod percent / on |
| W7-34 | L-2 placeholder `_deleted` plus dev migration; L-7 HMAC `conversation_hash` and peer redaction | backend-developer | S | Before prod |
| W7-35 | L-4 owner-stamped wipe, L-5 Android backup exclusion, L-9 request-thread links | frontend-developer | S | Before prod |
| — | L-6 SLA or TTL; L-10 F2(d) setting | founder / planner | — | Follow-up |

SECURITY: BLOCKED — H-1 (release blocker for prod; M-1 to M-4 must also be fixed or decided before prod)
Dev allowlist: GO, on these conditions:
- (1) H-1 is ticketed (W7-28) before `feature_messaging` leaves `off` in dev.
- (2) The dev allowlist stays at the 3 team test accounts, as the flag ceiling (`max_allowlist: 3`) already enforces. No real-user data.
- (3) M-1 to M-4 and the Lows are ticketed per section 5.
- (4) Nothing moves in prod until H-1, M-1, M-2 and M-3 are fixed, M-4 is decided, and the section 4 Privacy Policy and Terms lines exist.
