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
| Suspend an account | `suspend-user --uid U --report R` (use `--dry-run` first) | status SUSPENDED (callers get ACCOUNT_RESTRICTED within 60 s), then every post of the user is hidden (marker SUSPENDED_AUTHOR); report resolved SUSPENDED |
| Reverse a suspension | `unsuspend-user --uid U` | ACTIVE again, restores exactly the posts the suspension hid; TAKEN_DOWN posts stay hidden |

Every writing command ends with a `cost: reads=... writes=...` line (the `hidden:`/`settle pass:`/`restored:` lines before it are running totals). Prod project ids (`*-prod`) ask for the project id as a typed
confirmation. Nothing here touches Firebase Auth.

## 3. Cost of the commands (free quota: 50k reads, 20k writes per day)
| Command | Reads | Writes |
|---|---|---|
| `reports list` | one per report shown (<= 50) | 0 |
| `reports show` | 1 | 0 |
| `reports resolve` | 1 | 1 (0 if already resolved) |
| `takedown-post` | 1 (+2 with `--report`: target check, resolve) | 2 (post + log entry; +1 with `--report`) |
| `restore-post` | 1 (rejects `--report`) | 2 (post + RESTORED log entry) |
| `suspend-user` | P + 2, or P + 4 with `--report` (+1 only when P is a multiple of 250, + the posts of the last ~3 minutes re-read by the settle pass) | 2P + 1, or 2P + 2 with `--report` |
| `unsuspend-user` | P_hidden + 2 | 2 P_hidden + 1 |

`suspend-user` on a 5,000-post account is about 5,000 reads and 10,000 writes (50% of the daily write quota: each hidden post is
the post update plus its removal-log entry): run it
off-peak and use `--dry-run` to see the number first (`suspend-user` is the only moderator command with a dry run; the
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
the post id: a repeat overwrites one document. The API reads it incrementally into a per-instance cache (at most `removalKeep` = 200 entries; <= 50 per query) and
answers `removed_ids` on `since_token` refreshes, so a client drops a card it already holds within about two cache TTLs.
- **Looks stale / a card did not disappear.** The client drops ids only on its next refresh; the instance cache lags up to
  60 s.
- **Many clients are being sent back to a full reload after a big suspension.** Expected: a log window that cannot list
  every id (more than 50 removals newer than the client's token, or a token older than the log) rejects the refresh
  exactly like an expired `since_token` and the app cold-opens, replacing that feed.
  **Suspension reset cost.** Suspending (or unsuspending) an account with P >= 50 posts makes every client that refreshes
  reset every cached feed once (home and each cached user timeline: about DAU x 30 reads at a 30-read cold open). Tokens
  issued before the burst, and tokens issued up to `removalLag` (135 s) after it, are rejected too, so a client that
  refreshes right after the burst can be reset again once. `opsctl suspend-user --dry-run` prints a WARNING when P >= 50:
  run those off-peak. Server cost of the log itself: one 50-read cold load per instance, 1 read per CACHE_TTL after that, a
  100-read reload only when 50 or more entries are new within one TTL (these reads are in `ReadBudgetMaxCallReads` = 369).
  The kill switch is `FEATURE_REMOVED_IDS=off` (no log reads, no resets; the log is still written).
- **Flag.** `FEATURE_REMOVED_IDS` (off | allowlist | percent | on, default off, Terraform `feature_removed_ids*`). Off for a
  caller means refreshes carry no `removed_ids` and never touch the log. If the log query fails on an instance that holds
  data, the stale cache is served and `removal_log_refresh_failed_serving_stale` is logged at ERROR (retried every 5 s).
- **TTL.** `postRemovals.expireAt` needs the TTL policy (Terraform `ttl_fields.post_removals_expire_at`, ADR-0016 D10); until it is
  applied the log only grows (about 1 KB per hidden post), never wrong. Check with `gcloud firestore fields ttls list`.
- Entries hold a post id, a state and timestamps. No uid, no text: the log is not personal data (ADR-0011 Q10 table row).

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

## 4. Failure modes
- **Suspended user still sees the app / their posts still show.** Instances cache the profile and posts for
  `CACHE_TTL` (60 s). Wait a minute. If posts of a suspended user still appear after that, re-run `suspend-user` (a post
  created during the cache window is normally hidden by the command's own settle pass; the re-run is the backstop).
- **`suspend-user` says the account is DELETING.** Refused on purpose: a moderator action never overrides an account
  deletion. Let the deletion finish (`docs/runbooks/account-deletion.md`).
- **`reports list` fails with "The query requires an index".** The `(status, createdAt)` composite index on `reports` is
  in `firebase/firestore.indexes.json`; deploy the indexes (`firebase deploy --only firestore:indexes`) and retry.
- **Reports spike or a single reporter floods.** `QUOTA_EXCEEDED quota=reports` (20/day, 5/day for accounts younger than
  24 h) and the 5/min bucket already bound one account. Many accounts is spam: `docs/runbooks/abuse-spike.md`. The kill
  switch is `FEATURE_REPORTS=off` (`docs/runbooks/cost-spike.md`, pinned-traffic procedure).
- **Appeals.** Stage 0 has no appeal UI. If a user writes in, `restore-post` / `unsuspend-user` is the whole procedure.

## 5. Privacy and retention
- Evidence (the post text and author handle at report time) is kept **90 days after resolution**, then Firestore TTL
  deletes the report (`reports.expireAt`, set by `reports resolve`/`takedown-post`/`suspend-user`). Open reports are
  kept until resolved. Check the TTL policy exists on the project (`gcloud firestore fields ttls list`).
- Account deletion anonymises reports the user **filed** (`reporterId := ""`, step `reports`) and leaves them as safety
  evidence; reports **about** the user stay until resolved + 90 days. The privacy policy
  (`app/web/privacy.html`, "When your account is deleted") must say so before `FEATURE_REPORTS` is turned on for real
  users. The data export lists the reports the user filed, never reports about them.
- Logs hold enums and counters only (`report_target`, `report_reason`, `outcome`), never ids, handles, notes or text.
