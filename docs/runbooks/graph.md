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

**Symptom: "a user can't unfollow an account that no longer exists."** Unfollow answers "not following" (NONE), but
the account stays in the user's Following list and count. This is ADR-0009 state S2: `users/{b}` was deleted
(account-deletion Step 2) before `purge-graph` finished for `b`, so the counter update in Unfollow's batch fails and
the whole batch is a no-op. No API path produces it; only the deletion steps run out of order. Don't hand-edit the
edge. Run the repair in `docs/runbooks/account-deletion.md` ("Repair: Step 2 ran before the purge finished"):
`opsctl purge-graph --skip-start-gate` for the deleted uid, then the dry run must show 0/0 edges, then check the
followers' counters with steps 1 to 3 above. If instead the edge doc is missing while the uid is still in the
caller's `following` (state S1), the only producers are an account set back to ACTIVE after purge step 1 (forbidden:
deletion is one-way, ADR-0009) or a hand edit. For the first, finish that account's deletion; for the second, repair
by hand as in step 5 and record the cause.

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
- `FEATURE_FOLLOW_SUGGESTIONS[_ALLOWLIST|_PERCENT]` / `feature_follow_suggestions*` (wire name `follow_suggestions`, default off, ADR-0024 D8-D9) gates
  only `ListSuggestedUsers`, on top of `FEATURE_GRAPH`: without it the answer is `FEATURE_DISABLED` with `metadata[feature]=follow_suggestions`
  and 0 reads. `GetProfileRelationship` needs `FEATURE_GRAPH` only. W3-4 registers the flag, the limits and the gate; `GetProfileRelationship` is live since W3-11 (section 5) and
  `ListSuggestedUsers` is live since W3-12 (section 6). Config (validated at startup, a typo fails the boot): `SUGGESTIONS_SAMPLE_FOLLOWEES`
  (30, max 30), `SUGGESTIONS_EDGE_LIMIT` (20 since ADR-0024 Amendment 2, max 50; section 6), `SUGGESTIONS_HYDRATE_MAX` (10, max 50), `SUGGESTIONS_MAX_RESULTS` (5, max 5),
  `SUGGESTIONS_CACHE_TTL` (1h), the curated fallback `SUGGESTED_USER_IDS` (Terraform `suggested_user_ids`, <= 20 comma-separated uids; empty
  = none; one bad uid fails startup), and the limits `RATE_LIMIT_SUGGESTIONS_PER_MIN` (10), `SUGGESTIONS_CALLS_PER_DAY` (50) and
  `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN` (60), all per instance. `RESOURCE_EXHAUSTED` with `limit_name=suggestions_daily` is the
  daily call cap (150/day with 3 instances). Kill switch: set the flag to `off` and deploy; nothing stored changes.
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

## 5. "Follows you" is wrong, missing, or the profile header 404s (`GetProfileRelationship`, ADR-0024 D7)
`GetProfileRelationship(user_id)` answers the caller's `Relationship` from the cached caller snapshot plus `followed_by`:
whether `follows/{target}_{caller}` exists. It needs `FEATURE_GRAPH` only. One target per call; list rows never get it
(1 read each). The request line carries `graph_op=profile_relationship`, `followed_by_cache_hit` (true: answered from the
pair cache, false: it cost the one edge read; absent when no edge lookup ran: the caller's own id, a target the caller
blocks, a refused target) and the usual `fs_reads`. Cost: caller graph 1 + edge 1 cold (2) when the target's profile is
warm, +1 for a cold profile, +1 on `blockedByOverflow`, plus the interceptor's 1; 0 warm; 0 writes.

**The pair cache** (`graph.Cache`, instance memory, no Redis): 5,000 `(follower, followee)` entries, about 1 MiB, true and
false both cached, TTL = `CACHE_TTL` (<= 60 s). Staleness bound: another instance's Follow, Unfollow or Block is seen here
within that TTL. On THIS instance the pair is evicted by Follow, Unfollow and Block (both directions) as they commit; the
caller's own Follow or Unfollow never changes `follows/{target}_{caller}` and evicts the opposite pair only. A Follow or
Unfollow that lands between the edge read and its cache write can leave one stale answer for at most the same TTL.

**Symptoms and what they mean**
- "Follows you" shows up to a minute late, or disappears late, right after the other user followed or unfollowed: expected
  when the write landed on another instance (max-instances 3). No action; it converges at the TTL.
- `NOT_FOUND` ("profile not found") on the header, the target exists in the console: the target blocked the caller, is
  SUSPENDED or DELETING, or was deleted. The answer is byte-identical to `GetProfile` on purpose (no existence leak): never
  tell the caller which.
- `followed_by` is `false` for a target the caller blocks even though an edge once existed: correct, Block deleted both
  edges and a blocked pair cannot follow (ADR-0008 D9).
- A wrong value that outlives the TTL on every instance: check invariant 1 (section 2) for that pair, and that
  `follows/{target}_{caller}` is what you expect (point read in the console). A missing edge with a `following` entry is
  a data bug, not a cache bug.
- `INTERNAL` from this RPC: the edge point read or the profile lookup failed; the logged cause has the uids replaced by
  their hash. Retry once; if it persists look at Firestore status and `docs/runbooks/cost-spike.md`. Reads from the RPC
  are covered by the per-user read budget; a client polling it hits `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN` (60 per
  instance) first.
- Kill switch: `FEATURE_GRAPH=off` (the whole service). The client treats `FEATURE_DISABLED` and `UNIMPLEMENTED` as "unknown"
  and hides the chip; nothing stored changes.

## 6. Who to follow (`ListSuggestedUsers`): empty, stale, slow or erroring
ADR-0024 D8, ticket W3-12, behind `FEATURE_GRAPH` and `FEATURE_FOLLOW_SUGGESTIONS` (section 4). At most 5 rows
(`SUGGESTIONS_MAX_RESULTS`), no cursor, `since` unset, an empty list is a normal answer.

**How an answer is built** (`suggestions.go`, `suggester.go`)
1. The per-viewer instance cache (below). A hit reads nothing.
2. The caller's `graph/{uid}` (cache-first, 60 s). Its newest 30 followees (`Snapshot.RecentFollowing`, the tail of the
   `following` array, which `ArrayUnion` appends in follow order) seed the next step.
3. One query, `follows where followerId in [<= 30] ORDER BY createdAt DESC, __name__ DESC LIMIT SUGGESTIONS_EDGE_LIMIT`
   (20 since ADR-0024 Amendment 2 B1(b); it was 30), served by the
   existing `follows (followerId ASC, createdAt DESC)` index (no new index). Candidates are the `followeeId`s, ranked
   by how many sampled followees follow them, ties by a hash of (viewer, candidate, IST day): the order is stable
   within an IST day and reshuffles at IST midnight. Two limits at 0 reads (W3-22 L-5): a sampled followee the
   identity profile cache already knows is SUSPENDED, DELETING or gone is left out of the query's follower list
   (`identity.KnownInactive`, cache only), and each remaining followee contributes at most its newest 3 usable edges
   (`maxCandidatesPerFollowee`).
4. The exclusion matrix at 0 reads: self, following, requested, blocked, blockedBy, muted.
5. If fewer than 3 usable candidates remain (or the viewer follows fewer than 3 accounts, which skips step 3), the
   curated `SUGGESTED_USER_IDS` list (same filter) fills after them.
6. ONE `identity.Directory.GetProfiles` over at most `SUGGESTIONS_HYDRATE_MAX` (10) candidates. SUSPENDED, DELETING
   and deleted users drop out here, so a list can come back shorter than the candidates.

**Reads.** The cold cap is `2 + SUGGESTIONS_EDGE_LIMIT + SUGGESTIONS_HYDRATE_MAX`: **32** at the defaults (interceptor 1,
graph 1, edges <= 20, profiles <= 10; ADR-0024 Amendment 2 B1(b), it was 42 at edge limit 30); curated 12; warm 1
(the interceptor; 0 when its profile read is cached) or 2 when the viewer's 60 s snapshot has expired, because every warm
hit is re-filtered against `graph/{uid}` (W3-22 L-1); planning **27.6** per call (0.95 x (0.85 x 32 + 0.15 x 12) + 0.05 x
1.5; about 95% of calls are cold) and **17.2 reads per DAU** with the 48 h client cache and the B2 guards below (0.63 calls
per DAU, 27.6 reads each). `fs_reads` on the request line above 32 for this RPC is a regression: compare
`SUGGESTIONS_EDGE_LIMIT` and `SUGGESTIONS_HYDRATE_MAX` on the serving revision (startup rejects values above their
bounds). **Dev still runs `SUGGESTIONS_EDGE_LIMIT=30` explicitly** (the W3-24 apply) until the production-deployer's
targeted apply of the `api` service with the `main.tf` literal 20 (Amendment 2 handoff step 4): a cold call of up to 42
there before that apply is expected, not a regression, so read the serving revision's env value first; after it a cold
dev call logs `fs_reads` of at most 32. A project may set 30 again (the walk-back: 20 to 30 only, by a reviewed config
PR that cites the B3 fill check; above 30 needs an ADR), and its cap is then 42. A fresh instance pays the cold cost once
per viewer per hour; the per-uid 10/min bucket, the 50/day cap (`limit_name=suggestions_daily`, per instance) and the
daily read budget bound a storm: one account's worst day is 50 calls x 32 reads x 3 instances = 4,800 reads, under the
6,000 per-uid read budget (2,000 x 3), so the call cap binds.

**Client lifetimes (Amendment 2 B2; only from the app release that carries them, older builds keep 24 h for every
answer).** A non-empty answer is kept 48 h on the device, an empty one 6 h, an answer after RESOURCE_EXHAUSTED (a rate
limit, a quota or a limit reached) 24 h, which backs off past the IST-day reset of the 50/day cap. The card refills once
per session when follows from the card use up its last row (one extra call; dismissals and NOT_FOUND drops never refill).
All of it stays under the server's 10/min and 50/day per instance; an account whose answer is empty makes at most four
calls a day.

**Cost trigger (ADR-0024 stage ladder, Amendment 2 B3).** Suggestion reads above 10% of the daily Firestore reads
(it fires at about 29.4 suggestion reads per DAU), or the `free-tier-budget` section 6 trigger, sustained 7 days, needs
an ADR (a precomputed table). After B1 and B2 the model is 17.2 of 281.7 reads per DAU = **6.1%** (5.0% in the best case):
read the measured share against 6.1%, not the 11.9% of W3-23 (that was before the two levers), and ignore dev shares
(3 allowlisted users mean nothing). Regression checks (same `docs/reviews/cost-model.md` section 9 queries, no new alert,
not stage triggers):
- **Cold reads per call.** `mean_cold_reads` above 32 is a config regression (the model is 29.0 = 0.85 x 32 + 0.15 x 12).
- **Calls per DAU.** Above 0.8 for 7 days means the 48 h cache is not holding (old builds, second devices, cleared web
  storage or a refill loop): fix the client before reading the share. The model is 0.63.
- **Fill.** Cold `source=fof` calls with `candidates` below 5 in more than 30% of cold fof calls for 7 days means the
  20-edge window is starving the card: walk the limit back toward 30.

The daily share query, the warm-hit and curated shares, and the L-5 signal (`source=fof` with `candidates` of 3 or fewer)
are in `docs/reviews/cost-model.md` section 9.

**Request line.** `source` = `fof` (3+ usable friends of friends, no curated row), `curated` (the curated list was
consulted; any friends of friends found still come first) or `none` (the viewer's `blockedByOverflow` is set, so no
candidate can be ruled out as a blocker at 0 reads: nothing is suggested); `candidates` (uids sent to hydration);
`suggestions_cache_hit`; `graph_cache_hit`. Counts and enums only, never uids.

**Cache and staleness.** Per viewer, in the instance only, up to `SUGGESTIONS_CACHE_TTL` (1 h) after the call that built
it (the expiry is stored in the entry and does not stretch when a row is removed). It holds the hydrated rows (up to
`SUGGESTIONS_HYDRATE_MAX`), so a removal refills from the tail. This instance's own Follow, Block and Mute remove the
user from the viewer's entry at once (Block also removes the viewer from the other user's entry). EVERY warm hit is also
re-filtered against the viewer's snapshot (W3-22 L-1): the 60 s snapshot cache when it holds one (0 reads), else one
read of `graph/{uid}` that refills it. So a user who blocks the viewer, or whom the viewer follows, blocks or mutes on
another instance, is gone within 60 s, not at the end of the hour. If that read fails the call fails (INTERNAL), it is
never answered with an empty list, because the client would cache the empty answer (6 h; 24 h on a build without B2); an
overflowed `blockedBy` shows nothing. What stays stale for up to the TTL: a user who is suspended, deletes the account or
changes handle, name or avatar after the entry was built (the status check happens at build time only), and an empty
answer. The client caches on top (W3-19, Amendment 2 B2): 48 h for a non-empty answer, 6 h for an empty one, 24 h after
a limit (24 h in every case on a build without B2). **On a device, then, a blocker is bounded by the client TTL (48 h, or
until a tap gets NOT_FOUND, which drops the row for good), not by the server's minute; "more than a minute" applies to
the server's answer only.** The cache is cleared by a restart or scale-in; nothing else clears it.

| Symptom | Cause and action |
|---|---|
| Always an empty list | The viewer follows fewer than 3 accounts and `SUGGESTED_USER_IDS` is empty or every curated user is excluded or not ACTIVE: set `suggested_user_ids` in Terraform. Or `source=none` (blockedByOverflow). An empty answer is cached for the TTL on the server and 6 h on the device (24 h on a build without Amendment 2 B2), so an account sees friends of friends within 6 h of following 3 accounts. |
| INTERNAL on every call, error text "requires an index" | The `follows (followerId ASC, createdAt DESC)` COLLECTION-scope index is missing or still building in that project (the emulator never checks). It is in `firebase/firestore.indexes.json` since ADR-0008: check `gcloud firestore indexes composite list --project=<p>` and deploy with `firebase deploy --only firestore:indexes`. Kill switch meanwhile: `FEATURE_FOLLOW_SUGGESTIONS=off`. |
| A user the viewer already follows or blocked is suggested | Another instance's cache (<= 1 h) or a Follow made elsewhere; the client drops followed users locally; the server hides them within 60 s (every warm hit re-checks the snapshot). A user who blocked the viewer showing up in the SERVER's answer for more than a minute is the one to escalate: it is a privacy leak of the block (the blocker is NOT_FOUND on `GetProfile`). Turn the flag `off` and open a security issue; check `blockedBy` for that uid. On a DEVICE the same row can stay for up to the client TTL (48 h, was 24 h; until a tap gets NOT_FOUND, which drops it for good): that alone is not a leak. Check the request line first (the server re-filters every answer within 60 s); the row shows only the public profile as of the build, and the profile and Follow are refused. |
| `source=fof` with `candidates <= 3` on many calls (W3-23 watches this) | One account fills the edge window (20 edges by default, 30 before Amendment 2): a follow-back bait account that follows 20 or more promotion accounts in a minute has the newest 20 edges for everyone who follows it. The per-followee cap (3) bounds the steering to those 3 candidates, but the window is still full, so the answer is those 3 (no curated top-up: 3 is enough for `fof`). Find the flooder: the sampled followee whose `follows` docs (`followerId == uid`) are the newest; `opsctl suspend-user` removes its share on instances whose profile cache has seen the suspension, and the next purge removes the edges. A cohort of candidates that all lead to one uid is the abuse signal. |
| Fewer than 5 rows although many candidates | Hydration dropped suspended or deleted users, or the viewer's graph is small. The top-up is made before hydration, never after, to keep the 32-read cap. With the 20-edge window (Amendment 2) a small, dense network, where many friends of friends are already followed, gives up to a third fewer usable candidates, so more cards come back with 3 or 4 rows or with curated rows after the friends of friends: the B3 fill check watches it (section 6, cost trigger); walk `SUGGESTIONS_EDGE_LIMIT` back toward 30 if it persists. |
| `fs_reads` 33 to 42 on a cold call | Expected only where `SUGGESTIONS_EDGE_LIMIT=30` is still set (dev until the Amendment 2 apply; a project that walked the limit back): cap `2 + edge limit + hydrate max`. Read the serving revision's env first. Above that cap, or above 32 where the limit is 20, it is a regression (Reads, above). |
| ERROR logs mentioning a graph error with hashed uids | Firestore failure in the edge query or hydration; the text is redacted (`logger.RedactErr`). Not cached, the next call retries. A canceled request is CANCELED, not INTERNAL. |
