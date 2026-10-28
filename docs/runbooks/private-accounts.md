# Runbook: private accounts, the protected set (identity, ADR-0025)

Owner module: `backend/internal/identity` (ADR-0025 D2, D3, D8, D11; ticket W3-26a). Flag: `FEATURE_PRIVATE_ACCOUNTS`
(`private_accounts`), which gates only setting `is_private=true`; every enforcement path ignores it (a protected account stays
protected when the flag is ramped down). Data: `users/{uid}.isPrivate` (the single source of truth) and the derived index
`privacy/protectedAuthors {uids[], updatedAt}` (one doc, cap `PROTECTED_AUTHORS_MAX` 20,000, about 600 KB). Config:
`QUOTA_PRIVACY_TOGGLES_PER_DAY` (4), `PROTECTED_AUTHORS_MAX`, `PROTECTED_SET_MAX_STALE` (10m), `CACHE_TTL` (60 s). Other modules read
the set only through `identity.ProtectedAuthors` (`docs/code-map.md`). Account deletion is `docs/runbooks/account-deletion.md`.

Git Bash on Windows; queries are for **Logs Explorer**
(`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`).

## 1. The toggle (`UpdateProfile` with `is_private`)

| Client sees | Meaning | Check |
|---|---|---|
| FAILED_PRECONDITION `FEATURE_DISABLED` `feature=private_accounts` | `is_private=true` from outside the cohort (or flag off). 0 reads past the interceptor, 0 writes. `is_private=false` is never refused for this. | `GetMe.enabled_features`; the `FEATURE_PRIVATE_ACCOUNTS*` env vars. |
| RESOURCE_EXHAUSTED `QUOTA_EXCEEDED` `quota=privacy_toggles` | The 5th change of an IST day (both directions count; an equal value does not). 0 writes. Retry-After is the next IST midnight. | `quotas/{uid}.privacyToggles` and `day`. Do not reset by hand unless support has verified the user. |
| FAILED_PRECONDITION `LIMIT_REACHED` `limit=private_accounts` | The set already holds `PROTECTED_AUTHORS_MAX` uids. 0 writes. See section 3. | `count()` check in section 4. |

Request-line fields: `privacy_toggle=on|off|noop|quota|cap`, `privacy_toggle_attempts` (transaction attempts). Budget: protect 4 cold
/ 3 warm reads and 3 writes (`users`, set doc, `quotas`); unprotect 3 / 2 reads and 3 writes; equal value 1 read and 0 writes. A toggle
bumps no `snapshotVersion` and enqueues no snapshot job.

`privacy_toggle_attempts` above 1 on many requests, or ABORTED on the set doc, is the hot-doc signal of ADR-0025 D3: protect and
unprotect are limited to 4 a day per user, so it takes a burst of different users. The planned fallback is 16 shards
(`privacy/protectedAuthors-{0..f}`) behind the same loader; it needs an ADR amendment, do not add shards by hand.

An unprotect hands `PrivacyListener.BecamePublic` the uid after the commit (detached, 2 s deadline); `graph.PrivacyListener` (wired in
`apiserver.go`) publishes `{kind: privacy_public, uid}` to the `jobs` topic. If it fails, ERROR `privacy_public_enqueue_failed` (Error
Reporting): the toggle succeeded, the account is public, and its pending follow requests stay pending until the `privacy_public` job is
republished (section 6). A follow of
that account meanwhile becomes an edge (ADR-0025 AQ4).

## 2. The stale set and UNAVAILABLE

The loader reads the set doc lazily: only when a request needs it and its copy is older than 60 s, one read per instance, shared by
concurrent requests, on a detached counter (log field `protected_set_reads`, never in a caller's `fs_reads`). The instance that
committed a toggle applies it at once; the others within 60 s. A toggle that lands on the same instance while a refresh read is
in flight no longer discards that read: the fetched copy is installed with the toggle re-applied, so an instance idle for more than
10 minutes never serves the old copy (W3-40a, W3-36 L-3).

**The wire-visibility hint (W3-40b, W3-36 L-4).** `Audience.ProtectedAuthor` (the computed `visibility` of a row) asks the loader for the
viewer's own and followed authors through `Cached()`, which never refreshes and never logs, and falls back to `Current` when no copy is
fresh (younger than 60 s). A Home page of followed authors therefore makes no `Current` call on a warm instance; the wire value is the same.
During a set outage a request raises one ERROR `protected_set_unavailable` and WARN (`repeat=true`) for every further ask in the same
request, so Error Reporting counts one error per affected request, not one per row. Undo path: `UnlikePost` and `UndoRepost` of a REPOST id
whose original is hidden echo the original's id, exactly like a deleted original.

**Startup refusal (W3-36 L-5).** `apiserver.Build` refuses to start, with `protected-author seams not wired (would fail open): <names>`,
when any of the seven protected-set seams is nil (the loader, graph `Protected`, `identity.WithProtectedAuthors`, the notifications
`Audience`, `posts.WithProtectedAuthors`, the engagement `Audience` from `posts.AudienceOf`, `timeline.WithProtectedAuthors`). Every
module reads a nil seam as "nobody is protected", so the deploy fails instead. A revision that crash-loops with this message has a
wiring regression: roll back (never forward-fix by passing a nil).

**Undo of a post the caller cannot see (W3-36 L-1).** UnlikePost and UndoRepost still always remove the caller's like or repost, but
answer the missing-post shape (the post id only, zero counts: the bytes of a deleted post) when the caller may not see the post or
its author (protected and not followed, blocks the caller, taken down). Cost: +0 warm, +1 cold (the caller's graph snapshot).

| Log line | Meaning | What to do |
|---|---|---|
| WARN `protected_set_stale` (`age_s`) | The refresh is failing; the last good copy is served, at most 10 minutes old (`PROTECTED_SET_MAX_STALE`). A user who just went public or protected may be seen with the old state for that long. | Find the Firestore error behind it (Firestore status, quota exhausted: `docs/runbooks/cost-spike.md`). It ends by itself when reads work again. |
| ERROR `protected_set_unavailable` (once per request, then WARN with `repeat=true`; W3-40b L-4) | The copy is older than 10 minutes, or the instance never loaded one. Every path that needs the set answers UNAVAILABLE (retryable); the profile header is still served and omits the pin (`pin_omitted=set_unavailable`); post-bearing notifications are redelivered by Pub/Sub. An unknown set is never read as "everyone is public". | Same as above. If the daily read quota is exhausted, restoring service needs the quota, not a code change. Do not "fix" it by emptying the set doc. |

## 3. The 20,000 cap

At about 600 KB the doc is close to the 1 MiB document limit and `PROTECTED_AUTHORS_MAX` is the guard. Raising it needs the doc size
re-checked (28-char uids) and an ADR note; the Stage 2 answer is the 16-shard layout or Memorystore behind `identity.ProtectedAuthors`.
Users who hit the cap see LIMIT_REACHED; nothing else is affected.

## 4. Verify the set equals the accounts

The set is a derived index of `users.isPrivate`. To check it (1 read per 1,000 users matched, so cheap):

1. `count()` of `users where isPrivate == true` (Firestore console aggregation query, or a `gcloud firestore` count).
2. `uids` length of `privacy/protectedAuthors` in the console.

They must match. A difference means a write bypassed the toggle (hand edit, `opsctl` command) or a deletion left an entry. Fix by
hand only with the founder's OK: add the missing uid with `ArrayUnion`, remove a dead one with `ArrayRemove`; never delete the doc
(the instance copies refresh within a minute).

## 5. Deletion and export

The identity eraser step removes the uid with `ArrayRemove` (0 reads, at most 1 write, NotFound of the doc is success, never
creates it) before `users/{uid}` is deleted; it runs for every deleted account, protected or not, so a drifted entry cannot outlive
the account. The set lists other users, so it is never exported (T11 row `privacy`, `erasedByStep: identity`).

## 6. The `privacy_public` job (W3-28b)

What it does: when an account goes public, `graph.PrivacyPublicJob` accepts every pending follow request addressed to it. It rides
the shared `jobs` topic and `/internal/pubsub/jobs` (OIDC push), is registered whatever the flags say (never gated), and acts on
Firestore, never on the message's word: a forged message for an account that is still protected logs `outcome=stopped:protected` and
writes nothing.

How it works: pages of 100 (`followRequests where followeeId == uid ORDER BY createdAt DESC, __name__ DESC`), one transaction per page
that reads `users/{uid}` fresh, the page itself, the requesters' status (Directory, cache-first) and each requester's `graph` doc, then
queues the W3-28a accept (`classifyAccept` + `queueAccept`) per request and `followersCount += n` once. Accepted requests drop out of
the query, so a redelivery resumes where the crash left off; the counter increment shares the transaction with the edges it counts, so
it is never doubled or lost. `FollowRequestAccepted` notifications go out after each page commits.

Cost: per page 1 read (users) + 2 per request (the request, the requester graph) + the cache-first Directory lookup; per accepted
request 3 writes + 1 delete, + 1 write per page. 500 pending: about 1,005 reads, 1,505 writes, 500 deletes. A redelivery after
completion: 2 reads, 0 writes.

Log line, one per page (`msg=privacy_public`): `page`, `scanned`, `accepted`, `skipped_inactive`, `skipped_cap`, `drift`, `outcome`
(`page` = more follow, `done`, `stuck`, `stopped:protected`, `stopped:target_gone`, `stopped:target_inactive`, `error`); the delivery line
(`account_job=privacy_public`) carries `fs_reads`/`fs_writes`/`fs_deletes` and the final outcome.

Failure modes:
- **The owner protects again while the job runs.** The next page's transaction reads `isPrivate` and stops (`stopped:protected`);
  what was accepted stays accepted (those people followed while the account was public), the rest stay pending. A protect that lands
  inside a page conflicts with that transaction and wins on the retry. Nothing to do.
- **Stuck or partial** (the message was lost, the enqueue failed, or the job nacked until the DLQ): the account is public and some
  requests are still pending. Republish by hand (any publisher of the `jobs` topic): `{"kind":"privacy_public","uid":"<uid>"}`. The job is
  idempotent; a Follow of that account meanwhile already creates an edge and removes its own leftover request (ADR-0025 AQ4).
- **`ErrPrivacyPublicMore`** (error `more pending requests than one delivery handles`): more than 5,000 pending in one delivery, and the
  delivery accepted or dropped at least one. The delivery nacks and the redelivery continues. Seen only for an account with thousands of
  pending requests.
- **`outcome=stuck`** (WARN `privacy_public`; `pages`, `scanned`, `skipped_cap`, `skipped_inactive`, counts only; W3-40b O-1): every page of
  the delivery (50) was skipped, so nothing was accepted or dropped and a redelivery would only repeat the scan. The message is acked,
  not nacked, so it never loops to the DLQ. The requests stay pending. To clear them: the owner declines them (`RespondToFollowRequest`,
  or ListFollowRequests then decline), or the requesters unfollow someone (below 5,000 following) and the job is republished by hand
  (see Stuck or partial). Seen only past 5,000 requesters at the following cap.
- **A requester at the 5,000 following cap** is `skipped_cap`: its request is left in place (D7), so every rerun counts it again. A
  requester that is not ACTIVE or has no `graph` doc is `skipped_inactive`: the request is dropped without an edge.
- **Large accepts and notifications.** The accept notifications are emitted with the accepting account as actor, so they pass
  through the per-actor daily recipient cap (`NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY` 200, 50 for a new account
  within its first day). Past the cap the edges are all created but the surplus requesters get no `follow_accepted` row or push; the
  fan-out logs `notification_fanout_capped`. That is the abuse cap working, not a job failure.
- A crash between a page's commit and its emits loses that page's notifications (the edges are safe).

## 7. The pin on a protected profile and the GetMe badge (W3-26b)

`GetProfile` of a protected account returns the whole header to everyone and omits `pinned_post_id` for a viewer who is neither the
account nor a follower (ADR-0025 D4). Order, so the common cases cost nothing: the owner skips the check; a follower is decided from
the viewer's cached graph snapshot (`identity.BlockChecker.IsFollowing`, 0 extra reads, the block check just loaded it) and never needs
the set; anyone else asks the protected set. The stored profile keeps the pin, so unprotecting or following brings it back with no write.
Reads: +0 over before Part B (3 cold for a viewer, 1 for the owner). It is never gated by `FEATURE_PRIVATE_ACCOUNTS`.

`GetMe.pending_follow_request_count` is read only for a caller whose `isPrivate` is true: `FollowRequestCounter.PendingFollowRequests`
(graph, one `count()` on `followRequests`, 1 read per 1,000 matches, capped at 1,000), cached 30 s per uid in identity. A public caller
reads and reports nothing. On this instance the cached count is evicted together with the unread count (`Directory.Forget` and `ForgetUnread`, called
by any notification row written, a post or follow counter change, an accepted request), so a protected caller pays the +1 `count()` again after
any of those; a decline, a withdraw by the requester and other instances show the change within 30 s. A request-count failure leaves the badge at 0 and is retried by the next GetMe.

| Log line | Meaning | What to do |
|---|---|---|
| request field `pin_omitted=protected` | The pin was hidden from an unapproved viewer. Normal; no uid is logged. | Nothing. |
| WARN `pin_omitted` with `pin_omitted=set_unavailable` | The set could not be loaded (see section 2) and the viewer is neither the account nor a follower: the header is served without the pin (fail closed). | Fix the set first (section 2). Owners and followers are unaffected. |
| WARN `pin_omitted` with `pin_omitted=follow_check_failed` | The viewer's graph snapshot could not be read; the pin was omitted. The block check ran just before and would normally have failed first. | Look for the Firestore error on the same trace. |
| WARN `pending_count_failed` | The `count()` failed; the badge shows 0 for that call. GetMe still succeeds. | Firestore status or quota (`docs/runbooks/cost-spike.md`). |
| request field `follow_requests_count_cache_hit` | `true` when the 30 s count was served from the instance cache (0 reads). | Nothing. |

## 8. Rollback and traffic splits (W3-36 M-1)
A revision older than the Part B enforcement floor (`main` 061395a0, #395) shows protected posts to everyone, because
stored posts stay `PUBLIC`. While `privacy/protectedAuthors.uids` is non-empty, never route traffic to such a revision. The
check, the floor and the prod rule are in `docs/runbooks/rollback.md`, "Private accounts: never roll back past
enforcement". W3-38 records the revision names of 100% of dev traffic and of `last-good` before the allowlist apply.
