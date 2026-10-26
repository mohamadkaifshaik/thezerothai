# Runbook: bookmarks (ADR-0023)

Owner module: `backend/internal/engagement` (`Bookmarks` / `BookmarkRepo` seams). Plan: `docs/plans/ui-w2-engagement-composer-basics.md`
(W2-3 Add/Remove, W2-4 List, W2-5 lifecycle). Add/Remove failure modes also live in `docs/runbooks/engagement.md` section 8.

Data: `users/{uid}/bookmarks/{postId}` = `{createdAt}` (a thin doc: the post id is the doc id, no copy of the post, no author uid),
`userLikes/{uid}.bookmarks` (the complete set, at most `BOOKMARKS_MAX_PER_USER` = 1,000), `quotas/{uid}.bookmarks`, and the TTL'd
`idempotency/{hash}` docs of Add and Remove (24 h). Bookmarks are private: no event, no notification, no count on posts, nothing the
post's author can see. Client rules stay deny-all.

## Kill switch
`FEATURE_BOOKMARKS=off` (or lower the percent / allowlist) and deploy; no data migration. With the flag off every bookmark RPC answers
`FAILED_PRECONDITION FEATURE_DISABLED feature=bookmarks` with 0 reads. Only `off` is the kill switch for List and Remove (they need the
flag only "not globally off", so a user dropped from the allowlist can still list and remove what they saved). Percent 0 or an empty
allowlist is a rollout, not a stop. Existing bookmarks stay and come back when the flag is on again. **Never flag-gated:** the account
eraser step, the export section and the list prune (cleanup must run after the flag is off).

## Posts that go away: no fan-out (D6)
Deleting, taking down or purging a post writes nothing to its bookmarkers. Consequences, all by design:
- **Hidden rows.** ListBookmarks (W2-4) drops a row whose post is missing, hidden by a moderator (`TAKEN_DOWN`, `SUSPENDED_AUTHOR`) or whose author
  (or a quote's embedded author) is blocked, blocks or is muted by the viewer. Hidden and blocked rows are kept, so a restore or an
  unblock brings them back. A page may therefore be short or empty with `next_page_token` set.
- **Lazy prune.** A row whose post no longer exists is deleted, together with its `userLikes.bookmarks` entry, in one best-effort batch on the
  owner's next open, once. Skipped under `DEGRADED_MODE=readonly`. Snowflake ids are never reused, so it is safe. The request line carries
  `rows_dropped` by cause and `rows_pruned`.
- **The residue.** Until the prune (or the bookmarker's own deletion) a bookmark doc holds a post id that resolves to nothing, under the
  bookmarker's own path. It holds no uid of the post's author and no content. This is narrower than the orphaned likes the founder accepted in
  ADR-0018. There is no collection-group query, no index and no field override for it.

## Account deletion and export (W2-5)
| Path | Reads | Writes / deletes | Notes |
|---|---|---|---|
| Eraser step `bookmarks` (after `scheduled`, before `identity`) | 1 per document, minimum 1 (1 when the account has none) | 1 delete per document; 1 field-level `userLikes` update on the last page (none when `userLikes` is gone) | pages of at most 500; an account at the cap (1,000) takes 3 invocations; resumable and idempotent (a re-run is 1 read) |
| Export section `bookmarks` | 1 per document, minimum 1 | 0 | `{"bookmarks":[{"postId","bookmarkedAt"}]}` newest first, at most about 70 KB at the cap; never the post's content |

The step name is persisted in `deletionJob.step`: never rename it. `userLikes` is deleted by the earlier `engagement` step; the `bookmarks`
step clears the field with an `Update` so it can never recreate that document. If a deletion stalls on `bookmarks`, the cause is a failed
batch or Update (the job retries and logs `engagement_purge_bookmarks` per page); the account-deletion runbook's stuck-job procedure applies.

## Quick reference
- Caps and limits: 1,000 bookmarks per user (`LIMIT_REACHED limit=bookmarks`), 200 adds per IST day and 50 for accounts younger than
  `QUOTA_NEW_ACCOUNT_WINDOW` (`QUOTA_EXCEEDED quota=bookmarks`), 30/min Add+Remove and 10/min List per instance.
- Replays: Add and Remove both store an idempotency doc, including their no-op paths (an already bookmarked post, a missing bookmark: 1 write),
  so a late retry of any key replays instead of re-executing and never undoes a newer toggle.
- Cost: `docs/adr/0023-bookmarks.md` "Cost impact"; the feature adds about 18.2 reads, 1.4 writes and 0.5 deletes per DAU per day.
