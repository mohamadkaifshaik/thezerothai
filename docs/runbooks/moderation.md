# Runbook: reports, takedown and suspension (P7, ADR-0016)

Owner module: `backend/internal/moderation` (+ `posts.Moderator`, `identity.SetAccountStatus`, `cmd/opsctl`).
Data: `reports/{reportId}` (TTL field `expireAt`), `postRemovals/{postId}` (removal log, TTL field `expireAt`, ADR-0016 D10), `posts/{id}.moderation`, `users/{uid}.status`, `quotas/{uid}.reports`.
The user-facing RPC `ModerationService.ReportContent` is behind `FEATURE_REPORTS` (off | allowlist | percent | on,
default **off** in every environment). Moderator actions are `opsctl` commands run by the founder; there is no admin
console at Stage 0.

## 1. Response SLA (published commitment, ADR-0016 D5 / plan D2)
- **Acknowledge and triage every report within 48 hours.** Open `opsctl reports list` at least once per working day
  while `FEATURE_REPORTS` is on for anyone.
- **Clearly illegal content** (child sexual abuse material, credible threats, doxxing of private individuals) is removed
  as soon as it is seen, ahead of the 48 hour queue. For CSAM follow the legal reporting duty for the jurisdiction; do
  not keep copies outside the report evidence.
- Reporter identity is never disclosed to the reported user. Do not paste `reporter` lines from `reports show` into any
  reply to the reported user.

## 2. Daily triage
```bash
cd backend
P=dzeroth-prod   # prod prompts for the project id before running
go run ./cmd/opsctl reports list --project $P                    # OPEN, oldest first (default 20, max 50)
go run ./cmd/opsctl reports show --project $P --id <reportId>     # reporter, target, reason, note, evidence
```
Decide one of:
| Outcome | Command | Effect |
|---|---|---|
| Nothing wrong | `reports resolve --id R --resolution NO_ACTION` (or `DISMISSED` for abusive/duplicate reports; these are the only two resolutions `resolve` accepts) | report RESOLVED, evidence TTL-deleted 90 days later |
| Remove one post | `takedown-post --post POSTID --report R` | post hidden from GetPost (NOT_FOUND for everyone, the author included), profile timeline and Home within 60 s; report resolved TAKEDOWN |
| Reverse a takedown | `restore-post --post POSTID` | clears TAKEN_DOWN only; a post hidden by a suspension is left to `unsuspend-user` |
| Remove one direct message | `messages takedown CONVERSATION_ID:MESSAGE_ID --report R` (use `--dry-run` first; the argument is the report's `target`) | the message becomes `REMOVED` with its text cleared and both people's inbox previews are rewritten; both see "This message was removed" (devices that cached the thread or the inbox at their next poll or refresh); report resolved TAKEDOWN. Not undoable. See "Reading a message report" below |
| Take down a list | `lists hide LIST_ID --project P` (use `--dry-run` first; the argument is the report's `target`), then `reports resolve --id R --resolution NO_ACTION --note "list hidden"`; undo with `lists restore LIST_ID` | the list answers NOT_FOUND to everyone but its owner on every list read within 60 s on every server (cached copies expire); the owner still sees it; nothing else is touched. See `docs/runbooks/lists.md` section 7 |
| Suspend an account | `suspend-user --uid U --report R` (use `--dry-run` first) | status SUSPENDED (callers get ACCOUNT_RESTRICTED within 60 s), then every post of the user is hidden (marker SUSPENDED_AUTHOR); then other users' reposts and quote embeds of those posts are removed or tombstoned (**permanent**: `unsuspend-user` restores the author's own posts, not the copies); report resolved SUSPENDED |
| Reverse a suspension | `unsuspend-user --uid U` | ACTIVE again, restores exactly the posts the suspension hid; TAKEN_DOWN posts stay hidden |
| Clear a malicious profile link, location, bio or image | `clear-profile-fields --uid U --fields website,location,banner,avatar,bio --report R` (use `--dry-run` first) | those fields of one profile emptied with one field-level update (empty ones skipped, a rerun writes 0); for `banner` or `avatar` it also schedules the delete of the image when `PROFILE_MEDIA_RETIRE` is set in your shell (A4) and prints the object names either way (section 3a); report resolved PROFILE_CLEARED. Details: `docs/runbooks/abuse-spike.md` section 5b |

Every writing command ends with a `cost: reads=... writes=...` line (the `hidden:`/`settle pass:`/`restored:` lines before it are running totals). Prod project ids (`*-prod`) ask for the project id as a typed
confirmation. Nothing here touches Firebase Auth.

## 3. Cost of the commands (free quota: 50k reads, 20k writes per day)
| Command | Reads | Writes |
|---|---|---|
| `reports list` | one per report shown (<= 50) | 0 |
| `reports show` | 1 | 0 |
| `reports resolve` | 1 | 1 (0 if already resolved) |
| `takedown-post` | 1 (+2 with `--report`: target check, resolve) | 2 (post + log entry; +1 with `--report`); on a REPOST: 3 writes + 1 delete (see below) |
| `restore-post` | 1 (rejects `--report`) | 2 (post + RESTORED log entry) |
| `suspend-user` | P + 2, or P + 4 with `--report` (+1 only when P is a multiple of 250, + the posts of the last ~3 minutes re-read by the settle pass) | 2P + 1, or 2P + 2 with `--report` |
| &nbsp;&nbsp;↳ copy cleanup (part of `suspend-user`, issue #151) | + P to find the posts that have copies, then per such post 2 reads (minimum) | per repost 2 writes and 2 deletes, per quote 1 write |
| `unsuspend-user` | P_hidden + 2 | 2 P_hidden + 1 |
| `clear-profile-fields` | 1 (+1 to check `--report`, +1 to resolve it); a DELETING or missing account stops after the read | 1 (0 when every named field is already empty or with `--dry-run`; +1 to resolve the report) |
| `messages takedown` (W7-12) | 4 at most (message 1, conversation 1, each participant's entry 1; +2 with `--report`: target check, resolve); a repeat or a DELETED_ACCOUNT tombstone 1 | 4 at most (message 1, conversation revision 1, each preview that named it; +1 with `--report`); 0 with `--dry-run`, on a repeat and on a tombstone |
| `lists hide` / `lists restore` (W5-44) | 1 (the list); `--dry-run` 1; a missing list 1 | 1 (`hidden` + `updatedAt`, field-level); 0 on a repeat, a missing list and `--dry-run` |

`suspend-user` on a 5,000-post account is about 5,000 reads and 10,000 writes (50% of the daily write quota: each hidden post is
the post update plus its removal-log entry): run it
off-peak and use `--dry-run` to see the number first (`suspend-user`, `unsuspend-user` and `clear-profile-fields` have a dry run; the
others reject `--dry-run`). It is resumable and idempotent: if it stops half way, run the
same command again (it accepts an already SUSPENDED account for exactly that reason; hidden posts are skipped at 0
writes).

`suspend-user` takes about 75 seconds longer than the paging itself: after the posts are hidden it waits out the
60 s instance cache (+15 s margin) and runs one settle pass over posts created since just before the suspension, so a
post a warm instance accepted during that window is hidden too. Do not interrupt it; if it stops, re-run it.
`--report` is checked against the target before anything is written: a report about another post or user is refused,
an already RESOLVED report only warns.

## 3b. The removal log (`postRemovals`, ADR-0016 D10, plan T15)
Every hide and un-hide writes `postRemovals/{postId}` (`state` REMOVED | RESTORED, server-time `createdAt`, `expireAt` =
createdAt + 32 days) in the same transaction or batch as the `moderation` field, so a crash can never hide a post without
logging it and re-running `suspend-user` needs no extra step (hidden posts are skipped, they are already logged). The id is
the post id: a repeat overwrites one document. Each entry also stores `authorId` (the post author), which scopes it to the feeds that show that author. The API reads it incrementally into a per-instance cache (at most `removalKeep` = 200 entries; <= 50 per query) and
answers `removed_ids` on `since_token` refreshes, so a client drops a card it already holds within about two cache TTLs.
- **Looks stale / a card did not disappear.** The client drops ids only on its next refresh; the instance cache lags up to
  60 s.
- **Many clients are being sent back to a full reload after a big suspension.** Expected: a log window that cannot list
  every id (more than 50 removals newer than the client's token, or a token older than the log) rejects the refresh
  exactly like an expired `since_token` and the app cold-opens, replacing that feed.
  **Suspension reset cost (ADR-0016 amendment 2026-10-18 (b)).** The log is scoped per feed. Suspending (or unsuspending) an
  account with P >= 50 posts makes only the feeds that show that account reset once: the Home of its followers and its own
  profile (about followers x 30 reads at a 30-read cold open, usually about zero for a spam account), not every client. Check the
  follower count first. Tokens issued before the burst, and up to `removalLag` (135 s) after it, are rejected for those feeds,
  so a follower that refreshes right after can be reset again once. `opsctl suspend-user --dry-run` and
  `opsctl unsuspend-user --dry-run` print a WARNING when P >= 50: run those off-peak when the account has many followers.
  Server cost of the log itself: one 50-read cold load per instance and 1 read per CACHE_TTL after that, a 100-read reload only
  when 50 or more entries are new within one TTL. These shared reads run on a detached counter (log field `removal_log_reads`)
  and are **not** in the request's `fs_reads` nor charged to any user's daily read budget (when summing Firestore usage from logs, add `removal_log_reads`) (`ReadBudgetMaxCallReads` = 269). A viewer whose token is older than
  the instance's cache (a cold instance after a burst) pays one bounded window query of at most 107 reads for its own feed.
  The kill switch is `FEATURE_REMOVED_IDS=off` (no log reads, no resets; the log is still written).
- **Flag.** `FEATURE_REMOVED_IDS` (off | allowlist | percent | on, default off, Terraform `feature_removed_ids*`). Off for a
  caller means refreshes carry no `removed_ids` and never touch the log. If the log query fails on an instance that holds
  data, the stale cache is served and `removal_log_refresh_failed_serving_stale` is logged at ERROR (retried every 5 s).
- **TTL.** `postRemovals.expireAt` needs the TTL policy (Terraform `ttl_fields.post_removals_expire_at`, ADR-0016 D10); until it is
  applied the log only grows (about 1 KB per hidden post), never wrong. Check with `gcloud firestore fields ttls list`.
- Entries hold a post id, the author uid (pseudonymous link), a state and timestamps; no text. Account deletion deletes them by
  `authorId` (posts step, phase 2: +1 read when there are none); the 32-day TTL is only the backstop. Entries written before the
  scoped log (no `authorId`) are treated as visible to every feed and expire within 32 days. Cutover date: `defaultRemovalAuthorScopedFrom` in `backend/internal/posts/removals.go` is 2026-10-25; windows reaching before it reset the feed instead of being queried. Bump it to the release-tag date when tagging; delete the constant 32 days after release.
- **`suspend-user` also sweeps notifications (N-4).** After the settle pass it deletes (or unfolds) the notification rows other users
  hold about the suspended account: 1 read + 1 delete or update per row, 500 per page (1 read when there are none). It is not undone
  by `unsuspend-user`. Re-running `suspend-user` resumes it.

### Reading a repost report
A report on a **repost** has `target` = the repost id and `owner` = the reposter, but `reports show` prints
`evidence is the ORIGINAL post <id>`: the text, handle, media ids and time under `evidence` belong to the original post
(snapshot at report time). To remove the content run `takedown-post` on that original id; `takedown-post` on the repost id
removes only the repost: the repost doc is deleted and its reposts record, the original's `repostCount` and the reposter's
`postsCount` are released (issue #153; reads 1, writes 3, deletes 1, fewer counters when the original or the reposter's user doc
is gone). `restore-post` on it then answers not found: the removal is a fresh state and the user can repost again. Account actions on `owner` concern the reposter. Reports filed before B2, or whose original was
already unavailable, show empty evidence text.

### Reading an account report
A report with `target` type ACCOUNT keeps, under `evidence`, the profile **as the reporter saw it** (ADR-0024 Amendment 1
A3(b)): `reports show` prints `evidence profile @handle: display name, bio, location, website` and `evidence avatar ..., banner ...`
(URLs, never uids). It is copied from the profile the call already loaded (0 extra reads), so a link or image swapped right
after the report is still on record, and a reopened report (the same reporter reporting the same account after it was
resolved) refreshes it. Two things to know when reading it:
- **No website is not "no link".** While `FEATURE_PROFILE_EXTRAS` was globally off at report time the reporter saw no website, so
  none is kept. Look at the live document (`users/{uid}.website`, which the switch does not erase) before closing the report.
- **Older reports.** An ACCOUNT report filed before this change has no evidence: `reports show` prints `evidence none ... look at
  the live profile`. The evidence is never returned to any client, and it is deleted with the report (resolved + 90 days).

For a bad link, location, bio or image the action is `clear-profile-fields --report R` (above, the full procedure is
`docs/runbooks/abuse-spike.md` section 5b); a bad display name or a repeat offender is `suspend-user`. The resolution is
`PROFILE_CLEARED`; `reports resolve` still accepts only `NO_ACTION` and `DISMISSED`.

### Reading a message report
A report with `target` type MESSAGE (ADR-0027 D12, W7-12) has `target` = `<conversation id>:<message id>` (32 lower-case hex each) and `owner`
= the **sender's** uid. `reports show` prints `evidence message from @handle sent <time> (PRIVATE text, copied at report time): "..."`: that one
message and nothing else of the conversation. **It is private content.** Read it to decide; do not paste it into a reply, a ticket or a chat.
Two things to know:
- **The handle can be empty.** The sender was not ACTIVE (suspended or being deleted) when the report was filed; `owner` still names them.
- **Context is not kept on purpose.** The evidence is only the reported message. Messages around it are not in the report and are not
  reachable from `opsctl`; judge from the one message, the reason and the note. A pattern needs several reports against the same `owner`.

To remove it run `opsctl messages takedown <target> --report R` (`--dry-run` first). The message becomes `REMOVED` with its text and request
digest cleared, the inbox previews of both people that showed it are rewritten, and the conversation's revision is bumped, in one transaction
(at most 4 reads, 4 writes). Both see "This message was removed". Facts to expect:
- **A device that cached the text drops it at its next poll or inbox refresh.** The thread's `since_token` is retired (the app makes one cold
  open) and the inbox row comes back in the next `since` refresh, in the same place. A device polling an instance whose 60 s conversation copy
  predates the takedown can lag by up to 60 s; a closed thread converges when it is opened. See `docs/runbooks/messaging.md` section 5b.
- **The report keeps the text.** The evidence is a copy taken at report time; the takedown does not touch it. It is deleted with the report,
  resolved + 90 days.
- **Idempotent and safe to repeat.** An already `REMOVED` message, or one its sender's account deletion already tombstoned
  (`DELETED_ACCOUNT`), writes nothing and says so; `--report` still resolves. An unknown message, or one whose conversation is gone, exits 1.
- **Not undoable.** There is no restore for a message: the text is gone from the message document. The evidence is in the report only.
- **The sender who retries gets the tombstone.** The takedown clears the message's request digest (as the account eraser does), so Send cannot
  compare a retry of the same idempotency key; it replays the message as `REMOVED` (no text) instead of a "key reused" error. It never creates a duplicate.
- **The output holds no uid and no id in clear.** It prints `conversation_hash` (the keyed hash of the request logs, W7-34: set `CURSOR_HMAC_KEY` in your shell, else it prints `unavailable(set-CURSOR_HMAC_KEY)`; `docs/runbooks/messaging.md` section 5c) and `message_hash` (plain, one-way) and one `audit:` line with the
  project, time, before/after state, previews rewritten, `wrote`, `dry_run` and the report id. Keep that line with the case notes.
- For an abusive sender rather than one message, `suspend-user --uid <owner> --report R` accepts a message report (its owner is the sender);
  a SUSPENDED sender can no longer send (account-status interceptor) and a SUSPENDED recipient answers `CANNOT_MESSAGE`.

## 3a. Media on takedown (manual until `--purge-media` exists)
`takedown-post` hides the post document only. If the post has images (`reports show` prints `evidence`, and the
post's `media[]` ids; also `media` docs with `ownerId` = the author) the objects are **still public** in the media
bucket and reachable by anyone holding the URL. For illegal or abusive imagery:
1. `reports show --id R` prints `evidence media: <ids>` (copied at report time). Note them before anything else; the
   ids and the text are all that survives once the objects are deleted. If the report predates the post's media
   (or was filed through an older build) list them from Firestore: `media` where `postId == <id>` (Limit 4).
2. Delete the public objects `m/<mediaId>.<ext>` and `m/<mediaId>_t.<ext>` in `<proj>-media`, then the `media/*` docs,
   exactly as `docs/runbooks/media.md` "A deleted post's images are still served" step 2. If the content must be kept
   for law enforcement, copy the objects out of the bucket first (to a restricted location) before deleting.
3. Record what was done in the report resolution note.
Note: P4's `post_delete` job removes the objects when the **author** deletes the post or their account, so image
evidence is destroyed at that point; resolve image reports before the author can react, and rely on the ids plus the
text copy in the report. Ticket T14 in `docs/plans/reports.md` tracks `takedown-post --purge-media`.

**A removed banner or avatar.** `clear-profile-fields --fields banner,avatar` stops the profile pointing at the image and the
command prints the object names. The objects themselves are deleted by the A4 retire step, 24-48 h later, only when
`PROFILE_MEDIA_RETIRE` is set in your shell to the project's value (unset is `off`: nothing is scheduled, the objects stay
public and steps 1 to 3 above apply to them by hand; `docs/runbooks/media.md`, "Replaced and removed avatars and banners").
The `media` docs have `ownerId` = the user and `purpose` AVATAR or BANNER; the report evidence keeps the image URLs, which
hold the media ids. The old avatar URL also stays in the author snapshot of the user's older posts until a rename refreshes
them.

### Reported profile images
A reported avatar or banner is on a clock the report does not know about: once the user replaces or removes it (or you clear
it) the A4 step deletes the two objects 24-48 h later, and the `media` document 72 h later, which is shorter than the 48 h
triage SLA in section 1. `reports show` keeps the image URLs and the media ids, never the bytes. So when a report names an
image that matters (illegal or abusive imagery, anything law enforcement could ask for), at first sight, before any
`clear-profile-fields` and before the user can react:
1. Copy both objects (`m/<mediaId>.<ext>` and `m/<mediaId>_t.<ext>` in `<proj>-media`) to a restricted location outside the
   public bucket, as section 3a step 2 says (when the imagery may be illegal, do not download it to a personal machine: ask the
   founder where it goes). Do not use the `<proj>-exports` bucket: it is for user data exports and its lifecycle rule deletes every object
   after 7 days. Delete the copy when the case closes.
2. Note the ids in the report resolution note.
An image that is already retired is still public until the lifecycle run, so the same copy works for up to 48 h after the
change; after that only the ids and the text survive. This is the same rule as section 3a for post images.

## 4. Failure modes
- **Suspended user still sees the app / their posts still show.** Instances cache the profile and posts for
  `CACHE_TTL` (60 s). Wait a minute. If posts of a suspended user still appear after that, re-run `suspend-user` (a post
  created during the cache window is normally hidden by the command's own settle pass; the re-run is the backstop).
- **`suspend-user` says the account is DELETING.** Refused on purpose: a moderator action never overrides an account
  deletion. Let the deletion finish (`docs/runbooks/account-deletion.md`).
- **`clear-profile-fields` printed `avatar retire: would not run`, `not run` or a retire error.** The clear itself committed (a
  retire failure never rolls it back). `PROFILE_MEDIA_RETIRE` in your shell does not cover the image, or the retire step failed
  (exit 1, the `--report` is still resolved): the objects stay public until deleted by hand or retired by a later message
  (`docs/runbooks/media.md`, "Failure modes"). A rerun of the command writes 0 and retires nothing, because the field is already
  empty; to retire an image that was cleared earlier, publish the message by hand (`docs/runbooks/media.md`, "Failure modes").
- **`clear-profile-fields` refuses or reports nothing.** `the account is DELETING: refusing to change it` and `no such user` exit
  1 and write nothing (the deletion job's checkpoints must not race an operator write; a purged account has nothing to clear).
  `nothing to clear: 0 writes` means every named field was already empty (a rerun, or the user removed it first): not an error.
  A `--report` that is about another user is refused before any write; one already RESOLVED only warns. The command does not
  evict instance caches, so the old profile can show for up to 60 s.
- **`reports list` fails with "The query requires an index".** The `(status, createdAt)` composite index on `reports` is
  in `firebase/firestore.indexes.json`; deploy the indexes (`firebase deploy --only firestore:indexes`) and retry.
- **Reports spike or a single reporter floods.** `QUOTA_EXCEEDED quota=reports` (20/day, 5/day for accounts younger than
  24 h) and the 5/min bucket already bound one account. Many accounts is spam: `docs/runbooks/abuse-spike.md`. The kill
  switch is `FEATURE_REPORTS=off` (`docs/runbooks/cost-spike.md`, pinned-traffic procedure).
- **A user says "I reported a message and got not found" (or the report button does nothing).** Expected for a message that is no longer
  VISIBLE (already taken down, or its sender deleted the account), your own message (that is a validation error, not not found), a
  conversation you are not in, or an unknown id: one NOT_FOUND `message not found` for all of them, on purpose (no oracle). A user whose
  `messaging` flag is off but not off for everyone can still report. `FAILED_PRECONDITION FEATURE_DISABLED feature=messaging` means
  `FEATURE_MESSAGING=off` for everyone (the kill switch); `FEATURE_DISABLED` with no feature means `FEATURE_REPORTS` is off for them.
  The request line has `report_target=MESSAGE`, `outcome` (`created`, `duplicate`, `reopened`, `rejected:*`) and `conversation_hash`; never text.
- **`messages takedown` says `no such message`.** The id is wrong, or both accounts were deleted and the conversation tree went with them.
  The report (if any) still holds the text until resolved + 90 days; resolve it with `reports resolve`.
- **Appeals.** Stage 0 has no appeal UI. If a user writes in, `restore-post` / `unsuspend-user` is the whole procedure.

## 5. Privacy and retention
- Evidence (the post text and author handle at report time; for an ACCOUNT report the profile the reporter saw: handle, display
  name, bio, location, website, avatar and banner URL, at most about 1.3 KB, ADR-0024 Amendment 1 A3) is kept **90 days after
  resolution**, then Firestore TTL deletes the report (`reports.expireAt`, set by `reports resolve`/`takedown-post`/`suspend-user`/`clear-profile-fields --report`). Open POST and ACCOUNT reports are
  kept until resolved (a MESSAGE report keeps its copied text for less, below). Check the TTL policy exists on the project (`gcloud firestore fields ttls list`).
- Account deletion anonymises reports the user **filed** (`reporterId := ""`, step `reports`) and leaves them as safety
  evidence; reports **about** the user stay until resolved + 90 days. The privacy policy
  (`app/web/privacy.html`, "When your account is deleted") must say so before `FEATURE_REPORTS` is turned on for real
  users. The data export lists the reports the user filed, never reports about them.
- A LIST report (W5-44) keeps the owner's handle, the list's name and description and its creation time in the report document itself (public text once the list is public; no member id; no child document), with the same retention: resolved + 90 days. A list the reporter cannot see cannot be reported (the one NOT_FOUND).
- A MESSAGE report's evidence is **one private message** (its text, the sender's handle, its time; ADR-0027 D12 and the 2026-10-28 note
  on ADR-0016). The same retention applies: kept until resolved + 90 days, then the TTL deletes the report. **The copied text is stored apart, in `reports/{id}/evidence/message`, with its own `expireAt` = filing + 180 days (W7-36, ADR-0016 note 2026-10-30); a Firestore TTL on the collection group `evidence` deletes it, the report itself (target, reason, note, status, dates, handle) stays. `reports resolve` lowers it to at most resolved + 90 d; a re-file rewrites it with a fresh 180 days. `opsctl reports show` prints `evidence expired` once it is gone, so triage inside the 48 h SLA. The TTL policy is Terraform (`ttl_fields.report_evidence_expire_at`): check `gcloud firestore fields ttls list` shows `evidence` before relying on it.** The reporter's erasure the reporter's erasure
  (`reporterId := ""`) is unchanged and nothing in the evidence names the reporter. The report's `target` holds the conversation id, a
  one-way hash of the two participants' uids, so the operator could in principle test a candidate uid against it; it is operator-only data
  and never reaches a client or a log. The data export lists a reporter's own message reports with that `target` (no text).
- Logs hold enums and counters only (`report_target`, `report_reason`, `outcome`), never ids, handles, notes or text. A message report's line
  adds `conversation_hash` (one-way).

### Reading a poll report (ADR-0029 D8; W6-5)
A report on a post with a poll shows one extra line, `evidence poll choices: ["Yes" "No"]`: the choice labels as they were when the report was filed (for a repost, the original's, from its frozen embed). Labels only: no counts, no voters. The question is the post text, shown on the usual `evidence post by` line. `takedown-post` hides the post and its poll together (the poll is a field of the same doc, so every reader that drops a hidden post drops the poll with it); nothing separate to remove. Reports filed before W6-5 show no poll line.
