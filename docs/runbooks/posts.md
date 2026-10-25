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
  (held back by the 3-per-author cap, retried next run), `noop` (the item changed under us, quiet), `write_failed`, `skipped_bad_path`,
  `undecodable`, `max_lateness_ms`, `failed_total`, `failed.<reason>` (`media_unavailable`, `quota_exceeded`, `account_restricted`,
  `invalid_content`, `internal`, `unsupported`), `fs_reads`, `fs_writes`, `outcome` (`ok`, `flag_off`, `degraded`, `error`).
- `jsonPayload.message="scheduled_item_start"`: INFO, one per item, written before its transaction, with `uid_hash` and `scheduled_id`.
- `jsonPayload.message="scheduled_author_reads"` (WARN) and `"scheduled_item_transient"` (WARN, a retryable error; `attempts` moved).
- Error Reporting (`rpc` = `cron/publish-scheduled`): a 500, an item retired as FAILED `INTERNAL`, or a recovered panic (type only).
- A run that answers 500 writes no `scheduled_sweep` line: its counts (including the items already published when a later page failed)
  are on the ERROR entry with `rpc=cron/publish-scheduled` and `outcome=error`. Query both when reconstructing a run.

Cost: nothing due is 1 read; each due doc costs 1 read, plus 17 worst / 3 typical reads and 4 writes (+1 per attached image) when it
publishes, or 0 reads and 1 write when it is expired, unsupported, invalid or transiently failing. At most 100 due docs per run
(`SCHEDULED_SWEEP_LIMIT` 50 x `SCHEDULED_SWEEP_MAX_PAGES` 2). The empty ticks cost about 288 reads a day.

### Symptoms and what to do

| Symptom | Meaning | Do |
|---|---|---|
| `outcome=error` on the `scheduled_sweep` line, Error Reporting `cron/publish-scheduled`, and a 500 on the route only when page 1 failed | A due query page failed (a Firestore incident, or the `scheduled` collection-group index on `status, publishAt` is not deployed: `FAILED_PRECONDITION`). **Page 1 failed:** nothing was processed, the route answers 500 and Scheduler retries (3 times, then the next tick); a retry is harmless. **A later page failed:** the earlier pages were processed and the route answers 204 on purpose (a retry seconds later would burn the 3-attempt ladder of any item that failed transiently); the items on the failed page are due again next tick | Check the Firestore status page. If the index is missing, deploy `firebase/firestore.indexes.json` (a gate file, founder review). Nothing is lost: unprocessed items stay PENDING |
| `max_lateness_ms` > 600000 (10 min) | Runs are late or a backlog exists | Look for failed runs and for `deferred` > 0, then see "Draining a backlog". Past `SCHEDULED_MAX_LATENESS` (6 h) items become FAILED `EXPIRED` |
| A spike in one `failed.<reason>` | `quota_exceeded`: authors at the 100 (new accounts 20) posts-per-day cap, expected, see section 3. `media_unavailable`: images removed or never READY. `account_restricted`: authors suspended. `internal`: 3 transient failures or a panic, check Error Reporting. `unsupported`: a draft written by a newer revision than the one sweeping, for example after a rollback. `invalid_content`: a draft that no longer parses or whose reply policy or media is invalid | Failures are terminal and the user sees FAILED in ListScheduledPosts. No action unless `internal` or `unsupported` spikes |
| `skipped_bad_path` > 0 | A document that is not exactly `users/{uid}/scheduled/{32 hex}` matched the due query. It is skipped and never published | Find it in the console (collection group `scheduled`, `status == PENDING`) and delete it by hand. Rules deny clients, so find out who wrote it |
| `undecodable` > 0 | A due doc could not be decoded | Same as above; it is counted and skipped, never retried in a loop |
| `scheduled_author_reads` WARN | One author's items spent more than `SCHEDULED_AUTHOR_READS_WARN` (40) reads in a run (for example 3 items with 10 handle mentions each). These reads sit outside the per-user read budget by design | The same `uid_hash` repeatedly is abuse (`docs/runbooks/abuse-spike.md`). A single occurrence is noise |
| An instance crashes every 5 minutes (Cloud Run restarts, "fatal error", OOM kill) and those runs write no `scheduled_sweep` line | A fatal runtime error (concurrent map write, stack exhaustion) or an OOM in the publish path. These cannot be recovered, and `attempts` never moves | See "Isolating a crash-looping item" |
| Items stay PENDING past their time | The job is paused or failing, the flag is `off`, `DEGRADED_MODE=readonly`, or the 3-per-author cap is stretching a backlog (25 items need 9 runs) | `gcloud scheduler jobs describe publish-scheduled --location asia-south1`, then read `outcome` in the `scheduled_sweep` lines |

### Manual run

- **Prod.** `gcloud scheduler jobs run publish-scheduled --location asia-south1 --project dzeroth-prod`. It makes the same OIDC call as the
  tick. Do not call the prod route with an ID token minted for a person or a broader service account.
- **Dev.** `gcloud scheduler jobs run` cannot run a job that does not exist and dev has `jobs = {}`, so call the route directly with an OIDC
  token for the dev pubsub-push service account (ADR-0021 D1; the principal needs `roles/iam.serviceAccountOpenIdTokenCreator` on that SA,
  a 30-day conditional grant that is never applied in prod):
  `curl -X POST -H "Authorization: Bearer $(gcloud auth print-identity-token --impersonate-service-account=<dev pubsub-push SA> --audiences=<dev api_url> --include-email)" <dev api_url>/internal/cron/publish-scheduled`
  If gcloud's impersonation needs more than `getOpenIdToken`, mint the token through IAM Credentials with your own access token and pass the
  returned `token` as the Bearer. Never "fix" a failing impersonation by granting `roles/iam.serviceAccountTokenCreator` instead: that role
  also mints access tokens and signs blobs as the service account, which is far more than a manual cron test needs (security review I-6):
  `curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d '{"audience":"<dev api_url>","includeEmail":true}' https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<dev pubsub-push SA>:generateIdToken`
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
tick until the expiry check retires it after at most 6 h (72 runs).

1. Confirm: Cloud Run instance restarts on the 5 minute cadence, and `scheduled_sweep` lines missing for those runs.
2. Name the item: in Logs Explorer take `jsonPayload.message="scheduled_item_start"` just before the first crash. The last line has the
   `uid_hash` and the `scheduled_id` (the document id under `users/*/scheduled/`), and the same pair repeats every tick. To open the
   document, run a collection-group query on `scheduled` in the console with `status == PENDING` ordered by `publishAt`; the oldest entry
   is the one.
3. There is no operator cancel path today (CancelScheduledPost is user-only), and the doc must not be edited by hand without the founder's
   say-so. Options: wait for the 6 h expiry (the bound); lower `SCHEDULED_MAX_LATENESS` for one deploy (retires it sooner but also expires
   every other late item); or pause the job (stops everyone's publishing). This is a founder decision.
4. Follow-ups, not built: an `opsctl scheduled cancel` command, and "claim before publish" (`attempts++` before the work, +1 read and +1
   write per publish), which bounds even fatal crashes to 3 runs. A crash loop actually observed is the ADR's trigger to build it.

### Roll-forward only

Once `FEATURE_SCHEDULED_POSTS` has left `off`, do not roll a revision back past the first one that knows scheduled posts. An older
revision `Set`s the whole `quotas/{uid}` record and zeroes `quotas.schedules` on the next quota'd call (review I-3), and a Scheduler tick
that lands on it gets a silent 202 from the placeholder handler, so nothing publishes while it serves. Fix forward with a new revision, or
use the kill switch above. Overlapping runs (a retry and the next tick, or two instances) are safe: the publish transaction re-reads the
item as PENDING, so an item publishes at most once, and the loser is counted as `noop`.
