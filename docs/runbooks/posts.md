# Runbook: posts failure modes (CreatePost, DeletePost, GetPost, purge, timelines)

Owner module: `backend/internal/posts` (ADR-0010). Data: `posts/{postId}`, `idempotency/{hash}` (24 h TTL),
`quotas/{uid}.posts`, `users/{uid}.postsCount`. Everything is behind `FEATURE_POSTS` (off | allowlist | percent | on).
Queries are for **Logs Explorer** (`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`). The
kill switch is `FEATURE_POSTS=off` (pinned-traffic procedure in `docs/runbooks/cost-spike.md`); `DEGRADED_MODE=readonly`
rejects CreatePost and DeletePost but keeps reads.

Content disclosure (ADR-0021 D3): `FEATURE_CONTENT_DISCLOSURE[_ALLOWLIST|_PERCENT]` / `feature_content_disclosure*`, wire name
`content_disclosure`, default off. It gates only SETTING `paid_partnership` / `made_with_ai` on CreatePost (either true while off is
`FEATURE_DISABLED` `feature=content_disclosure`); existing labels keep rendering. Rollback: set the flag to `off` and deploy, never
roll a revision back. A stronger reason: a pre-C2 revision serving traffic (a rollback or an old canary) builds quotes and
reposts of labelled posts with its own `snapshotOf`, which has no label fields, so those embeds lose the labels permanently with
no backfill; reads on such a revision hide the labels but do not break. It leaves `off` only after 100% of traffic is on a revision that stores the labels (ADR-0021 L-1), otherwise an
old revision silently drops the unknown request fields. No new failure mode.

Reply audience (ADR-0021 D2): `FEATURE_REPLY_AUDIENCE[_ALLOWLIST|_PERCENT]` / `feature_reply_audience*`, wire name `reply_audience`,
default off. It gates only SETTING `reply_policy` on CreatePost (any value other than UNSPECIFIED while off is `FEATURE_DISABLED`
`feature=reply_audience`, 0 reads); FOLLOWING_OF_FOLLOWING, VERIFIED, unknown values and any value on a reply are `VALIDATION`
field `reply_policy`. **Enforcement and the `viewer_reply_permission` hint are never flag-gated**: a refused reply is
`PERMISSION_DENIED` + `REPLY_NOT_ALLOWED` with `metadata["policy"]` = `following` | `mentioned_only` (lower snake case), and an
unusable conversation root (missing, hidden, non-public, author not ACTIVE, a block in either direction, caller blockedBy overflow)
is the usual `NOT_FOUND "post not found"` before the policy runs (review M-1). Kill switch: set the flag to `off` and deploy; that
stops new policies and leaves every stored one enforced. **Never roll a revision back once the flag has left `off`:** enforcement keys
off the parent's stored `replyPolicy`, and a pre-B2 revision neither enforces it nor copies it, so its replies carry no policy
and re-open every sub-thread under them (permanently, no backfill). The flag leaves `off`, even for the allowlist, only after 100% of
traffic is on a revision that stores and enforces it (ADR-0021 L-1; during a 10/90 split GetMe on the new revision can list the feature
while the CreatePost lands on an old one, which drops the unknown field and posts to everyone without an error). Symptoms and checks:
a spike of `outcome=rejected:reply_not_allowed` is users hitting restricted conversations (expected), not an outage; reads of a
restricted reply are +0 warm and at most +3 (MENTIONED_ONLY) / +4 (FOLLOWING) cold. No new failure mode.

Profile extras and tabs (ADR-0024 D9, W3-4 registration): `FEATURE_PROFILE_EXTRAS[_ALLOWLIST|_PERCENT]` / `feature_profile_extras*` (wire name
`profile_extras`) will gate the `UpdateProfile` banner, location, website and pin fields and `CreateUpload(BANNER)` (which also needs `media`);
`FEATURE_PROFILE_TABS[_ALLOWLIST|_PERCENT]` / `feature_profile_tabs*` (`profile_tabs`) will gate `GetUserTimeline` tab MEDIA and REPOSTS (Posts
and Replies stay ungated). Both default off in every environment (dev ceiling: allowlist, at most 3 uids; no prod raise) and
`GetMe.enabled_features` lists them only when on for the caller. W3-4 registered them and the config; the `CreateUpload(BANNER)` gate is live since W3-5
(`docs/runbooks/media.md`), and the other gates arrive with W3-6 and W3-9, until then the new `UpdateProfile` fields and the tab are ignored without an error. Once gated, a field sent while off is `FEATURE_DISABLED`
`feature=profile_extras` (0 writes); data set while a flag was on keeps rendering after a ramp-down (the pin is hidden while `profile_extras`
is globally off). Kill switch: set the flag to `off` and deploy. No new failure mode yet.

Scheduled posts (ADR-0021 D4, foundation): `FEATURE_SCHEDULED_POSTS[_ALLOWLIST|_PERCENT]` / `feature_scheduled_posts*`, wire name
`scheduled_posts`, default off in every environment (dev ceiling: allowlist, at most 3 uids). `GetMe.enabled_features` lists it only
when on for the caller. The RPCs (CMP-D3) and the publish sweep (CMP-D4, section 12) are what the flag gates. Storage and plumbing that run whatever the flag says: the `quotas.schedules` daily counter (`QUOTA_SCHEDULES_PER_DAY` 50,
`QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY` 10) and the `SCHEDULED_*` limits (parsed and validated at startup; a typo fails the boot, so
check the Cloud Run revision came up), the `scheduled` account-deletion step and export section for `users/{uid}/scheduled/*`
(deleting `users/{uid}` does not remove a subcollection), and the rate-limit mapping (SchedulePost and CancelScheduledPost share the
CreatePost 10/min bucket; ListScheduledPosts uses the default read bucket). Rules to keep when the service lands: the flag leaves `off`
only after 100% of traffic is on a revision that stores scheduled posts (ADR-0021 L-1), and never roll a revision back past the first
one that knows `quotas.schedules`: an older revision `Set`s the whole quotas record and zeroes the counter on that user's next quota'd
call (review I-3; bounded by one extra day's quota, still under the pending and window caps). Deletion check: an account-deletion job
now runs a `scheduled` step after `reports`; a user with nothing scheduled costs 1 read and 0 deletes, and the export gains a
`scheduled` section (1 read when empty). The failure modes of the publish sweep are section 12.

SchedulePost caps and reads (pending.md 2.16). Exact: the per-account window cap (`SCHEDULED_PER_AUTHOR_PER_RUN` PENDING items, default 3,
within +/-4 min of `publish_at`; `LIMIT_REACHED` `limit=scheduled_window`) and the daily quota (`QUOTA_SCHEDULES_PER_DAY`). Both are decided
inside the schedule transaction, after it reads `quotas/{uid}`, which every schedule by one account reads and writes, so of two racing calls
only one commits. Dev and prod run Firestore in `OPTIMISTIC` mode (`infra/terraform/modules/firestore/main.tf`): the loser is rejected ABORTED
at commit, the transaction retries, and the retry recounts the window and sees the winner's committed document; the window check runs again
on every attempt, and must stay after the quotas read. Soft, on purpose: the pending cap (`SCHEDULED_MAX_PENDING`, 25;
`limit=scheduled_pending`). Its `count()` runs outside the transaction because reading up to 26 documents inside it would blow the read
budget, so concurrent calls can overshoot it by the number in flight, bounded by the exact daily quota (50, 10 for new accounts) and the
CreatePost-shared rate bucket (burst 10 per instance).

What is proven and what is not. PROVEN, on the emulator only (its transactions are lock-based, not optimistic): ten simultaneous calls of one
account for one minute never leave more than the cap stored, and never reject while fewer than the cap are stored
(`TestSchedulerIT_ConcurrentWindowCap`, repeated runs, with and without an existing `quotas` document), and each attempt of a retried
transaction counts afresh (`TestScheduled_Integration_WindowCapIsEvaluatedPerAttempt`). REASONED: optimistic mode plus an existing
`quotas/{uid}` document makes the cap exact, by the commit conflict on that document. VERIFIED on the real dev Firestore (`OPTIMISTIC`, the
same mode and module as prod, 2026-10-26, result in pending 2.16): the same ten-call race, with a brand-new account (no `quotas/{uid}`
document yet, where exactness needs Firestore to treat a not-found read as a conflict when another transaction creates the document) and with
an existing one, left exactly the cap stored every time, `quotas.schedules` matched, and the transactional aggregation `count()` (the first
one in the codebase; the others run outside transactions) works. NOT covered by that run: the deployed HTTP path with auth (it called the
service and repository directly), and prod itself.

Reads, service's own (add the interceptor's profile read when cold): typical 4 (doc, pending count, quotas, window count), worst 8 with four
images, replay 1, at the pending cap 2, at the window cap 5 (the extra read is the key's own document, see below), at the daily cap 4; a
conflicted transaction attempt is retried and re-reads quotas, the window count and the media. Writes 2, or 0 for a replay and every cap.
A rejection at the window cap now opens a transaction and costs 5 service reads (6 with the interceptor), where the old outside count cost 3
(4). Ceilings for one account hammering a full window: the CreatePost-shared 10/min per-instance bucket alone would allow about 14,400
calls a day, about 72k reads a day on one instance (was 43.2k) against the 50k/day free quota; the ADR-0010 D5 per-uid read budget
(`READ_BUDGET_PER_UID_PER_DAY`, 2,000, per instance lifetime; it covers SchedulePost and charges errored calls too) stops one account near
2.4k reads per instance lifetime, so the 72k figure needs deliberate instance cycling (D5 residual R2, accepted). Trigger for an in-instance
negative cache of full windows: `limit=scheduled_window` volume in the logs (`jsonPayload.posts_op="schedule"` and
`jsonPayload.limit="scheduled_window"`), a sustained rate from one or a few `uid_hash` values; not before.

Duplicates. A full window that holds the same key's own document is a concurrent duplicate (the first call committed it) and is answered as a
replay, not as `scheduled_window`; that is the extra read. A concurrent duplicate that loses at the DAILY cap still gets `QUOTA_EXCEEDED`, not
a replay (ADR-0021 known limit; the same holds at the pending cap): only the window path answers a replay, and a client retrying with the same
`idempotency_key` after any cap error gets the stored item.

A burst of many SchedulePost calls from ONE account contends on its `quotas` document: the losers retry (5 attempts, 5 s deadline) and a few
may end ABORTED or DEADLINE_EXCEEDED, which clients see as INTERNAL (a commit that timed out on our side can still have landed). That is the
account's own burst, not an outage; retrying with the same `idempotency_key` is safe, it returns the stored item or schedules once. Many
accounts doing it at once is the signal for `docs/runbooks/abuse-spike.md`.

Replay after losing permission (accepted behaviour, CMP-B2 review): enforcement runs before the idempotency lookup, so retrying
a CreatePost whose reply already exists, after the caller lost the right to reply (blocked by the root author, root hidden or deleted,
author suspended, or no longer a follower under FOLLOWING), answers `REPLY_NOT_ALLOWED` or `NOT_FOUND` instead of
returning the stored reply. It fails closed and never grants access. The reply itself still exists, so a client may show "you
cannot reply" for a reply that was posted; reloading the thread shows it. Pinned by `TestCreate_ReplyReplayAfterPermissionLost`.

## 1. `posts_txn_contention` (WARN)
**What it is.** A CreatePost transaction needed more than 3 attempts (`txn_attempts` on the request line). The hot
documents are the author's `users/{uid}` (postsCount) and `quotas/{uid}`, so it means one account is posting from
several devices at once, or a script is. Each attempt re-reads 2 docs, so contention costs reads, never duplicate posts.

**Find it:** `jsonPayload.message="posts_txn_contention"`; request lines with `jsonPayload.posts_op="create"` and
`jsonPayload.txn_attempts>3`.

**Do:** check whether it is one `uid_hash` (abuse: `docs/runbooks/abuse-spike.md`) or many (a Firestore incident; check
the status page). Sustained contention for ordinary users is a scale signal for the sharded-counter ADR (CLAUDE.md rule 3).

## 2. Startup fails with `TIMELINE_SETTLE_WINDOW ... must be at least 15s`
The since-watermark settle window must cover 3 x the 5 s CreatePost transaction deadline (ADR-0010 D13); a shorter value
could let a timeline refresh skip a post that is still committing. Remove the variable or set it to 15s or more, redeploy.

## 3. Users report "daily limit reached" when posting
`QUOTA_EXCEEDED` with `quota=posts` (`outcome=rejected:quota_exceeded`): 100 posts per IST day, 20 for an account younger
than `QUOTA_NEW_ACCOUNT_WINDOW` (24 h). Limits are env vars (`QUOTA_POSTS_PER_DAY`, `QUOTA_NEW_ACCOUNT_POSTS_PER_DAY`).
A spike across many accounts is spam: `docs/runbooks/abuse-spike.md`.

## 4. A retried CreatePost says "the post created by this request no longer exists"
The idempotency doc (24 h) outlived a post the author deleted in between. Harmless: the client should post again with a
new idempotency key.

## 5. Stale mention after a handle rename
A mention can point at the wrong user only if a handle was renamed and re-claimed within 10 s and the post was created on
another instance (ADR-0010 D21 G5, accepted residual). Fix by hand: correct `posts/{id}.mentions[]` and note it; if it
recurs, a handle-reclaim cooldown needs an identity ADR.

## 6. DeletePost succeeds but the post is still visible
Another instance may serve the post from its 60 s instance cache after the delete (ADR-0010 D15). It is NOT_FOUND on every
instance within 60 s, and clients drop unknown ids on refresh. Treat 60 s as the user-facing SLA for "deleted posts disappear everywhere". A post that is still there after 2 minutes means the delete
did not commit: look for `posts_op="delete"` request lines with `outcome="noop:not_owner"` (the caller was not the author;
a spike of those is probing, see `docs/runbooks/abuse-spike.md`) or an ERROR with `posts: delete post` (Firestore).
`outcome="noop"` is an unknown or already-deleted id and is normal on retries.
A delete that loses the `users.postsCount` lock race is retried by the server: at most 4 attempts with full-jitter exponential
backoff starting at 25 ms (`maxDeleteAttempts`, `deleteRetryBackoff` in `repo_delete.go`), then an INTERNAL error that the client may retry.

## 7. `users.postsCount` looks wrong
Create and delete each adjust it in the same atomic write as the post doc, so it should equal the user's post count. After
an account purge (`opsctl purge-posts`) it is not updated on purpose: the `users` doc is deleted next. Drift on a live
account is a bug: count with `opsctl purge-posts --dry-run` (read-only, `dry-run: posts=N`) and fix the field by hand.

## 8. Account purge and export
`opsctl purge-posts` and `opsctl export-posts` are steps of `docs/runbooks/account-deletion.md`. A purge that stops with
"giving up after 5 consecutive errors" is resumable: re-run it. Log line `posts_purge_batch` carries `uid_hash`, `posts` and
`deleted_total` for each 500-post batch. Cost is about 1 read and 1 delete per post, once per deletion.

## Timelines (GetHomeTimeline, GetUserTimeline)

Owner module: `backend/internal/timeline` (ADR-0004, ADR-0010 D13-D16). It stores nothing; request lines carry
`timeline_op`, `timeline_mode` (`cold|refresh|older|gap`), `timeline_chunks`, `authors_from_cache`,
`timeline_cache_hit`, `items_returned`, `items_filtered`, `gap`, `since_clamped`, `page_size` and `fs_reads`.

## 9. Home timeline reads are high (`fs_reads` per `timeline_op=home`)
Expected ceiling is `2 + C + 2*page` (269 at 5,000 followed, page 50). Find outliers with
`jsonPayload.timeline_op="home" AND jsonPayload.fs_reads>100`; `timeline_chunks` is C of that caller. Many power users
(> 5% of DAU above 1,000 followed) is the ADR-0004 revisit trigger. A sudden rise for everyone with `authors_from_cache`
near 0 means the author-recent cache stopped filling (instance churn or `CACHE_AUTHOR_RECENT_ENTRIES` too small).

## 10. Clients report `VALIDATION field=since_token` / `page_token`
The token is expired (30 days, `TIMELINE_TOKEN_TTL`), tampered, from another account, another feed or tab, or a
`CURSOR_HMAC_KEY` rotation invalidated it. This is the designed answer, with 0 reads: the client drops the token and
cold-opens. A burst right after a key rotation is expected; a burst without one points at a client bug (sending both
tokens is also `page_token`).

## 11. A post appears twice, or a just-created post shows up late
`since_token` trails the newest item by `TIMELINE_SETTLE_WINDOW` (15 s, D13), so a refresh may re-return recent posts
(`since_clamped=true`); clients dedupe by `post_id`. A post can lag up to 60 s when another instance's author-recent
entry still serves the author. Neither needs action.

## 12. Scheduled posts sweep (`POST /internal/cron/publish-scheduled`)

Owner: `backend/internal/posts` (ADR-0021 D1 and "Sweep", CMP-D4). Cloud Scheduler job `publish-scheduled` (`*/5 * * * *`, prod only,
OIDC, `retry_count = 3`, created by CMP-D5) calls the route; it publishes every PENDING `users/{uid}/scheduled/{id}` whose `publishAt`
has passed. Until the job is applied nothing calls the route. The flag leaves `off` only after 100% of traffic is on a revision that has
this sweep (a tick that lands on an older revision gets a silent 202 from the placeholder handler). Logs Explorer queries:

- `jsonPayload.message="scheduled_sweep"`: one line per run. `due`, `published`, `cancelled`, `expired`, `transient`, `deferred`
  (held back by the 3-per-author cap, retried next run), `held_media` (items with images left alone because `FEATURE_MEDIA` is globally off,
  see "Images held while `FEATURE_MEDIA` is off"; they are in `due`, not in `deferred`), `noop` (the item changed under us, quiet), `write_failed`, `skipped_bad_path`,
  `undecodable`, `max_lateness_ms`, `failed_total`, `failed.<reason>` (`media_unavailable`, `quota_exceeded`, `account_restricted`,
  `invalid_content`, `internal`, `unsupported`, `expired`; `expired` is also the top-level `expired` count), `fs_reads`, `fs_writes`,
  `fs_deletes`, `latency_ms`, `outcome` (`ok`, `flag_off`, `degraded`, `error`).
- `jsonPayload.message="scheduled_item_start"`: INFO, one per item, written before its transaction, with `uid_hash` and `scheduled_id`.
- `jsonPayload.message="scheduled_author_reads"` (WARN, `uid_hash` only) and, naming the item with `uid_hash` and `scheduled_id`:
  `"scheduled_item_transient"` (WARN, a retryable error: the item's `attempts` is bumped by one, unless that bump fails, see the next line,
  or loses its precondition because the item changed under us, which is counted in `noop`); `"scheduled_item_bookkeeping_failed"` (WARN, a
  write that records an item's outcome, a terminal transition or the `attempts` bump, returned an error: counted in `write_failed`, the item
  keeps its state and is re-read next run); `"scheduled_item_second_panic"` (WARN, a panic while another panic was being handled; the type only).
- Error Reporting (`rpc` = `cron/publish-scheduled`): a due page that failed, an item retired as FAILED `INTERNAL`, or a recovered panic
  (type only). Item-level entries carry `uid_hash` and `scheduled_id`.
- A failed run (a due page failed) still writes its `scheduled_sweep` line, at WARN with `outcome=error` and the counts of what was
  processed, and a SEPARATE Error Reporting entry (ERROR, `rpc=cron/publish-scheduled`) that carries only the scrubbed error.

Cost: nothing due is 1 read; each due doc costs 1 read, plus 17 worst / 3 typical reads and 4 writes (+1 per attached image) when it
publishes, or 0 reads and 1 write when it is expired, unsupported, invalid or transiently failing, or nothing beyond its 1 query read and 0 writes
while it is held for images (`held_media`). At most 100 due docs per run
(`SCHEDULED_SWEEP_LIMIT` 50 x `SCHEDULED_SWEEP_MAX_PAGES` 2). The empty ticks cost about 288 reads a day.

### Symptoms and what to do

| Symptom | Meaning | Do |
|---|---|---|
| `outcome=error` on the `scheduled_sweep` line, Error Reporting `cron/publish-scheduled`, and a 500 on the route only when page 1 failed | A due query page failed (a Firestore incident, or the `scheduled` collection-group index on `status, publishAt` is not deployed: `FAILED_PRECONDITION`). **Page 1 failed:** nothing was processed, the route answers 500 and Scheduler retries (3 times, then the next tick); a retry is harmless. **A later page failed:** the earlier pages were processed and the route answers 204 on purpose (a retry seconds later would burn the 3-attempt ladder of any item that failed transiently); the items on the failed page are due again next tick | Check the Firestore status page. If the index is missing, deploy `firebase/firestore.indexes.json` (a gate file, founder review). Nothing is lost: unprocessed items stay PENDING |
| `max_lateness_ms` > 600000 (10 min) | Runs are late or a backlog exists. Held items count: `max_lateness_ms` is the age of the oldest due item, held or not | Check `held_media` first (see "Images held while `FEATURE_MEDIA` is off"), then look for failed runs and for `deferred` > 0 and see "Draining a backlog". Past `SCHEDULED_MAX_LATENESS` (6 h) items become FAILED `EXPIRED` |
| `held_media` > 0 on the `scheduled_sweep` line, and users see scheduled posts with images still PENDING after their time | `FEATURE_MEDIA` is `off` for everyone (the kill switch, for example during an image-abuse incident). CreatePost refuses `media_ids` in that state, so the sweep does not attach images either; it leaves those items PENDING with no write. Text-only items still publish | Expected while the switch is off, as long as `due` is well below the window (50 per page fetched, 100 at the defaults): no action. They publish once the flag is back (3 per author per run, so 25 items take 9 runs), or become FAILED `EXPIRED` once `SCHEDULED_MAX_LATENESS` (6 h) overdue. If the incident will outlast that and late posts are preferred to lost ones, see "Images held while `FEATURE_MEDIA` is off" (raising the bound has a cost). When `due` reaches the window, use the next row |
| `held_media` equal or close to `due`, with `due` at the size of the window (50 per page fetched: 100 at the defaults) and `published` 0 | **The held items fill the whole due window.** The query is ordered by `publishAt` and held items are never written, so they stay at its head: the run cannot read anyone newer. Other users' due items, text-only ones included, are NOT being read and may end FAILED `EXPIRED` (read more than 6 h overdue; see "Known limit" below). 100 held items is 4 accounts with 25 scheduled images each, or 10 new accounts with 10 | Turn `FEATURE_MEDIA` back on if the incident allows; the held items then drain and the window clears. Otherwise raise `SCHEDULED_SWEEP_MAX_PAGES` (up to 10) and deploy, so the window reaches past the held items; each page is up to 50 more reads in every run (see "Cost of holding" for the day total). **Do not raise `SCHEDULED_MAX_LATENESS` as a fix**: it keeps the held items at the head of the window for longer and lengthens the stall |
| A spike in one `failed.<reason>` | `quota_exceeded`: authors at the 100 (new accounts 20) posts-per-day cap, expected, see section 3. `media_unavailable`: images removed or never READY. `account_restricted`: authors suspended. `internal`: 3 transient failures or a panic, check Error Reporting. `unsupported`: a draft written by a newer revision than the one sweeping, for example after a rollback. `invalid_content`: a draft that no longer parses or whose reply policy or media is invalid | Failures are terminal and the user sees FAILED in ListScheduledPosts. No action unless `internal` or `unsupported` spikes |
| `skipped_bad_path` > 0 | A document that is not exactly `users/{uid}/scheduled/{32 hex}` matched the due query. It is skipped and never published | Find it in the console (collection group `scheduled`, `status == PENDING`) and delete it by hand. Rules deny clients, so find out who wrote it |
| `undecodable` > 0 | A due doc could not be decoded | Same as above; it is counted and skipped, never retried in a loop |
| `scheduled_author_reads` WARN | One author's items spent more than `SCHEDULED_AUTHOR_READS_WARN` (40) reads in a run (for example 3 items with 10 handle mentions each). These reads sit outside the per-user read budget by design | The same `uid_hash` repeatedly is abuse (`docs/runbooks/abuse-spike.md`). A single occurrence is noise |
| `scheduled_item_bookkeeping_failed` WARN, `write_failed` > 0 | A write that records an item's outcome failed (a Firestore error or a timeout on the 3 s bookkeeping budget). The item keeps its state, so it is retried next run; a post that was already committed is not affected | A burst is a Firestore incident. The same item every run: look at the `error` field (scrubbed) and at the document |
| An instance crashes in bursts of up to 4 every 5 minutes (Cloud Run restarts, "fatal error", OOM kill) and those runs write no `scheduled_sweep` line | A fatal runtime error (concurrent map write, stack exhaustion) or an OOM in the publish path. These cannot be recovered, and `attempts` never moves | See "Isolating a crash-looping item" |
| Items stay PENDING past their time | The job is paused or failing, the flag is `off`, `DEGRADED_MODE=readonly`, `FEATURE_MEDIA` is `off` and the items carry images (`held_media`), or the 3-per-author cap is stretching a backlog (25 items need 9 runs) | `gcloud scheduler jobs describe publish-scheduled --location asia-south1`, then read `outcome` in the `scheduled_sweep` lines |

### Manual run

- **Prod.** `gcloud scheduler jobs run publish-scheduled --location asia-south1 --project dzeroth-prod`. It makes the same OIDC call as the
  tick. Do not call the prod route with an ID token minted for a person or a broader service account.
- **Dev.** `gcloud scheduler jobs run` cannot run a job that does not exist and dev has `jobs = {}`, so call the route directly with an OIDC
  token for the dev pubsub-push service account (ADR-0021 D1; the principal needs `roles/iam.serviceAccountOpenIdTokenCreator` on that SA,
  a 30-day conditional grant that is never applied in prod; it exists only while `cron_test_invoker` is set in the dev `terraform.tfvars`, and
  a TARGETED apply creates or removes it, see pending 3.10). Mint the token through IAM Credentials `generateIdToken` with your own access
  token: gcloud's `print-identity-token --impersonate-service-account` does not work with this role, because it asks for `getAccessToken`.
  The `audience` must be the service's `INTERNAL_OIDC_AUDIENCE` (the deterministic `https://api-<project-number>.<region>.run.app` URL), not
  the `*.a.run.app` URL: a token for that one is a 401. Send an empty body with `--data ''`, or curl sends none and the route answers 411.
  `AUD=$(gcloud run services describe api --region asia-south1 --project dzeroth-dev --format=json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="INTERNAL_OIDC_AUDIENCE").value')`
  `TOKEN=$(curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d "{\"audience\":\"$AUD\",\"includeEmail\":true}" https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<dev pubsub-push SA>:generateIdToken | jq -r .token)`
  `curl -X POST -H "Authorization: Bearer $TOKEN" --data '' "$AUD/internal/cron/publish-scheduled"`
  Never "fix" a failing impersonation by granting `roles/iam.serviceAccountTokenCreator` instead: that role also mints access tokens and signs
  blobs as the service account, which is far more than a manual cron test needs (ADR-0021 security review L-5).
  The route answers 204 whatever happened to the items, so read the `scheduled_sweep` line for the result. A GET is a 405.

### Pause, kill switch

- **Pause the job** (stops all publishing; the sweep does not run at all): `gcloud scheduler jobs pause publish-scheduled --location
  asia-south1 --project dzeroth-prod`, and `jobs resume` to undo it. A paused job still counts toward the 3 free jobs. Pending items keep
  waiting and EXPIRE once they are `SCHEDULED_MAX_LATENESS` (6 h) overdue, so for a pause longer than that do the lateness step below before
  resuming. `daily-maintenance` (the account-deletion backstop) is never paused with it (ADR-0022,
  `docs/runbooks/credit-sunset-pause-resume.md`).
- **Kill switch** (the job keeps ticking at no cost): `FEATURE_SCHEDULED_POSTS=off` (or `FEATURE_POSTS=off`) and deploy. The route answers
  204 with `outcome=flag_off` and 0 reads, SchedulePost answers `FEATURE_DISABLED`, nothing is published, and pending items wait and expire as
  above. Only `off` stops the sweep: `allowlist` and `percent` modes still publish what was already scheduled, so a user outside the
  cohort keeps their items. `DEGRADED_MODE=readonly` gives `outcome=degraded`, also 0 reads.
- Do not roll a revision back to turn it off; see the roll-forward-only rule below.

### Images held while `FEATURE_MEDIA` is off

`FEATURE_MEDIA=off` is also a kill switch for the sweep (pending 2.15, security review of #289, Low 2). CreatePost refuses
`media_ids` while the flag is off for everyone, so the sweep does not publish already-uploaded images either. Each run asks once, with 0
reads, whether `media` is globally off. Only `off` holds: `allowlist` and `percent` are rollouts, so the sweep keeps publishing images that
were scheduled, as it does for `FEATURE_SCHEDULED_POSTS`. `DEGRADED_MODE=nomedia` holds nothing either: it blocks uploads only, for CreatePost
and the sweep alike.

- **What is held.** An item whose draft has images, and that nothing before the publish transaction would retire. It stays PENDING with its
  draft, `attempts` and `updatedAt` untouched: no write, no publish transaction, no media read. The author sees it still PENDING in
  `ListScheduledPosts`. It is counted in `held_media` (and in `due`, never in `deferred`). It does not use one of its author's 3 slots per run,
  so the same author's text-only items still publish in the same run.
- **What is not held.** The checks that need no read keep their order and their verdicts, expiry first. An item more than
  `SCHEDULED_MAX_LATENESS` (6 h) overdue is still retired FAILED `EXPIRED` (the user re-enters it; the draft is cleared), so a hold cannot
  keep content forever; UNSUPPORTED and INVALID_CONTENT items are retired as always.
- **Verdicts that are postponed.** The verdicts that only the publish transaction can give do not happen while an item is held:
  ACCOUNT_RESTRICTED (a suspended author), CANCELLED (an author who is deleting the account, or is gone), QUOTA_EXCEEDED and
  MEDIA_UNAVAILABLE (an image that moderation rejected or removed in the meantime). If the hold outlasts `SCHEDULED_MAX_LATENESS`, such an
  item ends FAILED `EXPIRED` instead: a suspended author's post shows EXPIRED, and an item whose image was removed keeps its draft PENDING
  until it expires. Safety is unchanged: nothing publishes while an item is held, and the transaction re-checks the account, the quota and
  every image when the item is finally released. The flag itself fails nothing, but it can turn the specific reason into EXPIRED.
- **When the flag returns** the next run starts publishing the held items like any other, with no special handling and no step to run. They
  publish late, in `publishAt` order, 3 per author per run: an author with 25 held items needs 9 runs (see "Draining a backlog"), and items
  that are already close to 6 h overdue can expire during that drain.
- **If the incident will outlast 6 h** and a late post is better than a lost one, raise `SCHEDULED_MAX_LATENESS` (up to 168h) and deploy
  BEFORE the oldest held item is 6 h overdue (expiry is decided on every run and is terminal) and BEFORE turning `FEATURE_MEDIA` back on, then
  restore the default once the backlog has drained (the same lever as "Raising the lateness bound before recovering from an outage"). The
  drain above is why it must come before the flag returns: otherwise items near the bound expire halfway through it. Two costs: the held
  images stay queued longer and publish as soon as the flag returns, so decide it with whoever owns the incident, and **a longer bound
  extends the starvation described under "Known limit"**, because the held items keep their place at the head of the due window for as long
  as the bound lets them (one item is re-read 72 times at 6 h and 2,016 times at 168 h at the */5 cadence). The publish transaction still
  checks every image when it finally runs: one that was rejected or removed in the meantime fails the item as `MEDIA_UNAVAILABLE`.
- **Revisions.** The flags are read once when an instance starts, so switching `FEATURE_MEDIA` takes effect per revision. During a traffic
  split a tick that lands on a revision where media is still on publishes images, exactly as CreatePost does on that revision; that is the
  flag's state there, and it is safe.
- **Cost of holding.** Held items still match the due query, so every run re-reads each of them: 1 read per item per run, up to
  `SCHEDULED_MAX_PENDING` (25) per user. The runs per day depend on the Scheduler cadence (`publish_scheduled_schedule`, every 1 to 10
  minutes; ADR-0022 allows every minute until 2026-12-22), so the day total is scaled by it. Against the free 50,000 reads a day:

  | Held items re-read every run | */5 (288 runs a day) | every minute (1,440 runs a day) |
  |---|---|---|
  | 20 | 5,760 | 28,800 |
  | 100 (a full window at the defaults) | 28,800 | 144,000 |
  | 500 (`SCHEDULED_SWEEP_MAX_PAGES` 10, a full window) | 144,000 | 720,000 |

  Past 50,000 a day it is billed per use ($0.035 per 100,000 reads in `asia-south1`, `docs/reviews/cost-model.md` section 7), but the free
  quota is shared with everything else the project reads (about 230 reads per DAU a day, so it runs out near 215 DAU), so a full window is not free.
  `max_lateness_ms` rises with the oldest held item.
- **Known limit: held items can starve the due window.** The due query is ordered by `publishAt` and reads at most 100 items a run
  (`SCHEDULED_SWEEP_LIMIT` 50 x `SCHEDULED_SWEEP_MAX_PAGES` 2). Held items are never written, so they stay at its head until they expire,
  and they are taken out before the per-author cap, so a few authors' held items can fill the whole window: 100 held items are 4 accounts
  with 25 scheduled images, or 10 new accounts with 10. While that lasts every newer due item, text-only items of uninvolved users
  included, is never read and may end FAILED `EXPIRED`. When the held items themselves expire they are retired 3 per author per run (25 take
  9 runs, about 45 minutes), which stretches the stall by that drain. It needs `FEATURE_MEDIA` switched off by the
  operator and enough accounts that had media when they scheduled, so it is unlikely at Stage 0 volume, but it is real. The signature is
  `held_media` equal or close to `due`, `due` at the window size and `published` 0 (the line never shows more than the window, so more than
  100 held items look exactly like 100). Do what the symptom row says: media back on, or `SCHEDULED_SWEEP_MAX_PAGES` up as a stopgap, never `SCHEDULED_MAX_LATENESS`. Adaptive
  paging (reading past the held items) is tracked as a follow-up and is not built. `TestSweepMediaHold_KnownLimit_HeldItemsFillTheWindow` pins
  today's behaviour, so whoever fixes it knows which test to change.

### Draining a backlog

A run publishes at most 3 items per author and processes at most `SCHEDULED_SWEEP_LIMIT` (50) x `SCHEDULED_SWEEP_MAX_PAGES` (2) = 100 due
docs, about 1,200 items an hour (the Stage 0 worst case, about 375 items, takes about 45 minutes). To go faster while draining, raise
`SCHEDULED_SWEEP_MAX_PAGES` (up to 10; each page costs up to 50 reads, and the 25 s deadline plus the 6 s start guard still bound a run)
and deploy, then put it back. Do not raise `SCHEDULED_PER_AUTHOR_PER_RUN` (review L-3: it bounds one account's share of a run). The daily
posts quota still applies when an item publishes: an author past the cap that IST day gets FAILED `QUOTA_EXCEEDED`, not a delay.

### Raising the lateness bound before recovering from an outage

Every item overdue by more than `SCHEDULED_MAX_LATENESS` (default 6 h) is retired as FAILED `EXPIRED`, at 0 reads, the next time the sweep
runs. After an outage or pause longer than that, decide first whether users would rather have a late post than none. If so, set
`SCHEDULED_MAX_LATENESS` (up to 168h) and deploy BEFORE resuming the job or turning the flag back on, let the backlog drain, then restore the
default. An item already marked EXPIRED is terminal; the user schedules it again.

### Isolating a crash-looping item

A recovered panic never loops: the item is retired as FAILED `INTERNAL` in one run, with an Error Reporting entry that carries the panic
type only. A fatal runtime error cannot be recovered, so the same item crashes the instance (and up to 80 in-flight requests on it) on every
tick until the expiry check retires it after at most 6 h (72 ticks). A crash is a failed request, so Cloud Scheduler retries it
(`retry_count = 3`, backoff 5 s, 10 s, 20 s): one tick crashes up to 4 instances, and the bound is up to 288 crashes over the 6 h, not 72.

1. Confirm: Cloud Run instance restarts in bursts of up to 4 (the tick and its 3 retries, about 40 s) every 5 minutes, and
   `scheduled_sweep` lines missing for those runs.
2. Name the item: in Logs Explorer take `jsonPayload.message="scheduled_item_start"` just before the first crash. The last line has the
   `uid_hash` and the `scheduled_id` (the document id under `users/*/scheduled/`), and the same pair repeats every tick. To open the
   document, run a collection-group query on `scheduled` in the console with `status == PENDING` ordered by `publishAt`; the oldest entry
   is the one.
3. There is no operator cancel path today (CancelScheduledPost is user-only), and the doc must not be edited by hand without the founder's
   say-so. Options: wait for the 6 h expiry (the bound); lower `SCHEDULED_MAX_LATENESS` for one deploy (retires it sooner but also expires
   every other late item); or pause the job (stops everyone's publishing). This is a founder decision.
4. Follow-ups, not built: an `opsctl scheduled cancel` command, and "claim before publish" (`attempts++` before the work, +1 read and +1
   write per publish), which bounds even fatal crashes to 3 crashes in total. A crash loop actually observed is the ADR's trigger to build it.

### Roll-forward only

Once `FEATURE_SCHEDULED_POSTS` has left `off`, do not roll a revision back past the first one that knows scheduled posts. An older
revision `Set`s the whole `quotas/{uid}` record and zeroes `quotas.schedules` on the next quota'd call (review I-3), and a Scheduler tick
that lands on it gets a silent 202 from the placeholder handler, so nothing publishes while it serves. Fix forward with a new revision, or
use the kill switch above. Overlapping runs (a retry and the next tick, or two instances) are safe: the publish transaction re-reads the
item as PENDING, so an item publishes at most once, and the loser is counted as `noop`.

### Accepted risk: an ambiguous commit

If the publish transaction commits on the server but the client sees DEADLINE_EXCEEDED or UNAVAILABLE, the sweep treats the error as
transient and tries to bump `attempts`. Exactly-once still holds: the document is already PUBLISHED, so the bump's `LastUpdateTime`
precondition fails (counted as `noop`) and no later run sees the item as PENDING. What is skipped is everything after the commit: the
instance cache and the author's cached profile are not refreshed (the usual 60 s lag applies) and `events.Created` never runs, so the
mention notifications of that one post are lost, with no replay. If it happens on the last allowed attempt, a false `FAILED INTERNAL` Error
Reporting entry can also fire for an item that is in fact PUBLISHED (the FAILED write loses its precondition, so the document is not
changed). Before acting on such an alert, open the document: `status` PUBLISHED with a `postId` means the post is live. This is accepted:
telling the cases apart would cost an extra read after every ambiguous error, and the sweep adds none for it.

## 13. `hasMedia`, the Media / Reposts tab queries and the pin check (ADR-0024 D3-D5; W3-7, W3-8, W3-9)

Owner: `backend/internal/posts`. Every post create path (CreatePost root, reply and quote, the publish sweep, the REPOST doc) writes
`hasMedia` as an explicit boolean in the post's own write: true when the post's own stored images are non-empty, always false for a
REPOST (its original's images live in `embedded`). It is never flag-gated, so it is right before `FEATURE_PROFILE_TABS` turns on, and
it costs no write. The single definition is `posts.HasMediaFor`. The Media and Reposts tab queries (`Reader.ByAuthorMedia`,
`Reader.ByAuthorKind`) are called only by `GetUserTimeline` with `tab` MEDIA or REPOSTS (W3-9) and only while `profile_tabs` is on.

- **Media tab is empty, or lacks an old post.** Read the raw `posts/{id}`. `hasMedia` absent means a pre-W3 post the one-off
  `opsctl backfill-has-media --project P` (W3-8) has not visited; run it (it writes only posts that lack the field, so a rerun writes 0).
  `hasMedia: false` on a post that has `media` is a bug in a create path: stop and hand back to the backend developer.
- **GetUserTimeline MEDIA / REPOSTS answers INTERNAL, logs show `requires an index` (Firestore FAILED_PRECONDITION).** The composite
  index `posts (authorId, hasMedia, createdAt DESC)` or `posts (authorId, kind, createdAt DESC)` is not READY in that project (the
  emulator does not enforce indexes, so tests cannot catch this). Check `gcloud firestore indexes composite list --project P`. Kill
  switch: `FEATURE_PROFILE_TABS=off` and deploy (the Posts and Replies tabs are unaffected). `profile_tabs` never leaves `off` in a
  project before the backfill ran and both indexes are READY.
- **Reads.** Each tab query reads one row per post returned (1 when empty), no instance cache: `fs_reads` of `timeline_op=user` with a
  tab is about the page size plus the profile reads. A rise for everyone points at a client refreshing the tab in a loop.
- **Pin check (`posts.PinChecker`, used by `UpdateProfile`).** 1 read cold, 0 warm. A post deleted or taken down on another instance can
  still pass the check for up to the posts cache TTL (60 s); the client hides a pin whose `GetPost` answers NOT_FOUND and the
  `post_delete` job clears the pin (`docs/runbooks/identity.md` section 3). A refused pin is always one `VALIDATION field=pinned_post_id` answer, whatever the cause (`docs/runbooks/identity.md` section 1).
