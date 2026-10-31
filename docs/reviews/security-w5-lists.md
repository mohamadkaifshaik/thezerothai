# Security review: W5 Part A, Lists and custom Home tabs (W5-17)

**Reviewer:** security-auditor · **Date:** 2026-10-31 · **Reviewed:** `origin/main` at `20fb36ec`, read only (W5-3 to W5-9 incl. #518, #524, #526, #529; client W5-10 to W5-13 incl. #523, #527, #531). PR #537 (W5-14 Home tab bar, OPEN) was read as a diff at head `f9be5cbe`.

**Design:** ADR-0030 (Accepted 2026-10-30), ADR-0025 (protected accounts), ADR-0008 (blocks), ADR-0010 D5 (read budget). Plan `docs/plans/ui-w5-lists-communities.md`, W5-17 and "Abuse & security surface".

**Code read:**
- `backend/internal/lists/{api,cache,model,repo_firestore,repo_members,repo_read,purge,reader_export,server,service,service_members,service_read}.go`
- `backend/internal/timeline/{service_list,home_tabs,service,tokens,audience}.go`
- `backend/internal/identity/{home_tabs,single_line_text,validate,lifecycle_export,service,server}.go`
- `backend/internal/apiserver/{apiserver,ratelimit_config}.go`, `lifecycle_collections_guard_test.go` (rows 75, 138), `pkg/platform/{idempotency,cursor,limits,quota,degraded,config}`
- `proto/dzeroth/lists/v1/lists.proto`, `scripts/promotion/flag-ceiling.json`, `docs/runbooks/lists.md`
- Client: `app/lib/features/lists/**`, `app/lib/features/timeline/{domain/feed_key,data/timeline_repository,data/timeline_store,presentation/bloc/timeline_cubit}.dart`, `app/lib/core/storage/app_database.dart`; PR #537 diff (`home_tabs_cubit.dart`, `home_list_tab.dart`, `manage_pinned_screen.dart`, `app_router.dart`)

**Not run:** no unit, integration, emulator or Flutter tests (the local checkout was behind `origin/main`); no cloud calls; `govulncheck` and `osv-scanner` were not run (W5 added no Go or pub dependency). The L-1 timing difference is not measured.

**Test inputs:** W5-15 (backend tests incl. the authz matrix) and W5-16 are Open, so there were no tester authz results to read. The verdicts below rest on code reading and the existing unit tests (`service_read_page_test.go`, `service_members_test.go`, `service_test.go`).

**Where it runs today:** `FEATURE_LISTS` is off everywhere. Dev ceiling `{"mode":"allowlist","max_allowlist":6,"max_percent":0}` (I-1). Prod has no entry and the prod release is held (ADR-0019).

## 1. Threat model (STRIDE)

**Assets:** private-list name, description and members; the fact that a private list exists; who a protected account curates; members' block and mute state; pinned-tab references on `users/{uid}`; the free Firestore quota and the credit (cost).

| STRIDE | Threat | Control as built | Result |
|---|---|---|---|
| Spoofing | Calling list RPCs as someone else | Global chain: App Check, Firebase ID token, account-status interceptor (routes.go `connect`, apiserver.go:625-634); uid from `authn.UIDFromContext` only | OK |
| Tampering / IDOR | Edit, delete or add to another user's list by id | `getOwned` reads the list in the transaction and refuses `ownerId != uid` as `ErrNotFound` (repo_firestore.go:208-225); DeleteList of a foreign list is success with no effect (:287-322) | OK |
| Tampering | Replaying or forging page tokens | AES-256-GCM sealed (`cursor.go:4`), bound to `lists\|ulists\|viewer\|owner`, `lists\|members\|viewer\|list`, `tl\|list\|uid\|list`; foreign token = VALIDATION, 0 reads | OK |
| Tampering | Idempotency key reuse across users or RPCs | `idempotency.Key(uid, rpc, key)` = SHA-256 of `uid\|rpc\|key` (idempotency.go:72-75) on all six mutations (service.go:262, 304, 345; service_members.go:110, 135; identity/home_tabs.go:133); same key with another body = IDEMPOTENCY_KEY_REUSED | OK |
| Repudiation | Untraceable list abuse | Request line `list_op`, `outcome`, `fs_reads`, `fs_writes`, `dropped`; WARN lines carry `uid_hash` only; no ids or names logged (grep of `slog`/`SetRequestField` in the lists, timeline and identity files) | OK (by design, an operator reaches ids only via Firestore) |
| Information disclosure | Private list name, members or timeline to a non-owner | `resolve` (service_read.go:77-121) on GetList, Members (timeline), ListListMembers; private and hidden refused before any further read (:96-98) | OK, except **M-1**, **M-2**, L-1, L-3, L-5, L-6 |
| Information disclosure | Block oracle in Add and member pages | Add: missing, inactive, blocks-owner and owner-blocks are one NOT_FOUND, checked before PROTECTED_ACCOUNT (service_members.go:45-68) | OK; L-5 residual |
| Denial of service / cost | Read and write amplification, fan-in timeline | Buckets, `list_mutation_daily`, exact quotas, read budget (section 1.1) | Bounded; **M-3** bypasses the flag |
| Elevation | Feature use while off, platform `hidden` bypass | `lists.Guard` first on every ListService RPC (server.go:39-58) and GetListTimeline (service_list.go:53-62); `hidden` honoured on every read (:70, :96, :296) | OK, except **M-3**; no write path for `hidden` (**M-4**) |

### 1.1 Effective limits (per instance x 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| `RATE_LIMIT_LISTS_WRITE_PER_MIN` (six mutations incl. SetHomeTabs) | 30/min | 90/min | memory |
| `LIST_MUTATIONS_PER_DAY` (`list_mutation_daily`, all six) | 500/day | 1,500/day | memory |
| `RATE_LIMIT_LISTS_READ_PER_MIN` (GetList, ListUserLists, ListListMembers) | 30/min | 90/min; no daily call cap | memory |
| `RATE_LIMIT_LIST_TIMELINE_PER_MIN` (GetListTimeline) | 12/min | 36/min; no daily call cap | memory |
| Read budget (ADR-0010 D5), per-call hold 269 | 2,000 reads/uid/day | 6,000 | memory |
| `QUOTA_LIST_CREATES_PER_DAY` | 10 (3 new) | exact | `quotas` |
| `QUOTA_LIST_ADDS_PER_DAY` | 300 (50 new) | exact | `quotas` |
| `LISTS_MAX_PER_USER` / `LIST_MAX_MEMBERS` / `HOME_TABS_MAX_PINNED` | 20 / 150 / 5 | exact | in-transaction count or doc |

Rate limits are mapped for all ten new procedures (ratelimit_config.go:193-202, 234-239); none falls to the default bucket. Quota `Record` cases for `listCreates` and `listAdds` exist (quota.go:145-148, 180-183, 259-261; ADR-0021 I-3).

### 1.2 Cost-amplification scenarios (INR 95/USD, `cost-model.md` §7: reads $0.035, writes $0.104, deletes $0.012 per 100k)

- **GetListTimeline fan-in:**
  - Worst case is 218 reads per call (non-owner, 150 members, page 50, removal-log window).
  - Without the read budget, 36/min x 218 x 1,440 is about 11.3M reads a day per account, about INR 376 a day.
  - With the budget it is at most 6,000 reads a day, **about INR 0.20 a day, INR 6 per account-month**. 100 accounts is about INR 600 a month; 1,000 accounts about INR 6,000 a month (24% of the INR 25,000 credit cap).
  - The per-uid read budget is the control that carries the load; the bound beyond it is App Check plus signup friction (the number of accounts). Lists add no new ceiling, since every read path shares the budget.
- **Mutations:**
  - At most 1,500 calls a day: 300 real adds x 3 writes plus about 1,200 UpdateList toggles x 2 writes. That is 3,300 writes plus about 1,500 TTL deletes.
  - Cost is **about INR 0.34 a day, INR 10 per account-month**. About 6 such accounts use up the free 20k writes a day; 100 accounts cost about INR 1,000 a month. Bounded, comparable to `graph_mutation_daily`.
- **M-3 path:** inside the same 1,500 calls, 3,000 reads plus 1,500 writes plus 1,500 deletes is about INR 0.27 a day, INR 8 per account-month, but reachable by **every** account with `lists` off.
- **Id guessing:** GetList of a guessed id costs 1 read from the guesser's budget. Ids are time-ordered Snowflakes, but the sequence and node bits make blind guessing poor. A hit on a private id still answers NOT_FOUND (L-1 aside).
- **Requests:** 72/min per instance x 3 is at most about 311k list requests a day per account. Requests refused by the budget are still billed past the 2M free, about INR 11.8 a day sustained. This is generic, not new, and covered by the request-flood alert.

## 2. Findings

### M-1 (Medium): ListUserLists reveals the count and position of another owner's private lists
**Where:** `backend/internal/lists/service_read.go:285-307`. The query reads `size+1` rows of **all** the owner's lists, sets `next_page_token` from that raw count (:291-294), then drops private and hidden rows (:296-298). `lists.proto:114-115` says the token "is always ''", which holds only for `page_size >= 20`. `ClampPageSize` accepts 1 (limits.go:20-29).
**Scenario:** the viewer calls `ListUserLists(owner=O, page_size=1)` and follows the tokens. Every page that comes back with 0 lists and a token is a private or hidden list, so the viewer learns how many private lists O has and how their creation order interleaves with the public ones. The very first call answers "is O's oldest list private?". Cost is about 5 reads per page. This breaks ADR-0030 D3: "a private list must be indistinguishable from a missing one". No name or member leaks, because the tokens are encrypted.
**Fix:** for another owner, read all `LISTS_MAX_PER_USER` (≤ 20, ≤ the 50 page maximum) in one query, filter, and return every public list with `next_page_token = ""`, ignoring `page_size`. Alternatively, page over the filtered set so the token is set only when more public lists remain. Add a test: owner with [private, public], `page_size 1`, expect [public] and no token.

### M-2 (Medium, founder question): a protected account's public lists are visible to viewers it has not approved
**Status: In review (#PRNUM, W5-42). Founder 2026-10-31: hide protected accounts' lists from unapproved viewers.** Implemented as proposed: NOT_FOUND on single lists, PROTECTED_ACCOUNT on ListUserLists, 0 reads; I-3 recorded in ADR-0030 D3 (note 2026-10-31).

**Where:**
- `resolve` (service_read.go:96-119) never checks `owner.IsPrivate`. It has already read both the owner's profile (:105-113) and the viewer's graph (`Following`), so a check costs 0 reads.
- `otherOwner` (:314-341) has the same gap for ListUserLists.
- The client shows "View Lists" on any profile (W5-13).

**Scenario:** P creates a public list, or one made public before P went protected, and later protects the account. Any signed-in non-follower still reads its name, description and members (who P watches), and its timeline. ADR-0025 hides ListFollowing(P) from unapproved viewers for the same reason (PROTECTED_ACCOUNT, ADR-0025 matrix). ADR-0025 founder decision 5 ("not posts, lists or the pinned post") most plainly means the followers and following lists (its Context, line 39), so this is a gap, not a breach of an accepted decision. ADR-0030 does not address a protected **owner**.
**Fix (proposed default, needs the founder's yes):** for a non-owner viewer, treat `owner.IsPrivate && !viewerSnap.Following[owner]` as the D3 NOT_FOUND in `resolve`. In `otherOwner`, answer ListUserLists(P) with PROTECTED_ACCOUNT, following the ListFollowing precedent (architect's call), or with an empty list. Cost is 0 reads. Hide "View Lists" on protected profiles the viewer does not follow.

### M-3 (Medium): SetHomeTabs with an empty `tabs` skips the `lists` gate and still reads and writes
**Where:**
- `backend/internal/timeline/home_tabs.go:146-150` runs `lists.Guard` only when `len(sent) > 0`.
- `identity/home_tabs.go:132-177` then reads the idempotency doc and `users/{uid}` (2 reads) and always writes the idempotency doc (1 write plus 1 TTL delete).
- With `lists` off, `mergeTabs` keeps every stored LIST tab (:236-240), so the call is a pure no-op.

**Scenario:** with `FEATURE_LISTS=off`, or for a caller outside the allowlist (in prod, as soon as a release containing #526 is promoted), every account can call `SetHomeTabs({key, tabs:[]})` up to 1,500 times a day: 3,000 reads, 1,500 writes and 1,500 deletes per account-day (section 1.2). This breaks the W5-17 rule that off or not allowlisted means refused with no reads, and it adds idempotency documents as a write amplifier on a surface that should not exist while the feature is off.
**Fix:** when `lists` is off for the caller (and, after Part B, `communities` too), answer an empty request at 0 reads and 0 writes. Either return the empty visible order, which is exactly what the transaction would return, or FEATURE_DISABLED. The ADR D6 behaviour ("an empty list is always accepted") is preserved. Add a test: flag off, empty tabs, assert 0 Firestore reads and 0 writes beyond the interceptor.

### M-4 (Medium): no list-level moderation lever before the percent stage
**Where:**
- The read paths already honour `hidden` (service_read.go:70, :96, :296). No code writes it.
- `opsctl list hide|restore` and the LIST report target live in W5-29, which depends on W5-23 and W5-28 (Communities, Part B; plan line 363).
- `docs/runbooks/lists.md` §7 says "the hidden flag handling arrive[s] with W5-29. Until then the only lever is the flag". That is wrong: only the write is missing.

**Scenario:**
- A public list named as a slur or a "targets" list, holding the victims, is public user-generated text. It can be reached from the owner's profile and by a `/lists/:id` deep link.
- Members are never told (F4), so a victim cannot even know to report it.
- ReportContent has no LIST target. The only levers are suspending the owner (coarse) or turning the whole feature off.

**Fix:** split "opsctl `list hide` / `restore` (field-level `Update` of `hidden` plus `updatedAt`, never `Set`) and the LIST report target with a name/description snapshot as evidence" out of W5-29 into its own ticket that depends only on W5-4. Correct runbook §7.

### L-1 (Low): a cache-shaped timing oracle between "private" and "missing"
**Where:** `loadList` caches every document it reads, private and hidden ones included (service_read.go:56-66). A missing id is never cached and costs a Firestore point read every time. On a list whose public owner blocks the viewer, `resolve` makes 3 more cache-first reads (:99-119).
**Scenario:** probing the same guessed id twice on a warm instance answers a private list without a round trip, measurably faster than a missing id after enough samples. It reveals only that a private list exists with that id; the block variant needs the list id already and repeats what GetProfile's NOT_FOUND already says.
**Fix:** a 60 s negative-cache entry for missing ids in the same LRU (it also cuts repeat-probe reads). Optionally pad the refusal path.

### L-2 (Low): invisible or format-character list names
**Where:** `identity.SingleLineText` → `singleLineIssue` rejects Cc, U+2028/2029, U+202A-202E and U+2066-2069 (validate.go:57-64, 145-147). It accepts other Cf and filler characters: U+200B, U+200E/200F (LRM/RLM), U+061C, U+2060, interior U+FEFF, U+3164, U+115F and tag characters.
**Scenario:** a name made of one U+3164 or U+200B renders blank in the lists screen, tabs and header, and mixed characters allow light spoofing. The client renders with plain `Text` (no HTML, linkify or markdown under `app/lib/features/lists`), so there is no injection. Display names follow the same rule, so the gap is not new (W3-22 L-2 precedent).
**Fix:** in the shared helper, require at least one visible rune and reject Cf except ZWJ/ZWNJ/VS inside emoji sequences; add vectors to `testdata/profile_text`.

### L-3 (Low, privacy): list name and description persist in idempotency records
**Where:** `headerResult` stores name, description, private flag and count in every list mutation's idempotency record (repo_firestore.go:102-107, 195, 272; repo_members.go:73, 94). The T11 row marks `idempotency` `notPersonal` (lifecycle_collections_guard_test.go:75).
**Scenario:** after DeleteList or account erasure, a private list's name and description survive for up to 24 h plus the TTL deletion lag (up to about another 24 h). A replay of an old UpdateList returns the old name.
**Fix:** store only the list id in `Result` and re-read on replay (+1 read on replays only). Otherwise, document it in the T11 note and the Privacy Policy retention line.

### L-4 (Low): an account in deletion can be re-added to a list within the cache window
**Where:** AddMember checks the target's status through cache-first `identity.Directory` (service_members.go:88, :49).
**Scenario:** within 60 s of a user entering DELETING, and after the `lists` eraser's member phase (purge.go:143-152) has already run for a small account, an owner can add that uid. The uid then outlives the erasure in another user's list. Reads drop it as inactive, but it is residue (rule 10).
**Fix:** read the target's `users` doc fresh inside the add transaction (+1 read on real adds), or have the residue sweep re-run the member phase.

### L-5 (Low): short member pages reveal blocks, given a sock-puppet account
**Where:** the non-owner header count is net of members who block the owner only (service_read.go:139-145). The member page also drops the viewer-level blocks and mutes and inactive accounts (:376-388, :425-451). The owner sees the stored count while their page drops members who block them.
**Scenario:** a sock puppet lists X, and the attacker sees header count 1 with 0 rows, so X blocks the attacker. ADR-0008 already accepts that sock puppets defeat block secrecy, and for the owner this equals GetProfile's NOT_FOUND (block and deletion look alike). Accept and document.

### L-6 (Low): a cold start renders cached list rows before the server's NOT_FOUND
**Where:** on NOT_FOUND, `timeline_repository.dart:337-341` calls `removeFeed`, which deletes `list:<id>` rows and state (`timeline_store.dart:336-342`), and the cubit clears the screen (`timeline_cubit.dart` `_listGone`). Until that first response, and indefinitely while offline, the drift rows of a list that has since gone private still render.
**Scope:** the same account only. `clearAll` wipes `timelineItemEntries` on sign-out, and `claimCacheFor` wipes on an account switch (`app_database.dart` around :518-560). The rows are public posts the user already saw. Accept.

### L-7 (Low, privacy, founder question): the export leaves out the user's memberships in other people's public lists
**Status: In review (#PRNUM, W5-46). Founder 2026-10-31: export the user's own membership records, redacting private-list details and other members.** `lists_member_of`: public rows (list id, owner handle, name) plus `redactedCount`; see ADR-0030 D8 (note 2026-10-31). The 'Private lists must stay out' line above is met by redaction.

**Where:** purge.go:155-157 and ADR-0030 D8 export only the user's own lists.
**Scenario:** under GDPR Art. 15 and DPDP Act s.11 a user may be entitled to "lists I am on", and X's archive includes lists-member. Private lists must stay out (F4).
**Fix:** a `lists_member_of` export section of public, non-hidden lists naming the uid (list id, owner handle, name), using the eraser's `memberIds array-contains` query (≤ 1 read per list). It is a founder decision.

### Informational
- **I-1:** the dev ceiling for `LISTS` is `max_allowlist: 6` (flag-ceiling.json:28), while the plan and ADR D9 say 3. The file is founder-gated; align one or the other.
- **I-2 (cost, for W5-18):** PR #537's `HomeTabsCubit` calls GetList once per unnamed tab per session (another user's lists carry `title ""`): up to 5 calls, about 25 reads cold, per Home open on a new session.
- **I-3:** `resolve` and `otherOwner` refuse when the owner blocks the viewer, not when the viewer blocks the owner. A viewer can still read public lists of someone they blocked; member posts from blocked accounts are dropped. This is a product choice consistent with viewing a blocked profile; record it in ADR-0030 D3. Recorded in the ADR-0030 note of 2026-10-31 (W5-42, #PRNUM).
- **I-4:** the request bound in 1.2 is generic (rejected requests are billed); there is no list-specific action.

## 3. Explicit verdicts on the threats handed over

| Threat | Verdict |
|---|---|
| Private list via GetList / ListListMembers / GetListTimeline | One NOT_FOUND (`notFoundText`, service.go:44); private and hidden refused before further reads; visibility re-checked on every page and refresh (service_list.go:99, service_read.go:407) |
| ListUserLists `containsUserId` | Accepted only on own lists, else VALIDATION before any read (service_read.go:258-261; test `TestListUserLists_Contains`). Count leak: **M-1** |
| Pinned tab after the list goes private or is deleted | Stored tab keeps only the id; `title` is stored only for own lists (home_tabs.go:207-211); GetMe +0 reads; GetListTimeline answers NOT_FOUND; the client offers Unpin. OK |
| Export | Own lists with member ids; `homeTabs` in the profile section (lifecycle_export.go:69, 246-252). Member-of gap: L-7 |
| Error and timing oracles, private vs deleted | Byte-identical errors; timing: L-1 |
| Adding a blocker; mass adds; telling the member | Blocker → NOT_FOUND, checked before PROTECTED_ACCOUNT; 300 adds a day exact, 150 per list, 20 lists; no notification (lists imports no Emitter) |
| Block and mute in a list timeline | `listAuthors` + `listAuthorAllowed` before the query, `keep` after the shared cache, `embedAllowed`, the audience filter for protected members, overflow fails closed (service_list.go:121-178) |
| Quotas, caps, fan-in cost | Section 1.1 and 1.2; bounded by the read budget; M-3 |
| Authz on mutations, IDOR on list or member id | `getOwned` in every transaction; `user_id` validated with `ids.ValidUID` |
| Idempotency key reuse across users | Hash includes the uid; no cross-user replay |
| Input length, bidi, zero-width, rendering | 1-25 / 0-100 code points after NFC; bidi overrides refused; Cf gap L-2; plain `Text` rendering |
| `lists.Guard` | First on every ListService RPC and GetListTimeline, 0 reads beyond the interceptor; exception **M-3** |
| Right to delete and export | `lists` step (own lists, then `memberIds` ArrayRemove with LastUpdateTime), T11 row 138, `homeTabs` deleted with `users/{uid}`; residue L-4; idempotency L-3 |
| Client: shared device, account switch, deep link | Drift wiped on sign-out and on owner-stamp change; in-memory title overrides cleared (`home_tabs_repository.dart:336`); `/lists/:id` behind the `lists` redirect; NOT_FOUND drops the feed (L-6) |
| Logs | Counts and enums only; errors redacted with `logger.RedactErr`; no ids or names |

## 4. Founder actions
1. **M-2:** should a protected account's public lists be hidden from viewers it has not approved (proposed: yes, 0 reads)?
2. **L-7:** should the export include memberships in other people's public lists?
3. **Privacy Policy lines:** lists are private by default; a public list, its name and members are visible to all signed-in users; members are not notified; deletion removes your lists and your membership in others' lists; idempotency copies expire within about 48 h (L-3).
4. **I-1:** settle the dev ceiling for `LISTS` (6 vs 3).

## 5. Proposed tickets (W5-40 was the highest existing; added to the plan in this PR)

| ID | Ticket row text | Owner | Size | Depends | Gate |
|---|---|---|---|---|---|
| W5-41 | M-1: ListUserLists for another owner returns all public lists in one page, token "" (filter before paging); fix the lists.proto:114-115 comment; test private-first with page_size 1 | backend-developer | XS | W5-7 | before percent |
| W5-42 | M-2: protected owner rule in `resolve` and `otherOwner` (NOT_FOUND / PROTECTED_ACCOUNT for unapproved viewers, 0 reads); hide "View Lists" on protected profiles not followed; ADR-0030 D3 note | architect + backend-developer + frontend-developer | S | founder answer (yes) | before percent; in review (#PRNUM) |
| W5-43 | M-3: SetHomeTabs with the kind's flag off for the caller answers an empty request at 0 reads and 0 writes; test it | backend-developer | XS | W5-9 | before the prod release containing #526 is promoted |
| W5-44 | M-4: opsctl `list hide` / `restore` (field-level Update, never Set) and the LIST report target with a name/description snapshot, split from W5-29 to depend on W5-4 only; correct runbook §7 | backend-developer | S | W5-4 | before percent |
| W5-45 | L-1 negative cache, L-2 visible-rune rule (shared with display names), L-3 id-only idempotency result or T11 note, L-4 fresh target status on add | backend-developer | S | W5-6, W5-7 | before prod on |
| W5-46 | L-7 export section `lists_member_of` (redacted, founder 2026-10-31) | backend-developer | S | founder answer (yes) | before prod on; in review (#PRNUM) |

## 6. Verdict per stage

| Stage | Verdict |
|---|---|
| **Dev allowlist** (team and test accounts, ceiling 6) | **GO**, once W5-41 to W5-45 are in the plan (the W5-17 rule: fixed or ticketed before any dev allowlist). They are, in this PR. |
| **Percent** (dev or prod; needs a founder-gated ceiling raise) | **GO** once W5-41, W5-43 and W5-44 are merged, W5-42 is decided and merged, and W5-15's authz matrix is green |
| **Prod on** | **BLOCKED** until everything for percent, plus W5-45, the L-7 decision, the Privacy Policy lines and the held release (ADR-0019) |

No Critical or High finding is open.

SECURITY: CLEAR
