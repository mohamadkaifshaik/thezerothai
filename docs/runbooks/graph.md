# Runbook: social graph failure modes (follows, blocks, mutes)

Owner module: `backend/internal/graph` (ADR-0008). Data: `follows/{followerId}_{followeeId}` edges,
`graph/{uid}` (`following`, `blocked`, `muted`, `blockedBy`, `blockedByOverflow`), counters
`users/{uid}.followersCount` / `followingCount`. Everything is behind `FEATURE_GRAPH` (off | allowlist | percent | on).

Git Bash on Windows; queries below are for **Logs Explorer**
(`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`). Env changes on prod use the
pinned-traffic procedure in `docs/runbooks/cost-spike.md`. Abuse handling (follow spam, list scraping, kill switch) is
`docs/runbooks/abuse-spike.md` section 5a. Account deletion and export is `docs/runbooks/account-deletion.md`.

## 1. `blockedby_cap_reached` (ERROR log)
**What it is.** An account has been blocked by 10,000 users, the cap on `graph/{uid}.blockedBy` (ADR-0008 D2). The
block still succeeds, but `blockedBy` is skipped and `graph/{target}.blockedByOverflow` is set to `true`. Follow and
GetProfile then fail closed with one extra read for that account. At Stage 0 (< 10,000 users) this is unreachable
unless someone is farming blocks or is a very abusive account. The log line carries `target_uid_hash` only.

**Find it:** `jsonPayload.message="blockedby_cap_reached"` (severity ERROR, so it also shows in Error Reporting).

**Do:**
1. Match `target_uid_hash` to an account by the time window, or hash candidate uids the way the logger does
   (`logger.HashUID`). Logs never hold the raw uid.
2. Send the account for moderation review (report history, content, sign-up pattern). If abusive, disable it
   (`docs/runbooks/abuse-spike.md` section 3).
3. If the review clears it, clear the flag by hand once and record it in your tracker:
   `graph/{uid}.blockedByOverflow` = false. It is never cleared automatically; a stale `true` only costs that account
   +1 read on the fail-closed paths.
4. If it happens for a legitimate account, that is a scale signal: open an ADR (cap or data model) rather than raising
   the cap. Documents are sized to stay under Firestore's 1 MiB limit only at the current caps.

## 2. Counter drift suspected
**Symptom.** A profile's follower or following count disagrees with the actual list, or a `follows` edge exists
without the matching `graph.following` entry (or the reverse). All counter changes are made in the same transaction or
batch as the edge change, so drift means a bug or a manual edit. Treat it as a bug to report.

**The invariants** (ADR-0008 D3):
1. `follows/{a}_{b}` exists <=> `b` is in `graph/{a}.following`;
2. `users/{x}.followersCount` = number of `follows/*_{x}`, and `followingCount` = number of `follows/{x}_*`;
3. `b` is in `graph/{a}.blocked` <=> `a` is in `graph/{b}.blockedBy` (except when `graph/{b}.blockedByOverflow`);
4. no follow edge in either direction between `a` and `b` while either blocks the other.

**Dev.** Reproduce it against dev or the emulator and run the invariant checker logic from the T16a tests
(`backend/internal/graph`, integration tests via `make test-int`) to find which invariant breaks. Fix the bug before
repairing data.

**Prod repair** (a `count()` aggregation per affected user, then a manual set, recorded):
1. Count real edges with a Firestore `runAggregationQuery` (count aggregation costs 1 read per 1,000 index entries).
   Followers of a user: `follows` where `followeeId == <uid>`. Following: `follows` where `followerId == <uid>`.
   Run it with the REST call (`H` from the header of `account-deletion.md`):
   ```bash
   curl -s "${H[@]}" -X POST "https://firestore.googleapis.com/v1/projects/$P/databases/(default)/documents:runAggregationQuery" \
     -d '{"structuredAggregationQuery":{"aggregations":[{"alias":"n","count":{}}],"structuredQuery":{"from":[{"collectionId":"follows"}],"where":{"fieldFilter":{"field":{"fieldPath":"followeeId"},"op":"EQUAL","value":{"stringValue":"<uid>"}}}}}}'
   ```
2. Compare with `users/{uid}.followersCount` / `followingCount`, and check `graph/{uid}.following` length against
   the second count.
3. If the count is wrong, set the field on `users/{uid}` to the counted value (PATCH with `updateMask.fieldPaths`).
   Don't use the app or increment operations for repair.
4. Record the uid hash, before and after values, and the suspected cause in `docs/reviews/`.
5. A `follows` edge with no matching `graph.following` entry (or the reverse) is repaired by hand the same way, or,
   for an abusive or deleted account, by the graph purge in `account-deletion.md`.

Do not build an automatic recount job at Stage 0 (ADR-0008 D3).

## 3. Transaction contention (UNAVAILABLE "temporarily busy")
**What users see.** A graph mutation (Follow, Unfollow, Block, Mute...) that keeps losing Firestore lock races returns
Connect code `UNAVAILABLE` with message "temporarily busy, please retry" and a retry-after of 1 s. It is retryable
and is never `INTERNAL`, so it does not go to Error Reporting as a server bug.

**How it arises in code.** Transactions (Follow, Block) are retried by the Firestore SDK. Unfollow is a bare batch
that the SDK does not retry, so `FirestoreRepo.Unfollow` retries it up to 6 attempts with backoff (25, 50, 100, 200,
400 ms). If it still loses (`Aborted`), the repo returns `graph.ErrContention`, and the service maps that (and any
raw contention error) to the `UNAVAILABLE` response above. A failed attempt writes nothing, so the read/write budget is
unchanged.

**Find it:**
- Rejected calls: `jsonPayload.code="unavailable" AND jsonPayload.rpc:"GraphService/"`, grouped by `jsonPayload.rpc`
  (the request line also carries `outcome="rejected:contention"`).
- Contention that still succeeded: the WARN `graph_txn_contention` (message `jsonPayload.message`) with
  `txn_attempts=N`, emitted when a transaction's callback ran more than 3 times. Every graph request line also
  carries `txn_attempts` for Follow, Block, Unblock, Mute and Unmute (Unfollow reports its retry-loop attempts).
- Per-operation view: `jsonPayload.graph_op!=""`, grouped by `graph_op` (sum `fs_reads`, or count of `txn_attempts>1`).
  This is the measure ADR-0008 D3 names for the sharded-counter revisit. No uids are logged in these fields.

**Do:**
1. A few per day is normal: two people acting on the same account at the same instant. No action.
2. A sustained rate on one `uid_hash` or one RPC: usually a script (`docs/runbooks/abuse-spike.md` section 5a) or a
   client retrying without honouring retry-after.
3. A sustained rate across many callers all touching one `users/{uid}` doc: a viral account taking more than about
   1 follow per second on its counter document. That is the scale trigger for a sharded-counter ADR (CLAUDE.md rule 3,
   `free-tier-budget` section 6). Don't shard ad hoc.
4. If it is hurting users now, set `FEATURE_GRAPH=off` (pinned-traffic procedure) while you investigate.

## 4. Lists show a deleted user, or a graph RPC says the feature is off
- `FEATURE_DISABLED` (FAILED_PRECONDITION) on a graph RPC means `FEATURE_GRAPH` is off for that caller (mode `off`,
  `allowlist` without the uid, or outside the `percent` bucket). Check the env var on the serving revision.
- `purge-graph` removes a deleted user from other users' `following`, `blocked` and `blockedBy` arrays (confirmed by
  the 2026-09-30 dev drill). Other users' `muted[]` (and any dangling `blocked[]`) may still name the deleted uid.
  Since T27 the lazy clean-up (ADR-0008 D10) removes such a uid from a user's **own** array the next time that
  user opens ListMutedUsers / ListBlockedUsers: one `ArrayRemove` on their own `graph/{uid}` (at most one page,
  50 ids, one write, 0 extra reads). Only uids with no `users/{uid}` doc are removed; SUSPENDED and DELETING
  users stay. The request log line carries `confirmed_missing` (only uids whose users doc a fresh read confirmed
  absent on that page; excludes SUSPENDED/DELETING and negatively-cached uids) and `lazy_removed` (counts; 0 when
  nothing was written). Under `DEGRADED_MODE=readonly` the clean-up write is skipped (`lazy_removed=0`, DEBUG
  `graph_lazy_cleanup_skipped_readonly`). A failed clean-up logs
  WARN `graph_lazy_cleanup_failed` and the list still succeeds. Residue therefore lasts until the muter next
  opens that list. There is no manual step; do not hand-edit other users' documents.
