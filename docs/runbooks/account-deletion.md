# Runbook: manual account deletion and data export

**Why this exists:** in-app `DeleteAccount` / `RequestAccountExport` ship in Phase 1. Until then, requests to
**privacy@dzeroth.com** are handled by hand, within **30 days**, as the privacy policy promises. This closes security
audit finding M5 for the web launch. App Store and Play submissions still need the in-app flow.

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
created and last-login times) from `accounts:lookup`, plus the graph export below. Phase 1 will add posts and likes
here as those modules ship. Don't include internal fields such as `status`.

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

## 3b. Delete
Order matters: **the graph purge comes before `users/{uid}` is deleted**, because the purge decrements the counters on
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
npx -y firebase-tools@15 firestore:delete "quotas/$UID_" --recursive --project $P --force  # per-user daily quota counters (written by graph)
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
- **Media:** Phase 0 has no avatars or posts, so there's nothing to delete. When media ships, also delete
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
