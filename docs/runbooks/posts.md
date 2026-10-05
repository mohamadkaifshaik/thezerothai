# Runbook: posts failure modes (CreatePost, timelines)

Owner module: `backend/internal/posts` (ADR-0010). Data: `posts/{postId}`, `idempotency/{hash}` (24 h TTL),
`quotas/{uid}.posts`, `users/{uid}.postsCount`. Everything is behind `FEATURE_POSTS` (off | allowlist | percent | on).
Queries are for **Logs Explorer** (`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`). The
kill switch is `FEATURE_POSTS=off` (pinned-traffic procedure in `docs/runbooks/cost-spike.md`); `DEGRADED_MODE=readonly`
rejects CreatePost and DeletePost but keeps reads.

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

## Timelines (GetHomeTimeline, GetUserTimeline)

Owner module: `backend/internal/timeline` (ADR-0004, ADR-0010 D13-D16). It stores nothing; request lines carry
`timeline_op`, `timeline_mode` (`cold|refresh|older|gap`), `timeline_chunks`, `authors_from_cache`,
`timeline_cache_hit`, `items_returned`, `items_filtered`, `gap`, `since_clamped`, `page_size` and `fs_reads`.

## 6. Home timeline reads are high (`fs_reads` per `timeline_op=home`)
Expected ceiling is `2 + C + 2*page` (269 at 5,000 followed, page 50). Find outliers with
`jsonPayload.timeline_op="home" AND jsonPayload.fs_reads>100`; `timeline_chunks` is C of that caller. Many power users
(> 5% of DAU above 1,000 followed) is the ADR-0004 revisit trigger. A sudden rise for everyone with `authors_from_cache`
near 0 means the author-recent cache stopped filling (instance churn or `CACHE_AUTHOR_RECENT_ENTRIES` too small).

## 7. Clients report `VALIDATION field=since_token` / `page_token`
The token is expired (30 days, `TIMELINE_TOKEN_TTL`), tampered, from another account, another feed or tab, or a
`CURSOR_HMAC_KEY` rotation invalidated it. This is the designed answer, with 0 reads: the client drops the token and
cold-opens. A burst right after a key rotation is expected; a burst without one points at a client bug (sending both
tokens is also `page_token`).

## 8. A post appears twice, or a just-created post shows up late
`since_token` trails the newest item by `TIMELINE_SETTLE_WINDOW` (15 s, D13), so a refresh may re-return recent posts
(`since_clamped=true`); clients dedupe by `post_id`. A post can lag up to 60 s when another instance's author-recent
entry still serves the author. Neither needs action.
