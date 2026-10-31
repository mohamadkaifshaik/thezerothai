# Runbook: lists (ADR-0030)

Owner module: `backend/internal/lists` (`Service`, `Pins` seams; `lists.Reader` arrives with W5-7). Plan:
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
One line per RPC: `list_op` (`create`, `update`, `delete`), `outcome` (`done`, `replay`, `noop`, `rejected:*`, `contention`), `fs_reads`,
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

## 6. Rule F4 (members are never told)
No notification when someone is added to a list. Members who block the list owner are dropped at read time and removed from storage by the
owner's next write to the list (W5-6, W5-7). A private list reveals nothing to its members.

## 7. Hiding an abusive public list
Not built yet: `opsctl list hide` / `restore` and the `hidden` flag handling arrive with W5-29. Until then the only lever is the flag.
