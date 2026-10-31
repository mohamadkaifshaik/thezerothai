# 0030. Lists and custom Home tabs at Stage 0 (W5 Part A)
Status: Accepted (founder, 2026-10-30: Part A defaults F2, F3, F4, F5, F10 and F13 for lists as written, plus the architect's calls: idempotency record on every mutation, PROTECTED_ACCOUNT on adding an unfollowed protected account, one NOT_FOUND for hidden lists)
Date: 2026-10-30
Deciders: architect (proposal); the founder accepts by merging the PR. The Part A founder questions (F2, F3, F4, F5,
F10 for lists, F13 for lists) were not answered, so **each is decided by the plan's default and the founder may
override any of them at acceptance** (table below). No default bends a `CLAUDE.md` non-negotiable rule or adds a fixed
cost.

Plan: `docs/plans/ui-w5-lists-communities.md`, tickets W5-1 (this ADR) and W5-2 (`proto/dzeroth/lists/v1/lists.proto`
new; `common.proto` `HomeTab`; `timeline.proto` `GetListTimeline` and `SetHomeTabs`; `identity.proto`
`GetMeResponse.home_tabs`), one PR. The plan asked for "ADR-0027 (or the next free number)". 0026 to 0029 went to W8,
W7, W4 and W6, so this is **0030**. Part B (Communities, W5-20) is not decided here and takes the next free number
when it is written.

Related ADRs:
- ADR-0002: modules talk only through Go interfaces. ADR-0003: data model, Snowflake ids, idempotency documents.
- ADR-0004 and ADR-0010: pull-on-read, D5 (per-uid read budget, `ReadBudgetMaxCallReads` 269), D6 (feed filtering),
  D9 (text rules), D13 and D14 (sealed, bound, settle-windowed tokens), D15 (author-recent cache).
- ADR-0008: D2 (`blockedBy` overflow fails closed), D6 (flags are env vars), D9 (no block oracle).
- ADR-0011: T11 lifecycle guard, eraser steps, export sections.
- ADR-0016: D10 removal log and `removed_ids`, the window query for feeds of at most 180 authors.
- ADR-0023: the rule-4 idempotency document kept for toggles (founder Q4), and the late-retry hazard it closes.
- ADR-0025: protected authors, `posts.Audience`; its D4 matrix row "W5 lists" is answered by D4 below.
- ADR-0022: credit mode. **Nothing here depends on a credit-mode item.**
- ADR-0029: the current cost baseline.

## Context
Home is chronological Following only (founder, 2026-10-22). Lists let a user read a topic or a circle without
following everyone in it, and custom Home tabs let them pin those feeds next to Following. `CLAUDE.md` fixes the Stage 0
means: pull-on-read with a `since` cursor (rule 2), no write fan-out, instance and client caches, opaque cursors and a
`Limit` on every query (rule 5), idempotency on every mutation (rule 4), no fixed cost.

**Cost baseline (ADR-0029, on `docs/reviews/cost-model.md` §5 and §7, 2026-10-29 block plus W4 and W6):** 358.65 reads, 40.58
writes, 8.82 deletes per DAU per day; 1,759 Cloud Run requests and 176.2 vCPU-s per DAU-month. Free reads run out at
about **139 DAU**, writes at about 493, deletes at about 2,268, requests at about 1,137 and vCPU-s at about 1,021 DAU.
The Stage 0 bill is about **INR 547 / 1,811 / 4,822** a month at 300 / 1,000 / 3,000 DAU.

**What changed since the plan was written (plan "What exists already", `main` d2ff011).** Each changes this ADR:
1. **Private accounts shipped (ADR-0025).** The plan's A10 asked for a "hook". It is no longer a hook: the list feed
   calls the same `posts.Audience` filter Home calls (`timeline.newAudienceFilter`), and unlike Home it can drop rows,
   because a list can name a protected account the viewer does not follow. ADR-0025 D4 left "adding a protected
   account to a list" to this ADR (D4).
2. **The baseline moved.** The plan priced W5 on the W2-only baseline (248.7 reads per DAU, free reads out at about
   201 DAU, INR 441 at 300 DAU). Every crossover below is re-priced on ADR-0029's numbers.
3. **Rule 4 is applied to every mutation.** The plan's sketch gave `idempotency_key` to CreateList only and treated
   Add and Remove as "state-setting, replay 0 writes". ADR-0023 (founder Q4) and the ADR-0027 note of 2026-10-29
   treat a key that is not stored as a rule-4 bend, and a late retry of Add after a Remove would re-add the member. D7
   stores the standard idempotency document on all six mutations; at these call rates that costs about INR 4 a month
   at 3,000 DAU.
4. **`List` cannot be a message name.** Generated Dart would shadow `dart:core` `List` in every file that imports it.
   The header message is `ListInfo`.
5. **`memberCount` is dropped.** The list doc is read in every mutation's transaction, so the count is
   `len(memberIds)`: no counter, no rule-3 hot-doc question, nothing to drift.
6. **Plan text that is stale:** "W4 holds 0026" (0026 is the W8 shells ADR; W4 is 0028), the `.claude/skills` rows
   "in the same PR" (agents do not edit `.claude/` here; they are follow-ups FU-2, FU-3), and the `quotas` fields
   (W5-3 adds them with their `Record` cases, ADR-0021 I-3).

## Founder decisions (Part A)
INR are per month, the Part A increment over ADR-0029's baseline (`cost-model.md` §5 totals, §7 prices), at 300 / 1,000 / 3,000
DAU (Cost impact). "Default"
= applied by this ADR; **decided by default; the founder may override at acceptance.**

| # | Question | Options | Decision | INR 300 / 1,000 / 3,000 |
|---|---|---|---|---|
| F2 | Members per list (`LIST_MAX_MEMBERS`) | 150 (5 chunks); 500 (17); 5,000 (X, 167 chunks) | **150, default.** Raising it later is a config change and safe; lowering would strand larger lists | 150: in the totals. 500: about +3 reads per DAU if the average list grows from 40 to 100 members, **+0.9 / +3.0 / +9.1**. 5,000: refused, 272 reads at page 50 > the 269 per-call hold |
| F3 | Lists per user, default visibility | 20 private; 20 public (X); 1,000 (X's cap) | **At most 20 per owner, created private, default.** `CreateListRequest.is_private` absent = private, so an old or careless client fails closed | 0 for every option (the cap check is one `count()`; the visibility is a field) |
| F4 | Being added to a list | no notification; a notification | **No notification, default.** Block rules in D4 | none: 0. A notification: about +0.4 reads and +0.2 writes per DAU, **+0.1 / +1.0 / +3.0**, plus a harassment vector |
| F5 | Custom Home tabs | Following + up to 5 pinned, synced on `users/{uid}`; synced in a `homeTabs/{uid}` doc; on the device only | **Following first and fixed, then up to 5 pinned tabs synced on `users/{uid}.homeTabs`, returned by GetMe at 0 reads, default** | `users` field: about 0.02 / 0.1 / 0.5 (in the totals). Own doc: +2 reads per DAU and an eraser step, **+0.6 / +2.0 / +6.1**. Device only: 0, no sync |
| F10 (lists part) | List discovery | none; "Discover new Lists"; list following with counts | **None, default.** Pinning someone's public list to Home is how you follow it; you reach it from their profile ("Lists") | 0 |
| F13 (lists part) | List images | flat default tile; uploaded banner | **Default tile, no image, default** (`lists.md` §3) | 0. A banner: about 0.6 Vision units per DAU-month, **+26 / 0 / 0** (past 1,000 DAU the Vision cap is already reached, so it displaces other screening instead) |

Part B questions (F1, F6 to F9, F11, F12, and the community halves of F10 and F13) are for the Part B ADR.

## Options
### A. Where a list's members live (plan A5)
- **(a) `memberIds[]` on `lists/{listId}` (chosen).** One read gives the whole list: the timeline's author set, the
  member page, the cap check and `contains`. 150 uids of 28 characters are about 4.2 KB (19 KB at the 128-character
  uid maximum), far under 1 MiB, and 150 array index entries, far under 40,000.
- (b) `lists/{listId}/members/{uid}`: the timeline would read up to 150 docs (or keep a copy anyway), the cap needs a
  `count()`, and the eraser a collection-group query. +C reads on every cold timeline for nothing at a cap of 150.

### B. How the list timeline is built (plan W5-8)
- **(a) Home's pull-merge over the members (chosen).** `homeSources`, `Merge`, the author-recent cache, the token codec
  and `removedIDs` are reused unchanged; only a `listFeed` binding is new. A list refresh costs one read per 30
  members even when nothing is new, which is what bounds the member cap (F2).
- (b) Write fan-out into a per-list feed: breaks rule 2 and pays a write per post per list.
- (c) Query `authorId in members` without the shared cache: the same reads cold, worse warm.

### C. Where pinned tabs live (plan A4, F5)
- **(a) `users/{uid}.homeTabs` (chosen):** GetMe already reads the doc, so the tabs cost 0 reads; it goes with the
  account at erasure. Written through a consumer-side `timeline.HomeTabsStore` that identity implements, so timeline
  never touches `users` itself and the storage can move without changing a caller.
- (b) `homeTabs/{uid}`: +1 read per GetMe miss and one more eraser step and export section.
- (c) Device only: no sync across devices; no proto change.

### D. Idempotency for the five state-setting mutations
- **(a) The standard idempotency document on every mutation (chosen):** rule 4 as written. +1 read, +1 write and +1 TTL
  delete per call; about +0.3 of each per DAU a day.
- (b) Validate the key and do not store it (the ADR-0008 graph and ADR-0027 Accept precedent): 0 extra cost, but a
  **bend of rule 4** that the founder would have to accept, and a late retry of Add after a Remove re-adds the member.
- (c) A ring of key digests on the list doc (the ADR-0027 DeleteConversation idea): +0 cost, but SetHomeTabs would
  need a second ring on `users`, and the shape is new code to test for a saving of about INR 4 a month.

## Decision
**D1. A new `lists` module** (`backend/internal/lists`) owns `lists/{listId}` and `dzeroth.lists.v1.ListService`.
Other modules read lists only through **`lists.Reader`**:
- `Get(ctx, viewer, listID) (ListView, error)`: the visibility rules of D3 applied; NOT_FOUND as one sentinel.
- `Members(ctx, viewer, listID) (ListMembers, error)`: the member uids after the D4 owner-level drop (members who block
  the owner), plus the owner id and the header; per-viewer drops are the caller's job, as on Home.
- `OwnedBy(ctx, uid)`: the caller's own lists (for SetHomeTabs titles).

`lists` depends on `identity` (`Directory`), `graph` (`Reader.Snapshot`) and the platform packages, and declares its
own consumer-side **`lists.Pins`** (`Unpin(ctx, uid, listID)`, `Retitle(ctx, uid, listID, name)`) for DeleteList and a
pinned rename. `timeline` gains a dependency on `lists.Reader`. No cycle: `lists` never imports `timeline` or `posts`;
one identity adapter over `users/{uid}.homeTabs` satisfies both `lists.Pins` and `timeline.HomeTabsStore` (D6), and
`apiserver` wires it into both modules. Both interfaces use only identity's own tab type (`identity.HomeTab`) or
built-in types in their signatures, never a `timeline` or `lists` type, so identity imports neither.

**D2. Data model: `lists/{listId}`** (Snowflake id, rule 1):
| Field | Type | Notes |
|---|---|---|
| `ownerId` | string | equality queries: the owner's lists, the cap `count()`, the eraser |
| `name` | string | 1-25 code points after NFC and trim, single line, bio rules (ADR-0010 D9) |
| `description` | string | 0-100 code points, same rules |
| `isPrivate` | bool | created true unless the request sends false (F3) |
| `memberIds` | array of uid | ≤ `LIST_MAX_MEMBERS` (150), add order. **Not index-exempt**: the eraser's `memberIds array-contains uid` query needs the automatic array index |
| `hidden` | bool, absent = false | platform hide (opsctl, W5-29); a hidden list is NOT_FOUND to non-owners |
| `createdAt`, `updatedAt` | timestamp | |

- **No composite index and no fieldOverride are required.** Every query is an equality on one field with the
  implicit `__name__` order (the automatic single-field indexes): `ownerId == uid` (list page, `count()`, eraser) and
  `memberIds array-contains uid` (eraser), each with a `Limit`. The emulator never requires an index, so W5-19's dev
  smoke is the first proof on real Firestore; a "requires an index" error there means stop and ask.
- **Doc size:** ≤ about 19 KB at 150 members of 128 characters, about 4.5 KB typical. Index entries ≤ about 160.
- **IDs and hot spots:** list creation is capped at 10 per user per day, so the collection is nowhere near the
  500 writes/s ramp limit for time-ordered ids at any Stage 0-3 DAU. A list doc has one writer (its owner); the write
  bucket (30/min per instance, 1.5/s at 3 instances) is the only way to exceed 1 write/s on it. Contention signal:
  `ABORTED` or `txn_attempts > 3` on a list transaction (`list_txn_attempts` on the request line). Fallback: lower
  `RATE_LIMIT_LISTS_WRITE_PER_MIN`; there is no counter to shard.
- **`users/{uid}.homeTabs`** (identity owns the doc; written only through identity's adapter behind `timeline.HomeTabsStore` and `lists.Pins`): an array of at
  most 5 maps `{kind, id, title}`. `title` is stored only for the caller's own lists (D6). Absent = no pins. No
  backfill. It is not in `AuthorSnapshot`, so no snapshot job.
- **`quotas/{uid}`** gains `listCreates` and `listAdds` (daily, with their `Record` `valueFor`/`increment` cases in the
  same PR, ADR-0021 I-3; W5-3).

**D3. Who sees a list (F3).** A list is created private unless the request sends `is_private = false`. To a caller
other than the owner, **one byte-identical NOT_FOUND** answers: a missing id; a private list; a hidden list; a list
whose owner blocks the caller (the caller's own `blockedBy`, 0 reads); a list whose owner is not ACTIVE; a list whose
owner's `blockedBy` overflowed (ADR-0008 D2, fail closed: D4's owner-level drop cannot be trusted). The owner always
sees their own lists. Ids are guessable Snowflakes, so a guess costs the guesser's read budget and learns nothing.

**D4. Member rules (F4, ADR-0025 D4).**
- **Adding:** owner only. The target must exist and be ACTIVE (`identity.Directory`). A target who blocks the owner or
  whom the owner blocks answers NOT_FOUND, byte-identical to a missing user (ADR-0008 D9: no block oracle); the owner's
  `blockedBy` overflow adds one read of the target's graph (fail closed, as Follow). **A protected target the owner
  does not follow answers FAILED_PRECONDITION + `PROTECTED_ACCOUNT`** (ADR-0025 D4, "adding P to a list needs A to be
  approved"); `is_private` is already public on GetProfile, so this reveals nothing new. Adding yourself is allowed.
- **No notification** to the member (F4). Members are never told, so a private list reveals nothing to them.
- **At read time, for every viewer:** members who block the owner are dropped (the owner's graph, read for non-owner
  viewers, cached 60 s). **For each viewer:** members the viewer blocks or mutes, or who block the viewer, are dropped
  (`allowedAuthor`, ADR-0010 D6); a viewer whose `blockedBy` overflowed keeps only their own posts and members they
  follow (fail closed, the W4 rule); a protected member's rows are dropped unless that member approved the viewer, and
  REPOST and QUOTE rows follow Home's embed rules (`posts.Audience.Decide` through `newAudienceFilter`).
- **Lazy drop:** the owner's next Add or Remove on that list also removes, in the same write, members found in the
  owner's `blockedBy` (0 extra reads). A member who later stops being approved (P unfollowed by the owner) stays a
  member; P's rows are filtered at read time.

**D5. The list timeline (`TimelineService.GetListTimeline`).** In a new `backend/internal/timeline/service_list.go`:
`lists.Reader.Members` → authors minus `allowedAuthor` drops → `removedIDs(ctx, tok, authors)` (scoped to the members;
a list has ≤ 180 authors, so the ADR-0016 window query always applies) → `homeSources(ctx, authors, tok, limit, start)`
→ `Merge` with Home's `keep` (own posts, `allowedAuthor`, `embedAllowed`, `newAudienceFilter`) → `toViews` → `tokens(
listFeed(uid, listID), ...)`. `tokens.go` gains `listFeed`: bindings `tl|list|<uid>|<listId>|since` and `...|page`
(a Home or user token on a list, a list token on another list or for another caller: VALIDATION, 0 reads). Same
30-day token TTL, settle window, gap token and `removed_ids` contract as Home. The header (`ListInfo`) rides on every
response at 0 extra reads. **No new merge, cursor or cache.**
- Unlike Home, the protected-set loader can be consulted (an author who is neither the viewer nor followed). Its refresh
  is detached (`protected_set_reads`, +0 to the caller), and the ADR-0025 D3 fail-closed rule applies: no set younger
  than `PROTECTED_SET_MAX_STALE` → UNAVAILABLE, never an unfiltered page.
- **Read ceiling:** fixed reads for a non-owner are 6 (interceptor, list, caller graph, owner graph, owner profile,
  `userLikes`); the owner 4. C = ceil(members / 30) ≤ 5.

| Member cap | C | Empty `since`, owner, cold (3 + C) | Page 20 worst (6 + C + 40) | Page 50 worst (6 + C + 100) | + removal-log window (107) |
|---|---|---|---|---|---|
| **150 (F2)** | **5** | **8** | **51** | **111** | **218 ≤ 269** |
| 500 | 17 | 20 | 63 | 123 | n/a (> 180 authors: a too-old token is rejected) |
| 5,000 (X) | 167 | 170 | 213 | **273 > 269** | n/a |

**D6. Custom Home tabs (F5).** Following is first, fixed and never stored. After it, up to `HOME_TABS_MAX_PINNED` (5)
`HomeTab {kind, id, title}` in the user's order (`HomeTabKind` LIST; COMMUNITY reserved for Part B and refused until
it ships).
- **`SetHomeTabs(idempotency_key, tabs)`** in timeline replaces the order. A tab not already stored must be a list the
  caller may read now (D3), else VALIDATION `tabs` (one answer for every cause); a tab already stored is kept without a
  re-read, so an unavailable tab can still be moved or removed. LIST tabs need `lists` on for the caller; an empty
  list is always accepted. Stored tabs of a kind whose flag is off for the caller are kept after the sent ones and
  count toward the cap.
- **Storage:** one transaction in identity behind **`timeline.HomeTabsStore`** (`Replace(ctx, uid, key, requestHash,
  next func(current []identity.HomeTab) ([]identity.HomeTab, error)) ([]identity.HomeTab, error)`): reads the idempotency doc and `users/{uid}`
  fresh, writes `homeTabs` field-level (no other field) and the idempotency doc. List validation runs before the
  transaction (cache-first reads), never inside it. The writing instance's profile cache is updated in place.
- **GetMe `home_tabs`** comes from the doc GetMe already reads: **+0 reads**. Tabs of a kind whose flag is off for the
  caller are omitted. A dangling tab (list deleted or made private) is returned; the client learns it from
  GetListTimeline's NOT_FOUND and offers Unpin.
- **Titles and rule 10:** `title` is stored **only for the caller's own lists** (copied at pin time and refreshed by the
  owner's own UpdateList in the same call when the list is pinned, +1 read only when pinned) and is `""` for another
  user's list. So no other user's text is ever copied onto `users/{uid}`, and erasing a list owner leaves only an
  opaque list id in other users' tabs, which their next GetListTimeline answers NOT_FOUND. The client labels a tab from
  the newest `ListInfo` header it holds and calls GetList once for a tab it has no label for (a new device).
- DeleteList removes the caller's own pin of that list in the same call (+1 read, +1 write, only when pinned), and the
  owner's rename of a pinned list refreshes its title, both through `lists.Pins` (D1), never by importing timeline.
  Other users' pins dangle as above.

**D7. Idempotency (rule 4, Option D a).** All six mutations (CreateList, UpdateList, DeleteList, AddListMember,
RemoveListMember, SetHomeTabs) take `idempotency_key` and store the standard `idempotency/{sha256(uid|rpc|key)}`
document (`pkg/platform/idempotency`, 24 h TTL) in the same transaction as their effect. A replay returns the stored
outcome with 0 writes; the same key with another body is `IDEMPOTENCY_KEY_REUSED`. A mutation that changes nothing
still stores the document (1 write), as ADR-0023's W2-3 note, so a late retry can never undo a newer change.
**This keeps rule 4 as written: no bend.** DeleteList of a list the caller does not own, or of a missing list, is
success with no effect (the DeletePost precedent), and still stores the document.

**D8. Lifecycle (rule 10, ADR-0011).**
- **Eraser step `lists`**, `BeforeIdentity`, appended after the last step that exists when W5-5 merges (today
  `messaging`), resumable, pages of ≤ 500, never flag-gated: (1) delete the user's own lists (`ownerId == uid`); (2)
  remove the uid from other lists (`memberIds array-contains uid`: `ArrayRemove` + `updatedAt`, `LastUpdateTime`
  precondition, never `Set`). Other users' pins of the erased user's lists dangle as opaque ids (D6). `homeTabs` goes
  with `users/{uid}`.
- **Export section `lists`:** the user's own lists with name, description, `isPrivate` and member ids. `home_tabs`
  joins the profile section. Lists the user is a member of are not exported (they belong to their owners and are never
  shown to the member).
- **T11:** a `lists` row in `lifecycle_collections_guard_test.go`, residue-sweep fields `ownerId` and `memberIds`, and
  the step and section in `lifecycle_wiring_test.go`. The first PR that names the collection registers both (W5-4 with
  W5-5).

**D9. Flag `FEATURE_LISTS`** (wire name `lists`, default off): every `ListService` RPC, GetListTimeline, LIST entries in
SetHomeTabs and GetMe `home_tabs`; the client's Lists screens, drawer row, "Add to Lists" and list tabs. FEATURE_DISABLED
`feature=lists` at 0 reads. Dev ceiling `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`; prod none (held,
ADR-0019). `posts` stays required for the timeline, `removed_ids` gates `removed_ids` as on Home.

**D10. Caps, quotas and rate limits (rule 11, config validated > 0 at startup).** In-memory limits are per instance;
the effective limit is × 3 instances.

| Config | Default | Effective | Notes |
|---|---|---|---|
| `LISTS_MAX_PER_USER` | 20 | exact | `count()` in the CreateList transaction |
| `LIST_MAX_MEMBERS` | 150 | exact | F2; the list doc in the transaction |
| `HOME_TABS_MAX_PINNED` | 5 | exact | F5 |
| `QUOTA_LIST_CREATES_PER_DAY` | 10 (new accounts 3) | exact | `quotas.listCreates` |
| `QUOTA_LIST_ADDS_PER_DAY` | 300 (new accounts 50) | exact | `quotas.listAdds`; Remove has no quota |
| `LIST_MUTATIONS_PER_DAY` | 500 | 1,500 | `list_mutation_daily` `DailyCap` over all six mutations: without it 30/min × 3 × 1,440 UpdateList calls a day would be about 260k writes |
| `RATE_LIMIT_LISTS_WRITE_PER_MIN` | 30 | 90 | the six mutations |
| `RATE_LIMIT_LISTS_READ_PER_MIN` | 30 | 90 | GetList, ListUserLists, ListListMembers |
| `RATE_LIMIT_LIST_TIMELINE_PER_MIN` | 12 | 36 | tabs switch quickly; Home stays 6 |
| `CACHE_LISTS_ENTRIES` | 2,000 | per instance | list docs, 60 s TTL; ≤ about 8 KB each in memory, so ≤ about 16 MB. The plan's 5,000 would be about 40 MB of a 512 MiB instance for no measured gain |
| Read budget (ADR-0010 D5) | 2,000 reads/uid/day per instance | 6,000 | binds the read side first |

**D11. Caches and staleness (plan A9).**
| Cached read | Bound |
|---|---|
| List doc (members, name, visibility, hidden), per instance | 60 s. A write updates the writing instance at once; others within 60 s. A list made private or hidden stops serving non-owners within 60 s |
| The owner's lists (ListUserLists), per instance | 60 s; the owner's writes update the writing instance's copy |
| Owner graph snapshot (F4, D3), per instance | 60 s (the existing graph cache) |
| Author-recent entries | shared with Home, 60 s (ADR-0010 D15); filtered per viewer after the cache |
| Home tabs | GetMe through the 60 s profile cache; SetHomeTabs updates the writing instance; other devices see the new order at the next GetMe, within 60 s |
| Client | list feeds persist in drift like Home (`FeedKey.list(id)`, `since` refreshes, the new-posts pill, ≥ 60 s auto-refresh, `removed_ids`); list pages and member pages are session memory |

All caches sit behind the existing `cache.LRU` and module interfaces, so Memorystore can replace them by ADR.

**D12. Observability.** Request-line fields, counts and enums only, never ids, names or descriptions:
`timeline_op=list`, `list_members`, `timeline_chunks`, `authors_from_cache`, `items_returned`, `items_filtered`,
`audience_dropped`, `gap`, `fs_reads`; `list_op` (create, update, delete, add, remove, get, user_lists, members,
set_home_tabs), `outcome`, `fs_writes`, `rows_dropped` by cause (`blocked`, `muted`, `blocks_owner`, `inactive`,
`protected`), `list_txn_attempts`, `cache_hit`. Error Reporting on internal errors. No new log-based metric or alert
policy.

## Cost impact
- **Fixed monthly cost added: INR 0.** No new GCP service, Scheduler job, Pub/Sub topic, TTL policy (the idempotency
  TTL exists), composite index or fieldOverride. Nothing depends on ADR-0022.
- **Storage:** about 4.5 KB per list; at 20 % of DAU owning 2 lists, about 2 MB at 1,000 DAU. Inside the free 1 GiB.
- **Vision units:** 0 (F13). **GCS:** no new objects.

**Per RPC** (worst reads include the account-status interceptor; every call is charged to the ADR-0010 D5 per-uid
budget and stays under `ReadBudgetMaxCallReads` 269):
| RPC | Reads worst (cold) | Reads typical | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| CreateList | 4 (interceptor, idempotency, quotas, `count()`) | 3 | 3 (list, idempotency, quotas) | 1 TTL later | replay 3 (interceptor, idempotency, the list; was 2 before W5-45) / 0 writes; cap or quota 0 writes |
| UpdateList | 3 (+1 users when pinned, title refresh) | 2 | 2 (1 when unchanged; +1 when pinned and renamed) | 1 TTL | owner only; replay 3 (+1 list read, W5-45), 0 writes |
| DeleteList | 3 (+1 users when pinned) | 3 | 1 (+1 when pinned) | 1 (list) + 1 TTL | non-owner or missing: success, 1 write |
| AddListMember | 7 (interceptor, caller graph, target profile, idempotency, list, target `users` fresh in the txn, quotas; +1 target graph on overflow) | 5 | 3 (list, quotas, idempotency); already a member 1 | 1 TTL | refused 0 writes; replay 5 (+1 list read), a real add refused by cap, quota or a non-ACTIVE target has paid the fresh read (W5-45) |
| RemoveListMember | 3 | 2 | 2; not a member 1 | 1 TTL | no quota; replay 3 (+1 list read, W5-45) |
| GetList | 5 non-owner (interceptor, list, caller graph, owner profile, owner graph); 2 owner | 0–1 | 0 | 0 | |
| ListUserLists | 24 another owner (interceptor, caller graph, owner profile, owner graph, ≤ 20 lists); 21 own | 4 | 0 | 0 | `contains` from `memberIds`, 0 reads |
| ListListMembers, page 20 / 50 | 25 / 55 | 2 + misses | 0 | 0 | sealed 24 h token; `likesResume` over `memberIds` |
| GetListTimeline | 51 at page 20, 111 at page 50; 218 with the window query | refresh 4 + new; cold 30 | 0 | 0 | D5 table |
| SetHomeTabs | 19 (interceptor, idempotency, users, ≤ 5 lists, caller graph, ≤ 5 owner profiles and graphs) | 4 | 2 (users field-level, idempotency); unchanged 1 | 1 TTL | |
| GetMe `home_tabs` | +0 | +0 | 0 | 0 | |
| Eraser step `lists` | 1 per doc (min 2) | | 1 per list the user is on | 1 per own list | |
| Export section `lists` | 1 per own list (min 1) | | 0 | 0 | |

**Per DAU per day** (the plan's assumptions: 30 % of DAU have a pinned list of about 40 members, refreshed 4 times and
opened once a day, about 12 new list posts a day; W5-18 replaces them with measurements):
| Call | Calls/DAU | Typical reads | Reads/DAU | Writes/DAU | Deletes/DAU |
|---|---|---|---|---|---|
| GetListTimeline refresh | 1.2 | 4 + new (3.6 new in total) | 8.4 | 0 | 0 |
| GetListTimeline cold open or older page | 0.3 | 30 | 9.0 | 0 | 0 |
| GetList | 0.1 | 4 | 0.4 | 0 | 0 |
| ListListMembers | 0.1 | 24 | 2.4 | 0 | 0 |
| ListUserLists | 0.3 | 4 | 1.2 | 0 | 0 |
| AddListMember / RemoveListMember | 0.2 / 0.05 | 4 / 2 | 0.9 | 0.70 | 0.25 |
| CreateList / UpdateList / DeleteList | 0.01 / 0.01 / 0.002 | 3 / 2 / 3 | 0.06 | 0.05 | 0.02 |
| SetHomeTabs | 0.02 | 3 | 0.06 | 0.04 | 0.02 |
| **Part A total** | **≈ 2.3 requests** | | **≈ 22.4** | **≈ 0.79** | **≈ 0.29** |

D7's idempotency documents are inside these numbers: +0.28 reads, +0.28 writes and +0.28 TTL deletes per DAU over the
plan's state-setting design, about INR 0.1 / 1.1 / 3.6 a month.

**Free quotas that move** (whole product with Part A on for every DAU):
| Quota | Runs out at (was) | Part A increment at 2× that DAU | at 10× |
|---|---|---|---|
| Firestore reads 50k/day (381.07 per DAU) | **≈ 131 DAU** (139) | 262 DAU: INR 6.0 | 1,312 DAU: INR 30 |
| Firestore writes 20k/day (41.37 per DAU) | ≈ 483 DAU (493) | 967 DAU: INR 2.3 | 4,834 DAU: INR 12 |
| Firestore deletes 20k/day (9.11 per DAU) | ≈ 2,194 DAU (2,268) | 4,389 DAU: INR 0.5 | 21,944 DAU: INR 2.2 |
| Cloud Run requests 2M/month (1,829 per DAU-month) | ≈ 1,094 DAU (1,137) | 2,187 DAU: INR 5.8 | 10,937 DAU: INR 29 |
| Cloud Run vCPU-s 180k/month (183.2 per DAU-month at 0.1 s a request) | ≈ 983 DAU (1,021) | 1,965 DAU: INR 31 | 9,827 DAU: INR 156 |

**INR per month (Part A increment; Mumbai prices of `cost-model.md` §7: $0.035 / $0.104 / $0.012 per 100k reads /
writes / deletes, $0.40 per million requests, $0.000024 per vCPU-s, egress to India $0.12/GiB, INR 95 per USD; each line
priced at the margin, so a quota the product already exhausts bills Part A in full):**
| Line | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (all billed: the product is past the free reads) | 6.8 | 22.7 | 68.0 |
| Firestore writes (billed past about 483 DAU) and deletes (past about 2,194) | 0 | 2.4 | 7.5 |
| Cloud Run requests (+69.7 per DAU-month) and vCPU-s (+7.0 per DAU-month) | 0 | 7.2 (the product passes the free vCPU-s at about 983 DAU) | 55.6 |
| Egress to India, API JSON (about 18.7 KB per DAU a day) | 1.9 | 6.2 | 18.5 |
| **Part A total** | **≈ 9** | **≈ 39** | **≈ 150** |
| Upper bound: list image views additive to Home (+10 % of image GETs) | 9 | 39 (still inside the free 100 GB) | ≈ 342 (+16.8 GiB GCS egress, INR 192; list browsing mostly **replaces** Home browsing, so this is a ceiling, not a forecast) |
| **Stage 0 bill with Part A** | 547 → **≈ 556** | 1,811 → **≈ 1,850** | 4,822 → **≈ 4,972** |

- **Verdict: the budget holds in the sense `CLAUDE.md` sets for Stage 0.** No fixed fee and no step change; Part A adds
  about 1.6 % / 2.2 % / 3.1 % to the bill, and every RPC stays under the 269-read per-call hold (worst 218). The free
  reads were already past at the Stage 0 target (300 DAU) before Part A; it moves that crossover from about 139 to
  about 131 DAU and the free vCPU-s crossover from about 1,021 to about 983 DAU, which is why the 1,000 DAU column
  gains a small Cloud Run line.
- **Trigger share:** list feeds are about 17.4 of 381.07 reads per DAU (4.6 %), far under the 15 % trigger.
- **Abuse as cost (per account per day, worst):** writes are bounded by `list_mutation_daily` (1,500 calls × ≤ 3
  writes, about 4,500 writes, INR 0.44) and the exact `list_adds` quota (300 adds); reads by the read budget (6,000
  reads, INR 0.2); a public list is a ready-made "these 150 authors" query, but it reads only what Home reads for a
  user following them, under the same per-uid budget and the 36/min effective bucket.
- **Credit window (ADR-0022):** nothing here uses a credit-mode item; the lines above are the same with or without it.
- **Trigger that justifies it:** none (no fixed cost). The scale-up triggers are in the Stage ladder.


**Implementation note 2026-10-31 (W5-45, W5-47; the W5-17 Low findings and the W5-18 `LIST_MAX_MEMBERS` bound).**
- **L-1 negative cache.** `loadList` remembers a missing list id for 60 s in a second LRU of the same size (`docCache.miss`),
  so a repeat probe of a guessed id costs 0 reads and answers as fast as a cached private list. Create, Update and the
  member writes `put` the list, which clears the entry, so the owner sees a new list at once on the instance that took the
  write; on another instance the bound is the 60 s TTL, and it needs a probe of an id before it is minted (server
  Snowflakes, not guessable). Delete evicts. Staleness bound 60 s, as D11.
- **L-2 visible rune.** `identity.singleLineIssue` (display name, location, list name and description) refuses Cf other
  than ZWJ/ZWNJ between two non-space, non-format runes, the fillers U+115F/1160/3164/FFA0, and a non-empty text with no
  letter, number, punctuation or symbol. Applied to a value being written only; an unrelated profile edit never
  revalidates a stored name. Vectors: `testdata/profile_text/single_line_text.json` (Go only; Dart follow-up W5-48).
- **L-3 id-only idempotency result.** The record of CreateList, UpdateList, AddListMember and RemoveListMember holds the list
  id only. A replay reads the list (owner-checked) for its current header: **+1 read on a replay, 0 on a first call**, and a
  replay after the list was deleted is NOT_FOUND. DeleteList's record (`deleted` flag) was never personal. Records written
  before this change carry the old header fields; only their `id` is read.
- **L-4 fresh target status.** AddListMember reads `users/{target}` through the transaction (`identity.TxProfiles`, wired by
  `SetTxProfiles`) on a real add, after the already-a-member check and before the cap and quota: **+1 read on a real add**
  (worst 7 with the interceptor, was 6); missing or not ACTIVE is the same NOT_FOUND. Replays, no-ops, self-adds and
  Refusal answers do not pay it.
- **W5-47.** `LIST_MAX_MEMBERS` above `config.MaxListMembersCeiling` (500) fails startup; the default stays 150.
## Stage ladder
| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger (measured, 7 days sustained) |
|---|---|---|---|---|
| List timeline | pull-merge over ≤ 150 members: `homeSources` + `Merge`, author-recent cache, list doc cached 60 s | the `timeline` interface; the opaque `list` token binding; the merge stays behind the interface; `lists.Reader.Members` | the Home hybrid fan-out (Memorystore per-feed materialisation, write fan-out below N followers): a list becomes one more materialised feed with the same contract | list timeline reads > 15 % of daily Firestore reads, or the `free-tier-budget` §6 trigger (> 1.5M reads/day or > $30/month); or a member cap above 500 is wanted (C > 17 per refresh) |
| List membership storage | `memberIds[]` on the list doc, ≤ 150 | `lists.Reader`; member pages paged by a sealed position token, never by array index on the wire | `lists/{id}/members/{uid}` with a `count()` cap and a collection-group eraser query, plus a materialised author set for the feed | a cap above 1,000 members, or list docs above 64 KB |
| Home tabs | `users/{uid}.homeTabs` (≤ 5), GetMe at 0 reads | `timeline.HomeTabsStore` (identity implements it); `HomeTab.kind` is an enum | its own `homeTabs/{uid}` doc or a preferences store | contention on `users/{uid}` writes (ABORTED on profile or counter transactions) traced to tab writes, or a tab cap above 20 |
| List cache | in-process LRU per instance (2,000 docs, 60 s) | `lists.Reader`; every cached read states its bound (D11) | Memorystore, with the timeline cache | hit rate under the W5-18 model, or max instances above 3 |
| List ids | Snowflake, time-ordered | ids opaque to clients | hash-prefixed ids | list creation near 500/s (unreachable under the 10/day quota below about 4M DAU) |

## Proposed follow-ups (gate files and `.claude/` are not edited in this PR)
- **FU-1 (W5-3, founder-gated):** `scripts/promotion/flag-ceiling.json` entry `LISTS` (dev allowlist 6 (the dev ceiling for every flag since #463), no prod raise);
  Terraform `feature_lists*` and the D10 config variables in `envs/dev` and `envs/prod`, default `off`, not applied.
- **FU-2 `stage-ladder` skill:** a "Lists and Home tabs (ADR-0030)" section with the five rows above (the plan's A11).
- **FU-3 `firestore-data-model` skill:** a `lists/{listId}` [lists, ADR-0030] row (D2); `users` row: `homeTabs`
  `{kind, id, title}` ≤ 5, title only for own lists; `quotas` row: `listCreates`, `listAdds`; the per-RPC rows above;
  the Indexes section: "lists: none; `memberIds` stays indexed (eraser)".
- **FU-4 `docs/reviews/cost-model.md` (sre-performance, W5-18):** the Part A rows and the moved crossovers above, with
  a Logs Explorer query for `timeline_op=list`.
- **FU-5 (optional, founder-gated, not required):** a fieldOverride exempting `users.homeTabs` from single-field
  indexing (an array of ≤ 5 maps; nothing queries it). Only worth bundling with another `users` override.
- **FU-6 `docs/code-map.md`:** `lists.Service`, `lists.Reader`, `lists.Pins`, `timeline.HomeTabsStore`, `listFeed` (with the PRs
  that add them).

## Consequences
**Positive.** A list costs what Home costs for the same authors, reuses every Home piece (merge, tokens, caches,
`removed_ids`, the audience filter) and adds about INR 9 / 39 / 150 a month. Tabs sync across devices at 0 reads per
session. Rule 4 holds on every mutation. Private by default, no add notification and the block rules make a list a weak
harassment tool. Every Stage 2 move is a swap behind a named seam.

**Negative.** A list refresh pays one read per 30 members even when nothing is new. Lists can show fewer posts than
their member count suggests (blocks, mutes, protected members, members who block the owner), and pages may be short.
Pins of other users' lists carry no stored title, so a new device calls GetList once per such tab. A dangling pin shows
as unavailable until the user unpins it. The `count()` cap check and the eraser rely on automatic indexes that only the
dev smoke proves.

**Revisit when** a stage-ladder trigger fires; W5-18 measures reads per call more than 25 % off this table; W5-17 finds
a list a practical harassment or scraping tool; or the founder answers an F differently.

## Handoff
- **architect:** W5-2 in this PR. FU-2 and FU-3 in a `.claude/` PR the founder approves. Part B's ADR (W5-20) next.
- **backend-developer:**
  - W5-3: `make proto` (Go and Dart), `FEATURE_LISTS`, the D10 config with `config_test.go` bounds, `quota.Record`
    `listCreates`/`listAdds` with their cases, `ratelimit_config.go` buckets and `list_mutation_daily`, FU-1, the
    `internal/lists` skeleton naming no collection constant (T11).
  - W5-4 + W5-5 in one PR: D2, D3, D7 writes; D8 eraser, export, T11 rows, `docs/runbooks/lists.md`.
  - W5-6: D4 adds and removes (lazy drop, protected target, overflow). W5-7: `lists.Reader`, GetList, ListUserLists
    (`contains` own lists only), ListListMembers (reuse `likesResume` for the position token).
  - W5-8: D5 in `service_list.go`, `listFeed` in `tokens.go`; reuse `homeSources`, `Merge`, `removedIDs`,
    `newAudienceFilter` unchanged. W5-9: D6 `SetHomeTabs`, `timeline.HomeTabsStore` in a new identity file, GetMe
    `home_tabs`, UpdateList title refresh, the export profile field.
  - Seams: `lists.Service`, `lists.Reader`, `lists.Pins`, `timeline.HomeTabsStore` (one identity adapter implements
    both); lists never imports timeline; timeline names only posts, graph, identity and
    lists seams.
- **frontend-developer:** W5-10 to W5-14. Send `is_private` explicitly from the create sheet (Private on by default).
  Label tabs from the newest `ListInfo` you hold; call GetList once for a tab with an empty title and no cached
  header. On GetListTimeline NOT_FOUND show "This List is unavailable" with Unpin. Hide "Add to Lists" for protected
  accounts you do not follow, and map `PROTECTED_ACCOUNT` to friendly text anyway.
- **tester:** W5-15, W5-16: the D3 NOT_FOUND identity matrix (missing, private, hidden, owner blocks caller, owner not
  ACTIVE, owner overflow), the D4 drop matrix incl. protected members and the overflow rule, D7 replays and
  `IDEMPOTENCY_KEY_REUSED` on all six mutations, late retry of Add after Remove (replays, does not re-add), token
  bindings (Home vs user vs list, other list, other caller), the budgets above incl. GetListTimeline at 150 members and
  page 50 with the window query, GetMe at +0 reads.
- **security-auditor:** W5-17: private-list confidentiality (NOT_FOUND identity, cache keys, export), id guessing,
  member-page scraping (page ≤ 50, buckets × 3, read budget), the block oracle in Add and in member pages, the
  `contains_user_id` restriction, the protected-account rule, public lists as harassment lists (F3, F4), pinned tabs
  as a stored-reference leak (D6: no foreign titles stored), log hygiene.
- **sre-performance:** W5-18: FU-4; a k6 `list_timeline` scenario (cold, refresh with 0 and 5 new, 150 members at page
  50, the author-recent cache shared with Home); the 15 % trigger.
- **production-deployer:** W5-19: a targeted dev plan for `feature_lists*` and the config (roadmap section 9 item
  3.10: a full dev apply is unsafe), allowlist 3, the smoke (create, add 3, open the timeline, pin, reorder, unpin,
  delete, flag off; it is the first real-Firestore proof of the D2 queries). Prod: nothing until the held release
  (ADR-0019).
