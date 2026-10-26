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
- **Hidden rows.** ListBookmarks drops a row whose post is missing, hidden by a moderator (`TAKEN_DOWN`, `SUSPENDED_AUTHOR`) or whose author
  (or a quote's embedded author) is blocked, blocks or is muted by the viewer. Hidden and blocked rows are kept, so a restore or an
  unblock brings them back. A page may therefore be short or empty with `next_page_token` set: the client keeps following the token until it is empty (the server never refills a page). A hidden row costs its `GetMany` read on every open until it is restored or removed. When the viewer's `blockedBy` overflowed (10,000 entries), a foreign quote's embedded author fails closed (dropped, counted as blocked) rather than costing a read per row.
- **Lazy prune.** A row whose post no longer exists is deleted, together with its `userLikes.bookmarks` entry, in one best-effort batch on the
  owner's next open, once: 1 write (the `userLikes` field update) and 1 delete per row, 0 extra reads, inside the request itself (nothing runs after the response). Only a row whose post is confirmed missing by `GetMany` is pruned, never one that merely failed to load: a `GetMany` error fails the call and prunes nothing. The deletes are blind (no `Exists`), so two simultaneous opens may both delete the same row (a harmless extra delete). Skipped under `DEGRADED_MODE=readonly`; a failed batch logs WARN `engagement_bookmark_prune_failed` (counts and uid hash only), the page is still served and the next open retries. Snowflake ids are never reused, so it is safe. The request line carries
  `rows_dropped` by cause and `rows_pruned`.
- **The residue.** Until the prune (or the bookmarker's own deletion) a bookmark doc holds a post id that resolves to nothing, under the
  bookmarker's own path. It holds no uid of the post's author and no content. This is narrower than the orphaned likes the founder accepted in
  ADR-0018. There is no collection-group query, no index and no field override for it.

## Listing (W2-4)
| Case | Reads (cold) | Writes / deletes |
|---|---|---|
| ListBookmarks, page 20 / page 50 | 43 / 103: interceptor 1, query 1 per row, GetMany 1 per row not in the instance post cache, caller graph 1, userLikes 1 | 0 |
| Same, posts cached (warm) | 1 + page (the query); graph and userLikes cached 60 s | 0 |
| Empty list | 2: interceptor + the empty query (billed as 1); nothing else is read | 0 |
| Foreign, tampered or expired token (24 h TTL) | 0 from the handler (VALIDATION `page_token`, decided before any read) | 0 |
| A page that finds missing posts | as above | 1 write + 1 delete per pruned row |

The token is sealed (AES-GCM) and bound to `bookmarks|<uid>`; it resumes after the last row the query returned, kept or dropped, and is
issued whenever the query came back full, so an exactly-full last page ends with one empty page (1 read). Graph and userLikes are read only
when a live row is left to filter or render. Viewer state follows the timelines (`posts.HydrateViewer`: nothing when neither
FEATURE_ENGAGEMENT nor FEATURE_BOOKMARKS is on for the caller). The single request line carries `rows_returned`, `rows_dropped`,
`rows_dropped_missing`, `rows_dropped_hidden`, `rows_dropped_blocked`, `rows_dropped_muted` and `rows_pruned`.
Symptoms: many `rows_dropped_hidden` for one user is a takedown or suspension that has not been restored (kept on purpose); a steady
`rows_dropped_missing` with `rows_pruned=0` means the prune is failing or `DEGRADED_MODE=readonly` (look for the WARN above); read cost
above 43 / 103 means a code change, not data.

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
