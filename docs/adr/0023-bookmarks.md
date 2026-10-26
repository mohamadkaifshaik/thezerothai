# 0023. Bookmarks
Status: Accepted (founder, 2026-10-26, by merging PR #305 with every recommended default: Q1 Y thin doc, Q2 B `userLikes.bookmarks[]`, Q3 cap 1,000, Q4 keep the rule-4 idempotency doc)
Date: 2026-10-26
Deciders: architect (proposal); founder accepts by merging. Four founder questions are below.

Plan: `docs/plans/ui-w2-engagement-composer-basics.md` (ticket W2-1; roadmap W2 row; backlog B-30 closed by that plan). That plan's
questions 4-7, which are tagged for the architect, are answered in D9.
Related: ADR-0003 (data model, quotas), ADR-0008 (graph snapshot), ADR-0010 (D5 read budget, D6 visibility matrix,
D14 cursors), ADR-0011 (eraser order, export), ADR-0016 (takedown, `postRemovals`), ADR-0018 (engagement, `userLikes`,
the rule-4 bend precedent).

## Context
On X a user saves a post with the bookmark icon on the card and finds it under History > Bookmarks. The capture is
`docs/x_research/screens/history.md`. The visible action row has no bookmark count. X does compute one, though: an A11Y
label in `screens/explore.md` reads "4262 bookmarks". Search inside bookmarks, "Clear all" and the empty state were not
captured, and none of them is in scope.

Stage 0 (CLAUDE.md): about 300 DAU. Per `docs/reviews/cost-model.md` the product uses 232.3 reads, 32.4 writes and
7.71 deletes per DAU per day. Reads pass the free 50k at about 215 DAU, so every added read is billed. Writes pass the
free 20k at about 617 DAU.

**Fixed by the roadmap and stated here, not reopened:**
- The collection is `users/{uid}/bookmarks/{postId}`.
- The list is paged at 20 (max 50) with an opaque cursor.
- Bookmarks are private to the owner, and client rules stay deny-all.
- Mutations have a per-user daily quota and a rate limit.
- The flag is `FEATURE_BOOKMARKS` (off → allowlist → percent → on).
- There is no bookmark count on posts. A count would be a second write on the post doc, a hot counter on viral posts
  (rule 3), and a public aggregate of private actions.
- The History > Likes tab is W3.

This ADR replaces two of the roadmap's ESTIMATED figures, which were marked as placeholders for the ADR's table:
- "A denormalised post snapshot, so a list page is 20 reads." It does not survive the visibility matrix: a page is
  43 cold reads (D2).
- "A toggle is 1 write plus the idempotency doc." The daily quota and viewer state add to it: Add is 4 writes,
  Remove is 2 writes + 1 delete (D4, D3).

**What the code has today:**
- `engagement` owns `userLikes/{uid}`. One cached read per request hydrates viewer flags through `posts.ViewerFlags`, and
  `userLikes` arrays are exempt from indexing (`firestore.indexes.json:130-131`).
- `posts.Engagement.Viewable` is the GetPost visibility check, 3 reads cold and 0 warm.
- `posts.Reader.GetMany` is cache-first and costs 1 read per miss.
- `graph.Reader.Snapshot` is one cached read covering blocked, blockedBy and muted.
- `cursor.Encode`/`Decode` give caller-bound `(createdAt, id)` tokens.
- `quota.CheckAndReserve` serves `quotas/{uid}`, which holds daily counters only (ADR-0021 I-3).
- The erasers run as `... engagement, reports, scheduled, identity ...`, pinned in `lifecycle_wiring_test.go:217`.

## Options
**(1) Module placement.**
- **A. engagement module, RPCs in `EngagementService` (recommended).** It reuses the visibility seam, the quota and
  rate-limit wiring, and the `userLikes` doc. The doc is the only place where viewer state costs 0 extra reads (D3).
- **B. A new `bookmarks` module and `bookmarks.v1` service.** Ownership is cleaner, but viewer state then needs a second
  per-user doc. That doc is read on every timeline, GetPost and GetThread request: +1 cold read each, cached 60 s, about
  +5 reads/DAU/day. Option B would only be cheaper by writing into engagement's `userLikes`, and one writer per
  collection forbids that. It also means another service, flag check, eraser and wiring.
- Either way the seam is the same: a Go interface (`engagement.Bookmarks`) and an opaque cursor. A later split changes no
  caller.

**(2) What the list shows (snapshot staleness).** A bookmark can be months old. Nothing cheap tells the server that its
post was deleted or taken down:
- `postRemovals` lives for 32 days, caches only the newest 50 and is feed-scoped.
- Author deletes have no log at all.

So a correct list has to read the post. One cache-first `GetMany` per page catches delete, takedown and
`SUSPENDED_AUTHOR`, because the post doc carries `moderation`. The graph snapshot catches blocks and mutes, including a
QUOTE's `EmbeddedAuthor()`.

| | X. Full snapshot, rendered after a GetMany check (roadmap) | **Y. Thin doc, render the live post (recommended)** | Z. Full snapshot, no check, fan-out cleanup |
|---|---|---|---|
| List reads, page 20 / 50 | 43 / 103 cold | 43 / 103 cold | 21 / 51 |
| Shown text, counts, author | frozen copy, never fresher than the live post already read | live | frozen |
| Copies of another user's content | yes: rule 10 needs a COLLECTION_GROUP `postAuthorId` index to erase them | none | yes: the same index plus a `postId` index |
| Post delete / takedown / restore | hidden by the check | hidden by the check | `post_delete` job, opsctl and the posts eraser must find and delete or rewrite every copy: 1 read + 1 write per bookmarker; a restore cannot revive them |
| Gate files | fieldOverride + ack | none | 2 fieldOverrides + ack |
| Bytes per bookmark (doc + automatic indexes) | about 1.5-3 KB unless the map is exempted | about 0.4 KB | about 1.5-3 KB |

Option Y has the same reads as X. It holds none of another user's content, needs no index, and shows live counts.
Option Z saves about 22 reads per page but buys a three-path fan-out and two gate-file indexes. At 3,000 DAU it saves
about INR 25/month (25.2k reads/day). Rejected at Stage 0. Stage ladder below.

A cheaper check was considered and rejected: one `count()` over `__name__ in [page ids]` costs 1 read and detects
deletes. It cannot see `moderation`, because a missing field cannot be queried.

**(3) Viewer state on the card.**
- **A. Client-only.** 0 cost. On a fresh device, or the user's other device, the icon shows "not bookmarked" until the
  Bookmarks tab is opened. Tapping it then re-adds (0 writes).
- **B. `userLikes/{uid}.bookmarks[]` (recommended).** The array holds the complete set (exact because of the D4 cap).
  It is written in the same transaction or batch as the bookmark doc, and `ViewerSet` gains `bookmarked`.
  - Cost: +1 write per toggle and 0 reads, because the `userLikes` read already happens on every feed request when
    FEATURE_ENGAGEMENT is on. With only FEATURE_BOOKMARKS on it costs +1 cold read per request, cached 60 s.
  - Choosing B now avoids backfilling the array from every subcollection later.
  - Needs: one fieldOverride exempting `userLikes.bookmarks` from indexing (gate file). Without it, 1,000 array entries
    would add about 140 KB of index per user.
  - Needs: one additive field, `PostView.bookmarked_by_viewer = 6`, in `posts.proto`. That file is outside this
    change's scope, so the architect adds it after Q2.

## Decision
**D1. Placement.** The engagement module gets three new RPCs in `dzeroth.engagement.v1.EngagementService`:
`AddBookmark`, `RemoveBookmark` and `ListBookmarks`.
- **Not a `bookmarks.v1` package.**
- The code sits behind its own Go interfaces, `engagement.Bookmarks` (service) and `BookmarkRepo`, in its own files.
  It reads posts only through `posts.Engagement.Viewable` and `posts.Reader.GetMany`, and blocks only through
  `graph.Reader.Snapshot`.
- No event is emitted and nothing is published: bookmarks are private. If analytics are ever needed, an `Events`
  method goes on this seam.

**D2. Data model and the list (Option Y).**
- **The doc.** `users/{uid}/bookmarks/{postId}` = `{createdAt}`: the bookmark time, server-set. The doc id is the
  original's id (a REPOST id resolves to its original, as in ADR-0018 D4). It holds no text, media, author or author
  uid.
- **The query.** `orderBy(createdAt DESC, __name__ DESC).Limit(page)`, served by the automatic single-field index, so
  no composite index and no index-file change.
- **The cursor.** `cursor.Encode` binds it to `bookmarks|<uid>` with the 24 h `Decode` TTL.
- **The page.**
  1. Query.
  2. `posts.Reader.GetMany` of the ids, cache-first.
  3. Drop rows by the **ADR-0010 D6 Home column**: the post is missing; `!Visible()` (takedown, suspended author); or
     the author or the QUOTE's embedded author is in the caller's `blocked`, `blockedBy` or `muted`.
  4. Hydrate viewer flags.
  5. Render the live post.
- **Not filtered.** DELETING authors stay until the purge removes their posts, as in Home: 0 extra reads.
- **No caching or staleness tokens.** No instance cache for the list (private, per user) and no since/removed_ids. The
  client replaces page 1 on each open and keeps paging while `next_page_token` is non-empty, because short pages are
  expected.
- **Staleness bound.** A deleted or taken-down post disappears on the next open. A post the instance cached is at most
  60 s stale (CACHE_TTL). Blocks and mutes take up to 60 s across instances (ADR-0008 D8).
- **Lazy prune.** A missing post's bookmark is deleted, together with its `userLikes.bookmarks` entry, in one
  best-effort batch, once. Snowflake ids are never reused, so this is safe. This is the ListBlockedUsers T27 precedent;
  it is skipped under `DEGRADED_MODE=readonly`. Hidden and blocked rows are kept, because a restore or an unblock
  brings them back.
- **Edits.** Nothing edits post text. If an edit feature ships, the list shows it automatically.

**D3. Viewer state: Option B, subject to Q2.** `userLikes.bookmarks[]` is the complete set, at most the cap. Add
writes `ArrayUnion` in its transaction; Remove and the prune write `ArrayRemove` in their batch.
- **Every `userLikes` write stays field-level.** That means `Set` with `MergeAll` plus
  `ArrayUnion`/`ArrayRemove`, as every write in `repo_firestore.go` does today. It also creates the doc when it is
  missing. A whole-doc `Set` without merge, or a trim that rewrites the doc, would silently empty the set: the
  ADR-0021 I-3 class of bug. The existing like and repost trim never touches `bookmarks`.
- **If Q2 = A (client-only), this ADR changes as follows:**
  - Add becomes 3 writes. The cap becomes a soft `count()` with `Limit(cap+1)` outside the transaction, which replaces
    the `userLikes` read, so the reads stay 7 cold.
  - Remove becomes 1 write + 1 delete.
  - The prune writes nothing.
  - The proto comments lose the `userLikes` writes, and there is no `posts.proto` follow-up and no fieldOverride.

**D4. Writes, idempotency, cap and quota.**
- **Add, one transaction.**
  - Before the transaction: Viewable.
  - Fresh reads, in order: first `idempotency/{hash(uid,"AddBookmark",key)}`. A replay returns here, which is why it
    costs 5 cold / 1 warm. Then `quotas/{uid}` and `userLikes/{uid}`, never in one `GetAll` with the idempotency doc.
    The `userLikes` array length is the cap check, so the cap is exact.
  - Writes: `Create` the bookmark, `Create` the idempotency doc, the quota, and `ArrayUnion`.
  - A bookmark that already exists fails with `AlreadyExists` at commit. That answers success with 0 writes, and the
    quota is not charged.
- **Remove, one transaction.** It reads idempotency, then: `Delete(bookmark, Exists)`, `Create` the idempotency doc,
  `ArrayRemove`. A failed `Exists` is the 0-write no-op. There is no visibility check and no quota: removals are bounded
  by what exists.
- **Rule 4 is kept as briefed.** Both mutations store the TTL'd idempotency doc. That also means a late retry can never
  undo a newer toggle, which is the residual risk ADR-0018's bend accepted. Bending it is Q4.
- **Cap.** `BOOKMARKS_MAX_PER_USER` = 1,000, answered with `LIMIT_REACHED` `limit=bookmarks`. The maths is in D7.
- **Daily quota.** `quotas.bookmarks`: `QUOTA_BOOKMARKS_PER_DAY` 200 and `QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY` 50,
  answered with `QUOTA_EXCEEDED` `quota=bookmarks`. The new `quota.Bookmarks` kind ships with its `Record` field and
  its `valueFor`/`increment` cases together (ADR-0021 I-3).
- **Rate limits.** `RATE_LIMIT_BOOKMARKS_PER_MIN` 30, shared by Add and Remove, and `RATE_LIMIT_BOOKMARKS_LIST_PER_MIN`
  10. Both are per instance, so the effective limits are 90/min and 30/min at max 3 instances. Every call is also
  charged to the 2,000-read/day per-uid budget (ADR-0010 D5). ListBookmarks' worst case of 103 reads is under
  `ReadBudgetMaxCallReads` (269).

**D5. Flags.** `FEATURE_BOOKMARKS[_ALLOWLIST|_PERCENT]`, wire name `bookmarks`, default off everywhere, plus
FEATURE_POSTS.
- Add needs the flag on for the caller. List and Remove need it only to be not globally off, the ADR-0021 pattern, so
  a user dropped from the allowlist can still see and remove what they saved.
- `GetMe.enabled_features` lists `bookmarks`.
- Viewer-state hydration runs when `engagement` or `bookmarks` is on for the viewer.
- Cleanup (the eraser, the export, the prune) is never flag-gated.
- Ceiling: allowlist in prod until the founder ramps it, registered in `scripts/promotion/flag-ceiling.json` (a gate
  file).

**D6. Deletion (rule 10).**
- **The owner's account.** A new eraser step, `bookmarks` (`engagement.BookmarkEraser`), is registered after
  `scheduled` and before `identity`.
  - Deleting `users/{uid}` does not cascade to subcollections, so the step is required.
  - The step name is persisted in `deletionJob.step`, so it is appended and never folded into engagement's checkpoint.
  - It pages by `__name__` in pages of ≤ 500, at 1 read + 1 delete per doc (minimum 1 read). An account at the cap
    costs 1,000 reads + 1,000 deletes over 2 invocations.
  - `userLikes` (with its array) is already deleted by the earlier `engagement` step.
  - The T11 row for the `bookmarks` subcollection is `erasedByStep: bookmarks`.
- **The bookmarked post.** When it is deleted, taken down or its author is purged, nothing is fanned out to
  bookmarkers. The list check hides the row, and a deleted post's row is pruned on the owner's next open.
  - Rule 2's "no write fan-out" is about timelines, and `post_delete` already fans out to likes, reposts and quotes
    (ADR-0018 D6). The real reasons are below.
  - The doc holds nothing of the author's, so there is no rule-10 copy to erase.
  - Finding bookmarkers would need a COLLECTION_GROUP index (a gate file, plus index storage on every bookmark) and
    1 read + 1 delete per bookmarker on every delete of a popular post. The lazy path costs that read at most once,
    and only if the owner opens the list.
  - A takedown can be restored. A fan-out would have to rewrite copies twice.
- **The residue** is a doc holding only a post id that resolves to nothing, under the bookmarker's own path, until
  the prune or the bookmarker's deletion. That is narrower than the orphaned likes the founder accepted in ADR-0018:
  no uid of the author.

**D7. Cap maths: 1,000.** Per bookmark: doc name 81 B + `createdAt` 18 B + 32 B overhead = about 131 B, plus 2
automatic index entries (asc and desc) of about 121 B each, so about 0.4 KB.
- **Storage.** An account at the cap holds about 0.4 MB. The shared 1 GiB holds about 2,600 accounts at the cap. Past
  that the cost is $0.104/GiB-month, linear with use and never a step.
- **Expected growth.** About 60 bookmarks/day net at 300 DAU, so about 24 KB/day (about 9 MB/year).
- **Deleting an account at the cap.** 5% of the daily free deletes, 2% of the daily free reads.
- **Export at the cap.** About 70 KB.
- **The `userLikes` doc.** It grows by about 22 KB (worst total about 55 KB, well under 1 MiB). Its size is read on
  every request, which is another reason not to go higher.
- **5,000 instead.** Deleting one account at the cap would use 25% of the daily free deletes, and `userLikes` would
  reach about 130 KB.
- The cap is config, but raising it past 2,000 needs this maths redone (rule 11).

**D8. Export.** A new section, `bookmarks`, is appended after `scheduled` (section names are file keys).
- Shape: `{"bookmarks":[{"postId","bookmarkedAt"}]}`, newest first.
- It never includes the bookmarked post's content, which belongs to another user.
- Reads: 1 per doc, minimum 1, in pages of 500. Size ≤ 70 KB at the cap; the ADR-0011 reference export is about
  0.5 MB.
- The `engagement` section's bytes and its golden file are unchanged.

**D9. The planner's defaults (W2 plan), one line each.**
| # | Planner default | This ADR |
|---|---|---|
| Q4 | Collection-group cleanup query on `postId` (fieldOverride + ack) when a post is deleted, taken down or its author is purged | **Override.** No collection-group query, no index. The list re-reads posts (43 cold reads per page of 20, not 20), prunes deleted rows lazily, and cleans up only on the owner's deletion (D2, D6) |
| Q5 | Viewer "bookmarked" state client-only | **Override, subject to founder Q2.** The plan's alternative was a separate `userBookmarks` doc at +1 read per page. Folding the array into the existing `userLikes` doc costs 0 extra reads when engagement is on, because that read already exists, and the plan ramps bookmarks no further than engagement. It costs +1 write per toggle. Client-only stays the fallback if Q2 = A (D3 lists the deltas). The plan's `BookmarksRepository` seam fits either answer |
| Q6 | List filters blocked and muted authors; counts as of bookmark time | **Agree** on the filter (D6 Home column, both block directions, embedded author too). **Override** on counts: rows render the live post, so counts are current |
| Q7 | 30/min in-memory limit, no quota doc, no per-user cap, toggle = 1 write + idempotency doc | **Override.** Cap 1,000 (D7, founder Q3). The 30/min bucket stays, but an in-memory limit alone allows 30 × 3 × 1,440 = 129,600 adds/day per account. At 4 writes each that is about 518k writes, 26 times the free write quota. ADR-0018 rejected the same for likes. Add = 4 writes (bookmark, idempotency, quota, `userLikes`), Remove = 2 writes + 1 delete |
| pkg | `bookmarks.v1` package, new module | **Override.** `dzeroth.engagement.v1.EngagementService`, engagement module (D1) |

## Cost impact
Per operation, using the ADR-0008 convention: "cold" includes the account-status interceptor's read.
| Operation | Reads cold / warm (planning) | Writes | Deletes |
|---|---|---|---|
| AddBookmark | 7 / 3 (4): interceptor, Viewable 3 (+2 REPOST id, +1 blockedBy overflow), idempotency, quotas, userLikes | 4 | +1 TTL later |
| AddBookmark replay / already bookmarked / at cap / at quota | 5 / 1 replay; 7 / 3 others | 0 | 0 |
| RemoveBookmark | 2 / 1: interceptor, idempotency | 2 (idempotency, userLikes); no-op or replay 0 | 1 + 1 TTL later |
| ListBookmarks, page 20 / 50 | 43 / 103 cold (1 + page + GetMany ≤ page + graph + userLikes); posts warm 1 + page; empty 2 | 0; a page that prunes +1 | 1 per pruned row, once |
| Timelines, GetPost, GetThread viewer state | +0 with engagement on; +1 cold (60 s cache) with only bookmarks on | 0 | 0 |
| Account deletion, `bookmarks` step | 1 per doc (min 1), ≤ 1,000 | 0 | 1 per doc |
| Account export, `bookmarks` section | 1 per doc (min 1) | 0 | 0 |

**Daily budget.** Assumptions per DAU per day: 0.3 Add, 0.1 Remove, 0.3 first-page opens and 0.1 older pages, posts
mostly not cached (planning 42 per page).
- Reads = 0.3×4 + 0.1×2 + 0.4×42 = **18.2 per DAU per day**.
- Writes = 0.3×4 + 0.1×2 = **1.4**.
- Deletes = 0.3 + 0.1×2 = **0.5**.

| At 300 DAU | Result | Share |
|---|---|---|
| Reads | 5,460/day | 10.9% of 50k, all billed (the product is already over at about 215 DAU); +7.8% over the 69.7k baseline |
| Writes | 420/day | 2.1% of 20k |
| Deletes | 150/day | 0.8% |
| Storage | about 24 KB/day | negligible |
| Egress to India | about 8 KB/DAU/day (pages of PostViews), 72 MB/month | billed |

| Quota | Feature alone runs out at | INR/month at 600 DAU (2×) | at 3,000 DAU (10×) |
|---|---|---|---|
| Firestore reads 50k/day | about 2,750 DAU | 10.9 | 54.4 |
| Firestore writes 20k/day | about 14,300 DAU (the product: about 617) | 2.5 | 12.4 |
| Firestore deletes 20k/day | about 40,000 DAU | 0 | 0.5 |
| Egress to India ($0.12/GiB) | never free | 1.5 | 7.7 |
| Storage 1 GiB | worst case about 2,600 accounts at the cap | 0 | 0 |
| Cloud Run 2M requests | about 0.8 calls/DAU/day, not binding | 0 | 0 |
| **Total** | | **≈ INR 15** | **≈ INR 75** |

At 300 DAU the feature costs about INR 6/month: reads INR 5.4 and egress INR 0.8; writes stay inside the free quota.
Prices are the Mumbai list prices (`cost-model.md` §7, INR 95/USD).
- **Fixed monthly cost added: INR 0.** No new GCP resource, topic, Scheduler job or composite index. One fieldOverride
  exemption is needed for Q2 = B. The credit window lifts nothing.
- **Trigger:** none; this is pay-per-use.

## Stage ladder
| Concern | Stage 0 (this ADR) | Seam | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| Saved lists (bookmarks) | Per-user subcollection, thin doc, read-time `GetMany` validation, lazy prune, `userLikes` viewer set | `engagement.Bookmarks` / `BookmarkRepo`; opaque caller-bound cursor; `posts.Reader.GetMany`; `ViewerFlags` | A `bookmarks(uid, post_id, created_at)` table (Cloud SQL), joined with post visibility server-side or cached in Memorystore; or post tombstones on the event bus feeding a cleanup consumer | ListBookmarks > 15% of daily Firestore reads, or the §6 Firestore trigger (> 1.5M reads/day or > $30/month), sustained 7 days |
| Hot spots | Each user's subcollection is its own key range; ≤ 90 writes/min per user | ids opaque to clients | n/a | none at any DAU |
| Counters | none (no bookmark count) | n/a | a count would need an ADR and the rule-3 contention plan | product demand |

## Consequences
- **Positive.**
  - No N+1 (one batched `GetMany`).
  - Live counts.
  - No copy of anyone's content.
  - No new index or fan-out.
  - Takedowns and deletes vanish everywhere on the next open.
- **Negative.**
  - The list costs about twice the roadmap estimate (43 vs 20 cold reads per page).
  - A hidden post costs its read on every open until it is restored or removed.
  - Rows can vanish when the user mutes or blocks the author, and return on undo.
  - The 1,000 cap is lower than heavy X users have.
- **Revisit when:**
  - private accounts ship (the list must apply `VISIBILITY_FOLLOWERS`);
  - the Stage 2 trigger fires;
  - bookmark folders, search inside bookmarks or a count are requested.

## Questions for the founder
| # | Question | Recommended default |
|---|---|---|
| 1 | Bookmark doc shape: Y thin doc rendering the live post (43 reads/page, no copies, no index) vs X roadmap snapshot (same reads, plus a rule-10 erase index) vs Z snapshot with fan-out cleanup (21 reads/page, 2 gate-file indexes, about INR 25/month saved at 3k DAU) | **Y** |
| 2 | Viewer state: B `userLikes.bookmarks[]` (+1 write per toggle, 0 reads, one fieldOverride, `PostView` field 6) vs A client-only (0 cost, stale on other devices) | **B** |
| 3 | Per-user cap: 1,000 (D7) vs 2,000 / 5,000 | **1,000** |
| 4 | Rule 4: keep the stored idempotency doc on Add and Remove (about INR 3.5/month at 3k DAU) vs an ADR-0018-style natural-key bend | **Keep rule 4** (also stops a stale retry from undoing a newer toggle) |

## Handoff
- **architect (after Q2):**
  - `posts.proto` `PostView.bookmarked_by_viewer = 6`;
  - a `firestore-data-model` skill row and operation-cost rows;
  - the fieldOverride `userLikes.bookmarks` (`indexes: []`) plus the `field-overrides.ack` entry (gate files,
    founder review).
- **backend-developer:**
  - `engagement.Bookmarks`, `BookmarkRepo` and the Firestore repo: the Add and Remove transactions (D4) and List
    (D2), with the prune skipped under readonly;
  - `ViewerSet.bookmarked`, plus hydration when either flag is on;
  - `quota.Bookmarks` (kind, `Record` field, `valueFor`/`increment`);
  - config: `FEATURE_BOOKMARKS*`, `QUOTA_*BOOKMARKS_PER_DAY`, `BOOKMARKS_MAX_PER_USER`, `RATE_LIMIT_BOOKMARKS_*`, all
    added to the `config_test.go` env list;
  - the rate-limit mapping in `ratelimit_config.go`;
  - `BookmarkEraser` and the export section, registered after `scheduled`;
  - update `lifecycle_wiring_test.go:217` (both lists);
  - `lifecycle_collections_guard_test.go:321/371/380` uses `"bookmarks"` as its example of an unregistered collection:
    rename that fixture when adding the real T11 row;
  - charge every read to `budget.Counter`;
  - one log line per ListBookmarks with `rows_dropped` by cause (missing, hidden, blocked, muted) and `rows_pruned`,
    with Error Reporting on internal errors;
  - `docs/runbooks/bookmarks.md` (kill switch, prune behaviour, the residue);
  - `make proto` (generation is this ticket).
- **frontend-developer:**
  - the bookmark icon on `PostCard` (flag-gated, optimistic, rollback with a snackbar, "Bookmarked" semantics), sending
    the original id for REPOST rows;
  - the drawer entry and the `/bookmarks` route;
  - the list replaces page 1 on open and follows `next_page_token` through short pages;
  - handle `LIMIT_REACHED bookmarks`, `QUOTA_EXCEEDED bookmarks` and `FEATURE_DISABLED bookmarks`;
  - serialize toggles per post (latest intent wins).
- **production-deployer:** the env vars (default off) and the `flag-ceiling.json` entry (gate file); no new resource.
- **tester:**
  - the D2 drop matrix (deleted, takedown, restore, suspended, DELETING, blocks in both directions, mute, embedded
    author);
  - prune once;
  - replay after Remove;
  - cap and quota;
  - `budgettest` limits 7 / 2 / 43 / 103;
  - eraser and export.
- **sre-performance:** the Cost impact rows into `docs/reviews/cost-model.md` (+18.2 reads, +1.4 writes, +0.5 deletes
  per DAU).
- **security-auditor:**
  - the private-list authz (the path comes from the token uid, the cursor is caller-bound);
  - Add is no new block oracle (the GetPost NOT_FOUND bytes);
  - the abuse arithmetic in D4.
