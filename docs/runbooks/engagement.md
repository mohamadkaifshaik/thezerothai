# Runbook: engagement failure modes (likes, reposts, quotes, post_delete job)

Owner module: `backend/internal/engagement` (ADR-0018, plan `docs/plans/engagement.md`). Data: `likes/{postId}_{uid}`,
`reposts/{postId}_{uid}`, `userLikes/{uid}`, `quotas/{uid}.likes`, `posts/{id}.{likeCount,repostCount,quoteCount,embedded}`.
Everything user-visible is behind `FEATURE_ENGAGEMENT` (off | allowlist | percent | on, FEATURE_POSTS still required).
Cleanup (the `post_delete` job, Eraser, export) is never flag-gated. Kill switch: `FEATURE_ENGAGEMENT=off`.

| Flag (wire name) | Env vars / Terraform | Gates | Default |
|---|---|---|---|
| `engagement` | `FEATURE_ENGAGEMENT[_ALLOWLIST\|_PERCENT]` / `feature_engagement*` | LikePost, UnlikePost, RepostPost, UndoRepost, viewer flags; required by `quotes` | off |
| `quotes` | `FEATURE_QUOTES[_ALLOWLIST\|_PERCENT]` / `feature_quotes*` | `CreatePost.quote_of_post_id` only (needs `engagement` on too; ADR-0018 amendment 2026-10-18) | off |
| `bookmarks` | `FEATURE_BOOKMARKS[_ALLOWLIST\|_PERCENT]` / `feature_bookmarks*` | AddBookmark needs it on for the caller; ListBookmarks and RemoveBookmark only need it not globally off (ADR-0023 D5); needs FEATURE_POSTS, not `engagement`. All three RPCs are live behind it (W2-3, W2-4). The runbook is `docs/runbooks/bookmarks.md` | off |
| `likes_list` | `FEATURE_LIKES_LIST[_ALLOWLIST|_PERCENT]` / `feature_likes_list*` | ListLikedPosts needs it on for the caller (ADR-0024 D6, D9); needs FEATURE_POSTS, not `engagement`. Without it: `FEATURE_DISABLED` `feature=likes_list`, 0 reads. W3-10 implemented the handler (section 9); a Server built without a LikesList answers Unimplemented behind the gate. Rate limit `RATE_LIMIT_LIKES_LIST_PER_MIN` (10/min per instance). Kill switch: set it to `off` and deploy, nothing stored changes | off |

Quote rollback: set `FEATURE_QUOTES=off` (or lower the percent) and deploy. New quotes are refused with `FEATURE_DISABLED`
`feature=quotes`; existing quotes keep displaying (display never consults the flag), likes and reposts are unaffected.
`enabled_features` lists `quotes` only for callers it is on for; clients treat the refusal as the sub-feature being off.

## 1. Likes or reposts of a deleted post remain (orphans)
**What it is.** DeletePost publishes `post_delete` best effort. If the publish failed
(`post_delete_job_publish_failed` in Error Reporting) the post is gone but its `likes/*`, `reposts/*` and REPOST posts
stay, and quotes still show the frozen text. There is no reconciliation sweep at Stage 0 (plan "Risks").
**Find it:** `likes` where `postId == <id>` returns docs while `posts/<id>` does not exist.
**Fix:** publish by hand to the jobs topic
`{"kind":"post_delete","uid":"<author uid>","postId":"<postId>","mediaIds":[]}`. The job refuses while the post exists
(`refused`), is idempotent, and converges on a redelivery. The same message re-runs the media step.

**Expected orphans, no action (ADR-0018 "Orphaned likes", founder approval 2026-10-17).** After an *account* deletion,
likes that other users left on the deleted user's posts (`likes/{postId}_{otherUid}`, and those ids in their
`userLikes`) remain by design. They hold only the liker's uid and a dead post id, counts are unaffected, ids are never
reused, and they are erased with the liker's account. They are not ADR-0011 Q10 residue. Tell them apart from the
failed-publish case above by Error Reporting: if there is no `post_delete_job_publish_failed` for that postId, treat
the orphans as expected; no action needed.

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

## 7. `posts_purge_copies_stuck` (Error) during an account deletion
The posts purge's copy phase (ADR-0018 D14) removes the deleted user's text from other users' REPOST docs and
tombstones their QUOTE docs. A full page that made no progress would repeat forever, so the job stops and logs
`posts_purge_copies_stuck` at Error (it reaches Error Reporting) with `uid_hash` and `docs`.
- Cause: copy docs the batch and the per-doc fallback both reject (typically a reposter's `users` doc in an unexpected
  state, or a malformed `kind`).
- Check: `opsctl purge-posts --dry-run` for the uid, then query `posts where embeddedAuthorId == <uid> limit 20` in
  the Firestore console and look at the first doc's `kind`, `authorId` and `repostOfId`.
- Fix: repair or delete the named doc by hand (write budget: a handful), then re-deliver the deletion job; the phase
  resumes from the first full page. The account-deletion backstop does not delete `users/{uid}` while a residue
  remains, so nothing is lost by waiting.
- Related, same shape for a post deletion: `engagement_post_delete_no_progress` (Error) means a full page of likes,
  reposts or quotes of a deleted post made no progress; the step is skipped for that delivery instead of
  re-publishing forever. Same check on `repostOfId` / `quoteOfId` / `postId`.

### Deploying while deletions are in progress
A deletion whose posts step is still running at deploy time re-enters at its stored checkpoint (`Phase` 0 is the post
purge), finishes it and then runs the copy phase once, so copies are cleaned. A deletion that had already left the
posts step before the deploy never runs the copy phase: its copies (other users' REPOST and QUOTE docs of the
deleted user) remain until `opsctl purge-posts` is run for that uid. Check the account-deletion jobs in flight at
deploy time and re-run the posts purge for any that were past the posts step.

### Concurrent likes: abandoned follower
A LikePost that joined another request's in-flight like of the same post (same instance, same user) and whose client
then left returns CANCELED / DEADLINE_EXCEEDED (not INTERNAL, not in Error Reporting). Its request log does not
carry the transaction's `fs_reads` / `fs_writes`: the leader's request owns them. The leader never abandons its
flight, so a committed like always updates the counter hook, the cache and the notification.

## 8. Bookmarks: AddBookmark and RemoveBookmark (ADR-0023, W2-3)
Data: `users/{uid}/bookmarks/{postId}` = `{createdAt}` (a thin doc, no copy of the post), `userLikes/{uid}.bookmarks` (the
complete set, at most `BOOKMARKS_MAX_PER_USER` = 1,000), `quotas/{uid}.bookmarks`, `idempotency/{hash}` (24 h TTL). Nothing
is emitted or notified; a bookmark is private to its owner. **Kill switch: `FEATURE_BOOKMARKS=off` and deploy** (Add and
Remove then answer `FEATURE_DISABLED feature=bookmarks`, 0 reads); no data migration is needed and existing bookmarks stay.
Taking a user off the allowlist stops their Add only, they can still Remove. The request line carries `engagement_op`
(`add_bookmark` / `remove_bookmark`), `outcome` (`done`, `replay`, `noop`, `not_found`, `rejected:limit_reached`,
`rejected:quota_exceeded`, `rejected:key_reused`, `contention`), `fs_reads`, `fs_writes`, `fs_deletes` and `txn_attempts`.

| Symptom | Cause and action |
|---|---|
| `LIMIT_REACHED limit=bookmarks` | The user holds 1,000 bookmarks (exact: counted from `userLikes.bookmarks` inside the transaction). Expected; they remove some. Raising `BOOKMARKS_MAX_PER_USER` past 2,000 needs ADR-0023 D7's maths redone |
| `QUOTA_EXCEEDED quota=bookmarks` | 200 adds per IST day, 50 for an account younger than `QUOTA_NEW_ACCOUNT_WINDOW` (`QUOTA_BOOKMARKS_PER_DAY`, `QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY`). A replay or an already bookmarked post is not charged. A spike across many accounts is spam: `docs/runbooks/abuse-spike.md` |
| Add returns `NOT_FOUND "post not found"` for a post the user saw | The post is deleted, taken down, or its author (or a quoted author) blocks the user: the same answer and bytes as GetPost, by design (no block oracle) |
| `UNAVAILABLE` (retry after 1 s) from Add or Remove, `outcome=contention`, WARN `engagement_bookmark_contention`, `txn_attempts` at 4+ or a deadline | Contention (W2-14 L-3, no longer INTERNAL): one user's concurrent adds all lock their `quotas` and `userLikes` docs and serialise; the transaction retries 4 times inside 5 s and then gives up without writing. The client retries (same key). Sustained = a client bug or a script; the 30/min per-instance rate limit and the `bookmark_mutation_daily` cap bound it |
| `RESOURCE_EXHAUSTED` with `limit_name=bookmark_mutation_daily` | The user made more than `BOOKMARK_MUTATIONS_PER_DAY` (1,500) Add + Remove calls on this instance today (W2-14 M-1). A legitimate heavy day is about 1,200; see `docs/runbooks/bookmarks.md` quick reference for the sum. Many hashes at once = a script farm: `docs/runbooks/abuse-spike.md` |
| Bookmarked state missing on a card | Viewer state comes from `userLikes.bookmarks`, cached 60 s per instance. The wire field `PostView.bookmarked_by_viewer` does not exist yet (architect follow-up), so clients keep a local set until it ships |
| Bookmark exists in the subcollection but not in the array (or the reverse) | Not expected: every writer changes both in one transaction. Add then answers success and writes only its idempotency doc (it cannot heal it); the ListBookmarks prune (it removes the id from the array too, for a missing post only) and the account eraser delete by doc. File a bug with the uid hash |

Replays: a replayed Add returns its stored `bookmarked: true` even if the bookmark was removed since, and a replayed
Remove returns `false` even if it was added again; neither writes, so a late retry never undoes a newer toggle. The two no-op paths (Add of an
already bookmarked post, Remove of a missing bookmark) also store their idempotency doc, so they cost 1 write, not 0, and a late retry
of their key replays too. Account deletion and export of the `users/{uid}/bookmarks` subcollection, the prune and the residue are in
`docs/runbooks/bookmarks.md`.

## 9. Likes list: ListLikedPosts (ADR-0024 D6, W3-10)
Read only. The ids are `userLikes/{uid}.recent` (the last 1,000 liked post ids, newest last, owned by the like path); the posts are
live reads through the posts cache. Nothing is written, pruned or emitted. **Kill switch: `FEATURE_LIKES_LIST=off` and deploy**
(`FEATURE_DISABLED feature=likes_list`, 0 reads); percent 0 or an empty allowlist is a rollout, not a kill. It needs `posts`, not
`engagement`. The request line carries `engagement_op=list_liked_posts`, `outcome` (`done`, `rejected:invalid_argument`),
`rows_returned`, `rows_dropped`, `rows_dropped_{missing,hidden,blocked,muted,protected}`, `userlikes_cache_hit` and `fs_reads` (23 at page 20
cold, 53 at page 50, 2 for an empty array, 20 warm at page 20); there is no `rows_pruned`.

| Symptom | Cause and action |
|---|---|
| Old likes are missing from the list, or the list stops at about 1,000 | By design: `recent` keeps the 1,000 most recent likes (`MaxRecentLikes`), the same limit as the liked state on cards (section 5). A longer history needs the Stage 2/3 `likes (uid, createdAt)` index or a SQL table (ADR-0024 D6, out of scope), not a bigger array (document size and write cost) |
| Short or empty pages while `next_page_token` is non-empty | Expected. Rows whose post is deleted, taken down, hidden, by a blocked or muted author, by an author who blocks the viewer, or by a protected account the viewer does not follow (`rows_dropped_protected`, W3-29b: kept, never pruned, back after a follow or an unprotect; a REPOST of such a post is dropped, a QUOTE stays with the stripped embed) are dropped after the read and the page is not refilled; the client keeps following the token. Many `rows_dropped_missing` for one user means their liked posts were deleted (section 1 removes the like docs; the array entry stays until the user unlikes it or it ages out of the 1,000). Nothing to repair: the list never prunes, on purpose |
| A like made just now is missing | `recent` is cached 60 s per instance. The instance that served the like updates its cache in place; another instance shows it within 60 s. Only a like still missing after that is a bug: check the like's `userLikes` write (section 5) |
| `INVALID_ARGUMENT VALIDATION page_token` | The token is older than 24 h, another user's, hand-edited, from another list (a ListBookmarks token does not open here) or of another payload version. 0 reads; the client drops it and reloads the first page. A spike across many users right after a deploy means `CURSOR_HMAC_KEY` or the token payload changed |
| A row repeats or is skipped between two scrolls | Only a row changed at the page boundary can (the ADR-0024 D6 residual: both anchors unliked, or the last row unliked and the next one re-liked). A re-liked row moves to the top and is not shown twice. Anything larger is a bug: keep the token's issue time and the user's unlike times and check `likesResume` |
| `UNIMPLEMENTED` "ListLikedPosts is not wired" | The Server was built without a `LikesList`. `apiserver.Build` cannot do this (`NewServer` takes it from the Module); a test or a split-out wiring left `WithLikesList` out |
| `RESOURCE_EXHAUSTED` | The per-instance bucket `RATE_LIMIT_LIKES_LIST_PER_MIN` (10/min; it multiplies by max-instances) |
