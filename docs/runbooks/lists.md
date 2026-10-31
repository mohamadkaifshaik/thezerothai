# Runbook: lists (ADR-0030)

Owner module: `backend/internal/lists` (`Service`, `Reader`, `Pins` seams). Plan:
`docs/plans/ui-w5-lists-communities.md` (W5-4 write path and W5-5 lifecycle ship together; W5-6 members, W5-7 reads, W5-8 timeline, W5-9
Home tabs follow).

Data: `lists/{listId}` = `ownerId`, `name`, `description`, `isPrivate`, `memberIds[]` (stays indexed: the eraser queries it), `hidden`
(absent = false, platform hide), `createdAt`, `updatedAt`. No member count is stored. Also `quotas/{uid}.listCreates` / `listAdds` and
the TTL'd `idempotency/{hash}` docs of the mutations (24 h). Those idempotency docs keep the list header (name, description, member count)
of the call for up to 24 h, so a replay needs no list read; they hold no other user's uid. Client rules stay deny-all.

## 1. Kill switch
`FEATURE_LISTS=off` and deploy; no data migration. Every `ListService` RPC then answers `FAILED_PRECONDITION FEATURE_DISABLED feature=lists`
with 0 reads. Percent 0 or an empty allowlist is a rollout, not a stop. Existing lists stay and return when the flag is on again. **Never
flag-gated:** the account eraser step and the export section.

## 2. Caps and quotas (config, rule 11)
`LISTS_MAX_PER_USER` 20 (exact `count()` in the CreateList transaction, answer `LIMIT_REACHED limit=lists`), `LIST_MAX_MEMBERS` 150 (W5-6),
`QUOTA_LIST_CREATES_PER_DAY` 10 (3 for accounts younger than `QUOTA_NEW_ACCOUNT_WINDOW`; answer `QUOTA_EXCEEDED quota=list_creates`),
`QUOTA_LIST_ADDS_PER_DAY` 300 (50). `RATE_LIMIT_LISTS_WRITE_PER_MIN` 30 per instance and the daily call cap `LIST_MUTATIONS_PER_DAY` 500
(limit name `list_mutation_daily`) cover the six mutations; the effective numbers are times max-instances (3). `CACHE_LISTS_ENTRIES` 2,000
entries per instance, 60 s TTL.

## 3. Reading the request line
One line per RPC: `list_op` (`create`, `update`, `delete`, `add`, `remove`, `get`, `user_lists`, `members`), `dropped` (members removed by the lazy drop in the same write), `cache_hit` (reads: the list doc came from the instance cache), `rows_dropped_owner` / `rows_dropped_viewer` / `rows_dropped_inactive` (a member page: members who block the owner; members the viewer blocks, mutes or is blocked by, or, with the viewer's own blockedBy overflowed, does not follow; members that are not ACTIVE), `outcome` (`done`, `replay`, `noop`, `rejected:*`, `contention`), `fs_reads`,
`fs_writes`, `txn_attempts`. Never a list id, name or description. A `lists_contention` WARN means a transaction kept losing the lock race
(a double tap on one list; a list has one writer, so this is not a hot document); the client gets a retryable UNAVAILABLE. Lower
`RATE_LIMIT_LISTS_WRITE_PER_MIN` if it persists. `lists_retitle_failed` / `lists_unpin_failed` WARNs (W5-9 onward) mean the pinned-tab
clean-up after a commit failed; the dangling tab is dropped lazily and nothing is lost.

## 4. Failure modes
- **NOT_FOUND for a list the owner expects.** One answer for every cause (missing, someone else's, deleted). Nothing to debug beyond
  checking the id in the console. DeleteList of such an id succeeds on purpose (a retry after a lost response).
- **"requires an index" on `ownerId ==` or `memberIds array-contains`.** Both are served by automatic single-field indexes and the emulator
  never reports a missing one, so the W5-19 dev smoke is the first proof. If real Firestore asks for an index: stop and ask the architect.
  Do not exempt `memberIds` from indexing in `firestore.indexes.json`: the eraser needs it.
- **CreateList LIMIT_REACHED with fewer than 20 lists visible.** The count includes private and hidden lists. Count with
  `lists where ownerId == <uid>`.
- **A member page is short, or empty, while `next_page_token` is set.** By design (proto): drops need no read and leave holes, so the client keeps following the token. Not a bug unless the token never ends; the token ends when the scan reaches the oldest member.
- **"A list I can open on one device is NOT_FOUND on another", or the reverse after a privacy change.** The list doc is cached 60 s per instance (`CACHE_LISTS_ENTRIES`): making a list private or hidden stops serving non-owners within 60 s on every instance (at once on the one that took the write). The owner's graph is cached the same 60 s, so a block is seen within a minute. NOT_FOUND for a reader is one answer for every cause (missing, private, hidden, the owner blocks the reader, owner not ACTIVE, owner blockedBy overflowed): debug by reading the doc and the two graph docs, never by the message.
- **ListUserLists of another owner is NOT_FOUND `profile not found`, or empty.** NOT_FOUND (GetProfile's bytes) when the owner is missing, not ACTIVE, blocks the caller or the caller's blockedBy names them; an empty page when the owner's blockedBy overflowed (ADR-0008 D2, fail closed).
- **Idempotency key reused** (`IDEMPOTENCY_KEY_REUSED`): a client bug (same key, different body, including an unset versus empty field).

## 5. Account deletion and export (W5-5)
Step `lists` (`BeforeIdentity`, after `messaging`, before `identity`; `lists.Eraser`): phase 1 deletes the user's own lists (pages of at most
500), phase 2 removes the uid from every other list that names it (`memberIds array-contains uid`, `ArrayRemove` plus `updatedAt`, a
`LastUpdateTime` precondition, never a `Set`). One page per job call; an account with no lists takes two calls (1 read each, 0 writes).
A **stuck page** is almost always a conflict: the batch found a list changed or gone since its query, wrote nothing, and the next call
re-queries (log `lists_purge` with `conflict=true`). Repeated conflicts on one account mean its lists are being edited continuously; the
job backstop (`docs/runbooks/account-deletion.md`) keeps retrying. Other users' pins of the erased owner's lists dangle as opaque ids by
design. Export section `lists`: the user's own lists with member ids; lists the user is only a member of belong to their owners and are not
exported. Reads: one per own list (minimum 1).

## 6. Rule F4 (members are never told) and member writes (W5-6)
No notification when someone is added. AddListMember / RemoveListMember drop, in the same write, members found in the owner's `blockedBy` (log field `dropped`); a no-op add or remove writes only the idempotency doc and drops nothing. Failure modes: `LIMIT_REACHED limit=list_members` (150, checked after the lazy drop, so a drop can make room); `PROTECTED_ACCOUNT` (target is protected and the owner does not follow it); a block either way, a missing or non-ACTIVE target, and a foreign list are all the same NOT_FOUND `list not found` (no oracle: debug by checking the target in the console, never by the message); `QUOTA_EXCEEDED quota=list_adds` (300/day, 50 new accounts; only real adds are charged). A `lists_lazy_drop_skipped` WARN means the owner's graph read failed during a remove: the removal succeeded, the drop waits for the next write. The block and protected checks read the owner's graph and the target profile from caches (60 s stale), so a block placed within the last minute may not be seen.

## 7. Hiding an abusive public list
Not built yet: `opsctl list hide` / `restore` and the `hidden` flag handling arrive with W5-29. Until then the only lever is the flag.

## 8. Reads (W5-7)
GetList, ListUserLists and ListListMembers share `RATE_LIMIT_LISTS_READ_PER_MIN` (30 per uid per instance, times max-instances 3) and the per-uid daily read budget. Page tokens (`ListUserLists`, `ListListMembers`) are sealed with `CURSOR_HMAC_KEY`, bound to the caller and the list (or owner), valid 24 h; a tampered, expired or foreign token is `VALIDATION page_token` with 0 reads. Members are listed newest added first; the resume rule is `pageresume.Index` over `memberIds`, so an add or a remove between two pages neither repeats nor skips a row. Worst-case reads (interceptor included): GetList 5 non-owner / 2 owner; ListUserLists 24 another owner, 21 own; ListListMembers 25 at page 20 / 55 at page 50 non-owner, 23 / 53 owner. `pinned_by_viewer` is false until W5-9 (SetHomeTabs) supplies the pin check. Deferred: the ADR-0030 D11 per-owner "list set" cache for ListUserLists (the doc cache serves GetList and `Reader` only); it would cut the own-lists call from at most 20 reads to 0-2 warm and changes no budget ceiling.

## 9. The list timeline (W5-8, `TimelineService.GetListTimeline`)
Behind `FEATURE_LISTS` and `FEATURE_POSTS` (both must be on for the caller; `lists.Guard` runs first, 0 reads). Own limiter `RATE_LIMIT_LIST_TIMELINE_PER_MIN` (12 per uid per instance, times max-instances 3), no daily cap, and every call is charged to the per-uid daily read budget. It is Home's pull-merge over the members: the same chunks of 30, the same author-recent cache (a warm Home makes a list cheaper), the same token contract and `removed_ids`. Tokens are bound to the caller and the list (`tl|list|<uid>|<listId>|since|page`): a Home token, another list's token or another caller's is `VALIDATION` with 0 reads. Request line: `timeline_op=list`, `list_members`, `list_authors_dropped` (members removed for this viewer before the query: blocked, muted, blocks the viewer, or not followed when the viewer's `blockedBy` overflowed), plus Home's `timeline_chunks`, `authors_from_cache`, `items_returned`, `items_filtered`, `audience_dropped`, `gap`, `removed_ids`, `fs_reads`. Never an id.
Worst-case reads (interceptor included), `C = ceil(members / 30)` (5 at 150): non-owner `6 + C + 2 * page` (51 at page 20, 111 at page 50), owner `4 + C + 2 * page`, an empty `since` refresh by the owner cold `3 + C`; a `since_token` older than the removal-log cache adds at most 107 (218 worst, under the 269 per-call hold). Writes 0.
- **A pinned tab shows "unavailable" (NOT_FOUND).** The list was deleted, made private or hidden, or its owner blocks the viewer or went inactive; the answer is the same bytes as `GetList` (see section 4). The client offers Unpin. Nothing to repair.
- **UNAVAILABLE (retryable) from a list that works for others.** A member is neither the caller nor followed and the protected-author set could not be refreshed for `PROTECTED_SET_MAX_STALE` (10 min): the call fails closed rather than serve an unfiltered page. Look for `protected_set_reads` errors from `identity.ProtectedAuthors`; it clears on the next successful refresh. Home never hits this because every Home author is followed.
- **A page is shorter than `page_size` while `next_page_token` is set.** Per-viewer drops (muted, blocked, protected) happen after the query, as on Home; the client follows the token.
- **`removed_ids` refresh answers `VALIDATION since_token`.** The removal log cannot answer for this member set (token older than the log keeps, or more than 50 matches): the client cold-opens, as for Home.
- **Cost watch.** A list of 150 members at page 50 is 111 reads; the per-uid daily budget (`ReadBudgetPerUIDPerDay`) is what stops a client that polls it. If `GetListTimeline` becomes a visible share of reads (W5-18 sets the trigger), lower `RATE_LIMIT_LIST_TIMELINE_PER_MIN` first.
`pinned_by_viewer` in the response header is false until W5-9 supplies the pin check, as for `GetList`; the header's `member_count` is net of members who block the owner for every viewer including the owner (`GetList` shows the owner the stored count).
