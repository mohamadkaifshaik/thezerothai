# Test audit: posts-and-timeline T19 and T20

Date: 2026-10-06. Branch: claude/gracious-babbage-2barib. Auditor: tester.
Method: static read of every `*_test.go` that could cover the two tickets, plus `go vet -tags=integration` (clean) and
`go test -cover` on the unit packages. Emulators and `make test-int` were NOT run, so "tests pass in CI" is taken from the
plan, not re-verified here. Production code and tests were not changed.

Rules applied: a test counts only if its assertions fail when the behaviour breaks. A budget ceiling counts only if an
assertion fails when it is exceeded (`budgettest.Assert` is a `<=` ceiling on reads, writes and deletes).
"unit" = fakes, no emulator. "emu" = `//go:build integration` against the Firestore emulator.

## Summary

| Scope | Items | COVERED | PARTIAL | MISSING |
|---|---|---|---|---|
| T19 (Description + Acceptance bullets) | 29 | 16 | 12 | 1 |
| T20 (Description + Acceptance bullets) | 24 | 15 | 9 | 0 |
| **Ticket bullets total** | **53** | **31** | **21** | **1** |
| ADR-0010 D6 matrix cells (12 rows x 5 RPC columns) | 60 | 28 | 8 | 24 |
| Budget ceilings table (below) | 18 | 14 | 2 | 2 |

Headline gaps:

1. No posts invariant checker exists (`users.postsCount` == count of `posts` by `authorId`), and nothing in `code-map.md` for it.
2. The D6 matrix is only half exercised: GetHomeTimeline never asserts that SUSPENDED, DELETING or doc-missing authors are still
   included, nor the overflow row (no extra read), nor both-block; DeletePost is tested for one relationship only; CreatePost
   mentions skip own, follows, both-block, mute, SUSPENDED and DELETING.
3. The two T20 acceptance scripts (P0 random-handle loop; mint-and-rotate unverified accounts) exist only as components.
4. Budget ceilings never asserted: home older page (269), settle-window re-reads, user timeline cold page with p < 20, cold
   replay / reused key (14).
5. Posts IST rollover, D21 G2 and G5 end to end, D13 on the user timeline, D14 since-token posts<->replies binding.

## T19 table

| # | Bullet | Status | Evidence | Gap |
|---|---|---|---|---|
| D1 | Contract tests CreatePost: happy path + every documented ErrorReason | PARTIAL | Service-level unit: FEATURE_DISABLED+metadata `service_create_test.go:199`, VALIDATION `:226`, EMAIL_NOT_VERIFIED `:250`, PROFILE_REQUIRED `:282`, IDEMPOTENCY_KEY_REUSED `:289`, NOT_FOUND replay of deleted `:326`, QUOTA_EXCEEDED `:361` (+ emu `create_integration_test.go:238`). Handler: `server_test.go:135` (happy + VALIDATION), `:88` (FEATURE_DISABLED). Wire/chain: `apiserver/posts_wiring_test.go:31` (UNAVAILABLE), `posts_ratelimit_test.go:23` (RATE_LIMITED), `e2e/posts_flag_test.go:26`. | No Connect-wire assertion of the ErrorDetail (reason + metadata) for EMAIL_NOT_VERIFIED, PROFILE_REQUIRED, QUOTA_EXCEEDED, IDEMPOTENCY_KEY_REUSED; ACCOUNT_RESTRICTED never asserted for CreatePost; no golden request/response (grep: no golden for posts/timeline). |
| D2 | Contract DeletePost | COVERED | VALIDATION field `post_id` / `idempotency_key` `service_delete_test.go:132` (0 reads); success/no-op `:45,:89`; handler `server_test.go:162`; flag `server_test.go:88`. | None material. |
| D3 | Contract GetPost | COVERED | NOT_FOUND exact message `post not found`, empty metadata `service_delete_test.go:180,190`; byte-identical `:243`; VALIDATION `:279`; emu `service_delete_integration_test.go:190`. | None material. |
| D4 | `budgettest.Assert` on every call | PARTIAL | Used on create `create_integration_test.go:136,186,193,301,308,318,359`; delete `service_delete_integration_test.go:72,81,88,104,118`; GetPost `:207,:213,:241`. | No Assert on: the first create and the 10-way concurrent creates (`create_integration_test.go:178,208`); quota-rejection reads (`:255`, only Writes==0); `in2.create` overflow (`:331`); every GetPost NOT_FOUND call (`service_delete_integration_test.go:219-265`); concurrent deletes (sums writes/deletes only, `:156-172`). `budgettest` has no self-test proving `Assert` fails (see AC2). |
| D5 | Replay with same key, sequential | COVERED | `create_integration_test.go:182-186` same id, 1 read, 0 writes; counts of posts/postsCount/quotas/idempotency docs `:222-233`; unit `service_create_test.go:289`. | None. |
| D6 | Replay with same key, concurrent | COVERED | 10 goroutines, two instances, one key: all return the same id, exactly 2 posts total, counters 2 (`create_integration_test.go:195-233`). | None. |
| D7 | Reused key with a different body | COVERED | `create_integration_test.go:188-193` (reason IDEMPOTENCY_KEY_REUSED, <=1R 0W); unit `:315`. | None. |
| D8 | Quota exhaustion | COVERED | emu `create_integration_test.go:238-268`: 100 established, 20 new; QUOTA_EXCEEDED, RESOURCE_EXHAUSTED, `metadata.quota=posts`, no post/idempotency doc, postsCount 0; unit `service_create_test.go:361`. | None. |
| D9 | IST rollover (quota) | PARTIAL | `quota_test.go:44` (TodayAt boundary) and `graph/mutations_integration_test.go:738` (follows quota seeded yesterday resets). Shared `quota.Get` day check. | No posts test seeds `quotas/{uid}` with a yesterday `day` and `posts=100` and then creates successfully. |
| D10 | New-account quota | COVERED | emu `create_integration_test.go:245` (24 h window, limit 20); unit tiers incl. exactly-at-window boundary `service_create_test.go:335`. | None. |
| D11 | Concurrent deletes | COVERED | `service_delete_integration_test.go:126`: 5 cold instances race; total writes==1, deletes==1, postsCount 2->1, other post survives. | None. |
| D12 | Reusable posts invariant checker + code-map entry | MISSING | None. `countByAuthor` / `countDocs` exist (`service_delete_integration_test.go:289`, `create_integration_test.go:93`) but no test compares `users.postsCount` to `count(posts where authorId)`; `docs/code-map.md` has no such line (graph has `assertGraphInvariants`, line 97). | Whole bullet. |
| D13 | D6 matrix, GetPost | PARTIAL | See matrix: 8 C, 2 P, 2 M. | Both-block; A follows B; DELETING with the real Directory status. |
| D14 | D6 matrix, CreatePost mentions | PARTIAL | See matrix: 5 C, 1 P, 6 M. | Own handle, follows, both-block, mute, SUSPENDED and DELETING author all unasserted; overflow and B-blocks-A asserted on emu `create_integration_test.go:281`. |
| D15 | D6 matrix, DeletePost | PARTIAL | See matrix: 2 C, 1 P, 9 M. Only "stranger" is exercised (`service_delete_integration_test.go:68`, `service_delete_test.go:89`). | No relationship rows (blocks, mute, suspended, overflow, doc missing). Structurally Delete reads no graph, so low risk, but the plan says every row is a case. |
| D16 | DeletePost other user / unknown / already deleted: identical success, 0 writes, 0 deletes | COVERED | emu `service_delete_integration_test.go:68-107` (success, `Budget{Reads:1}` so any write/delete fails, post survives, postsCount stays 0 on repeat); unit `service_delete_test.go:89,120`. | Response bodies are empty, so "byte-identical" is trivially true. |
| D17 | D7/D8 example tables end to end (stored `mentions`/`hashtags`) | PARTIAL | Parser tables verbatim: `text/text_test.go:33` (every D7 example), `:84` (every D8 example), `:127` (11 tags -> 10), shared fixture `fixture_test.go:55,86`. Stored shape on emu: `create_integration_test.go:146-149,324` (`#World`->`world`; `@bob @carol`; 11 mentions -> 10 `:339`). | No stored-doc rows for Devanagari, case-insensitive dedupe, `#123` none, 11 hashtags -> 10 stored with text unchanged, NFC. |
| D18 | D21 G1: `https://ex.com/?ref=@bob` stores no mention, 0 `handles/*`, 0 `graph` reads | COVERED | emu `create_integration_test.go:304-308`: mentions empty and Reads <=2 (idempotency+quotas), so any handles/graph read fails; unit `service_create_test.go:135,136`. | Uses `@carol`, same shape. |
| D19 | D21 G2: U+2028 stored as `\n` | PARTIAL | Pure: `fixture_test.go:136` (9 `\n`, none left; 11 lines rejected), fixture `normalise` rows. | Never through `Create` into a stored doc. |
| D20 | D21 G4: invisible-only post is VALIDATION | COVERED | `service_create_test.go:236` (`​⁠` -> VALIDATION field=text, 0 reads, `createCalls==0`); fixture normalise rows. | None. |
| D21 | D21 G5: freed and reclaimed handle resolves to the new owner after 11 s | PARTIAL | `identity/resolve_handles_g5_test.go:14` (fake clock: 11 s -> carol, 1 read; 9 s + renamed profile -> carol; 9 s hit; residual pinned). | Plan asks for an emu row through CreatePost; identity unit only, nothing asserts `mentions[]` of a created post. |
| D22 | Purge crash-resume (descending query, T10) | PARTIAL | emu `service_delete_integration_test.go:307`: 1,203 posts, kill after batch 1 (cp.Deleted 500, 703 left), resume with the saved checkpoint -> 1,203 deleted in 3 calls, other user's 7 kept, 1203 reads/deletes, 0 writes. | No restart from a zero checkpoint (the real crash case when the checkpoint was lost; the comment at `:336` claims it works but does not run it); delete order (newest first) not asserted. |
| D23 | Degraded readonly | COVERED | `apiserver/posts_wiring_test.go:31`: CreatePost and DeletePost UNAVAILABLE (handler would panic on nil repo if reached); GetPost, both timelines reach handlers. | None. |
| AC1 | `internal/posts` coverage >= 70% | COVERED | `go test -cover ./internal/posts/...` = 71.1% (unit only, no emulator); `posts/text` 98.7%. | Thin margin without the integration suite; CI pass of `make test-int` not re-run here. |
| AC2 | Over-budget fails with RPC name and actual vs budget | PARTIAL | `budgettest.Assert` message: `"%s: Reads() = %d, want <= %d (documented budget)"` (`budgettest.go`). | No test of `budgettest` itself (no `_test.go` in that directory), so "fails when exceeded" is by reading, not by assertion. |
| AC3a | CreatePost <=14 / 2R 4W | COVERED | cold `create_integration_test.go:359` (`Reads:14, Writes:4`, 10 mentions); warm `:136` (2, 4). | Cold ceiling has 1 read of slack in this harness (actual 13). |
| AC3b | Replay and reused key <=14 / 1R 0W | PARTIAL | warm `create_integration_test.go:186,193` (1, 0). | Cold replay / cold reused-key ceiling (14) and replay on another instance (+1 post read) not asserted on emu; unit fake only (`service_create_test.go:310`, exactly 2). |
| AC3c | DeletePost <=2 / 0R, 1W/1D; no-op 0W/0D | COVERED | `service_delete_integration_test.go:72,81,88,104,118` (cold 1 read excl. interceptor; warm 0; no-ops 0W/0D). | None. |
| AC3d | GetPost <=4 / 0R, +1 overflow | COVERED | `service_delete_integration_test.go:207` (3 excl. interceptor), `:213` (0), `:241` (4 exact). | None. |

T19 count: 16 COVERED, 12 PARTIAL, 1 MISSING.

## T20 table

| # | Bullet | Status | Evidence | Gap |
|---|---|---|---|---|
| 1a | Refresh with 0 new posts == C (author-recent empty, graph warm) | COVERED | emu `timeline_integration_test.go:284` (`Reads()==3`, 0 posts, F=60); unit `service_test.go:191` (graph 1 + C 3 = 4). | None. |
| 1b | F=60, p=20 <= 2 + 3*14 = 44 cold | COVERED | unit dense data (every chunk fills k) `service_test.go:141,160` (<=43 excl. interceptor, 3 chunks); emu `timeline_integration_test.go:229` (`Reads:43`). | Emu data is sparse; the dense proof is the unit run. |
| 1c | Gap token never re-reads items older than the previous since | COVERED | unit `service_test.go:268` (every gap page strictly newer than the decoded old since, all fresh ids delivered, no dups); property `merge_test.go:159`. Fake enforces the After bound (`fakes_test.go:74`) so a missing bound returns old items and fails. | Not asserted on the emulator; asserts items, not a query read count. |
| 2 | Seeded F=5,000: home <= 2 + C + 2p = 269 | COVERED | emu `timeline_integration_test.go:412` (`Reads:268`, 5,000 ids, 8 real authors); unit `service_test.go:448` (<=268, C=167 chunks, concurrency bound). | Data is sparse (k=1), so the 2p term is not exercised; headroom ~90 reads before it fails. |
| 3a | GetUserTimeline <= 3 + max(p, 20) | PARTIAL | emu `:470` (p=20 -> 22), `:547` (p=50 -> 52), warm 0 `:480`, since-refresh 3 `:537`; unit `service_test.go:572,598`. | Cold first page with p < 20 (the `max` branch, `userFirstPageMax`) never budget-asserted. |
| 3b | Exact-multiple final empty page (D16) | COVERED | emu `:507-521` (40 posts: page 3 empty, no token, 1 read); unit `service_test.go:543` (3 reads cold). | None. |
| 4 | D6 matrix, both timelines | PARTIAL | See matrix: Home 5 C / 1 P / 6 M; User 8 C / 3 P / 1 M. emu `:346` (home), `:555` (user); unit `service_test.go:235,687`. | Home: stranger-not-present, both-block, SUSPENDED/DELETING/doc-missing still included, overflow no-extra-read. User: SUSPENDED/DELETING only via a fake that deletes the profile. |
| 5 | D13 regression (late commit older than a returned item is delivered) | PARTIAL | unit home `service_test.go:325` (p2 older than p1 delivered; p1 re-delivered). | GetUserTimeline has no equivalent (D13 says the same rule applies); `TestSinceClampedIsLogged :798` checks only the log flag; not on the emulator with a real commit. |
| 6a | D14 tamper | COVERED | `tokens_test.go:76` (since with altered tail), `:78` (garbage page), foreign key and raw cursor as window `:147`. | Page/gap token tamper not separately flipped (same AEAD codec). |
| 6b | D14 cross-binding home<->user, since<->page, caller A<->B, posts<->replies | PARTIAL | `tokens_test.go:32` (home vs other caller / user feed / replies feed for since+page+gap; since<->page both ways; Posts-tab page token on Replies); service `service_test.go:355,736` (mallory since; carol target since; user token on home). | User `since` token posts<->replies not asserted either direction; replies->posts direction not asserted for page tokens; caller A<->B on user page/gap tokens not asserted. |
| 6c | D14 expiry 30 d + 1 s rejected, 30 d - 1 s accepted | COVERED | `tokens_test.go:87` (25 h ok; 720 h - 1 s ok; 720 h + 1 s rejected; since and page/gap tokens, VALIDATION field); emu `:596` (25 h ok, 31 d VALIDATION with 0 reads). | Exact 720 h not pinned (not required). |
| 7a | T3: read budget rejects at the cap | COVERED | `ratelimit/readbudget_test.go:84` (reject at 2,000, 0 handler calls, IST reset), `:462` (2,001st rejected, `limit=read_budget_daily`); emu `graph/readbudget_integration_test.go:20` (charged = counter reads; exhausted -> 0 reads). | None. |
| 7b | T3: parallel hold never passes cap - 1 + M | COVERED | `daily_cap_test.go:221` (8 start values, herd of 32), `:256`; through the interceptor `readbudget_amend_test.go:406` (40 callers, exactly 1 admitted, spent <= bound). | `:446-449` polls with `time.Sleep(1ms)` (bounded; against the no-sleep policy). |
| 7c | T3: unverified password uids cost 0 reads | COVERED | `authn/gate_test.go:80` (rejected from claims; 0 account-status lookups; `gate` log value), `:37` allowlist table; e2e `identity_smoke_test.go:519` (fs_reads 0, no `limit_name`), `:561`. | None. |
| 7d | T3: verified uids without a profile are charged to their /64 | PARTIAL | `readbudget_amend_test.go:140` (charged to the IP key and marked; never rejected, A8), `:251` (A9). /64 keying separately `readbudget_test.go:369,395`. | The A3 charge path is tested with an IPv4 only; no test charges a profile-less uid from two IPv6 addresses in one /64 and asserts one shared meter. |
| 7e | T3: IP budget enforced on CheckHandle, charge-only on CreateProfile | COVERED (as amended) | The ticket text is superseded by ADR D5 A8 (IP key never rejects). `readbudget_amend_test.go:318` (both charge-only, admitted at a spent budget), `guard_test.go:162,179` (`ReadBudgetIPEnforce` must be empty; sets partition the exempt procedures). Enforcing seam kept alive by test-only config `:387`. | Plan wording is stale; should read "charge-only on both (A8)". |
| 7f | T3: the three account operations never rejected by the budget | COVERED | `readbudget_test.go:251`; through the wired config `guard_test.go:230` (uid 5,000 over budget, 20 calls pass, 21st RATE_LIMITED); guard `:162`. | None. |
| 7g | T3: /64 keying of the IP budget and both per-minute IP limiters | COVERED | IP budget `readbudget_test.go:369`, `:395` (canonical <=43-byte key); in-chain limiter `readbudget_amend_test.go:464`; pre-auth middleware `:484`; fallback `:507`. | IP-budget keying uses the test-only enforcing config. |
| 7h | T3: negative handle cache | COVERED | `identity/negative_handle_cache_test.go:15` (GetProfile and CheckHandle: repeat probe = 1 `ResolveHandle`; cleared on CreateProfile/ChangeHandle; stale hint cannot duplicate). | Unit only; the 10 s expiry is not asserted there. |
| 7i | T3: guard test fails when a fake uncapped read procedure is registered | COVERED | `guard_test.go:275` (synthetic NO_SIDE_EFFECTS RPC; budget nil, exempt without reason, exempt with reason, charge-only changes -> named violations; empty enumeration fails), `:179`. | Feeds a synthetic list rather than registering a handler; adequate. |
| AC1 | Matrix: every cell matches D6 | PARTIAL | See matrix. | 24 of 60 cells have no assertion, 8 partial. |
| AC2 | All measured reads <= ADR cold/warm ceilings | PARTIAL | See budget table. | Home older page, settle-window re-reads, user p<20 unasserted. |
| AC3 | P0 scenario: scripted CheckHandleAvailability + GetProfile loop on random handles; reads stop at the budget | PARTIAL | Components: `graph/readbudget_integration_test.go:20` (real reads charged; exhausted uid rejected with 0 reads; set by `Charge(2000)`, not by a loop), `readbudget_test.go:462` (2,001 unit calls, fake handler), `negative_handle_cache_test.go:15`, `guard_test.go:340` (101st CheckHandle). | No test drives the loop with real Firestore reads and asserts the cumulative `fs_reads` stops. |
| AC4 | Mint unverified password accounts, rotate over GetMe and CheckHandleAvailability: `fs_reads` stays 0 | PARTIAL | `identity_smoke_test.go:519` (one emulator-minted unverified account: 1 CheckHandle + 4 GetMe, every line `fs_reads=0`, `gate=email_unverified`, no `limit_name`). | One account; no rotation across several minted uids, so the "minted uids cannot fill the limiter LRUs" claim is unproven. |

T20 count: 15 COVERED, 9 PARTIAL, 0 MISSING.

## ADR-0010 D6 matrix (cell by cell)

C = covered, P = partial, M = missing. Source in parentheses; "u" = unit with fakes, "e" = emulator.

| Relationship of A to B | GetPost | CreatePost mention | DeletePost | GetHomeTimeline | GetUserTimeline |
|---|---|---|---|---|---|
| A == B (own) | C (u `service_delete_test.go:199`) | M | C (e `:84`) | C (u `:235` self kept; e `:311`) | C (u `service_test.go:767`) |
| stranger | C (e `:207`) | C (e `:310`) | C (e `:68`) | M (nothing asserts a non-followed author is absent) | C (e `:586` plain) |
| A follows B | M | M | M | C (u/e f1, f5) | M |
| A blocks B | C (e `:216`, u `:205`) | C (u `service_create_test.go:134`) | M | C (u f3, e f3) | C (e `:586`, u `:702`) |
| B blocks A | C (e `:226` byte-identical vs missing) | C (e `:287,310`) | M | C (u f4 stale following, e f2) | C (e `:576` same bytes as missing; u `:698`) |
| both block | M | M | M | M | C (u `:699`) |
| A mutes B | C (e `:216`) | M | M | C (u f2, e f1) | C (e `:586`, u `:703`) |
| B SUSPENDED | C (e `:260`) | M | M | M | P (u deletes the profile from a fake; real status not exercised) |
| B DELETING | P (identity unit only; no posts/timeline test sets DELETING) | M | M | M | P (same) |
| B `users` doc missing | C (u `:201`) | C (unknown handle stays text, u/e) | M | M | C (e `:577`, u `:696`) |
| A `blockedByOverflow` | C (e `:241` +1 read exact, u `:211,214`) | C (e `:329`, u `:133`) | M | M (no extra read not asserted) | C (u `:704,708`) |
| A SUSPENDED/DELETING | P (generic: `authn/interceptor_test.go:253` SUSPENDED only, asserts code not ACCOUNT_RESTRICTED; DELETING none; not wired through these RPCs) | P | P | P | P |

Cell counts: GetPost 8C/2P/2M; CreatePost 5C/1P/6M; DeletePost 2C/1P/9M; Home 5C/1P/6M; User 8C/3P/1M; total 28/8/24.
Also: the user-timeline NOT_FOUND is compared to a missing-user timeline call, never to `GetProfile`'s bytes (D6 says identical to GetProfile).
Also: `service_test.go:263` (`len(r.dir.profiles) != 5 || graph.calls[0] != "me"`) is meant to pin D10 ("home never reads status") but cannot fail on status behaviour.

## Budget ceilings (T19 + T20)

| Ceiling (ADR D17 / table) | Status | Evidence / gap |
|---|---|---|
| CreatePost cold 14 R / 4 W | COVERED | `create_integration_test.go:359` |
| CreatePost warm 2 R / 4 W | COVERED | `:136,:301,:308` |
| Replay warm 1 R / 0 W | COVERED | `:186` |
| Replay cold 14 / reused key cold 14 | PARTIAL | only warm asserted on emu; unit fake exact 2 |
| DeletePost cold 2 (1 excl. interceptor), warm 0, 1W/1D, no-op 0/0 | COVERED | `service_delete_integration_test.go:72-118` |
| GetPost cold 4 (3 excl.), warm 0, overflow +1 | COVERED | `:207,213,241` |
| Home F=60 p=20 <= 44 | COVERED | unit `service_test.go:141`; emu `:229` |
| Home refresh 0 new == C | COVERED | emu `:284`; unit `:191` |
| Home refresh with new posts C + new | COVERED | emu `:304` (<=4) |
| Home warm 0 to C | COVERED | emu `:332` (0 reads after own post); unit `:226` |
| Home F=5,000 cold open 269 | COVERED | emu `:412`; unit `:448` (sparse data) |
| Home older page 269 | MISSING | walk tests (`service_test.go:465`, emu F=60 walk) assert coverage, not reads |
| Settle-window re-reads within the ceiling | MISSING | `service_test.go:325` asserts delivery only |
| User page 3 + p at p=20, p=50 | COVERED | emu `:470,:547` |
| User page with p < 20 (3 + max(p,20)) | PARTIAL | not asserted (tracked in T20 3a) |
| User warm first page 0 | COVERED | emu `:480` |
| User since refresh 0 new (3 + 1) | COVERED | emu `:537` |
| User exact-multiple empty final page (1 read) | COVERED | emu `:520` |

Counts above: 14 COVERED, 2 PARTIAL, 2 MISSING (the two PARTIAL rows are also counted in the ticket tables).

## Prioritised missing and partial items (one proposed test each)

P0 (privacy oracle, abuse bound, data integrity):

1. D12 posts invariant checker. New `backend/internal/posts/invariants_integration_test.go`: `assertPostsInvariants(t, client)` loads every `users/*` and `count(posts where authorId)`, fails on any mismatch in `postsCount`; pure `postsInvariantViolations` with negative self-tests like graph's (`graph/invariants_integration_test.go:302`); register as `t.Cleanup` in `newCreateInstance`; add the `code-map.md` test-helpers line.
2. T20 AC3 (P0 scenario). `backend/e2e/readbudget_loop_test.go` (or `internal/apiserver`): build with `READ_BUDGET_PER_UID_PER_DAY=40`, loop CheckHandleAvailability and GetProfile on random handles as one verified uid; assert the sum of `fs_reads` from request logs stops growing, the first rejection is RATE_LIMITED `read_budget_daily`, and later calls log `fs_reads=0`.
3. T20 AC4. Extend `e2e/identity_smoke_test.go:519`: mint 5 unverified password accounts, rotate 20 calls over GetMe and CheckHandleAvailability; assert every log line `fs_reads==0`, `limit_name` unset, and the limiter's key count unchanged.
4. D6 Home rows. `timeline/service_test.go` new `TestHome_D6Matrix` plus emu extension of `timeline_integration_test.go:346`: authors with real status SUSPENDED, DELETING and a missing `users` doc stay in home with 0 status reads; overflow caller adds 0 reads; both-block author dropped; non-followed author absent.
5. D6 row 12. `internal/apiserver/posts_restricted_test.go`: through the real chain, a SUSPENDED and a DELETING caller on each of CreatePost, DeletePost, GetPost, both timelines gets PERMISSION_DENIED + `ACCOUNT_RESTRICTED` with 0 reads past the interceptor.

P1 (budget ceilings and contract):

6. Home older page. `timeline_integration_test.go`: seed F=5,000 with dense authors (k=14 per chunk), fetch `next_page_token`; `budgettest.Assert` Reads <= 268.
7. User cold page p<20. `timeline_integration_test.go`: cold `p=5` asserts Reads <= 22.
8. Cold replay and reused key. `create_integration_test.go:173`: replay from a fresh `newCreateInstance` (cold, `cold=true`); assert Reads <= 14, Writes 0, same id; same for the reused key.
9. Settle-window re-read cost. `timeline/service_test.go`: after `:325`, assert refresh-2 reads <= C + overlap.
10. D4 gaps. Add `budgettest.Assert` to the GetPost NOT_FOUND calls (<=3, overflow <=4), the quota rejection (Writes 0, Reads <= 2), and the concurrent create goroutines.
11. AC2. `budgettest/budgettest_test.go`: pass a recording `testing.TB`; `Assert` over budget records an error containing the name, actual and budget; at budget records none.
12. D9 IST rollover (posts). `create_integration_test.go`: seed `quotas/uid-alice{day: yesterday, posts: 100}`; Create succeeds; `quotas.posts==1` and `day==today` (use `quota.TodayAt`).
13. D1 contract. `internal/apiserver/posts_contract_test.go` over the Build chain: assert reason + metadata on the wire for EMAIL_NOT_VERIFIED, PROFILE_REQUIRED, QUOTA_EXCEEDED (`quota=posts`), IDEMPOTENCY_KEY_REUSED, FEATURE_DISABLED (`feature=replies|quotes|media`); add golden JSON for the happy responses.

P2 (matrix cells and spec examples):

14. D14 (CreatePost mentions). `create_integration_test.go`: table of own handle, A follows B, both-block, A mutes B, B SUSPENDED, B DELETING; assert mention kept and 0 graph reads.
15. D13 (GetPost). `service_delete_integration_test.go:190`: own, A follows B, both-block, DELETING author (set `status=DELETING`); assert returned or byte-identical NOT_FOUND.
16. D15 (DeletePost). Same file: with each relationship seeded, A deletes B's post -> nil error, Reads <= 1, 0 W, 0 D, post still present.
17. D5 token binding. `timeline/tokens_test.go`: user `since` posts-tab token fails on replies and vice versa; user page/gap token from caller A fails for caller B; tampered page and gap tokens VALIDATION.
18. T20 5. `timeline/service_test.go`: `TestUser_SettleWindowDeliversALateCommit`, the same shape as `:325` on `GetUserTimeline`.
19. D17. `create_integration_test.go`: one table over D7/D8 examples (Devanagari, `#Go #go #GO`, `#123`, 11 tags) reading the stored `postDoc` (`hashtags`, `mentions`).
20. D19 (G2). `create_integration_test.go`: Create `"a b"`; stored `text == "a\nb"`.
21. D21 (G5). `create_integration_test.go`: bob renamed, carol claims `bob`; second instance with a fake clock resolves at 9 s and 11 s; stored `mentions[0].userId` is carol's at 11 s.
22. D22. `service_delete_integration_test.go:307`: after batch 1, restart `PurgeUser` from `Checkpoint{}`; assert 1,203 total deleted, none left, and the first batch removed the newest 500.
23. T20 7d. `ratelimit/readbudget_amend_test.go`: profile-less uid calls from `2001:db8:1:2::1` then `::2`; assert one IP-key spent total.
24. Hygiene. Replace the `time.Sleep(1ms)` poll at `readbudget_amend_test.go:446-449` with a channel rendezvous; fix `timeline/service_test.go:263` so it asserts that a SUSPENDED author is still included.

## Notes for the plan owner

- T20 bullet 7 ("IP budget is enforced on CheckHandleAvailability and charge-only on CreateProfile") predates ADR D5 A8; the shipped behaviour (and tests) is charge-only on both.
- T19 "D21 delta (if accepted)": D21 G1-G5 were accepted 2026-10-01; the conditional can be dropped.
- Integration tests call the services and the Connect handler below the interceptor chain; budgets assert the ADR ceiling minus the interceptor's one `users` read (documented at `timeline_integration_test.go:7` and `create_integration_test.go:39`).
