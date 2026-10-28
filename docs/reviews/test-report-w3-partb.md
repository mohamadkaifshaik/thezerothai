# Test report: UI wave W3 Part B (private accounts and follow requests)

Each ticket owns its own section below; keep an edit to your own section. W3-35a owns "W3-35a"; W3-35b owns the section
that follows. (The plan names `docs/reviews/test-report-w3b.md` for W3-35b; the task brief chose this Part B file, so the
plan's file name is stale.)

---

## W3-35a: read paths, visibility matrix, byte identity, leaks, audience guard, budgets (2026-10-28)

Tester: tester agent. Branch `test/w3-35a-visibility-matrix` on `main@15975e53` (every Part B backend ticket merged: W3-26a, W3-26b,
W3-27, W3-28a, W3-28b, W3-28c, W3-29a, W3-29b, W3-30, W3-31, W3-32). Plan: `docs/plans/ui-w3-profile-graph-completion.md`
(W3-35a and the Part B rules). Design: ADR-0025 (D3 to D13, AQ1 to AQ6, implementation notes). Part A is in
`docs/reviews/test-report-w3.md`; the lifecycle, races and invariants half of Part B is W3-35b, the client half is W3-35c.

**VERDICT: PASS for W3-35a as specified.** Every row of the D4 visibility matrix holds on the emulators through
`apiserver.Build`, the refusals are byte-identical to the deleted post's answer, nothing an unapproved viewer receives
carries P's text or image id, the audience guard is in `make ci`, and every Part B budget is at or under its ADR-0025
ceiling. No production code was edited. Two Low defects are filed (D-1, D-2); neither blocks W3-38. Combined `internal/`
coverage from `make test-int` is 92.5%.

---

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| Unit (the audience guard, the push test) | `GOWORK=off go test -count=1 ./internal/apiserver ./internal/notifications` | green |
| Go integration, the whole module, fresh emulators (Firestore, Auth, Pub/Sub, Storage) | `GOWORK=off make test-int FIREBASE="firebase --config <untracked copy>.json"` (ports 32430 / 32530 / 32380 / 32390 / 32585 / 32395; `scripts/with-private-tmp.sh` via the Makefile) | **green**, exit 0, every package `ok`; combined `internal/` coverage **92.5%** (gate 70%) |
| W3-35a tests, iterated | `go test -tags=integration -run TestW335a ./internal/apiserver` against emulators held up on the same ports | green (section 2) |
| gofmt, `go vet`, `go vet -tags=integration` | `gofmt -l backend/internal`, `go vet ./...` | clean |
| golangci-lint | `golangci-lint run ./internal/apiserver/... ./internal/notifications/...` and with `--build-tags=integration` | 0 issues in the new code; 1 pre-existing SA4006 at `internal/notifications/repo_firestore_integration_test.go:196` (not touched here) |

Environment notes:
- `-race` was not run: CGO is off on this Windows machine (`RACE_FLAG` is empty). CI on Linux runs it.
- Ran on my own port block 32xxx through an untracked `--config` copy (`docs/runbooks/emulator-collisions.md` section 4); the copy is
  deleted before the commit. Pub/Sub started too slowly for firebase-tools' port probe three times under load ("port taken"),
  each leaving an orphan java; I did not kill any process (leftover PIDs in the PR description).
- Coverage by package, measured the `make test-int` way (`-coverpkg=./internal/...` over the whole run, duplicate blocks merged):
  apiserver 95.4%, notifications 90.4%, posts 92.6%, graph 92.1%, identity 93.3%, timeline 97.0%, engagement 90.2%.
- Nothing was run against dev or prod.

### 2. What was added

| File | Tests | Covers |
|---|---|---|
| `backend/internal/apiserver/audience_guard_test.go` (no build tag, runs in `make ci`) | `TestAudienceGuard_Backend`, `TestAudienceGuard_SelfTest` (16 cases) | the source-scan guard, section 4 |
| `backend/internal/apiserver/w335a_matrix_integration_test.go` | `TestW335a_VisibilityMatrix` (10 viewer classes), `TestW335a_OverflowFallbackRefusesAStaleEdge`, `TestW335a_SuspendedAuthorAndTakenDownPostHideFromApprovedFollowers`, `TestW335a_RefollowRequestAcceptBringsBackBookmarksAndLikes` | the D4 matrix, byte identity, the leak scan, owed item 1 |
| `backend/internal/apiserver/w335a_leaks_integration_test.go` | `TestW335a_FlagOffKeepsProtection`, `TestW335a_StaleProtectedSet`, `TestW335a_ExportOfAnotherUserCarriesNoProtectedContent`, `TestW335a_ProtectingRetiresNothingAndBannerReplacementRetiresAsForAPublicAccount`, `TestW335a_SuggestedProtectedAccountAndFollowCreatesARequest` | flag off, stale set, export and retire leaks, suggestions |
| `backend/internal/apiserver/w335a_budget_integration_test.go` | `TestW335a_BudgetTableWithPartBOn`, `TestW335a_PartBBudgetTable` | the budget table, section 5 |
| `backend/internal/notifications/push_ids_only_test.go` | `TestPush_CarriesIdsOnlyForEveryType` | push payloads carry ids and static text only |
| `w329a_protected_posts_integration_test.go` (edited) | the stranger-refusal loop | owed item 2: the loose 12 is now a per-RPC ceiling (below) |
| `w320_budget_table_integration_test.go` (edited) | `TestW320_BudgetTable` is now `w320BudgetTable(t, partB)`; the nil call is unchanged | the "+0 against the W3-20 table" run |

#### 2.1 The matrix (`TestW335a_VisibilityMatrix`)

One protected P (public text post with an image, a reply to X's root, a pin), X's quote and repost of P's post made while P
was public, every class bookmarking and liking P's post while P was public, then P protects through the real toggle. Each class
reads on a cold instance. Expected cells are the ADR-0025 D4 table written into the test, not read off the code.

| Class | GetPost, GetThread focal | 4 tabs | followers, following | pin | bookmarks, likes | Home: X's repost, X's quote |
|---|---|---|---|---|---|---|
| self | shown | rows | ok | pin | present | shown, intact |
| approved follower | shown | rows | ok | pin | present | shown, intact |
| requester (REQUESTED) | deleted-post bytes | `author_protected` | PROTECTED_ACCOUNT | none | dropped, kept | dropped, quote PROTECTED |
| stranger | as requester | as requester | as requester | none | as requester | as requester |
| follower who muted P | shown (D6) | not asserted | ok | pin | dropped (list surface) | not asserted |
| P blocks the viewer | deleted-post bytes | not asserted | not asserted | not asserted | dropped | repost dropped, quote not asserted |
| viewer blocked P | deleted-post bytes | not asserted | not asserted | not asserted | dropped | as above |
| P blocks, viewer's blockedBy overflowed | deleted-post bytes | not asserted | not asserted | not asserted | dropped | as above |
| follower, blockedBy overflowed, not blocked | shown | rows | ok | pin | not asserted (lists fail closed, W2-14 L-1) | not asserted |
| X, who copied P while public | deleted-post bytes | `author_protected` | PROTECTED_ACCOUNT | none | vacuous (X never bookmarked) | leak scan only |

"Not asserted" cells rest on ADR-0010 block and mute behaviour this ticket does not own; every such class is still held to the
leak scan on all paths.

- **Byte identity (rule 5).** For every class that may not see P, GetPost and the GetThread focal are compared with the same
  RPC on a deleted post: HTTP status, content type and body (the W3-20 comparator `TestW320_TabNotFoundBytesMatchGetProfile`).
  So are LikePost, AddBookmark, RepostPost, ReportContent, a reply to and a quote of the post (8 RPCs by the 6 classes that may not see P = 48 comparisons).
  Both oracles and the protected answer are asserted equal; the oracle must itself be 404.
- **The leak scan (rule 9).** For each class that may not see P, the raw JSON body of 21 read paths is searched for P's text and
  for P's image id: GetPost (P's post, X's quote, X's repost, P's reply), GetThread (four focals), the four profile tabs, Home,
  ListBookmarks, ListLikedPosts, ListFollowers, ListFollowing, GetProfile, GetProfileRelationship, ListSuggestedUsers and
  ListNotifications. A positive control (the approved follower's GetPost body does carry both) proves the scan can see them.
  P's avatar and banner are allowed and not searched for.
- `TestW335a_OverflowFallbackRefusesAStaleEdge`: a viewer whose follow edge was left behind, whose blockedBy lost P to the cap
  and whose overflow flag is set is refused only by the fallback read of P's blocked list (deleted-post bytes); the same state
  without the block shows the post. The state is not reachable through the RPCs (Block removes the edge) and is built by direct
  Firestore writes; it checks the fallback is wired into `Audience.Decide`.
- `TestW335a_SuspendedAuthorAndTakenDownPostHideFromApprovedFollowers`: an approved follower gets the deleted-post bytes for a
  taken-down post and for every post of a suspended author.

#### 2.2 The other plan bullets

| Plan bullet | Test | Result |
|---|---|---|
| Flag off keeps protection | `TestW335a_FlagOffKeepsProtection`: with `FEATURE_PRIVATE_ACCOUNTS` off, a protected P is refused on GetPost, GetThread, the tabs, both lists, the pin and the 21-path scan; P can list, accept and unprotect; protecting again is refused | pass |
| Stale set (10 minutes, then UNAVAILABLE) | `TestW335a_StaleProtectedSet`: an isolated project, `CACHE_TTL=1s` and `PROTECTED_SET_MAX_STALE=4s` (the same two knobs the 10 minutes use, scaled); the set document is made unreadable after one load; a `protected_set_stale` WARN is awaited while the stranger is still refused as NOT_FOUND (never "everyone is public"), then the stranger gets UNAVAILABLE (reason not PROTECTED_ACCOUNT); the stranger's own post, an approved follower and P are unaffected. The 10-minute default is pinned by `identity.TestProtectedSetLoader_StaleThenUnavailable` and `config` | pass |
| Another user's export | `TestW335a_ExportOfAnotherUserCarriesNoProtectedContent`: U bookmarks, likes, reposts and quotes P's post, P protects, U exports: the JSON has P's post id, U's quote id and U's own quote text, and no P text, no image id, no `/m/` | pass |
| Push payloads carry no post text | `TestPush_CarriesIdsOnlyForEveryType`: `Push` has exactly four id fields, and the FCM message for all eight notification types has four data keys and a title and body that name no handle, link or image | pass |
| `PROFILE_MEDIA_RETIRE=banner` | `TestW335a_ProtectingRetiresNothingAndBannerReplacementRetiresAsForAPublicAccount`: protecting publishes nothing; a protected account's banner replacement publishes exactly one BANNER message, delivers to `retired`, outcome identical to a public account's; the banner in use stays | pass |
| Suggestions | `TestW335a_SuggestedProtectedAccountAndFollowCreatesARequest`: P is suggested with `is_private`, Follow from there is REQUESTED, GetProfileRelationship says REQUESTED | pass |
| Notification fan-out | not repeated: `w331_protected_notifications_integration_test.go` (W3-31) and `w328a` (request and accepted rows); the matrix scans ListNotifications for every unapproved class | covered |

#### 2.3 Owed items

1. **Request, accept, rows back.** `TestW335a_RefollowRequestAcceptBringsBackBookmarksAndLikes`: U bookmarks and likes P's post
   while public; P protects (U, an existing follower, keeps access); U unfollows (rows hidden); U requests again (REQUESTED,
   rows still hidden, nothing pruned); P accepts; the rows are back in ListBookmarks and ListLikedPosts, and X's repost of
   P's post is back in U's Home. Pass.
2. **Stranger-refusal ceiling.** `w329a_protected_posts_integration_test.go` asserted a loose 12 reads on every refusal. Measured
   on a cold instance (2026-10-28): GetPost 3 (ceiling now 4, the cold figure), LikePost, AddBookmark, ReportContent, reply
   and quote 0 (ceiling 1), RepostPost by an approved follower 2 (ceiling 3). Each is the measured value plus one read of headroom.
3. **A who-to-follow row cached on the device (client, W3-35c).** Not built. The row is cached 48 hours (ADR-0024 Amendment 2) with
   the `is_private` it was fetched with, so after P protects or unprotects a cached row shows the old badge for up to 48 hours,
   and a Follow from a cached non-badged row of a now-protected P answers REQUESTED. W3-35c should assert that the follow
   control renders the server's response state (Requested), not the optimistic Following, and that the badge is refreshed from
   the next list response.

### 3. Byte identity and oracles, summary

No path leaks an existence or privacy oracle that the deleted-post answer does not: the 48 matrix comparisons, the flag-off, stale-edge,
suspended-author and taken-down cases and the W3-29a stranger table all compare equal on status, content type and body. UNAVAILABLE for a missing set is not PROTECTED_ACCOUNT.

### 4. The audience guard (`audience_guard_test.go`)

A `go/ast` scan of every non-test Go file under `backend/internal`, run by `make ci` (no emulator). It fails when:
- **R1**: a file other than `posts/audience.go` compares a post Visibility with the public (or followers) value, by `==`, `!=`
  or a `case` clause. Today there are none: all six rule-6 sites have been removed (the writers only assign).
- **R2**: a package that builds PostView rows (a composite literal of `PostView`, or a call to `ToView`) never names `Audience`.
  Today `posts`, `engagement` and `timeline` build rows and all name it.
- **R3**: a file outside the allowlist calls the AQ2 expression, a three-argument `.CanSee(viewer, author, following)` (identity's
  `ProtectedSet.CanSee`; `posts.Audience.CanSee` and `notifications.AudienceChecker.CanSee` take four arguments, so arity
  tells them apart without type information).

Each allowlist entry carries its reason and a stale entry fails. `TestAudienceGuard_SelfTest` has 16 cases proving every rule
fires on a synthetic violation (W4 search, W5 lists, a stored-visibility compare, a stray `CanSee`) and stays quiet on the
clean shape. A vacuity check fails if fewer than 100 files are scanned. It replaces the ADR's "W4 placeholder test".

### 5. Budget table

Every figure is a cold instance (a fresh `Build` chain per call, the account-status interceptor's read included), asserted by
`budgettest.Assert` through `w320Measure`, which logs a `W320BUDGET` line. The protected-set refresh runs on a detached
counter (`protected_set_reads`), so it never appears in a caller's `fs_reads`.

#### 5.1 Part B RPCs against the ADR-0025 Cost impact table (`TestW335a_PartBBudgetTable`)

| Operation | Reads (measured / ceiling) | Writes | Deletes |
|---|---|---|---|
| Follow a public account (edge) | 4 / 4 | 5 / 5 | 0 |
| Follow a protected account (request) | 4 / 4 | 3 / 3 | 0 |
| Withdraw (Unfollow of a REQUESTED target) | 1 / 1 (the interceptor) | 1 / 1 | 1 / 1 |
| ListFollowRequests, page 20 (20 pending) | 42 / 42 | 0 | 0 |
| RespondToFollowRequest, accept, after a List | 2 / 3 | 4 / 4 | 1 / 1 |
| RespondToFollowRequest, decline, after a List | 2 / 2 | 1 / 1 | 1 / 1 |
| RespondToFollowRequest, replay of an accept | 1 / 2 | 0 / 0 | 0 |
| RespondToFollowRequest, accept, standalone cold (W3-28a note) | 5 / 5 | 4 / 4 | 1 / 1 |
| UpdateProfile toggle, protect | 4 / 4 | 3 / 3 | 0 |
| UpdateProfile toggle, unprotect with 20 pending | 3 / 4 | 3 / 3 | 0 |
| GetMe, public caller / protected caller (+1 count) | 2 / 2 and 3 / 3 | 0 | 0 |
| GetUserTimeline of P, unapproved | 3 / 3 | 0 | 0 |
| ListFollowers, ListFollowing of P, unapproved | 3 / 3 each | 0 | 0 |
| GetPost of P's post, unapproved (refusal) | 4 / 4 | 0 | 0 |
| GetPost of P's post, approved follower (+ userLikes) | 5 / 5 | 0 | 0 |
| GetThread of X's root, P replied, unapproved (6 rows of data) | 6 / 38 | 0 | 0 |
| ListBookmarks page, unapproved owner (3 rows) | 4 / 43 (page-20 ceiling) | 0 | 0 |
| ListLikedPosts page, unapproved owner (3 rows) | 4 / 23 (page-20 ceiling) | 0 | 0 |
| Home page 20, P public / P protected | 7 / 7 (must not exceed) | 0 | 0 |

Not re-measured here because their own tickets assert them at the same ceilings: the `privacy_public` job (W3-28b,
`w328b_privacy_public_integration_test.go`), the notification fan-out (W3-31, W3-28a) and the eraser and export steps (W3-32).
The GetThread, ListBookmarks and ListLikedPosts page-20 ceilings are asserted at their full-page data in W3-29b.

#### 5.2 Existing read paths, "+0 against the W3-20 table" (`TestW335a_BudgetTableWithPartBOn`)

The whole W3-20 table (`w320BudgetTable`) runs again with `FEATURE_PRIVATE_ACCOUNTS` on and a protected account in the set, 25
measured cases, every one at its W3-20 ceiling: UpdateProfile 4 / 2 / 1, GetPost 4 and 5 and 0 warm, the MEDIA and REPOSTS tabs
24 / 20 at page 20 and 54 / 50 at page 50, ListLikedPosts 23 / 20, 53 / 50 and 2, GetProfileRelationship 3 / 0 / 4 / 5 and
ListSuggestedUsers under its cap. Predicate cost: **+0 reads on every path.** One setup note, not a defect: with bookmarks on
(Part B turns it on) the "engagement off" GetPost case reads 5, not 4, because GetPost's documented extra `userLikes` read fires
when engagement OR bookmarks is on; the wrapped case now turns both off.

### 6. Defects

| ID | Severity | Where | Finding |
|---|---|---|---|
| D-1 | Low (design deviation, no user impact) | `backend/internal/graph/follow_requests.go:149`, `backend/internal/apiserver/notifications_wiring.go:150` | ADR-0025 AQ2 says GetProfile is "the one caller outside `posts.Audience`" of `identity.ProtectedSet.CanSee` and that W3-35a's guard enforces it; AQ5 says `apiserver` adapts the notifications checker "from `posts.Audience.CanSee`". Both sites call the set's expression directly. The rule is not restated (both delegate to the one method) and the behaviour is tested, so the guard allowlists both with this ID. Fix by an ADR note naming the two callers, or by routing them through `posts.Audience` (owner: architect, then backend-developer). |
| D-2 | Low (test fragility; a stale reference budget) | `backend/internal/apiserver/account_lifecycle_integration_test.go:431-433`, `account_lifecycle_reference_integration_test.go:161-163` | Since W3-26a the account-delete job's `users_doc` step does a field-level `ArrayRemove` on `privacy/protectedAuthors`. When that document exists the step costs 4 writes, not the ADR-0011 reference budget of 3 (and 301, not 300, for the reference account). Both tests pass on a fresh emulator (as in `make test-int` above) and fail once any earlier test on the same emulator has protected an account (verified: `TestAccountLifecycle_Chain` passed on a fresh emulator and failed on the same emulator after `TestW326b_PinOmittedForUnapprovedViewers` ran; the reference-account test failed the same way, 301 writes, in the long run). Repro: on one emulator run `-run TestW326b_PinOmittedForUnapprovedViewers`, then `-run 'TestAccountLifecycle_Chain$'` (`fs_writes:4`, budget 3). In dev and prod the document always exists after the first protect, so a real account deletion costs one write more than the documented 3. Fix: raise both budgets by one with the ADR-0011 note, or seed the document in those tests (owner: backend-developer, W3-26a). |

No Critical, High or Medium defects. The matrix, the leak scan, the byte identity, the stale set and the export found nothing.

### 7. Not covered, and why

- `-race` (CGO off here); CI runs it.
- Stale set at the 10-minute default: scaled to seconds through the production knobs; the default itself is pinned by the
  identity loader's fake-clock test.
- The notification rows and pushes themselves are W3-31's tests; the matrix adds the response-body scan only.
- A real FCM send, a real GCS signed URL and the Cloud Run revision mix (rule 10, W3-38) cannot run on emulators.
- The client (W3-35c).

### 8. Repro

```
GOWORK=off make test-int FIREBASE="firebase --config <copy of firebase.graph-loadtest.json on free ports>.json"
GOWORK=off go test -count=1 ./internal/apiserver -run TestAudienceGuard
# inside emulators:exec: go test -tags=integration -count=1 -v -run TestW335a ./internal/apiserver

---


## W3-35b: request lifecycle, races, invariants I-R and I-X, the `privacy_public` job, flag matrix, eraser and export

Tester: tester agent, 2026-10-28. Branch `test/w3-35b-request-lifecycle` on `main@15975e53` (W3-26a, W3-27, W3-28a, W3-28b,
W3-28c, W3-31 and W3-32 merged; W3-26b is in review and not needed here). Design: ADR-0025 D6 to D9, D11, D12 and the W3-28a
and W3-28b implementation notes; runbooks `docs/runbooks/graph.md` sections 7 to 9 and `private-accounts.md`. Test code only:
no production file was edited, and no production seam was added (the one test-only window into the job is
`backend/internal/graph/export_w335b_test.go`, a `_test.go` file).

**VERDICT: PASS** (details and one by-design observation, O-1, below; no production defect found).

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| New and changed Go integration tests, graph and apiserver | `firebase --config <temp 33xxx config> emulators:exec --project demo-dzeroth-local --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -run W335b ...'` behind `scripts/with-private-tmp.sh` | green |
| The three touched packages, whole, with combined coverage (the `make test-int` command line, restricted to the packages) | `go test -tags=integration -count=1 -coverprofile=cover-w335b.out -coverpkg=./internal/... ./internal/graph/ ./internal/apiserver/ ./internal/identity/` | see section 5 |
| `gofmt -l`, `go vet`, `go vet -tags=integration`, `golangci-lint run` (also with `--build-tags=integration`) on `./internal/graph/... ./internal/apiserver/...` | as written | clean |

Environment notes: `-race` was **not** run (CGO is off on this Windows machine; CI on Linux runs it). All four emulators ran on
a private 33xxx port block through an untracked `--config` copy, deleted before the commit. Pub/Sub's emulator JVM stays alive
after `emulators:exec` on Windows; the leftover PIDs are listed in the hand-back, none was killed.

### 2. Coverage map: ticket bullet to test

Tests marked **new** are in this PR; the others already existed on `main` and are cited, not duplicated.

| Ticket bullet | Test | Status |
|---|---|---|
| D7 Request (cold 4 / warm 3 reads, 3 writes), replay, 500 cap | `TestFollowRequest_Integration_CreateReplayWithdraw`, `_RequestedCapIs500`, `_DriftedRequestDocIsAReplay` | existing |
| D7 Withdraw (1 write, 1 delete), withdraw after the target went public | `TestFollowRequest_Integration_CreateReplayWithdraw`, `_WithdrawAfterTargetWentPublic` | existing |
| D7 Accept, Decline, replay, requester not ACTIVE, requester at 5,000, drift | `TestRespond_Integration_AcceptDeclineReplay`, `_RequesterInactive`, `_RequesterAtCap`, `_DriftIsDropped` | existing |
| D7 Block in either direction | `TestFollowRequest_Integration_BlockClearsRequestsBothWays`, `_BlockRulesComeFirst` | existing |
| Race: follow vs protect | `TestFollow_Integration_ProtectRacingWithFollowIsSerialized` (`follow_race_integration_test.go`, package `graph`: the transaction hook) | existing |
| Race: accept vs withdraw, accept vs block (one instance) | `TestRespond_Integration_Races` | existing |
| Race: **Respond on two instances**: accept+accept, accept+decline, decline+decline, accept+withdraw, decline+withdraw, accept+block, 3 rounds each | `TestW335b_Respond_TwoInstances` (`graph/request_races_integration_test.go`) | **new** |
| Race: the job vs a re-protect, mid-run | `TestPrivacyPublic_Integration_ReprotectedMidRun` (graph: the re-protect lands between pages). The chain test says it cannot interleave a toggle with one delivery (`w328b_privacy_public_integration_test.go` header), so it is not repeated through `apiserver.Build` | existing |
| Race: **the job vs withdraw, Block and a manual accept**, all running at once on one target | `TestW335b_PrivacyPublic_AgainstWithdrawBlockAndManualAccept` | **new** |
| Race: **job redelivery mid-run**: a delivery that stops at the 50-page cap and its redelivery; a crash before and a crash after a page's commit; **two concurrent runs** of 250 pending on two instances | `TestW335b_PrivacyPublic_DeliveryStopsAtThePageCap`, `_CrashBetweenAndAfterPages`, `_ConcurrentRuns` | **new** |
| Job counts, budget, redelivery, at the cap, inactive and gone requesters | `TestPrivacyPublic_Integration_Counts` (0, 1, 100, 101, 250), `_ReprotectedBeforeRun`, `_CapInactiveAndGone`; chain: `TestW328b_PrivacyPublicThroughTheChain` | existing |
| Job: **at-cap requesters re-counted on every rerun** | `TestW335b_PrivacyPublic_AtCapRequestersAreRecountedEveryRun`, `_AtCapRequestersNeverDropOut` (O-1) | **new** |
| Invariants: I-R and I-X in the checker, each with negative self-tests | `invariants_integration_test.go`: `graphInvariantViolations` now loads `followRequests` and `graph.requested`; `TestGraphInvariantChecker_DetectsEveryViolation` has 11 new rows (2 clean, 9 violations) | **extended** |
| Flag matrix, D12, in the ten rollout states | `TestW335b_PrivateAccountsFlagMatrix` (`apiserver/w335b_private_accounts_flag_matrix_integration_test.go`), reusing `w320ModeCases` | **new** |
| Flag matrix, four modes with real requests | `TestW328a_FlagModesNeverStrandAProtectedAccount`, `TestPrivateAccountsContract_FlagOff`, `_AllowlistCohort` | existing |
| Limits: the 4 per day toggle quota, the set cap, the equal-value no-op | `TestPrivacyToggle_Chain`, `TestPrivacyToggle_Cap` (existing); **the corners**: `TestW335b_PrivacyToggleLimits` | existing + **new** |
| Eraser: a requester and a target with requests both ways, through the job chain | `TestW335b_FollowRequestsThroughAccountLifecycle` | **new** |
| Eraser: page boundaries, ghost in a full page, gone between calls, redelivery, concurrent loops | `TestW335b_RequestEraser_PageBoundaries`, `_RequesterGoneBetweenCalls`, `_RedeliveryKeepsOtherRequests`, `_ConcurrentLoops` | **new** |
| Eraser and export basics | `TestRequestEraser_Integration`, `TestExportRequests_Integration` | existing |
| Export golden | `testdata/w335b_follow_requests_export_golden.json` (a section-level golden; the shared `account_export_golden.json` is untouched), plus the export page boundary `TestW335b_ExportRequests_PageBoundaries` | **new** |
| The wiring lists; T11 green | `lifecycle_wiring_test.go` (the step and section lists, `TestFollowRequestsSection`), `lifecycle_collections_guard_test.go` (`followRequests` row; dropping the step or the section is detected), and the runtime residue sweep `requireNoResidue` called for each deleted account in the new lifecycle test | existing + used |
| The identity step removes the protected-set entry | `TestRemoveFromProtectedSet_Integration` (identity, existing) and, through the whole job chain, `TestW335b_FollowRequestsThroughAccountLifecycle` | existing + **new** |

### 3. What the new tests prove

**I-R and I-X in the sweep.** `assertGraphInvariants` runs at the end of every graph scenario; it now also reads `followRequests`
and `graph.requested` and checks I-R in both directions, I-X on the documents and on the arrays (`b` in both `following`
and `requested`), S1 (a request id is `follower_followee`, no self-request) and S2 (no duplicate in `requested`, the 500
cap, `pad-` entries skipped). Nine negative rows prove each rule can fail. The widened sweep added no red to the 89 s graph
integration run: no existing scenario ended in a state the new rules forbid.

**Respond on two instances** (18 rounds). Neither call ever failed; the loser of every pair was a replay. End states: one
edge or none, `followersCount` and `followingCount` read straight from Firestore agree with the edge, at most one
`FollowRequestAccepted` across both instances (exactly one for accept+accept), accept+block never leaves an edge. The counters
are read from Firestore on purpose: the first draft of this test read `followingCount` through the other instance's profile
cache and failed twice; that is the cache TTL, not a defect.

**The job under pressure.** With a page of 1 (test-only window) 60 pending requests reach the 50-page cap: the run returns
`ErrPrivacyPublicMore` (a nack), `followersCount` is exactly 50 and 50 requests are left; the redelivery ends `done` with
`followersCount` exactly 60 and exactly one event per requester; a third delivery is a no-op. A crash before page 3 and a crash
after page 3 committed both converge on `followersCount` 5 and no double edge. The after-commit crash loses exactly that page's
one notification (4 events, not 5), which is the ADR-0025 D8 residual, now pinned by a test. Two simultaneous runs of 250
pending on two instances both end `done`, 250 edges, `followersCount` exactly 250, one event per requester. Withdrawers, a
Block per requester and a manual accept racing one job run: no request left, `followersCount` equals the edges, no blocked
requester follows.

**Flag matrix.** In all ten states, for both sides of the cohort (a fresh user pair and a fresh protected account per state):
`enabled_features` lists `private_accounts` exactly for the callers it is on for; `UpdateProfile(is_private=true)` is refused
as FEATURE_DISABLED `feature=private_accounts` at **exactly 0 reads, 0 writes, 0 deletes** (the account-status read warmed first
with GetMe); `ListFollowRequests` and `RespondToFollowRequest` refuse a public caller **only in mode `off`**, also at 0 / 0 / 0;
an empty allowlist and percent 0 pass. Never gated and checked in every state: Follow of a protected account answers
REQUESTED, the withdraw works, `is_private=false` works (including unprotecting a protected account with the flag off), the
protected owner lists and answers requests, and a stranger gets `author_protected` and no rows from the protected author's
timeline tab. The job, eraser and export are never gated (they read no flag; the lifecycle and job tests above run them
without one).

**Limits.** The no-op is decided before the quota: `is_private` equal to the stored value succeeds with 0 writes at 4 of 4
(public and protected); the other value at 4 of 4 is QUOTA_EXCEEDED `quota=privacy_toggles` with 0 writes and the state
unchanged; an equal-false on a never-protected account is 1 read, 0 writes and does not touch the quota; with the protected
set at its cap an unprotect and an equal-true pass, and a new protect is LIMIT_REACHED with nothing written.

**Eraser.**

| Case | Calls | Reads | Writes | Deletes |
|---|---|---|---|---|
| exactly 500 outgoing | 3 | 502 | 0 | 500 |
| exactly 250 incoming (500 operations in one batch) | 3 | 252 | 250 | 250 |
| 250 incoming, one requester without a graph doc inside the page | 3 | 502 | 249 | 250 |
| 250 incoming, every requester gone | 3 | 502 | 0 | 250 |
| requester's graph doc deleted between two calls | (1 outgoing, then incoming) | 5 | 1 | 3 |
| redelivery after the step finished, from the start and from either phase | - | 2 | 0 | 0 |

A full page costs one extra empty query, as predicted. The purge never recreates a graph doc (`Update`, never `Set`), keeps a
requester's other requests and `requested` entries, deletes both directions of a mutual pair, and two loops on one account
at the same time (300 incoming of which 6 ghosts, 120 outgoing) both finish with a clean end state. "Graph doc gone mid-page"
cannot be interleaved inside one batch without a production seam, so it is approximated by a ghost inside a full 250 page and
by a graph doc deleted between two calls; this is a documented approximation. Through the real job chain: the export of an
account with requests both ways matches the section golden and is newest first; another account's export names no request it
is not a party to; deleting a requester, then a protected target with requests both ways, then the second protected account
leaves no request naming them, no `requested` entry of a survivor naming them, the queue the target had joined clean, the
protected-set entries gone, and the T11 residue sweep empty. Export page boundary: exactly 500 and 501 requests each way, every
row once, newest first, none lost at the page edge (reads 2,002 and 2,004: the request docs, the empty re-query at exactly
500, and one lookup per counterpart that has no profile).

### 4. Budgets measured (all within the documented ceilings)

| RPC or step | Measured | Ceiling |
|---|---|---|
| `UpdateProfile(is_private=true)` refused by the flag, warm | 0 / 0 / 0 | 0 reads, 0 writes (D12) |
| `ListFollowRequests`, `RespondToFollowRequest` refused by the flag, warm | 0 / 0 / 0 | 0 (D12) |
| `UpdateProfile` equal value (public, quota 0) | 1 read, 0 writes | no writes (D8) |
| `UpdateProfile` equal value at 4 of 4 (public or protected) | 1 read, 0 writes | no writes (D8) |
| `UpdateProfile` different value at 4 of 4 (QUOTA_EXCEEDED) | 3 reads, 0 writes | no writes (D8) |
| `privacy_public`, rerun with 3 requesters at the cap | 7 reads (1 + 3 x 2), 0 writes, 0 deletes, identical on every rerun | D8 per request 2 reads |
| `privacy_public` stopped at the page cap (page 1, 51 stuck requests) | 150 reads, 0 writes per delivery | see O-1 |

### 5. Coverage

Measured the `make test-int` way (`-tags=integration -coverprofile -coverpkg=./internal/...`), restricted to the three packages
this ticket touches (their unit tests are not in this run, so these are integration-only figures and a lower bound). Per-package
statement coverage computed from the merged profile:

| Package | Statement coverage |
|---|---|
| `internal/graph` | 92.1% |
| `internal/apiserver` | 95.3% |
| `internal/identity` | 93.1% |

The three packages passed whole on the emulators (graph 151 s, apiserver 127 s, identity 48 s, run in parallel as `./...` does).
The ticket's gate (`internal/` combined at least 70%) is the full `make test-int` figure; this ticket adds tests only, so it can
only raise it. The full-module figure was not re-measured here.

### 6. Defects and observations

No production defect. Nothing was marked as a known failure with `t.Skip`.

- **O-1 (informational, Low at Stage 0): a request whose requester is at the 5,000 following cap never drops out of the
  `privacy_public` query.** The job re-reads it on every delivery (7 reads for 3 stuck requests, no writes, stable) and
  finishes `done` at the production page of 100. Only when the first 5,000 requests of a target are all stuck does a run end
  `ErrPrivacyPublicMore` (a nack) on every redelivery until the owner declines them, because the 50-page cap is reached
  without progress. `TestW335b_PrivacyPublic_AtCapRequestersNeverDropOut` models it at a page of 1 (51 stuck requests): two
  deliveries, both nack at 150 reads and 0 writes. It needs more than 5,000 stuck requests and each stuck requester follows
  5,000 accounts, so it is not reachable at Stage 0; it is recorded so nobody is surprised by a nack storm that only Decline
  ends. Recommendation for the owner, not a change request: if it is ever reached, ack with a log line when a whole delivery
  accepted nothing.
- **O-2 (by design, not a defect): contention answers a retryable error.** In a first draft of the job-chaos test, ten Blocks
  fired by one account in the same millisecond while the job ran made 5 of the 10 answer "temporarily busy, please retry"
  (the Block transactions all write the blocker's graph doc). The test now sends the Blocks one after another; the shipped
  behaviour (a retryable error, the client retries) is the documented ABORTED mapping.
- **O-3 (by design, from ADR-0025 D7, not observed in the 18 rounds): withdraw is two blind batches.** A withdraw that races an
  accept can run its edge batch before the edge exists and its request batch after the request is gone, so it answers NONE
  while the accept's edge stands. The ADR accepts this ("a second failure is NONE"); the invariants hold either way (the sweep
  passed in every round).
- **O-4 (documented, now pinned by a test): a process crash after a job page commits and before its events are emitted loses
  that page's accept notifications** (ADR-0025 D8, the W3-28b note). The edges and counters are exact.

### 7. Reuse report

- Reused: `newWired`, `newInstance`, `acceptRecorder`, `pendingTo`, `runJob`, `seedRequest`, `runRequestPurge`, `measured`,
  `runConcurrently` (graph); `newW320Chain`, `w320ModeCases`, `w320Warm`, `w320AssertNothing`, `w320Disabled`, `w328Request`,
  `w328List`, `w328Respond`, `newLifecycleEnvCfg`, `exportOf`, `normalizeExport`, `requireNoResidue`, `ptoggleStored` (apiserver).
- Extended: `graphInvariantViolations` and `loadGraphState` (I-R, I-X, S1, S2 for requests); `w320DrawGates` gained
  `w320DrawGatesFor(names)` (the old function calls it, behaviour unchanged).
- Created: `graph/export_w335b_test.go` (a test-only setter for the job's page size, so the 50-page cap is reachable with 60
  requests instead of 5,001; no production file changed), `request_races_integration_test.go`,
  `purge_requests_edges_integration_test.go`, and the four `w335b_*` apiserver files. Nothing existing fit these cases.
- Catalog: no shared production helper was added, so `docs/code-map.md` is unchanged.

### 8. Reproduce

```sh
export GOWORK=off
# an untracked copy of firebase.graph-loadtest.json with all six ports in 33xxx, then:
bash scripts/with-private-tmp.sh firebase --config <copy>.json emulators:exec --project demo-dzeroth-local \
  --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -run W335b ./internal/graph/ ./internal/apiserver/'
# rewrite the section golden:  ... -run W335b_FollowRequests ./internal/apiserver/ -update-golden
```

VERDICT: PASS

---

## W3-35d: `TestW335a_PartBBudgetTable` independent of test order (2026-10-29)

W3-40b found that the table failed when run alone, on clean main: `Respond decline` 3 reads against the asserted 2, and
`Respond accept, standalone cold` 7 against 5. It passed in the full package run. The test is fixed (no production file
changed in this ticket); the investigation also surfaced one low production observation, D-1 below.

**Cause (two effects).**
1. **A decline after an accept on the same instance reads 3 (production behaviour, D-1).** An accept calls
   `Directory.Forget(requester, caller)` (`backend/internal/graph/follow_requests.go:110`, because the follower counters
   moved), and `identity.Forget` (`backend/internal/identity/service.go:790`) evicts the *caller's* profile too. The next call
   on that instance pays the account-status interceptor's read again. The old test ran accept, decline and replay on one
   instance; whether the decline read 2 or 3 depended on effect 2.
2. **Test-side: the test chain delivers notifications with `notifications.InlineEmitter`**
   (`backend/internal/notifications/emitter.go:173`), a goroutine carrying the request's budget counter that runs after the
   response. Its fan-out reads (the actor's profile, which also re-warms the evicted caller entry, and the recipient's settings)
   land in the measured request line or not, by a race. That is why the cold accept read 7 in some runs and 5 in others (four
   repeats in one process: 7, 7, 5, 5) and why the order of earlier tests changed the outcome. In production the fan-out is a
   separate Pub/Sub push request with its own line.

**Fix.** Every Respond row builds its own instance and says what it is: warm = fresh instance plus one `ListFollowRequests`;
cold = fresh instance and nothing else. The Part B table runs on `noFanout` chains (`w335aOn` with `FEATURE_NOTIFICATIONS` off, so
`prepare` drops the event before the goroutine starts). A cold standalone decline row was added. No ceiling was raised or
lowered; every figure is inside ADR-0025 D7 and the W3-28a implementation note.

| Respond row | State | Reads (measured, 6 of 6 runs) | Ceiling |
| --- | --- | --- | --- |
| accept | warm (after List) | 2 | 3 |
| decline | warm (after List) | 2 | 2 |
| replay, right after an accept | interceptor re-read after `Forget` (D-1) | 2 | 2 |
| accept | standalone cold | 5 | 5 |
| decline | standalone cold | 4 | 5 |

Writes and deletes are unchanged (accept 4 + 1 delete, decline 1 + 1 delete, replay 0).

**Other rows unchanged.** Every non-Respond `W320BUDGET` line of the fixed run was compared with the pre-fix repro and is
identical (Home 7 / 7, Follow 4 / 5 and 4 / 3, UpdateProfile 4 / 3 and 3 / 3, Withdraw 1, ListFollowRequests 42, GetMe 2 and 3,
GetUserTimeline 3, ListFollowers and ListFollowing 3, GetPost 4 and 5, GetThread 6, ListBookmarks 4, ListLikedPosts 4), so
turning the fan-out off moved no other row and the GetMe "+1 count" row still pins its label.
`TestW335a_BudgetTableWithPartBOn` (the W3-20 table) is untouched and still runs with notifications on.

**Order independence (emulators on 38xxx ports, `GOWORK=off`).**
- Alone, `-run '^TestW335a_PartBBudgetTable$' -count=6` in one process (the first iteration is a cold process): 6 of 6 pass with
  identical figures. Before the fix the same command failed (decline 3 against 2 on the first run).
- After the other W3-35a tests, in one process: `go test -shuffle=on -count=3 -timeout 40m ./internal/apiserver/` (whole package,
  seed 1793219025365663600, 776 s): `ok`, the table passed 3 of 3. Go applies one shuffled order to every `-count` repeat; in
  that order the table ran after nine other `TestW335a_*` tests (visibility matrix, `BudgetTableWithPartBOn`, stale protected
  set, ...) and, in repeats 2 and 3, after its own earlier run. A first attempt with default flags hit the 10-minute `go test`
  timeout (the package takes about 4 minutes per pass); that was the timeout, not a failure.
- Separate processes (`-run '^TestW335a_[^P]'`, then the table alone): both pass (no cache carries across processes, so this
  only shows the other tests do not break the table's data).

### Defects and observations

- **D-1 (low, production, owner backend-developer; architect for the ADR wording): a Respond after an accept on the same
  instance reads 3, not the ADR's warm 2.** Repro: one instance, `ListFollowRequests`, accept requester A, then decline (or
  accept) requester B. B's call reads 3 (interceptor, request, requester graph) because the accept's
  `s.directory.Forget(requesterUID, callerUID)` (`backend/internal/graph/follow_requests.go:110`) evicted the caller's
  profile. Production does not hide it (the fan-out is a separate request), so a user working through the requests screen pays
  1 extra read from the second tap on. ADR-0025 D7 and the W3-28a note say the List-then-tap flow "stays at 3 / 2". Impact is
  tiny (1 read per tap, 20 taps = 20 reads). Options for the owner: evict only the requester (the caller's own profile does not
  change, only its follower count, which `Forget` drops with it), or amend the ADR note to "3 / 2 for the first tap, 3 for
  the taps after an accept". Not decided here; no ceiling was changed.
- **Leftover emulators.** Every Pub/Sub emulator run of this ticket left its JVM listening after `emulators:exec` ended (one per
  run, 38085 to 38785). I did not kill them; PIDs are in the hand-off message.

**Reproduce.**
```sh
export GOWORK=off
bash scripts/with-private-tmp.sh firebase --config <untracked copy of firebase.json, ports in 38xxx> emulators:exec --project demo-dzeroth \
  --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -v -run "^TestW335a_PartBBudgetTable$" ./internal/apiserver/'
```

Update 2026-10-29: the founder accepted D-1 as documented behaviour (option B: keep the eviction, record the read); ADR-0025's W3-28a implementation note now says a later Respond after an Accept on the same instance reads 3. The test-side cause (the inline fan-out's reads landing on the producer's request line) is also fixed at the source by #434 (`notifications.InlineEmitter` runs on its own budget counter); this test keeps its per-row fresh instances and the `noFanout` config on top of that.

VERDICT: PASS (D-1 accepted by the founder 2026-10-29, recorded in ADR-0025; no ceiling changed)
