# Runbook: manual account deletion and data export

**Why this exists:** requests to **privacy@dzeroth.com** are handled by hand, within **30 days**, as the privacy policy
promises. This closes security audit finding M5 for the web launch. The in-app flow (`DeleteAccount` /
`RequestAccountExport`, ADR-0011, P8) is built behind `FEATURE_ACCOUNT_LIFECYCLE` (dev: allowlist; prod: off until the
release ramp); **section 6** is its operations guide and the **primary** path once the flag is on. Sections 1 to 5 stay
valid as the manual fallback and are the **only** path for email requests today: `opsctl delete-account` /
`export-account` (plan T12) are not built, so do not look for them. Section 7 is how to answer an email request.

Run it from Git Bash with the founder's gcloud login. Examples use prod; use `dzeroth-dev` for dev accounts.
```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"; P=dzeroth-prod
TOKEN=$("$G" auth print-access-token)
H=(-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $P" -H "Content-Type: application/json")
```

## 1. Verify the requester
Act only on a request that comes **from the account's own email address**. Otherwise, reply to the account's address
and ask them to confirm. Never act on a request from a different address.

## 2. Find the user
```bash
curl -s "${H[@]}" -X POST "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:lookup" \
  -d '{"email":["user@example.com"]}'           # -> users[0].localId is the uid
UID_=<localId from above>
curl -s "${H[@]}" "https://firestore.googleapis.com/v1/projects/$P/databases/(default)/documents/users/$UID_"
# -> fields.handleLower is the handle document id
```

## 3a. Export (a right-to-access / portability request)
Send the user their data as JSON: the `users/<uid>` document from step 2, plus the Auth record (email, provider,
created and last-login times) from `accounts:lookup`, plus the graph export and the posts export below. Phase 1 will
add likes here as those modules ship. Don't include internal fields such as `status`.

**Graph export** (`opsctl export-graph`, ADR-0008 D12). It runs from the `backend/` directory with Application Default
Credentials (`gcloud auth application-default login` once) and always needs an explicit `--project`. A `*-prod`
project asks you to type the project id to continue. It reads only, and writes JSON with `userId`, `following`,
`followers`, `blocked` and `muted` (uids + handles).
```bash
cd backend
go run ./cmd/opsctl export-graph --project $P --uid "$UID_" --out "$HOME/export-graph-<hashed-uid>.json"
```
`--out` refuses to overwrite an existing file (created 0600); without it the JSON goes to stdout. **The export never
contains who blocked the user (`blockedBy`)**. That's third-party data and revealing it defeats blocking (founder
decision 2026-09-28). Never add it by hand from the Firestore document. Send the file over the same confirmed email
thread, then delete your local copy.

**Posts export** (`opsctl export-posts`, ADR-0010 T10). Same flags and guards as `export-graph`. It reads only and writes JSON
`{"userId", "posts": [{id, text, createdAt, hashtags, mentions}]}`, newest first; mentions are handles only. Cost: 1 read per post.
```bash
go run ./cmd/opsctl export-posts --project $P --uid "$UID_" --out "$HOME/export-posts-<hashed-uid>.json"
```
Send both files over the same confirmed email thread, then delete your local copies.

## 3b. Delete
Order matters: **the posts purge and the graph purge come before `users/{uid}` is deleted**, because the purge decrements the counters on
other users' `users/*` docs and its start gate reads this user's profile (ADR-0008 D10).

**Step 0. Mark the account DELETING and stop it signing in.** `opsctl purge-graph` refuses to run unless
`users/{uid}.status` is `DELETING` and `updatedAt` is at least **120 s** old (2x the 60 s instance cache, so no
instance still treats the user as ACTIVE and creates a new edge mid-purge). Set both fields (`updatedAt` is what the
gate measures from), disable the Auth user so no fresh token keeps working, then wait two minutes.
```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s "${H[@]}" -X PATCH \
  "https://firestore.googleapis.com/v1/projects/$P/databases/(default)/documents/users/$UID_?updateMask.fieldPaths=status&updateMask.fieldPaths=updatedAt" \
  -d "{\"fields\":{\"status\":{\"stringValue\":\"DELETING\"},\"updatedAt\":{\"timestampValue\":\"$NOW\"}}}"
curl -s -X POST "${H[@]}" -d "{\"localId\":\"$UID_\",\"disableUser\":true}" \
  "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:update"
```

**Step 1a. Purge the posts (before the graph).** Same flags and guards as `purge-graph` (explicit `--project`, typed
confirmation for `*-prod`, the DELETING >= 120 s start gate, `--dry-run`, `--skip-start-gate`). It deletes every
`posts` doc with `authorId == uid`, 500 per batch, newest first; it is resumable (deleted docs drop out of the next page,
so a re-run after a crash simply continues) and does not touch `users.postsCount` because the `users` doc is deleted
later. Cost: about 1 read and 1 delete per post (a 300-post user: 300 reads, 300 deletes).
```bash
cd backend
go run ./cmd/opsctl purge-posts --project $P --uid "$UID_" --dry-run   # prints: dry-run: posts=N (nothing written)
go run ./cmd/opsctl purge-posts --project $P --uid "$UID_"             # ends with "purged: reads=.. writes=0 deletes=.."
go run ./cmd/opsctl purge-posts --project $P --uid "$UID_" --dry-run   # must print: dry-run: posts=0 (nothing written)
```
If a run stops with "giving up after 5 consecutive errors", re-run the same command. Do not go on to Step 1 until the last
dry run shows `posts=0`. Other instances may serve a purged post from their 60 s cache for up to a minute.

**Step 1. Purge the graph.** Dry run first (prints counts, writes nothing), then the real run. It is resumable and safe
to re-run: it deletes the follow edges both ways, fixes the other users' `followersCount` / `followingCount` and their
`following` / `blockedBy` / `blocked` arrays, then deletes `graph/{uid}`. A cost of about 200 reads, 300 writes and
200 deletes for a user with 100 followers and 100 following.
```bash
cd backend
go run ./cmd/opsctl purge-graph --project $P --uid "$UID_" --dry-run
go run ./cmd/opsctl purge-graph --project $P --uid "$UID_"      # ends with "purged: reads=.. writes=.. deletes=.."
```
`--skip-start-gate` bypasses the DELETING and 120 s check. Use it only for an account that has no `users/{uid}` doc
any more (the S2 repair below), or a dev test account, and say so in your tracker. If a run stops with "giving up
after 5 consecutive errors", re-run the same command; it resumes from what is left.

**Deletion is one-way once Step 1 has started** (ADR-0009). Purge step 1 deletes the user's outgoing `follows` edges
but leaves their own `graph/{uid}.following` and `followingCount` alone until the purge finishes. So after the first
real (not `--dry-run`) `purge-graph` run, never set `status` back to `ACTIVE` and never re-enable the Auth user, even
if the purge stopped part way: the user would be left following accounts they can't unfollow (ADR-0009 state S1) with
a wrong `followingCount`. If the user changes their mind, finish the deletion and ask them to sign up again. Restoring
an account needs a new plan with its own ADR. (Before Step 1 has run, reverting Step 0 is still safe.)

**Step 2 precondition: the dry run shows 0/0 edges.** After the real run has printed `purged:`, run the dry run again:
```bash
go run ./cmd/opsctl purge-graph --project $P --uid "$UID_" --dry-run
# must print: dry-run: outgoing_edges=0 incoming_edges=0 blocked=0 blocked_by=0 (nothing written)
```
This costs 2 count reads plus 1 read of the (already deleted) `graph/{uid}`. If either edge count is not 0, do **not**
start Step 2: re-run the real `purge-graph` and check again. A run that ended with "giving up after 5 consecutive
errors" is not finished, however far it got. Deleting `users/{uid}` while an edge to it still exists leaves every
remaining follower unable to unfollow the account (ADR-0009 state S2; repair below).

**Step 2. Delete the rest.**
```bash
npx -y firebase-tools@15 firestore:delete "users/$UID_" --recursive --project $P --force   # profile + subcollections
npx -y firebase-tools@15 firestore:delete "handles/<handleLower>" --project $P --force     # frees the handle
npx -y firebase-tools@15 firestore:delete "quotas/$UID_" --recursive --project $P --force  # per-user daily quota counters (graph writes follows/blocks, posts writes posts)
curl -s "${H[@]}" -X POST "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:delete" \
  -d "{\"localId\":\"$UID_\"}"                                                               # Firebase Auth user
```
(The old `firestore:delete graph/$UID_` step is gone: it left counters and the other side of every edge behind.)

**Verify `accounts:delete` succeeded.** Step 0 only *disables* the Auth user; the call above is what removes it, and
it can fail silently in a `curl -s` pipeline. Confirm the user is gone (expect no `users` in the response):
```bash
curl -s "${H[@]}" -X POST "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:lookup" \
  -d "{\"localId\":[\"$UID_\"]}"
```
If the user is still listed, re-run the `accounts:delete` call. **Never re-enable an Auth user whose `users/{uid}` doc
was deleted:** with no profile the uid counts as deleted, so T27's lazy clean-up will already have removed it (or will
remove it) from other users' `blocked[]` / `muted[]`; a returning uid would come back without those blocks and mutes.

**Repair: Step 2 ran before the purge finished (ADR-0009 state S2).** Symptom: a user reports they can't unfollow an
account that no longer exists (Unfollow answers "not following", but the account stays in their Following list), or
a residue check finds a `follows` edge to or from a uid that has no `users/{uid}` doc. Finish the purge for the
**deleted** uid. The start gate has to be skipped because it can't read a profile that is gone:
```bash
cd backend
go run ./cmd/opsctl purge-graph --project $P --uid "<deleted uid>" --dry-run            # expect edges > 0
go run ./cmd/opsctl purge-graph --project $P --uid "<deleted uid>" --skip-start-gate    # ends with "purged: ..."
go run ./cmd/opsctl purge-graph --project $P --uid "<deleted uid>" --dry-run            # must show 0/0 edges
```
The purge resumes by query: it deletes the remaining edges and, for each follower, removes the uid from their
`following` and decrements their `followingCount` (a missing `graph/{uid}` counts as empty). Then check the affected
followers' counters with the count-and-set procedure in `docs/runbooks/graph.md` section 2, and record the repair in
your tracker. The emulator test `TestT32_Unfollow_StuckS2_IsFlaggedAndPurgeRepairs`
(`backend/internal/graph/unfollow_noop_invariant_integration_test.go`) pins this path; it has not yet been run
against a cloud project.

- **Other users' mute and block lists:** other users' `muted[]` / `blocked[]` entries that still name the deleted uid
  are not found by the purge (Firestore arrays aren't indexed). The lazy clean-up on read (ADR-0008 D10, ticket T27,
  built) removes them from the owner's own array the next time the owner opens ListMutedUsers / ListBlockedUsers
  (uids with no `users/{uid}` doc only; SUSPENDED/DELETING are kept). So the residue is bounded by "until that
  user next opens the list", not permanent. Do not hand-edit other users' documents.
- **Mentions of the deleted user in other users' posts:** a post by someone else that @-mentions the deleted account
  keeps `mentions[] = {userId, handle}` for it (Firestore array-of-maps is not queryable by member without a
  `mentionIds` field, which P1 does not write, ADR-0010). Decision: these are kept as third-party content, the same
  stance as other people's replies and quotes; the purge neither finds nor edits them, and the deleted uid and
  handle stay readable there. Scrubbing them is deferred to a follow-up ADR (P6, when `mentionIds` and mention
  notifications land). Do not hand-edit other users' posts. Tell the requester about this residue in the reply.
- **Reports (P7, ADR-0016 D5):** reports the user **filed** are anonymised by the `reports` step (`reporterId` is
  cleared; the report stays as safety evidence about third-party content). Reports **about** the user (and the
  `evidence` copy of their post text) are kept until resolved + 90 days, then Firestore TTL deletes them; this is the
  residue allowlist entries `reports.targetOwnerId` / `reports.targetId`. Do not hand-delete them. Tell the
  requester in the reply; the privacy policy carries the same sentence.
- **Media:** posts carry no media yet (P1 is text-only), so there are no objects to delete. When media ships, also delete
  `gs://$P-media/m/<mediaId>*` for the user's media, and extend this list (and ADR-0003's delete path) as each
  Phase 1 module lands.
- **Backups:** prod weekly Firestore backups keep data for up to **14 days**, and deleted data ages out with them.
  Say so in the reply. Logs hold only a hashed uid.

## Drill record (T22 acceptance)
The graph deletion steps above were drilled end to end on `dzeroth-dev` on 2026-09-30, following this runbook as
written. The test account (C) had a mutual follow with A, a follow from B that was removed by a mutual block with B,
and mutes on A and B; A also muted C. All three accounts were throwaway, and all of them and their data were deleted
afterwards.

| Field | Result |
|---|---|
| Date | 2026-09-30 |
| Environment | dev (`dzeroth-dev`) |
| Duration | 3 min 47 s end to end (export, Step 0 including the 125 s wait, dry run, purge, Step 2). About 100 s of that was active work. Target < 10 min: met |
| Purge output | dry run `outgoing_edges=1 incoming_edges=1 blocked=1 blocked_by=1`; real run `purged: reads=6 writes=5 deletes=3` |
| Residue check | PASS. No `follows/*` doc involving C; A and B counters correct (A followers 1 to 0, B unchanged); C no longer in A/B `following`, `blocked` or `blockedBy`. Only `A.muted[]` still named C: T27's clean-up was not built at drill time. With T27 shipped, re-run and expect `A.muted[]` to drop C after A calls ListMutedUsers (until then that entry is the expected residue). The check did **not** look for `quotas/{uid}` (added to Step 2 after the T19 review); re-check it on the next drill |
| Commands that failed as written | None |

**Residue check.** `assertGraphInvariants` (T16a) is an integration-build-tag Go test helper that loads the whole
graph from an emulator, so it can't be pointed at a cloud project. For the drill the same invariants (I1 edge and
`following[]`, I2 counters equal edge counts, I3 `blocked`/`blockedBy` symmetry, I4 no edge while blocked) were
checked over the accounts involved by reading `follows` (queries on `followerId` and `followeeId` for the uids),
`graph/{uid}` and `users/{uid}` through the Firestore REST API, before and after the purge, then that no `follows`
doc, `graph/{C}` or `users/{C}` remained.

**Notes from the drill (no runbook step was wrong):**
- `opsctl export-graph --out FILE` prints nothing on success; check the exit code and the file.
- Step 2 assumes `npx firebase-tools` is already logged in (`firebase login`); the drill machine was.
- From a git worktree nested under a directory with a `go.work` file, `go run ./cmd/opsctl` fails with "directory
  is contained in a module that is not one of the workspace modules"; set `GOWORK=off`. The main checkout is unaffected.

## 4. Confirm and record
Reply to the user that the deletion or export is done (mention the 14-day backup expiry for deletions). Record the
date, request type and a **hashed** uid in the founder's private tracker, not in this repo.

## 5. Pre-gate check: no disallowed Auth account owns a profile (ADR-0010 D5 A10, T26)
Run once against dev, then prod, before the verified-identity gate reaches prod (and again after any change to the
enabled sign-in providers). It lists Firebase Auth users in memory, classifies each as allowed (a `google.com` or
`apple.com` provider, or `password` with a verified email) or not, and batch-reads `users/{uid}` for the not-allowed
ones only. It is read-only, writes no file, and prints aggregate counts only (never a uid, email or provider list).

```bash
cd backend
GOWORK=off go run ./cmd/opsctl check-t26 --project dzeroth-dev
GOWORK=off go run ./cmd/opsctl check-t26 --project dzeroth-prod   # asks you to type the project id
# total=.. allowed=.. not_allowed=.. not_allowed_with_users_doc=.. firestore_reads=..
# last line: T26: PASS (exit 0) or T26: FAIL (exit 1)
```

- Cost: Firestore reads = `not_allowed` (printed as `firestore_reads`); Auth listing has no Firestore cost. Expected
  `not_allowed=0`, so 0 reads.
- Record only the date, project and the five counts (for example in the release readiness doc). Never paste uids.
- On `T26: FAIL`, do not enable the gate. Find the offending accounts by hand in the Firebase console (they are not
  printed on purpose), then handle each as an account deletion (sections 3b and 4) or amend ADR-0010 before retrying.

## 6. In-app account deletion and export (P8, ADR-0011)

### How it works (one paragraph)
`DeleteAccount` (own uid only, sign-in no older than `ACCOUNT_DELETE_REAUTH_MAX_AGE`, 5 min) marks `users/{uid}` as
`DELETING` with a `deletionJob` and publishes to the Pub/Sub topic `jobs`. The push subscription `jobs-push` calls
`/internal/pubsub/jobs` (OIDC, only the `pubsub-push` service account). After a **120 s gate** (so no instance still
treats the user as ACTIVE) the job runs the steps in this fixed order, in 20 s slices that re-publish themselves:
`auth_disable`, `posts`, `graph`, `identity`, `auth_delete`, `users_doc` (`users/{uid}` last). Step names are
persisted in `deletionJob.step`; never rename or remove one without a migration. `RequestAccountExport` writes
`exports/{id}` and a JSON object to the private bucket `<project>-exports` (7-day lifecycle, soft delete off); each
`GetAccountExport` signs a fresh 15-minute GET URL. Exports are capped at 1 per day per user.

### Where to look
- Logs (Cloud Run `api`): `account_job` lines per delivery (fields `step`, `outcome`, `step_calls`, `deleted_docs`,
  `deleted_objects`, `sections`, `bytes`); `auth_admin_op` NOTICE lines (C3 audit: `get`, `disable_revoke`, `delete`
  with `outcome`, `actor`, `uid_hash`); `auth_admin_refused` at ERROR (C1 refusal); `outcome=leased` (export deliveries),
  `backstop_page_full` (WARN). Logs hold only hashed uids. A raw uid or export id in a log line is a bug: stop and fix it.
- Dashboard: the DLQ tile (topic `jobs-dlq`).
- Firestore console: `users` documents with `status == DELETING` show `deletionJob.step` and progress time.

### The C4 alert (prod only, about $0.40/month)
Fires when more than 5 successful Auth deletions (`auth_admin_op="delete"`, `outcome="ok"`) happen in an hour, or on
any `auth_admin_refused` ERROR. Dev has no alert; inspect logs instead.
1. Find the lines: filter `jsonPayload.auth_admin_op:*` and read `actor`, `account_job`, `outcome`. Count distinct `uid_hash` values.
2. A burst of real user deletions (for example after a press mention) is fine: confirm each `uid_hash` has a matching
   `DeleteAccount` request line and a re-auth, then adjust `auth_admin_alert_per_hour` in Terraform if it is routinely noisy.
3. Any `auth_admin_refused` means a C1 check stopped an Auth mutation on an account that was not DELETING. Treat as a
   potential bug or compromise: read the line, check the user's `users/{uid}` state, and file it before re-enabling anything.
4. If you suspect misuse: set `feature_account_lifecycle = "off"` (Terraform, `envs/prod`, plan then founder-approved apply),
   **then shift traffic to the revision that apply creates.** In prod `promote-prod.yml` pins traffic to a named revision
   (`--to-revisions`), so the apply alone creates a 0% revision and changes nothing (same trap as
   [cost-spike.md](cost-spike.md)):
   ```bash
   G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"   # Git Bash on Windows
   P="--project=dzeroth-prod --region=asia-south1"
   SERVING=$("$G" run services describe api $P --format="value(status.traffic[0].revisionName)")  # note it: instant fallback
   NEW=$("$G" run services describe api $P --format="value(status.latestCreatedRevisionName)")
   # Wait until $NEW is Ready and carries the flag off before shifting:
   "$G" run revisions describe $NEW $P --format=json | grep -A1 '"FEATURE_ACCOUNT_LIFECYCLE"'
   "$G" run services update-traffic api $P --to-revisions=$NEW=100 --quiet
   # Verify: DeleteAccount / RequestAccountExport now answer FAILED_PRECONDITION FEATURE_DISABLED.
   # Fallback while anything is unclear: update-traffic --to-revisions=$SERVING=100
   ```
   Check that `$NEW` was built from the image that is serving today: Terraform ignores the image, so it carries the
   service template's image, which `release-prod` may have staged as a newer candidate. If it differs, use
   `--image=<serving image>` on a `gcloud run services update` instead of shifting to it.
   The flag stops new `DeleteAccount` and export requests; **jobs already accepted keep running on purpose** (users must
   not be left half-deleted). To halt in-flight jobs too, remove the `accountLifecycleAuth` binding from the runtime
   service account in Terraform: Auth steps then fail, retry and end in the DLQ. Put it back to resume. IAM takes
   effect at once, with no revision or traffic shift.

### A deletion is stuck
Symptom: a user is `DELETING` for longer than about an hour, or the DLQ tile moved.
1. Read the latest `account_job` line for that `uid_hash` (use the hash, not the uid): `step` and `outcome` say where it stopped.
2. Delivery retries use a 60 s minimum backoff and up to 10 attempts, then the message goes to `jobs-dlq`. The DLQ topic
   has no pull subscription, so nothing is lost that the backstop cannot rebuild.
3. The Cloud Scheduler job `daily-maintenance` calls `/internal/cron/daily-maintenance`, which re-publishes stuck
   `DELETING` accounts and `PENDING` exports (resuming from the saved step). To run it now:
   `gcloud scheduler jobs run daily-maintenance --project <project> --location asia-south1`.
4. The backstop only reads accounts with no progress for an hour, oldest progress first, 50 per page and up to 4 pages
   (200) per run, so fresh deletions never hide a stuck one (L-6 fixed). WARN `backstop_page_full` (fields `query`,
   `pages`, `cursor_at`) means the 4th page was full: more than 200 jobs are stuck at once, which is itself an
   incident (each one is also in the DLQ). Fix the common cause first, then run the backstop again; it continues from
   the oldest still-stuck job. For one urgent account, finish it with the manual steps in section 3b (the graph and
   posts purges are resumable). The composite indexes `users(status, deletionJob.progressAt)` and
   `exports(status, createdAt)` must be deployed (`firebase deploy --only firestore:indexes`); without them the cron
   returns 500 with FAILED_PRECONDITION in `account_job` (Error Reporting).
5. A step that fails 5 times in a row ends the delivery with an error (Error Reporting); look for the underlying
   cause in the same log line (it is scrubbed of uids). Fix the cause, then run the backstop.

### Sign-up failures after the P8 deploy
`CreateProfile` now asks Firebase Auth whether the caller's Auth user still exists and is enabled, only on a first
sign-up (no profile yet). Replays for an existing profile make no Auth call.
- `PERMISSION_DENIED "this account cannot be used to sign up"`: the Auth user is deleted or disabled. Expected for a
  user who just deleted their account and reuses an old token. No action; tell them to sign up again.
- `UNAVAILABLE` on sign-up while Firebase Auth / Identity Toolkit is down: new sign-ups fail closed (no profile is
  created) and existing users are unaffected. Retry when Auth recovers; no data repair is needed.

### Export problems
- `GetAccountExport` returns NOT_FOUND for unknown, foreign, malformed and expired ids alike (by design, so ids cannot
  be probed). An expired export must be re-requested.
- An export stays `PENDING` while a delivery composes it. One delivery at a time holds a 35 s lease (`exports/{id}.leaseUntil`);
  other deliveries log `outcome=leased` (HTTP 429) and retry after 60 s, which is normal. A crashed run is retried by the
  next redelivery, or by the daily backstop once the export is an hour old (GetAccountExport keeps saying PENDING until
  then). A client replay inside 2 minutes of the request does not publish again.
- `FAILED` export: the object is deleted and the document says so; the user can request again after the daily cap resets.
  An export for a user who is `DELETING` or gone becomes `FAILED` with no object.
- **Export fails with `too_large`** (ERROR `jobs/account_export_too_large` in Error Reporting, delivery outcome
  `failed:too_large`): composing did not finish in 22 s, so the export is `FAILED` and not retried (a retry would re-read
  everything again, up to 10 times). The log line has `sections` and `bytes` reached. Nothing is wrong with the system;
  the account is simply large. Do not re-publish it. If the user needs their data, do the manual export in section 3a
  (it has no time limit). If it recurs for ordinary accounts, raise it as a follow-up: the fix is a bigger compose budget
  in a Cloud Run Job or a per-section cap, which needs an ADR.
- Never copy an export object out of the bucket by hand; if you must inspect, read metadata only.

### Rollout and rollback
Dev is `allowlist` (founder uid). Prod is `off`. Ramp with the `flag-rollout` skill (off, allowlist, percent, on).
Before the prod flag leaves `off`: the privacy policy rights section is reworded and reviewed, the security review
items for prod are closed (see `docs/reviews/security-review-account-lifecycle.md`), and `production-reviewer` says GO.
Rollback of a bad deploy is the usual Cloud Run traffic shift to the previous revision (the code is backward
compatible with in-flight `deletionJob` documents as long as step names are unchanged).

## 7. Answering a request that arrives by email (client-facing wording)
1. Verify the sender (section 1). Then check whether the in-app flow is available to them: it is only visible when the
   flag is on for their account. While the prod flag is `off`, go straight to the manual path (sections 2 to 4).
2. If the in-app flow is available, prefer it and reply with the steps below; handle by hand only if they cannot use the
   app (no device, cannot sign in, account without a profile). Do not run both paths for the same account.
3. Suggested reply text (edit to fit; do not promise timings the system does not measure):
   - **Delete:** "Open Settings, then Delete account, and confirm. You will be asked to sign in again first (the sign-in
     must be within the last 5 minutes). Deletion starts after a short safety wait of about 2 minutes and then runs in
     the background; you are signed out straight away. Your posts, follows and profile are removed. Backups age out
     within 14 days. Other people's posts that mention you keep your handle (they are their content), and entries in
     other people's mute or block lists disappear the next time they open those lists."
   - **Export:** "Open Settings, then Download my data. We prepare a file with your profile, posts and graph; the
     download link is valid for 15 minutes, you can request one export per day, and the file is deleted after 7 days.
     It never includes who has blocked you."
   - If the app says the feature is unavailable, tell them it is not enabled for their account yet and that you will do
     it by hand within 30 days.
4. Record only the date, request type and a hashed uid in the founder's tracker (section 4).

## 8. Drill records (P8, in-app path)
| Field | Result |
|---|---|
| Date | 2026-10-09 |
| Environment | dev (`dzeroth-dev`), Cloud Run revisions api-00093-k42 then api-00096-hsh (final backend image `0e714b317110`), flag `allowlist` with the throwaway uid `p8livecheck01` added temporarily and removed again via a saved Terraform plan |
| What ran | `live-auth-check` (6 steps): admin-create the throwaway user, sign in, `CreateProfile`, `DeleteAccount`, poll until the job finished, replay `CreateProfile` with the old token and expect 403 (M2). All 6 passed |
| Audit logs | `auth_admin_op` lines present for `get`, `disable_revoke`, `delete`, hashed uid only; no raw uid or export id found |
| Observed, by design | repeated `disable_revoke` lines are the 120 s start gate nacking and being redelivered: idempotent, 0 Firestore operations, not counted by the C4 alert |
| Not recorded / not done | wall-clock duration and active-work time; a Firestore residue sweep after the run (the emulator sweep T11 covers it, the cloud one was not run); a real signed-URL export download on dev; the `candidate` run of the T18 remote smoke; on-device client delete (Google, Apple, password, web) and Apple token revocation |

Because the duration and the cloud residue sweep were not recorded, the T22/T23 acceptance ("under 10 min of active
work, 0 residue") is **not** claimed from this drill. Repeat it once on dev when the on-device checks are done: time it,
run the cloud residue check from section 3b's drill notes (including `quotas/{uid}`), and add a row here.
