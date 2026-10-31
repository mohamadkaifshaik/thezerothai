# Test report: UI wave W5 Part A (Lists and custom Home tabs), backend

Plan: `docs/plans/ui-w5-lists-communities.md` (W5-15). Design: ADR-0030. Built by W5-3 (#495), W5-4/W5-5 (#506), W5-6 (#512), W5-7 (#518),
W5-8 (#524), W5-9 (#526). The client half is W5-16; the security review is W5-17; the load shapes (a 150-member list with every member
posting, a viewer switching 6 tabs a minute) are W5-18 and are not run here.

Tester: tester agent. Branch `test/ui-w5-15-lists-backend-tests` on `origin/main@0fa8b9ba`. No production code was edited.

**VERDICT: PASS for W5-15 as specified.** Every acceptance criterion of W5-4 to W5-9 has a named test (section 3). The audit found
**no product defect**. It found one test defect (the known flake, section 4), fixed here, and ten gaps in the existing tests, now covered.

---

## 1. Method

1. Read the ticket, ADR-0030 (D1 to D12 and the per-RPC cost table), the plan text of W5-4 to W5-9 (including their "as built" notes, which
   supersede the original wording where they differ) and the CLAUDE.md rules (idempotency, every query limited, budgets, rule 10).
2. Listed every test in `internal/lists`, `internal/timeline` (`list_test.go`, `home_tabs_test.go`), `internal/identity` (`home_tabs*_test.go`),
   `pkg/platform/quota` and `internal/apiserver` (`lists_*`, `w59_*`, `account_lifecycle_lists_*`, `lifecycle_*guard*`) and mapped each
   acceptance criterion, each "things to check" item of the ticket and each ADR budget row to a test (section 3). A criterion counts as covered
   only when a test would fail if the behaviour were removed, and only when it runs through the layer the criterion names: a package test below
   the interceptors does not prove a flag gate, a read count, or the bytes a client receives.
3. Wrote tests only for the holes (section 2), at the layer that was missing, using the existing harnesses (`ltChain`, `listsEnv`, the lifecycle
   env) and `budgettest`.
4. Ran everything against the Firebase emulators (Firestore, Auth, Pub/Sub, Storage, ports 57xxx, a private temp dir per run).

## 2. What was added

| File | Tests | Gap closed |
|---|---|---|
| `backend/internal/lists/repo_integration_test.go` | `TestCreateList_Integration_ConcurrentSameKey` rewritten | The flaky test (section 4) |
| `backend/internal/lists/repo_members_integration_test.go` | new-account tier of `TestAddMember_Integration_Quota` | Asserts `quota=list_adds` on the 50-a-day tier; only the code was checked |
| `backend/internal/lists/w515_page_size_test.go` | `TestListListMembers_PageSizeDefaultAndMax`, `TestListUserLists_PageSizeDefaultAndMax` (8 sizes each) | Rule 5: default 20, max 50, for 0, negative, 7, 20, 21, 50, 51 and 2^30 on both list-valued RPCs |
| `backend/internal/apiserver/w515_lists_gaps_integration_test.go` | `TestW515_SetHomeTabsIsGatedByTheListsFlag` | Gate on SetHomeTabs through the real chain: off, allowlist without the caller, percent 0 give FEATURE_DISABLED `feature=lists` at 1 read (the interceptor's) and 0 writes |
| | `TestW515_PinnedListsThatStopBeingReadable` | Dangling pins: another user's list turned private, deleted or renamed after the pin. GetMe still returns the tabs at the same cold read count as an account with no tabs (+0); GetList and GetListTimeline answer bytes identical to a missing id; stored tabs can be reordered (2 reads, 2 writes) and removed without reading the dangling lists; a fresh pin of either is VALIDATION `tabs`, identical to a missing list |
| | `TestW515_PinnedListThatBecameHidden` | The same for a platform-hidden list (W5-29 field), and a new pin of a hidden list is VALIDATION |
| | `TestW515_SetHomeTabsWorstCase` | The ADR table's worst SetHomeTabs shape (5 lists, 5 distinct owners, cold): exactly 19 reads, 2 writes; the sixth tab is LIMIT_REACHED `limit=home_tabs` at the interceptor's read |
| | `TestW515_ListTimelinePagingAndPrivateBetweenPages` | page_size 0, -5 -> 20, 51 and 500 -> 50 on a 60-member list; the opaque cursor walk returns the 60 posts once, newest first; a list made private through the real UpdateList between page 1 and page 2 makes both the page token and the since token answer the one NOT_FOUND |
| | `TestW515_ListTimelineAndMembersDropBlockedBothWays` | Real accounts and the real graph: a member the viewer blocks and a member who blocks the viewer are absent from that viewer's timeline and member page and present for the owner and a bystander |
| | `TestW515_QuotaNamesAtTheDailyCaps` | `quota=list_creates` on the 11th create (3 reads, 0 writes) and `quota=list_adds` on the 301st add (6 reads, 0 writes) through the wire |
| | `TestW515_ReadonlyDegradedModeRefusesWritesAndKeepsReads` | The W5-4 criterion for all six mutations: UNAVAILABLE under `DEGRADED_MODE=readonly`; the four read RPCs still answer with 0 writes (this pins the `idempotency_level` annotation of every new RPC, which is what the interceptor reads) |
| `backend/internal/apiserver/account_lifecycle_export_integration_test.go` and `testdata/account_export_golden.json` | the export golden now seeds an own list with two members and a list the account is only a member of | The golden's `lists` section was `[]`, so the W5-5 criterion "the export matches the golden" proved nothing for a populated list. The golden diff is 13 lines in the `lists` section only: the own list (id, name, privacy, member ids, times) is exported, the membership-only list is absent. **Merge-conflict risk:** the golden is a shared file; if another PR changes it, regenerate with `-update-golden` and check that the `lists` hunk is the only one from this PR |

Not added, because the existing test already pins it through the right layer (named in section 3): flag modes of the six list RPCs
(`TestServer_FlagGateOnEveryRPC`), idempotency key validation for all six mutations (service tests), the lifecycle eraser and its crash
chain, the D6 drop matrix, token binding, and the budgets of the other RPCs.

## 3. Acceptance criteria and ticket items to named tests

All paths under `backend/internal/`. "NEW" is added by this ticket.

### W5-4 / W5-5 (write path, lifecycle)
| Criterion | Test |
|---|---|
| 20 lists -> LIMIT_REACHED `limit=lists`, 0 writes | `lists TestCreateList_Integration_Cap` |
| Replayed key: the same list, 0 writes | `lists TestCreateList_Integration_Replay`; `TestCreateList_Integration_ConcurrentSameKey` |
| Another user's list id: NOT_FOUND identical to a missing id | `lists TestUpdateList_Integration_NotFoundIsOneAnswer`, `TestDeleteList_Integration`; chain `apiserver TestListTimelineChain_NotFoundIsByteIdenticalToGetList` |
| A name with a bidi control: VALIDATION `field=name` | `lists TestCreateList_Validation`, `TestUpdateList` |
| `DEGRADED_MODE=readonly` rejects before any read | NEW `apiserver TestW515_ReadonlyDegradedModeRefusesWritesAndKeepsReads` |
| Budget CreateList 4 / UpdateList 3 / DeleteList 3 (interceptor included) | `lists TestCreateList_Integration_Budget`, `TestUpdateList_Integration`, `TestDeleteList_Integration` |
| Quota tiers (10, 3 for a new account), exact | `lists TestCreateList_Integration_QuotaTiers`; NEW wire name `TestW515_QuotaNamesAtTheDailyCaps` |
| Idempotency on every mutation: replay at 0 writes, same key other body is IDEMPOTENCY_KEY_REUSED | Create, Update, Delete, AddMember in `lists *_Integration_Replay`/`_NoOpStoresTheKey`; RemoveMember in `TestRemoveMember_Integration` (replay at 1 read, 0 writes); SetHomeTabs in `apiserver TestW59_HomeTabsLifecycle`, `identity TestHomeTabsReplace_Integration_Budgets` |
| Malformed or empty key: VALIDATION `idempotency_key`, 0 reads, all six mutations | `lists TestCreateList_Validation`, `TestUpdateList`, `TestDeleteList`, `TestAddMember_Validation`; `timeline TestSetHomeTabs_Rules` |
| Eraser: own lists deleted, membership removed, counts right, rerun writes 0, resumable | `lists TestEraser_Integration`, `_Paging`, `TestEraser_ErrorKeepsCheckpoint`; `apiserver TestAccountLifecycle_ListsEraserIsCrashSafe` (a kill after every side effect of the step) |
| Eraser is never flag-gated | the lifecycle env runs with `FEATURE_LISTS` at its default (off) and still erases; `lifecycle_wiring_test.go` |
| Account deletion removes `homeTabs` | `users/{uid}` is deleted last by the same chain test (`requireListsErased` checks it and the residue sweep on `ownerId` and `memberIds`) |
| Export section `lists` matches the golden; membership-only lists are absent | `lists TestExporter_Golden`, `TestExporter_Integration`; NEW populated account export golden |
| T11 row, steps and sections registered | `apiserver lifecycle_collections_guard_test.go` (a `lists` row, and the negative cases that fail when the step, section or row is removed), `lifecycle_wiring_test.go` |

### W5-6 (members)
| Criterion | Test |
|---|---|
| List at 150: LIMIT_REACHED `limit=list_members`; two adds racing at 149 | `lists TestAddMember_Integration_Cap`, `_CapRace` |
| Target who blocks the caller: NOT_FOUND identical to a missing user; the block matrix; overflow | `lists TestAddMember_Integration_BlockMatrix`, `_OverflowBudget`, `_Protected` |
| Replay at 0 writes (1 write for the idempotency record on a no-op, per the as-built note) | `lists TestAddMember_Integration_Replay`, `_AlreadyMember`, `_ConcurrentSameKey` |
| 301 adds a day: QUOTA_EXCEEDED `list_adds` (50 for a new account) | `lists TestAddMember_Integration_Quota` (new-account tier now asserts the metadata); NEW wire test |
| Lazy drop of members who block the owner | `lists TestMembers_Integration_LazyDrop`, `TestRemoveMember_LazyDropHook` |
| Budget 5 cold / 6 on overflow | `lists TestAddMember_Integration_Budget`, `_OverflowBudget` |

### W5-7 (reads)
| Criterion | Test |
|---|---|
| Private list: owner sees, others NOT_FOUND identical to a missing id (also hidden, owner blocks caller, owner inactive, owner overflow) | `lists TestGetList_D3Matrix`, `TestListListMembers_Integration_RefusalsAreOneAnswer`; chain `TestListTimelineChain_NotFoundIsByteIdenticalToGetList` |
| A member who blocks the viewer is absent from that viewer's page | `lists TestListListMembers_DropMatrix`; NEW chain `TestW515_ListTimelineAndMembersDropBlockedBothWays` |
| A member who blocks the owner is absent for everyone | `lists TestMembers_OwnerLevelDrop`; chain `TestListTimelineChain_PerViewerAndTakedown` |
| Tampered token: VALIDATION with 0 reads; cursor binding | `lists TestListListMembers_VisibilityAndTokenFailuresReadNothing`, `TestListUserLists_PagingAndTokens` |
| Page size default 20, max 50 | NEW `lists TestListListMembers_PageSizeDefaultAndMax`, `TestListUserLists_PageSizeDefaultAndMax` |
| Budgets GetList 5/2, ListUserLists 24/21, ListListMembers 25/55 and 23/53, exact | `lists TestGetList_Integration_Budget`, `TestListUserLists_Integration_Budget`, `TestListListMembers_Integration_Budget` |

### W5-8 (GetListTimeline)
| Criterion | Test |
|---|---|
| 45 members: 2 chunks, Home order | `timeline TestList_FortyFiveMembersTwoChunksInHomeOrder`; chain `TestListTimelineChain_WarmFortyFiveMembersIsServedFromAuthorRecent` |
| `since` refresh with 0 new: 3 + C reads (owner, cold) | `timeline TestList_SinceRefreshWithNothingNewCostsOneQueryPerChunk`; chain `TestListTimelineChain_Budgets` |
| A member the viewer muted is dropped; a blocked author / one who blocks the viewer is dropped | `timeline TestList_PerViewerDrops`; chain `TestListTimelineChain_PerViewerAndTakedown` (mute); NEW chain block test with real accounts |
| A Home token on a list, a list token on another list or another caller: VALIDATION, 0 reads | `timeline TestList_TokenBindingAndMalformedIDCostNothing`; chain `TestListTimelineChain_PerViewerAndTakedown` |
| Takedown after the token is in `removed_ids` | chain `TestListTimelineChain_PerViewerAndTakedown`; `timeline TestList_RemovedIDsAreScopedToTheMembers` |
| 150 members at page 50: <= 110 reads, <= 217 with the window query | chain `TestListTimelineChain_Budgets`, `TestListTimelineChain_WindowQueryAtOneHundredFiftyMembers` |
| A list made private between pages: NOT_FOUND | NEW `TestW515_ListTimelinePagingAndPrivateBetweenPages` (page token and since token, through the real UpdateList) |
| Page size default 20, max 50; the cursor walk is complete and repeats nothing | NEW same test |
| `lists.Guard` gates it: off / not allowlisted / `posts` off -> FEATURE_DISABLED, no Firestore read | `timeline TestList_FlagModes` (0 reads, 0 member loads, 0 graph calls); chain `TestListTimelineChain_FlagModes` (1 read, the interceptor's) |
| Empty list, closed gap, repost/quote embed rules, protected members, overflow | `timeline TestList_EmptyListAnswersAnEmptyPageWithTokens`, `_ClosedGapReturnsHeaderOnly`, `_ProtectedMembers`, `_BlockedByOverflowKeepsOnlyOwnAndFollowedMembers` |

### W5-9 (Home tabs)
| Criterion | Test |
|---|---|
| 6 pinned: LIMIT_REACHED `limit=home_tabs`, before any read | `timeline TestSetHomeTabs_Rules`; `apiserver TestW59_HomeTabsLifecycle`; NEW worst-case test (metadata and read count) |
| Another user's private list: VALIDATION `tabs`, same as a missing list | `apiserver TestW59_HomeTabsLifecycle`; NEW dangling-pin tests (private, deleted, hidden) |
| Same order again: 0 writes (as built: a replay of the same key; a new key writes the idempotency record only) | `apiserver TestW59_HomeTabsLifecycle`, `identity TestHomeTabsReplace_Integration_Budgets` |
| `lists` off: GetMe omits LIST tabs; SetHomeTabs refused | `identity TestGetMe_HomeTabsAndFlags`, `apiserver TestW59_HomeTabsFlagOff`; `timeline TestSetHomeTabs_FlagModes` (0 list reads, 0 writes); NEW chain gate test (1 read, 0 writes) |
| GetMe +0 reads; a dangling tab is returned | `apiserver TestW59_HomeTabsLifecycle`; NEW `TestW515_PinnedListsThatStopBeingReadable` (same cold read count as an account with no tabs) |
| Stored tabs survive whole-document rewrites; export includes `home_tabs`; titles only for own lists | `identity TestHomeTabs_Integration_SurvivesWholeDocumentRewrites`, `TestProfileSection_HomeTabs`; account export golden |
| Worst case 19 reads, 2 writes | NEW `TestW515_SetHomeTabsWorstCase`; typical in `TestW59_HomeTabsLifecycle` |

### Rate limits and caps
`apiserver TestListsRateLimit_Guard` (write 30, read 30 and timeline 12 a minute per instance), `TestListMutationDailyCap_StopsTheCapPlusFirstCall`
(500 a day), `pkg/platform/quota TestListKinds*` (the counters and the wire names).

## 4. The flaky test: `TestCreateList_Integration_ConcurrentSameKey` (W5-4)

**Verdict: a test bug (an assertion stricter than the product contract, bound to emulator timing). No product race.** Fixed in this PR.

Evidence:
- The product code is correct for a same-key race. `FirestoreRepo.run` re-runs a transaction that lost an idempotency `Create` (`AlreadyExists`)
  and replays the stored header; `idempotency.Store.Put` is a `Create`; the quota and the list are written in the same transaction; the cache
  and the Snowflake node are mutex-protected. In every run the invariants held: exactly one list document and `listCreates == 1`.
- The contract for a racer that loses and exhausts its re-runs is documented: `service.mapErr` answers a retryable UNAVAILABLE (the same as
  messaging's "busy" racer, which `TestSend_ConcurrentSameKeyIsOneMessage` already accepts). The old test demanded that all four racers succeed.
- Timing: a contended call takes 2.0 to 3.4 s on the emulator whatever the number of racers (4, 16 and 32 were measured: the delay is the SDK's own
  backoff on the losers), against a 5 s `txTimeout`. A slower runner (CI runs this with `-race`) pushes a loser past the timeout and the test fails with the
  product's correct answer. The same package, run in parallel with 15 others against one emulator, answered `temporarily busy, please retry` to an
  uncontended `TestCreateList_Integration_Budget` (section 6), which shows the margin is load-dependent, not racy.
- Not reproduced: 30 runs alone, plus 24 rounds from 8 processes against one emulator, all passed. No CI log of the failure was available
  (the last 100 failed `ci` runs contain no `ConcurrentSameKey`; the only `DATA RACE` in them is the `newReadEnv` map race fixed by #529). The verdict
  therefore rests on the code and the timing, not on a captured failure. **If it still fails after this change, the failure text is the discriminator:**
  `lists = 2` or `listCreates = 2` is a product race (High); a `DATA RACE` frame in `docCache`, `service` or the repo is a product race; anything else is timing.

The rewrite follows the messaging precedent: at least one racer succeeds; a racer that did not must have received UNAVAILABLE (nothing written);
every success returns the same list id; each busy racer's retry with the same key replays that id; exactly one list document; `listCreates == 1`.
`txTimeout` and `maxTxRuns` are production constants and were not touched.

## 5. Defects

None in production code. No `t.Skip("W5-15 D-n")` repro was needed.

## 6. Observations (not defects)

1. **Same-class test risk.** `TestAddMember_Integration_ConcurrentSameKey` (two racers, both must succeed) has the same strictness as the old
   CreateList test and could flake the same way. It was not changed here (it has not been seen to fail); apply the same pattern if it does.
2. **Load sensitivity of the emulator suite.** Running all packages at once (`go test ./...`, the default `-p`) against one emulator produced five
   timing failures in packages this ticket does not own (`engagement TestBookmarkRepo_SamePostDifferentKeysConcurrently`, `media TestW320Banner_RacyRuleAndUnitsOnTheRealRepo`,
   `moderation TestRepo_AccountEvidenceRoundTripAndPostReportsKeepTheirShape`, `timeline TestHome_WorstCaseAtTheFollowingCapAndBoundedConcurrency`) and `lists
   TestCreateList_Integration_Budget` (`temporarily busy`). All passed when the packages were run one at a time (`-p 1`, as W7-20 did). On a loaded
   machine use `-p 1`.
3. **Caller-blocks-owner on a list read.** ADR-0030 D3 lists "the owner blocks the caller" as NOT_FOUND but does not name the reverse (the caller
   blocks the list's owner). The unit matrix (`TestListUserLists_Visibility`, `TestGetList_D3Matrix`) pins what the code does; nobody has decided that it is
   intended. A question for the architect, not a defect.
4. **Lint.** `golangci-lint --build-tags integration` reports 3 `errcheck` findings in `repo_members_integration_test.go` (lines 238, 467, 615: `wantCode`
   results ignored) and 4 findings in `search_chain_integration_test.go`. None is in a line this ticket added. CI runs lint without the integration tag, which is why they are not red.
5. **Emulator ports on Windows.** Fixed ports in the 57xxx range collided repeatedly with a Pub/Sub emulator JVM that leaves a self-connected socket
   behind after `emulators:exec`; the runs used a random 57xxx base per try. Not a repo problem, noted for `docs/runbooks/emulator-collisions.md`.

## 7. Results

| Run | Result |
|---|---|
| `go test ./internal/lists/` (unit, new page-size tests) | pass |
| `go test -tags=integration ./internal/lists/` against the emulators, with coverage | pass; coverage of `internal/lists` **91.2 %** of statements (unit + integration) |
| `go test -tags=integration -run TestW515_ ./internal/apiserver/` | pass, 8 tests |
| `-run TestAccountLifecycle_ExportContentsGolden` (regenerated, then re-run without `-update-golden`) | pass |
| `TestCreateList_Integration_ConcurrentSameKey` x30 (before the rewrite, no `-race`) and x5 (after) | pass |
| Whole module, `go test -tags=integration -p 1 -coverprofile=... -coverpkg=./internal/... ./...` (the `make test-int` command) | COVERAGE_RESULT |
| Unit only, `-coverpkg=./internal/...` | 64.2 % of `internal/` (expected: the repositories are only exercised by the integration run; the gate is on the combined number) |

Budgets measured through the real chain (request-line `fs_reads` / `fs_writes`, interceptor included; ceilings are the ADR figures):

| RPC and shape | Measured | ADR-0030 |
|---|---|---|
| SetHomeTabs refused (flag off / not allowlisted) | 1 / 0 | 1 / 0 |
| SetHomeTabs, 5 foreign lists of 5 owners, cold | 19 / 2 | 19 / 2 |
| SetHomeTabs, reorder of stored (dangling) tabs | 2 / 2 | <= 4 / 2 |
| SetHomeTabs, sixth tab | 0 / 0 | before any read |
| GetMe cold, with 3 dangling tabs vs none | 2 vs 2 | +0 |
| CreateList over the daily quota | 3 / 0 | <= 4 / 0 |
| AddListMember over the daily quota | 6 / 0 | <= 6 / 0 |
| GetList, ListUserLists, ListListMembers, GetListTimeline in readonly mode | 5, 1, 2, 3 reads / 0 writes | writes 0 |

## 8. Not run

- **`-race`.** No cgo on this machine; CI runs it. The rewritten concurrent test and the new tests share no state between goroutines except through the service under test.
- **Real-Firestore index proof.** The emulator never reports a missing index; the `ownerId ==` and `memberIds array-contains` queries are first proven on dev by W5-19. A "requires an index" error there means stop and ask (ADR-0030 D2).
- **Load shapes** (150 members all posting; 6 tab switches a minute): W5-18.
- **Flutter / client tests:** W5-16. Security review of private-list confidentiality and member-page scraping: W5-17.
- **`make ci` end to end** (Flutter analyze/test, buf): not part of a backend-tests ticket; `gofmt` and `go vet -tags=integration` are clean, and the packages touched are lint-clean for the lines added.

VERDICT: PASS
