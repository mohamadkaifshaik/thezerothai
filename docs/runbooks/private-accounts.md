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

An unprotect hands `PrivacyListener.BecamePublic` the uid after the commit (detached, 2 s deadline). Until W3-28b wires a listener it
publishes nothing. If it fails, ERROR `privacy_public_enqueue_failed` (Error Reporting): the toggle succeeded, the account is public,
and its pending follow requests stay pending until the `privacy_public` job is republished (W3-28b runbook section). A follow of
that account meanwhile becomes an edge (ADR-0025 AQ4).

## 2. The stale set and UNAVAILABLE

The loader reads the set doc lazily: only when a request needs it and its copy is older than 60 s, one read per instance, shared by
concurrent requests, on a detached counter (log field `protected_set_reads`, never in a caller's `fs_reads`). The instance that
committed a toggle applies it at once; the others within 60 s.

| Log line | Meaning | What to do |
|---|---|---|
| WARN `protected_set_stale` (`age_s`) | The refresh is failing; the last good copy is served, at most 10 minutes old (`PROTECTED_SET_MAX_STALE`). A user who just went public or protected may be seen with the old state for that long. | Find the Firestore error behind it (Firestore status, quota exhausted: `docs/runbooks/cost-spike.md`). It ends by itself when reads work again. |
| ERROR `protected_set_unavailable` | The copy is older than 10 minutes, or the instance never loaded one. Every path that needs the set answers UNAVAILABLE (retryable); the profile header is still served and omits the pin (`pin_omitted=set_unavailable`); post-bearing notifications are redelivered by Pub/Sub. An unknown set is never read as "everyone is public". | Same as above. If the daily read quota is exhausted, restoring service needs the quota, not a code change. Do not "fix" it by emptying the set doc. |

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

## 6. The pin on a protected profile and the GetMe badge (W3-26b)

`GetProfile` of a protected account returns the whole header to everyone and omits `pinned_post_id` for a viewer who is neither the
account nor a follower (ADR-0025 D4). Order, so the common cases cost nothing: the owner skips the check; a follower is decided from
the viewer's cached graph snapshot (`identity.BlockChecker.IsFollowing`, 0 extra reads, the block check just loaded it) and never needs
the set; anyone else asks the protected set. The stored profile keeps the pin, so unprotecting or following brings it back with no write.
Reads: +0 over before Part B (3 cold for a viewer, 1 for the owner). It is never gated by `FEATURE_PRIVATE_ACCOUNTS`.

`GetMe.pending_follow_request_count` is read only for a caller whose `isPrivate` is true: `FollowRequestCounter.PendingFollowRequests`
(graph, one `count()` on `followRequests`, 1 read per 1,000 matches, capped at 1,000), cached 30 s per uid in identity. A public caller
reads and reports nothing. On this instance the cached count is dropped at once when a `follow_request` notification is delivered or
the account accepts a request (`Directory.Forget` / `ForgetUnread`); a decline, a withdraw by the requester and other instances show the
change within 30 s. A request-count failure leaves the badge at 0 and is retried by the next GetMe.

| Log line | Meaning | What to do |
|---|---|---|
| request field `pin_omitted=protected` | The pin was hidden from an unapproved viewer. Normal; no uid is logged. | Nothing. |
| WARN `pin_omitted` with `pin_omitted=set_unavailable` | The set could not be loaded (see section 2) and the viewer is neither the account nor a follower: the header is served without the pin (fail closed). | Fix the set first (section 2). Owners and followers are unaffected. |
| WARN `pin_omitted` with `pin_omitted=follow_check_failed` | The viewer's graph snapshot could not be read; the pin was omitted. The block check ran just before and would normally have failed first. | Look for the Firestore error on the same trace. |
| WARN `pending_count_failed` | The `count()` failed; the badge shows 0 for that call. GetMe still succeeds. | Firestore status or quota (`docs/runbooks/cost-spike.md`). |
| request field `follow_requests_count_cache_hit` | `true` when the 30 s count was served from the instance cache (0 reads). | Nothing. |
