# Test report: UI wave W4 (search and trends), backend (W4-20), 2026-10-31

Plan: `docs/plans/ui-w4-discovery-search.md` (W4-20). Design: ADR-0028. The client half is `docs/reviews/test-report-w4-client.md` (W4-21).
Tester: tester agent. Branch `test/ui-w4-20-search-tests` on `main@be90d1bd` (W4-4 to W4-10 merged: #469, #467, #478, #481 and the SearchPeople PR #479).
The load shapes (a hot tag at 50 posts a minute, a 600-entry typeahead burst) are W4-23 and are not run here.

**Result: W4-20 is complete (every criterion has a named test), with one Low production defect, D-1, found by a flaky existing test.** Every acceptance criterion of W4-3 to W4-10 and every bullet of
the W4-20 description has a named test (section 3). The audit found that the package tests already covered the logic; what no test covered was
the **whole request through `apiserver.Build`** (the account-status read, the rate limiters, the shared `search_daily` cap, the read budget, the
degraded-mode gate, the `/internal/*` wall). The new file `backend/internal/apiserver/search_chain_integration_test.go` (14 test functions) adds
exactly that, and measures the documented per-RPC figures on a **cold second `Build`** from the request log's `fs_reads` / `fs_writes`.

---

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| New chain tests | `GOWORK=off go test -tags=integration -count=2 -run TestSearchChain ./internal/apiserver/` against the emulators | green, twice in a row (unique tags, no leftover state) |
| Whole module, one package at a time | `go test -tags=integration -p 1 -count=1 -coverprofile=... -coverpkg=./internal/... ./...` (the `make test-int` command) | **green**, 21 packages `ok`, none failed (apiserver alone 800 s, so `-timeout 40m`), combined `internal/` coverage **93.1 %** (gate 70 %). The first attempt with the default 10 min timeout timed out in `apiserver` while Flutter tests ran on the same machine; an earlier run also failed `TestTrends_ConcurrentColdCallersShareOneRead` (D-1) |
| gofmt, `go vet -tags=integration ./internal/apiserver` | | clean |

Environment notes:
- `-race` was not run: CGO is off on this Windows machine. CI on Linux runs it.
- Emulators ran from a scratch config outside the repo (every port in 58xxx: hub 58400, logging 58500, Firestore 58080, Auth 58099, Pub/Sub 58185,
  Storage 58199, UI off) behind `scripts/with-private-tmp.sh`, started with `emulators:start`. Pub/Sub 58085 refused to bind once on this
  machine ("port is not open"), so it was moved to 58185. An `emulators:exec` with a `GOWORK=off` prefix cannot work on Windows (the command line runs in
  `cmd.exe`), which is why the final run is the same `go test` command `make test-int` runs, not `make test-int` itself. The scratch config is not committed.
- A first whole-module run was lost when the emulators were interrupted mid-run (an `engagement` bookmarks test then timed out at 60 s); it was rerun from scratch.
- Nothing was run against dev or prod.

## 2. What was added

`backend/internal/apiserver/search_chain_integration_test.go` (build tag `integration`). It reuses `newChain`, `mintToken`, `authed`, `wireError`,
`asConnectErr`, `relaxLimits` and `logs.requestLines`.

| Test | Covers |
|---|---|
| `TestSearchChain_FlagModes` | off / allowlist / percent / on for `search` (SearchPeople and SearchPosts) and for `trends` (GetTrends) through the real registry; FEATURE_DISABLED with `feature=search\|trends`; at most the interceptor's read; the two flags are independent; the percent split is found with the registry's own bucket function; `GetMe.enabled_features` for an allowlisted and a foreign uid |
| `TestSearchChain_BudgetTable` | SearchPeople limit 5 = **7** reads and limit 20 (50 requested, clamped) = **22**, warm 0; SearchPosts TOP / LATEST / MEDIA first page = **33** (with `engagement` on, the documented userLikes read), LATEST older page = **23**, MEDIA scan call 18 (45 seeded posts; ceiling 33), warm 0; GetTrends cold = **2**, warm 0; writes and deletes 0 throughout |
| `TestSearchChain_GrammarRejectionsReadNothing` | empty, `@`, `#`, 51 code points, BEL, RLO, RLI, newline, `#` + 51: VALIDATION `field=query` for both RPCs; one character: VALIDATION for people and a valid tag for posts; unsupported answers (`#go` for people, `a-b`, a zero-width space, `@alice`, `#12345`, two words, `#go!` for posts); GetTrends `prefix` (control, bidi, 51) and negative `limit`; every one at 0 reads beyond the interceptor |
| `TestSearchChain_PageTokenBinding` | a good token works; tampered, garbage, another caller, another tag, another tab and a TOP request all give VALIDATION `field=page_token` at 0 reads |
| `TestSearchChain_PerMinuteDefaults` | the shipped 30/min (SearchPeople) and 20/min (SearchPosts) buckets: the first RATE_LIMITED comes after 30 to 32 and 20 to 22 calls, and a second caller is not affected |
| `TestSearchChain_SearchDailyIsOneSharedCap` | with `SEARCH_CALLS_PER_DAY=4`, two people and two posts calls spend the one cap; the next call of either RPC is RATE_LIMITED with `limit=search_daily` and the request line's `limit_name`; GetTrends and another caller are unaffected |
| `TestSearchChain_BlockOracleIsByteIdentical` | a user who blocks the caller: SearchPeople returns the bytes of a prefix that matches nobody; a blocker's tag returns the bytes of an empty tag (after `normalized_tag`); controls: an unblocked user and a **muted** user are found, an unrelated tag shows its 3 posts; TOP and MEDIA hide the same posts |
| `TestSearchChain_SuspendedUsersAndTakenDownPostsAreAbsent` | real documents: a SUSPENDED and a DELETING user are absent from People; a TAKEN_DOWN post is dropped from TOP and LATEST on a cold instance |
| `TestSearchChain_ReadonlyKeepsAnsweringReads` | `DEGRADED_MODE=readonly`: all three RPCs still answer |
| `TestSearchChain_TrendsRefreshEndToEnd` | `/internal/cron/trends-refresh` (GET is 405): 3 authors on a tag trends with authors 3 and posts 3; 5 posts by one author does not; a denylisted tag is absent; `computedAt` is written; one `trends_refresh` line and no uid in the log; GetTrends from a cold instance serves it and the typeahead `prefix` filters it with a rank; a retry is `trends_skipped reason=fresh` and the list is not replaced |
| `TestSearchChain_TrendsRefreshSwitches` | `FEATURE_TRENDS=off` (kill switch) and `readonly`: 204, document unchanged, one `trends_skipped` line with `fs_reads:0` and `fs_writes:0`; percent 0 and an empty allowlist are rollouts, so the refresh runs |
| `TestSearchChain_TrendsRoutesNeedOIDC` | with the verifier configured: no header, a garbage bearer and an Auth-emulator ID token give 401 on `/internal/cron/trends-refresh` and `/internal/cron/daily-maintenance`, also under `/api`; the refresh did not run |
| `TestSearchChain_DailyMaintenanceRunsTheTrendsStep` | F1 = B: one POST to `/internal/cron/daily-maintenance` answers 204 and the trends step wrote the list |
| `TestSearchChain_RequestLinesCarryNoRawQuery` | the request lines: `query_kind`, `query_len`, `results`, `cache_hit` (miss then hit) for SearchPeople, `tab` for SearchPosts, `results` / `cache_hit` / `computed_age_s` for GetTrends; the raw query appears in no log line |

## 3. Traceability

Paths: `srch/` = `backend/internal/search/`, `api/` = `backend/internal/apiserver/`, `ident/` = `backend/internal/identity/`,
`posts/` = `backend/internal/posts/`. "chain" = through `apiserver.Build` with the interceptors; "new" = added by this ticket.

### W4-3: flag, config, skeleton
| Criterion | Test(s) |
|---|---|
| `FEATURE_SEARCH` unset: FEATURE_DISABLED `feature=search`, 0 reads; GetTrends with `trends` | `srch/people_test.go:TestPeopleFlagModes`, `srch/service_posts_test.go:TestPosts_FlagDisabledReadsNothing`, `TestPosts_FlagModesWithRealRegistry`, `srch/trends_service_test.go:TestTrends_FlagOffReadsNothing`, `srch/service_test.go:TestFlagModes`; chain: `TestSearchChain_FlagModes` (new, 0 to 1 read) |
| allowlist: `GetMe.enabled_features` for that uid only | `TestSearchChain_FlagModes` GetMe section (new) |
| `check-flag-registry.sh`; `guard_test.go` sees both RPCs in the read budget and the daily cap | `api/search_guard_test.go:TestSearchWiring_Guard` (and its mutations); the registry script is unchanged and was not rerun (no flag edit) |
| config bounds (reject zero / negative) | `pkg/platform/config/search_test.go:TestLoad_SearchDefaults`, `TestLoad_SearchOverridesAndValidation` |

### W4-4: handle-prefix reader
| Criterion | Test(s) |
|---|---|
| `ab_c`, `abc`, `abd` in `handleLower` order | `ident/search_handles_integration_test.go:TestSearchHandles_Integration` (case "ab: handleLower order") |
| `succ` per character (`_` to backtick, `z` to `{`) | same, cases "z: succ is {", "ab_: succ of _ is a backtick"; `TestPrefixSucc` |
| limit 50 clamps to 20 | same (25 handles under one prefix) |
| no match charges 1 read | same (exact `budgettest` counts) |

### W4-5: SearchPeople
| Criterion | Test(s) |
|---|---|
| `@Ali` finds `ali` with relationships | `srch/people_integration_test.go:TestSearchPeople_Integration`, `srch/people_test.go:TestPeopleRelationshipsAndPrivacy`; chain `TestSearchChain_BudgetTable` (`@` + upper-case prefix, new) |
| a user who blocks the caller is absent; bytes match a non-existent user | `srch/people_test.go:TestPeopleBlockOracle`, `TestPeopleFilters`; chain `TestSearchChain_BlockOracleIsByteIdentical` (new, wire bytes) |
| a suspended user is absent | `TestPeopleFilters`; chain `TestSearchChain_SuspendedUsersAndTakenDownPostsAreAbsent` (new, real documents) |
| 1 character: VALIDATION with 0 reads | `TestPeopleQueryRules`; chain `TestSearchChain_GrammarRejectionsReadNothing` (new) |
| 31 calls in a minute: RATE_LIMITED | chain only: `TestSearchChain_PerMinuteDefaults` (new) |
| the 301st call in a day: RATE_LIMITED `search_daily` | chain only: `TestSearchChain_SearchDailyIsOneSharedCap` (new, cap lowered to 4; the shared-cap wiring is also `TestSearchWiring_Guard`) |
| warm entry: 0 reads | `TestPeopleCache`, `TestPeopleEmptyEntrySkipsGraph`; chain `TestSearchChain_BudgetTable` (new, warm 0) |
| budget 7 / 22 cold | chain `TestSearchChain_BudgetTable` (new): **7 / 22 measured** |
| both block directions; a muted user stays; a cache entry shared by two viewers filters per viewer | `TestPeopleFilters` (blocked, blockedBy, muted, overflow), `TestPeopleCache`; chain oracle test (muted user found, new) |
| log fields, never the raw query | `srch/people_test.go` request-line assertions; `srch/service_posts_test.go:TestRequestLine_FieldsAndNoQuery` (posts) |

### W4-6: posts reader methods
| Criterion | Test(s) |
|---|---|
| 25 tagged posts: pages 20 + 5 (6 with the extra), newest first, window honoured | `posts/hashtag_reader_integration_test.go:TestRepo_Integration_ByHashtag` (exact reads) |
| a REPOST never matches | same |
| `CreatedAfter` strictly newer, in order, ties by id | `TestRepo_Integration_CreatedAfter`, `posts/hashtag_reader_test.go:TestCreatedAfter` |

### W4-7: SearchPosts LATEST
| Criterion | Test(s) |
|---|---|
| 45 posts: 20 + 20 + 5 with `""` | `srch/service_posts_test.go:TestLatest_PagesOf20Plus20Plus5`, `TestLatest_PageSizeEdges`; `srch/integration/search_posts_integration_test.go:TestSearchPosts_Budgets` |
| foreign or tampered token: VALIDATION `page_token`, 0 reads | `TestPageToken_Rejections` (tampered, garbage, another caller, tag, tab, a media token, a TOP token, **expired** with a fake clock); chain `TestSearchChain_PageTokenBinding` (new, wire; "expired" stays below the chain because it needs a clock) |
| a blocked author's post is dropped and the token still advances | `TestLatest_DroppedPostStillAdvancesToken`, `TestFilter_Matrix`, `srch/integration/...:TestSearchPosts_BlockedAuthorAgainstTheRealGraph` |
| a taken-down post in a warm entry is dropped at serve time | `TestEntry_TakedownInWarmEntryIsDropped`; chain `TestSearchChain_SuspendedUsersAndTakenDownPostsAreAbsent` (new, a real document) |
| `#Go` and `go` give `normalized_tag` `go` | `TestPosts_HashAndPlainWordShareATag`; chain `TestSearchChain_BudgetTable` (`normalized_tag` asserted, new) |
| 21 calls a minute: RATE_LIMITED | chain only: `TestSearchChain_PerMinuteDefaults` (new) |
| budget 33 cold page 1; 23 / 53 older; 0 to 3 warm | `srch/integration/...:TestSearchPosts_Budgets` (service level, minus the interceptor); chain `TestSearchChain_BudgetTable` (new): **33, 23, warm 0 measured** (53 for page size 50 is the service-level test) |
| the D6 drop matrix (blocked, blockedBy, muted, QUOTE embed, `!Visible()`, protected, overflow) | `TestFilter_Matrix`, `TestFilter_ProtectedFollowedAuthorShowsFollowersVisibility`, `TestFilter_ProtectedSetUnavailableFailsClosed` |
| two viewers share an entry; concurrent misses share one load | `TestEntry_SharedAcrossViewersAndTabs`, `TestEntry_ConcurrentMissesShareOneLoad` |

### W4-8: TOP and MEDIA
| Criterion | Test(s) |
|---|---|
| 0 / 5 / 2 likes order 5, 2, 0; an 8-day-old post is excluded | `TestTop_RankingWindowAndCap`, `TestTop_ScoreWeightsAndOnePageOf20`, `TestTop_Deterministic` (the determinism test of the notes), `TestTop_FiltersBeforeRanking` |
| 3 media posts among 30: MEDIA page 1 returns 3 | `TestMedia_EntryScanAndEnd`, `TestMedia_ShortEntryHasNoToken`, `TestMedia_FiltersApplyToMediaRows` |
| a scan page with 0 media: `[]` plus a token; the scan that reaches the end: `""` | `TestMedia_EntryScanAndEnd`, `TestMedia_TruncationResumesAfterTheLastReturnedRow` |
| TOP 33 cold / MEDIA scan 33 | chain `TestSearchChain_BudgetTable` (new): TOP 33, MEDIA first page 33, MEDIA scan call 18 (fewer rows seeded than the 30 scan cap) |

### W4-9: trends refresh
| Criterion | Test(s) |
|---|---|
| 5 posts by 1 author with `#spam`: does not trend | `srch/trends_refresh_test.go:TestRefresh_Counting`; `srch/trends_integration_test.go:TestTrends_Integration_RefreshAndGetTrends`; chain `TestSearchChain_TrendsRefreshEndToEnd` (new) |
| 3 authors with `#launch`: trends with authors 3 | same three |
| a taken-down post (and a REPOST, and a protected author's post) is not counted | `TestRefresh_Counting`, the integration test; chain end to end does not seed these (service level covers them) |
| a denylisted tag is absent | `TestRefresh_Counting`; chain end to end (new) |
| 2,500 new posts, cap 2,000: 2,000 counted, watermark at the 2,000th, the next run continues | `TestRefresh_Cap_Resume_And_StaleWatermark` |
| flag globally off: 0 reads; percent 0 is not a kill switch; readonly | `TestRefresh_Switches`; chain `TestSearchChain_TrendsRefreshSwitches` (new, with the `trends_skipped` line at `fs_reads:0 fs_writes:0`) |
| route: POST only, OIDC, 204 / 500, panic recovery | chain GET 405 (new), `TestSearchChain_TrendsRoutesNeedOIDC` (new); `api/routes_integration_test.go` (401 without credentials, already there); `TestRefresh_Failures` for the 500 paths |
| budget: 1 + new posts reads, 1 write; time budget with a fake clock | `TestRefresh_Budget`, `TestTrends_Integration_RunBudget` |
| `lifecycle_collections_guard_test.go` has a `trends` row | `api/lifecycle_collections_guard_test.go` (row at line 126, passing) |
| no uid in logs | chain end to end (new): the log of the run is scanned for the four author uids |

### W4-9b: cron host
| Criterion | Test(s) |
|---|---|
| backstop fails: 500 whatever trends did | `api/daily_maintenance_test.go:TestDailyMaintenance_StatusMatrix` (all nine cells) |
| trends fails or is skipped: status is the backstop's alone | same |
| a retry minutes after a good run: skipped as `fresh`, list not replaced | `TestRefresh_FreshSkipAndWindow`; chain `TestSearchChain_TrendsRefreshEndToEnd` (route) |
| the backstop takes 26 s: `trends_skipped reason=deadline` | `TestDailyMaintenance_StatusMatrix`, `TestDailyMaintenance_StepDeadline` |
| the real route runs the step | chain `TestSearchChain_DailyMaintenanceRunsTheTrendsStep` (new) |

### W4-10: GetTrends
| Criterion | Test(s) |
|---|---|
| warm cache: 0 Firestore reads | `srch/trends_service_test.go:TestTrends_CacheTTLAndBudget` (fake clock for the TTL); chain `TestSearchChain_BudgetTable` (new, warm 0) |
| `prefix=la`: only tags starting with it, in rank order | `TestTrends_ListPrefixLimitAndRanks`; chain (new, `#LAM` against `launch, lamp, go`; then after a refresh the prefix on a real list) |
| flag off: FEATURE_DISABLED `trends`, 0 reads | `TestTrends_FlagOffReadsNothing`; chain `TestSearchChain_FlagModes` |
| no document yet: an empty list | `TestTrends_NoDocumentIsAnEmptyList`; `TestTrends_Integration_RefreshAndGetTrends` |
| budget 2 cold | chain `TestSearchChain_BudgetTable` (new): **2 measured** |

### The W4-20 description bullets
| Bullet | Where |
|---|---|
| flag modes off / allowlist / percent / on for `search` and `trends`, plus the refresh kill switch (`off` only) | `TestSearchChain_FlagModes`, `TestSearchChain_TrendsRefreshSwitches` |
| grammar table, each rejection at 0 reads | `srch/people_query_test.go`, `srch/service_posts_test.go:TestPosts_Grammar`, `TestQueryGrammarFixture` (shared `testdata`), `TestSearchChain_GrammarRejectionsReadNothing` |
| `budgettest` per the RPC table | the section 4 table |
| block oracle (People and Posts byte-identity) | `TestSearchChain_BlockOracleIsByteIdentical` |
| cursor tampering and binding (another uid, tag, tab, expired) | `TestPageToken_Rejections` (all four), `TestSearchChain_PageTokenBinding` (wire) |
| the D6 drop matrix on hashtag results | `TestFilter_Matrix` and the real-graph integration test |
| rate limits and `search_daily` | `TestSearchChain_PerMinuteDefaults`, `TestSearchChain_SearchDailyIsOneSharedCap` |
| trends: distinct authors, min authors, denylist, `!Visible()`, cap and resume, readonly, the composite cron status matrix | `trends_refresh_test.go`, `daily_maintenance_test.go`, plus the chain tests above |
| the guard-test row | `TestSearchWiring_Guard`, `lifecycle_collections_guard_test.go` |

## 4. Budget results per RPC (whole request, cold second `Build`, from the request log)

| RPC and case | Measured reads | Documented ceiling | Writes |
|---|---|---|---|
| SearchPeople, limit 5 | **7** | 7 | 0 |
| SearchPeople, limit 20 (50 asked) | **22** | 22 | 0 |
| SearchPeople, warm | 0 | 2 | 0 |
| SearchPosts TOP / LATEST / MEDIA, first page | **33** each | 33 | 0 |
| SearchPosts LATEST, older page (20) | **23** | 23 | 0 |
| SearchPosts MEDIA, scan call (45 posts seeded) | 18 | 33 | 0 |
| SearchPosts, warm | 0 | 3 | 0 |
| GetTrends, cold | **2** | 2 | 0 |
| GetTrends, warm / prefix | 0 | 1 | 0 |
| any FEATURE_DISABLED, any grammar rejection, any bad `page_token` | 0 to 1 (the interceptor's, 0 once the profile is cached) | 1 | 0 |

The exact figures equal the proto doc comments, so a regression to FEWER reads (a skipped filter or cache) would also be visible in the `W4BUDGET`
log lines the tests print; the assertions are ceilings. SearchPosts older page at `page_size` 50 (53) is asserted at service level only.

## 5. Defects
**D-1 (Low). `GetTrends` instance cache can read `trends/current` more than once per TTL under a burst, and `TestTrends_ConcurrentColdCallersShareOneRead` is flaky (about 3 % of runs).**`backend/internal/search/trends_service.go` lines 52 to 76 (the cache `get`): the TTL check happens under the mutex, the lock is released, and only then `sf.Do("current", ...)` runs. A caller that passed the check before a load finished, but reaches `sf.Do` after it returned, starts a second load. The closure does not re-check the cache.- Repro: `GOWORK=off go test -count=3000 -run TestTrends_ConcurrentColdCallersShareOneRead ./internal/search/` gave 89 failures in 3,000 (`store reads = 4 for 20 concurrent callers, want 1 (2 tolerated for a late race)`, `trends_service_test.go:286`); one whole-module run of this branch failed on it too.- Expected: at most one read per instance per TTL (the proto comment: "at most one doc read per instance per 10 min"). Actual: up to a few reads in a burst. The cost impact is negligible (a handful of reads, never one per caller); the real harm is a red CI run roughly one in thirty.- Suggested fix for the owner (backend-developer): re-check `c.doc` / `c.loaded` and the TTL inside the `sf.Do` closure before calling `store.Get`.Test-side finding fixed during the work: the first cut of the flag test computed the percent bucket with the arguments of `Registry.Enabled` swapped (it is `(uid, name)`); corrected, no production change.**W4-27 note.** W4-27 (#491) will change LATEST paging (fixed windows, the token from the last returned row). `TestSearchChain_BudgetTable` (the older-page figure 23 at page size 20) and `TestSearchChain_PageTokenBinding` (page 2 of 45 posts gives 20 rows) use today's `page_size`-dependent behaviour only as a setup; they assert the token binding and the documented read ceiling, and the older-page figure is the W4-27 case to revisit when it lands.

## 6. Observations (not defects)

- O-1. A real Google-signed OIDC token with the wrong audience cannot be minted offline, so the wall is tested with the cases an emulator can mint
  (none, garbage, an Auth-emulator ID token). The verifier's own audience and email checks are `pkg/platform/pubsubpush` unit tests.
- O-2. `TestSearchChain_PerMinuteDefaults` asserts "30 to 32" and "20 to 22" calls before the first RATE_LIMITED, not exactly 30 and 20: the bucket
  refills 0.5 and 0.33 tokens a second, so a loop that takes a few seconds can win one extra token. The exact per-minute figure is the limiter's unit test.
- O-3. The whole-request figures are measured on one instance. Three instances multiply the per-instance caches (cost table), which is `sre-performance`'s.
- O-4. The `trends` collection is shared by every test in the emulator project; the chain tests prime `trends/current` with a watermark five
  minutes back, so a refresh scans only posts seeded since then. They do not run in parallel.

## 7. Not run

`-race` (no CGO here), the W4-23 load shapes, anything against dev or prod, `check-flag-registry.sh` (no flag or Terraform edit in this PR).

VERDICT: FAIL — D-1 (Low): flaky GetTrends cold-cache singleflight test and its cause, trends_service.go:52-76; no other defect
