# Runbook: engagement failure modes (likes, reposts, quotes, post_delete job)

Owner module: `backend/internal/engagement` (ADR-0018, plan `docs/plans/engagement.md`). Data: `likes/{postId}_{uid}`,
`reposts/{postId}_{uid}`, `userLikes/{uid}`, `quotas/{uid}.likes`, `posts/{id}.{likeCount,repostCount,quoteCount,embedded}`.
Everything user-visible is behind `FEATURE_ENGAGEMENT` (off | allowlist | percent | on, FEATURE_POSTS still required).
Cleanup (the `post_delete` job, Eraser, export) is never flag-gated. Kill switch: `FEATURE_ENGAGEMENT=off`.

## 1. Likes or reposts of a deleted post remain (orphans)
**What it is.** DeletePost publishes `post_delete` best effort. If the publish failed
(`post_delete_job_publish_failed` in Error Reporting) the post is gone but its `likes/*`, `reposts/*` and REPOST posts
stay, and quotes still show the frozen text. There is no reconciliation sweep at Stage 0 (plan "Risks").
**Find it:** `likes` where `postId == <id>` returns docs while `posts/<id>` does not exist.
**Fix:** publish by hand to the jobs topic
`{"kind":"post_delete","uid":"<author uid>","postId":"<postId>","mediaIds":[]}`. The job refuses while the post exists
(`refused`), is idempotent, and converges on a redelivery. The same message re-runs the media step.

## 2. `engagement_post_delete_continued` appears repeatedly for one post
**What it is.** A post with thousands of likes/reposts: one delivery handles at most 10 pages of 100, then republishes
the same message and acks (D11), so it never dead-letters. Each continuation is normal; the job finishes when a page
is not full. A loop that never ends means the deletes fail silently: check `fs_writes`/errors on the `/internal` line.
**Cost:** 1 read + 1 delete per like; a post with 5,000 likes is ~5k reads and 5k deletes spread over 50 deliveries.

## 3. Users report "daily limit reached" when liking
`QUOTA_EXCEEDED` with `quota=likes`: 500 per IST day, 100 for an account younger than `QUOTA_NEW_ACCOUNT_WINDOW`
(`QUOTA_LIKES_PER_DAY`, `QUOTA_NEW_ACCOUNT_LIKES_PER_DAY`). Reposts count against the posts quota (`quota=posts`).
A spike across many accounts is spam: `docs/runbooks/abuse-spike.md`.

## 4. A like or repost count looks wrong
Counters are exact in Firestore; a viewer can see a count up to 60 s stale (instance cache). If `likeCount !=` the
number of `likes` docs, the cause is a write path that bypassed the transaction; repair with
`likeCount := count(likes where postId == id)` for that one post and file a bug. Quote and reply counters drift by
design when the quoting account is deleted (D16).

## 5. Liked state missing for old likes
`userLikes.recent` keeps the last 1,000 likes (500 reposts): older likes render as not liked (D7). Tapping like on such
a post is a replay (0 writes) and re-adds it to the set. Not a bug; raise the cap only through an ADR.

## 6. Account deletion stalls on the `engagement` step
The step pages 100 likes/reposts per invocation (each an atomic delete + counter -1) and falls back to one batch per
doc when a post in the page is gone. Resumable via the checkpoint; see `docs/runbooks/account-deletion.md` Step 2.
