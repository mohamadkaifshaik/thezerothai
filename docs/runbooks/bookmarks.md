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
  ADR-0018. There is no collection-group query and no index for it (the only override is the `userLikes.bookmarks` array exemption, below).

## Listing (W2-4)
| Case | Reads (cold) | Writes / deletes |
|---|---|---|
| ListBookmarks, page 20 / page 50 | 43 / 103: interceptor 1, query 1 per row, GetMany 1 per row not in the instance post cache, caller graph 1, userLikes 1 | 0 |
| Same, posts cached (warm) | the page itself, 20 / 50 (measured, W2-15), while the interceptor profile, graph and userLikes are cached (60 s); each expired one adds 1 (the proto comment's "1 + page" is that ceiling with one expired); graph and userLikes cached 60 s | 0 |
| Empty list | 2: interceptor + the empty query (billed as 1); nothing else is read | 0 |
| Foreign, tampered or expired token (24 h TTL) | 0 from the handler (VALIDATION `page_token`, decided before any read) | 0 |
| A page that finds missing posts | as above | 1 write + 1 delete per pruned row |

The token is sealed (AES-GCM) and bound to `bookmarks|<uid>`; it resumes after the last row the query returned, kept or dropped, and is
issued whenever the query came back full, so an exactly-full last page ends with one empty page (1 read). Graph and userLikes are read only
when a live row is left to filter or render. Viewer state follows the timelines (`posts.HydrateViewer`: nothing when neither
FEATURE_ENGAGEMENT nor FEATURE_BOOKMARKS is on for the caller). The single request line carries `rows_returned`, `rows_dropped`,
`rows_dropped_missing`, `rows_dropped_hidden`, `rows_dropped_blocked`, `rows_dropped_muted` and `rows_pruned`.
A followers-only post (`visibility != PUBLIC`) whose author the caller does not follow is dropped like a hidden row (counted in `rows_dropped_hidden`, kept, not pruned; 0 extra reads; the caller's own posts always stay), so Bookmarks is never a side door to private posts (W2-14 L-2). A caller whose `blockedBy` list overflowed cannot prove a foreign author does not block it: every foreign row fails closed under `rows_dropped_blocked` (0 extra reads; W2-14 L-1).
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

## Index exemption (`userLikes.bookmarks`)
`firebase/firestore.indexes.json` exempts `userLikes.bookmarks` from single-field indexing (`indexes: []`, like `recent` and `recentReposts`; its hash is in
`firebase/field-overrides.ack`, both founder-gated). Deploy it (`firebase deploy --only firestore:indexes`; dev: the deploy-dev run, prod: the release) **before
`FEATURE_BOOKMARKS` leaves `off` in that project**, or each of up to 1,000 array entries is indexed (about 140 KB per user at the cap). Nothing queries `bookmarks`
as a field, so the exemption removes no query. This array is the only source of `bookmarked_by_viewer` on every card, thread row, timeline row and ListBookmarks row
(ADR-0023 D3), and nothing re-syncs it from the subcollection (not even a repeated AddBookmark of an existing bookmark, which writes only the idempotency doc). If the
array is ever missing entries that bookmark docs have, a `userLikes` write was not field-level (the ADR-0021 I-3 class of bug): treat that as a code defect, not data.

## Cost trigger (ADR-0023, measured in W2-15)
The Stage 2 trigger (ADR-0023 stage ladder, `docs/reviews/cost-model.md` section 6): **ListBookmarks reads above 15% of the daily Firestore reads, or the section 6 Firestore trigger (more than 1.5M reads/day or a bill above $30/month), sustained 7 days**. It needs an ADR (a `bookmarks` table or Memorystore); nothing in this runbook changes the design. Modelled share: 16.9 of 248.7 reads per DAU = 6.8%; 15% is about 2.2x the modelled list usage. The plan's rollback line is bookmark reads per DAU above twice the model, i.e. above about 37 (the model: 18.56 reads, 1.42 writes, 0.62 deletes per DAU per day; AddBookmark 3 warm / 4 planning, RemoveBookmark 2, ListBookmarks 43 / 40 per cold page of 20 and 20 warm).

Measure it (read-only; the rpc string is `/dzeroth.engagement.v1.EngagementService/ListBookmarks`). **Denominator, primary: the Cloud Monitoring metric `firestore.googleapis.com/document/read_count`** (daily sum for the project; "daily Firestore reads" literally, including cron, job and fan-out reads). **Numerator: the sum of `fs_reads` on the ListBookmarks request lines.** The log-only cross-check below sums `fs_reads` over every line that carries it, not just `message="request"`: the notification fan-out (`notification_delivery`), the account jobs (`lifecycle_jobs.go`) and the scheduled-post sweep log their reads on their own lines; `removal_log_reads` rides the request line next to `fs_reads` and is added; `fanout_fs_reads` duplicates `fs_reads` on the fan-out line and is not added; the WARN line `scheduled_author_reads` repeats reads already in the sweep total and is skipped (cost-model section 9). One 24-hour share:
```
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.fs_reads:*' \
  --project=dzeroth-prod --freshness=1d --limit=200000 --format=json \
| jq '[.[].jsonPayload | select(.message != "scheduled_author_reads")] | {all_reads: (map((.fs_reads // 0) + (.removal_log_reads // 0)) | add // 0), list_reads: (map(select((.rpc // "") | endswith("/ListBookmarks")) | (.fs_reads // 0)) | add // 0)} | .share_pct = (if .all_reads == 0 then 0 else ((1000 * .list_reads / .all_reads) | round / 10) end)'
```
For the share against the metric, divide `list_reads` by that day's `document/read_count`. Run it once a day (prod while the flag is on there; dev for the allowlist); 7 consecutive days with `share_pct` above 15 fires the trigger. Logs Explorer cannot sum, so its filter only isolates the lines: `jsonPayload.rpc="/dzeroth.engagement.v1.EngagementService/ListBookmarks"`; with Log Analytics enabled the same numerator is `SELECT SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) ... WHERE JSON_VALUE(json_payload.rpc) LIKE '%/ListBookmarks'` (it is not enabled at Stage 0). Cross-check the denominator against the Cloud Monitoring metric `firestore.googleapis.com/document/read_count` (daily sum; it also counts cron and fan-out reads). `make cost PROJECT_ID=...` prints the same request lines (`rpc`, `fs_reads`, last 50) but no share column. Per-user spread: `read_budget_spent` on the list lines; a user at the 1,000 cap paging 50 rows cold uses the whole 2,000 daily read budget in about 19 pages (`limit=read_budget_daily`, cost-model section 11). The emulator smoke that produced these numbers: `make loadtest SCENARIO=engagement_bookmarks_list` and `node loadtest/analyze_bookmarks.js api.log` (`loadtest/README.md`).

## Quick reference
- Caps and limits: 1,000 bookmarks per user (`LIMIT_REACHED limit=bookmarks`), 200 adds per IST day and 50 for accounts younger than
  `QUOTA_NEW_ACCOUNT_WINDOW` (`QUOTA_EXCEEDED quota=bookmarks`), 30/min Add+Remove and 10/min List per instance.
- **Daily call cap (W2-14 M-1).** Add and Remove share ONE per-uid, per-instance counter: `BOOKMARK_MUTATIONS_PER_DAY` = 1,500 (limit_name `bookmark_mutation_daily`, `RESOURCE_EXHAUSTED`, retry after the IST day rolls). It exists because an already bookmarked Add and a Remove of a missing bookmark reserve no quota but each store an idempotency doc (1 write + 1 TTL delete): before it, only the 30/min bucket bounded them. Arithmetic: a legitimate heavy day is 200 adds (the quota) + a full clear-out of the 1,000 cap = 1,200 calls, so 1,500 leaves 300 for retries and undo churn. Worst abusive account per day = 1,500 calls x 3 instances (max-instances 3; the cap is per instance) = 4,500 idempotency writes + 4,500 TTL deletes, against the free 20k writes and 20k deletes a day. Find it: `jsonPayload.limit_name="bookmark_mutation_daily"`, sorted by `uid_hash`; many hashes at it is a script farm (`docs/runbooks/abuse-spike.md`). Raising it multiplies that worst case; do not go past 3,000 without redoing the sum. ListBookmarks is not on it (a read: the read budget covers it).
- **Contention is not an error (W2-14 L-3).** A write that lost every transaction re-run (Aborted after 4 runs) or ran out of the 5 s transaction time answers `UNAVAILABLE` with a 1 s retry hint, logged at WARN `engagement_bookmark_contention` with `outcome=contention`; it never reaches Error Reporting or the rollback trigger. The client retries with the same key. A client that left is `CANCELED` / `DEADLINE_EXCEEDED`. Only a genuinely unexpected repo error is `INTERNAL`, and its chain has the uid and the post id redacted (W2-14 I-4).
- Replays: Add and Remove both store an idempotency doc, including their no-op paths (an already bookmarked post, a missing bookmark: 1 write),
  so a late retry of any key replays instead of re-executing and never undoes a newer toggle.
- Cost: `docs/adr/0023-bookmarks.md` "Cost impact" (about 18.2 reads, 1.4 writes, 0.5 deletes per DAU per day); re-based in `docs/reviews/cost-model.md` (W2-15) to 18.56 / 1.42 / 0.62, about INR 6.4 a month at 300 DAU. The Stage 2 trigger and its query are in "Cost trigger" above.
