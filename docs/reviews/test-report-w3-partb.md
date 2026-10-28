# Test report: UI wave W3 Part B, read paths (W3-35a), 2026-10-28

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

## 1. What was run

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

## 2. What was added

| File | Tests | Covers |
|---|---|---|
| `backend/internal/apiserver/audience_guard_test.go` (no build tag, runs in `make ci`) | `TestAudienceGuard_Backend`, `TestAudienceGuard_SelfTest` (16 cases) | the source-scan guard, section 4 |
| `backend/internal/apiserver/w335a_matrix_integration_test.go` | `TestW335a_VisibilityMatrix` (10 viewer classes), `TestW335a_OverflowFallbackRefusesAStaleEdge`, `TestW335a_SuspendedAuthorAndTakenDownPostHideFromApprovedFollowers`, `TestW335a_RefollowRequestAcceptBringsBackBookmarksAndLikes` | the D4 matrix, byte identity, the leak scan, owed item 1 |
| `backend/internal/apiserver/w335a_leaks_integration_test.go` | `TestW335a_FlagOffKeepsProtection`, `TestW335a_StaleProtectedSet`, `TestW335a_ExportOfAnotherUserCarriesNoProtectedContent`, `TestW335a_ProtectingRetiresNothingAndBannerReplacementRetiresAsForAPublicAccount`, `TestW335a_SuggestedProtectedAccountAndFollowCreatesARequest` | flag off, stale set, export and retire leaks, suggestions |
| `backend/internal/apiserver/w335a_budget_integration_test.go` | `TestW335a_BudgetTableWithPartBOn`, `TestW335a_PartBBudgetTable` | the budget table, section 5 |
| `backend/internal/notifications/push_ids_only_test.go` | `TestPush_CarriesIdsOnlyForEveryType` | push payloads carry ids and static text only |
| `w329a_protected_posts_integration_test.go` (edited) | the stranger-refusal loop | owed item 2: the loose 12 is now a per-RPC ceiling (below) |
| `w320_budget_table_integration_test.go` (edited) | `TestW320_BudgetTable` is now `w320BudgetTable(t, partB)`; the nil call is unchanged | the "+0 against the W3-20 table" run |

### 2.1 The matrix (`TestW335a_VisibilityMatrix`)

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

### 2.2 The other plan bullets

| Plan bullet | Test | Result |
|---|---|---|
| Flag off keeps protection | `TestW335a_FlagOffKeepsProtection`: with `FEATURE_PRIVATE_ACCOUNTS` off, a protected P is refused on GetPost, GetThread, the tabs, both lists, the pin and the 21-path scan; P can list, accept and unprotect; protecting again is refused | pass |
| Stale set (10 minutes, then UNAVAILABLE) | `TestW335a_StaleProtectedSet`: an isolated project, `CACHE_TTL=1s` and `PROTECTED_SET_MAX_STALE=4s` (the same two knobs the 10 minutes use, scaled); the set document is made unreadable after one load; a `protected_set_stale` WARN is awaited while the stranger is still refused as NOT_FOUND (never "everyone is public"), then the stranger gets UNAVAILABLE (reason not PROTECTED_ACCOUNT); the stranger's own post, an approved follower and P are unaffected. The 10-minute default is pinned by `identity.TestProtectedSetLoader_StaleThenUnavailable` and `config` | pass |
| Another user's export | `TestW335a_ExportOfAnotherUserCarriesNoProtectedContent`: U bookmarks, likes, reposts and quotes P's post, P protects, U exports: the JSON has P's post id, U's quote id and U's own quote text, and no P text, no image id, no `/m/` | pass |
| Push payloads carry no post text | `TestPush_CarriesIdsOnlyForEveryType`: `Push` has exactly four id fields, and the FCM message for all eight notification types has four data keys and a title and body that name no handle, link or image | pass |
| `PROFILE_MEDIA_RETIRE=banner` | `TestW335a_ProtectingRetiresNothingAndBannerReplacementRetiresAsForAPublicAccount`: protecting publishes nothing; a protected account's banner replacement publishes exactly one BANNER message, delivers to `retired`, outcome identical to a public account's; the banner in use stays | pass |
| Suggestions | `TestW335a_SuggestedProtectedAccountAndFollowCreatesARequest`: P is suggested with `is_private`, Follow from there is REQUESTED, GetProfileRelationship says REQUESTED | pass |
| Notification fan-out | not repeated: `w331_protected_notifications_integration_test.go` (W3-31) and `w328a` (request and accepted rows); the matrix scans ListNotifications for every unapproved class | covered |

### 2.3 Owed items

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

## 3. Byte identity and oracles, summary

No path leaks an existence or privacy oracle that the deleted-post answer does not: the 48 matrix comparisons, the flag-off, stale-edge,
suspended-author and taken-down cases and the W3-29a stranger table all compare equal on status, content type and body. UNAVAILABLE for a missing set is not PROTECTED_ACCOUNT.

## 4. The audience guard (`audience_guard_test.go`)

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

## 5. Budget table

Every figure is a cold instance (a fresh `Build` chain per call, the account-status interceptor's read included), asserted by
`budgettest.Assert` through `w320Measure`, which logs a `W320BUDGET` line. The protected-set refresh runs on a detached
counter (`protected_set_reads`), so it never appears in a caller's `fs_reads`.

### 5.1 Part B RPCs against the ADR-0025 Cost impact table (`TestW335a_PartBBudgetTable`)

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

### 5.2 Existing read paths, "+0 against the W3-20 table" (`TestW335a_BudgetTableWithPartBOn`)

The whole W3-20 table (`w320BudgetTable`) runs again with `FEATURE_PRIVATE_ACCOUNTS` on and a protected account in the set, 25
measured cases, every one at its W3-20 ceiling: UpdateProfile 4 / 2 / 1, GetPost 4 and 5 and 0 warm, the MEDIA and REPOSTS tabs
24 / 20 at page 20 and 54 / 50 at page 50, ListLikedPosts 23 / 20, 53 / 50 and 2, GetProfileRelationship 3 / 0 / 4 / 5 and
ListSuggestedUsers under its cap. Predicate cost: **+0 reads on every path.** One setup note, not a defect: with bookmarks on
(Part B turns it on) the "engagement off" GetPost case reads 5, not 4, because GetPost's documented extra `userLikes` read fires
when engagement OR bookmarks is on; the wrapped case now turns both off.

## 6. Defects

| ID | Severity | Where | Finding |
|---|---|---|---|
| D-1 | Low (design deviation, no user impact) | `backend/internal/graph/follow_requests.go:149`, `backend/internal/apiserver/notifications_wiring.go:150` | ADR-0025 AQ2 says GetProfile is "the one caller outside `posts.Audience`" of `identity.ProtectedSet.CanSee` and that W3-35a's guard enforces it; AQ5 says `apiserver` adapts the notifications checker "from `posts.Audience.CanSee`". Both sites call the set's expression directly. The rule is not restated (both delegate to the one method) and the behaviour is tested, so the guard allowlists both with this ID. Fix by an ADR note naming the two callers, or by routing them through `posts.Audience` (owner: architect, then backend-developer). |
| D-2 | Low (test fragility; a stale reference budget) | `backend/internal/apiserver/account_lifecycle_integration_test.go:431-433`, `account_lifecycle_reference_integration_test.go:161-163` | Since W3-26a the account-delete job's `users_doc` step does a field-level `ArrayRemove` on `privacy/protectedAuthors`. When that document exists the step costs 4 writes, not the ADR-0011 reference budget of 3 (and 301, not 300, for the reference account). Both tests pass on a fresh emulator (as in `make test-int` above) and fail once any earlier test on the same emulator has protected an account (verified: `TestAccountLifecycle_Chain` passed on a fresh emulator and failed on the same emulator after `TestW326b_PinOmittedForUnapprovedViewers` ran; the reference-account test failed the same way, 301 writes, in the long run). Repro: on one emulator run `-run TestW326b_PinOmittedForUnapprovedViewers`, then `-run 'TestAccountLifecycle_Chain$'` (`fs_writes:4`, budget 3). In dev and prod the document always exists after the first protect, so a real account deletion costs one write more than the documented 3. Fix: raise both budgets by one with the ADR-0011 note, or seed the document in those tests (owner: backend-developer, W3-26a). |

No Critical, High or Medium defects. The matrix, the leak scan, the byte identity, the stale set and the export found nothing.

## 7. Not covered, and why

- `-race` (CGO off here); CI runs it.
- Stale set at the 10-minute default: scaled to seconds through the production knobs; the default itself is pinned by the
  identity loader's fake-clock test.
- The notification rows and pushes themselves are W3-31's tests; the matrix adds the response-body scan only.
- A real FCM send, a real GCS signed URL and the Cloud Run revision mix (rule 10, W3-38) cannot run on emulators.
- The client (W3-35c).

## 8. Repro

```
GOWORK=off make test-int FIREBASE="firebase --config <copy of firebase.graph-loadtest.json on free ports>.json"
GOWORK=off go test -count=1 ./internal/apiserver -run TestAudienceGuard
# inside emulators:exec: go test -tags=integration -count=1 -v -run TestW335a ./internal/apiserver
```

VERDICT: PASS
