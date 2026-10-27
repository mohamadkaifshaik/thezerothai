# Test report: UI wave W3 Part A backend (W3-20), 2026-10-27

Tester: tester agent. Branch `feat/ui-w3-20` on `main@16524df` (W3-2 to W3-12 merged, plus the W3-22 fixes L-1 to L-5 and M-3,
#350 and #351). Plan: `docs/plans/ui-w3-profile-graph-completion.md` (W3-20). Design: ADR-0024 (D1 to D9, Amendment 1).
Security input: `docs/reviews/security-review-w3.md`.

**VERDICT: PASS for W3-20 as specified** (every ticket bullet is covered by a test that passes on the emulators; every measured
budget is at or under its ADR-0024 ceiling; combined `internal/` coverage 92.4%). It is **not** a statement that W3-22 M-1 is
verified: M-1 is still open on `main` and two constants in the tests pin today's behaviour (section 6). One Low defect is
filed (D-1, the likes cursor) and one test-infrastructure defect (D-2, a shared emulator temp directory). Nothing in
production code was edited.

---

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| `make ci` (gofmt, vet, unit tests with the pkg/platform coverage gate, buf lint, buf breaking, golangci-lint if installed, `flutter analyze`, CSP hash check, `flutter test`) | `GOWORK=off make ci` | **green**, exit 0: gofmt clean, vet, unit tests (pkg/platform gate 87.0%), buf lint, buf breaking, golangci-lint 0 issues, `flutter analyze` no issues, `flutter test` 3,132 passed |
| Go integration on emulators, the whole module (Firestore, Auth, Pub/Sub, Storage) | `GOWORK=off make test-int FIREBASE=firebase`, emulators started by `firebase emulators:exec --project demo-dzeroth-local`, per-run `TEMP` (section 7) | **green**, exit 0, every package `ok`; **combined `internal/` coverage 92.4%** (gate 70%) |
| The W3-20 matrix, verbose | `go test -tags=integration -count=1 -v -run TestW320 ./internal/apiserver ./internal/media` inside `emulators:exec` | **green**: 38 top-level tests, 310 test and subtest results, 0 failed, 0 skipped (96 s apiserver, 14 s media) |
| The cross-ticket journey and the flag matrix, repeated | `-count=5 -run TestW320_E2E` and `-count=5 -run TestW320_FlagModeMatrix` with a private `TEMP`; earlier, `-count=4 -run TestW320_E2E` without it | 5 of 5 pass (and 4 of 4 without isolation when no other suite overlapped); section 7 explains the one failure seen before the merge |

Notes on the environment:
- `-race` was not run: CGO is off on this Windows machine (`RACE_FLAG` is empty). CI on Linux runs it.
- `make test-int` needs `FIREBASE=firebase` here: `command -v firebase` yields a `/c/...` path GNU make cannot spawn (the
  already known D-T17-2 of the graph report, `Makefile:29`).
- Nothing was run against dev or prod. Banner uploads cannot be driven through the apiserver chain on emulators (a V4 signed PUT
  URL cannot be minted), so the chain tests seed READY media documents the way FinalizeUpload leaves them and the upload and
  moderation logic is tested at the media package against the real Firestore repo (section 2, banner row).

## 2. Ticket bullets and the tests that cover them

All files are new and carry the `w320` prefix: `backend/internal/apiserver/w320_*_integration_test.go` (10 files) and
`backend/internal/media/banner_matrix_integration_test.go`. Existing W3-6 to W3-12 chain tests are not repeated; each file's
header says which cells it adds.

| Ticket bullet | Test (file) | What it proves |
|---|---|---|
| Flag modes off / allowlist / percent / on per new flag | `TestW320_FlagModeMatrix` (flag_matrix) | 10 rollout states (off, allowlist with the in user, the out user, empty, percent 0, percent 0 plus an allowlisted user, percent 50, percent 50 plus an allowlisted user, percent 100, on) x 4 flags x both sides of the bucket (the fnv32a bucket is recomputed in the test) x every gated RPC (13 call shapes): a refusal is FAILED_PRECONDITION `FEATURE_DISABLED` with `feature=<flag>` at **exactly 0 reads / 0 writes / 0 deletes**; a call the gate passes is answered by the handler; `GetMe.enabled_features` lists the flag exactly for the callers it is on for; a second chain with the same spec reaches the same verdicts. `TestW320_CompanionFlagPrecedence` (media before profile_extras, posts before likes_list and profile_tabs, graph before follow_suggestions; engagement not needed for the likes list) and `TestW320_UngatedSiblingsStayOpenInEveryMode` (name and bio edit, Posts and Replies tabs, GetProfile and GetProfileRelationship keep working with every W3 flag off) |
| `profile_extras` fields rejected while off | `TestW320_FlagModeMatrix` (banner, location, website, pin, and `""` for each, and `CreateUpload(BANNER)`), `TestW320_E2E_...` step 8 | FEATURE_DISABLED `feature=profile_extras`, 0 reads and 0 writes, before any validation |
| Website and location validation tables | `TestW320_SharedProfileTextOverTheWire` (profile_extras) | Drives the shared fixture `testdata/profile_text/{location,website,display_name,bio}.json` over the wire, one UpdateProfile per row: **61 accept rows** stored exactly as the fixture's `stored` (response and a second viewer's GetProfile), **126 reject rows** INVALID_ARGUMENT VALIDATION `field=<field>`, 0 writes, profile unchanged. The README's runner rule is applied (count of `"raw":` keys against decoded rows) and the 61 / 126 counts are asserted so the suite cannot shrink silently. `host` is a client-side value and is not on the wire (identity's own runner compares it). This replaces the private tables the previous agent wrote (their U+2028/2029 and local-host rows asserted the pre-L-2/L-3 behaviour and one fixture row was invalid by the new 63-character label rule) |
| Pin rules: other user's, REPOST, hidden, deleted, `""` | `TestW320_PinRules`, `TestW320_TakedownKeepsThePinRestoreBringsItBack`, `TestW320_PostDeleteJobClearsThePin`, `TestW320_ExtrasRequestLogNeverCarriesValues` | Own POST, QUOTE and REPLY pin (`pin_check=ok`); another user's post, a REPOST, a deleted, taken-down, suspended-author, never-existing, malformed, path-shaped and wrong-length id are **one identical VALIDATION answer** `field=pinned_post_id` (no existence oracle, `pin_check=rejected`, checked on a warm and a cold chain); `""` unpins and logs no pin_check; a takedown keeps the pin and a restore brings it back with no profile write; the post_delete job clears exactly the deleted post's pin (also with `profile_extras` off everywhere), forged jobs change nothing, redelivery is harmless; the log carries field names, never values |
| Banner moderation path | `TestW320Banner_RacyRuleAndUnitsOnTheRealRepo` (24 cases), `TestW320Banner_VisionCapPathsOnTheRealCounter` (10), `TestW320Banner_ConcurrentFinalizeUnits`, `TestW320Banner_ClaimHeldElsewhereAndFailureRelease`, `TestW320Banner_PurgeCoversEveryStatus` (media package, real Firestore repo) | The Racy rule on each of the two images for BANNER, AVATAR and POST (units 2 / 1 / 1 recorded in the real monthly counter); exhausted-cap paths on the real counter (2 units left, 1 left, at the cap; "established" policy for 30-day, 6-day and 7-day accounts; "reject" policy); a banner needs 2 units so 1 left is already exhausted; 8 concurrent finalizes on one instance: all READY, **exactly 2 units and 2 SafeSearch calls**; a claim held elsewhere answers the retryable MEDIA_NOT_READY at 2 reads / **0 writes**, 0 Vision calls, 0 units; an expired claim is taken over (2 reads / **3 writes**); a failed screening releases its claim (2 writes) and the immediate retry succeeds; purge covers PENDING, READY, READY_UNSCREENED and REJECTED banners with their objects and nobody else's |
| Tab token binding and the Posts-vs-Media token mismatch | `TestW320_TabTokenMatrix`, `TestW320_PreW3TokensStayValid`, `TestW320_UnknownTabIsValidationAtZeroReads` (profile_tabs) | 10 spellings x 10 spellings x {page token, since token} = 200 pairs: **52 open (same effective tab), 148 refused** as VALIDATION `field=page_token` / `since_token` at exactly 0 reads, Posts token on Media and the reverse included; a token is bound to its caller and its target; both tokens at once is refused; tokens forged with the frozen pre-W3 binding strings still open on the tab they were issued for; an unknown tab number is VALIDATION `field=tab` at 0 reads with the flag on or off |
| ADR-0010 D6 drop matrix on Reposts and Likes | `TestW320_TabDropMatrixOnRepostsAndMedia`, `TestW320_LikesDropMatrixWithEmbeddedAuthors`, `TestW320_TabRowsLeaveWhenPostsAreDeletedOrHidden` | A REPOST or QUOTE whose embedded author the viewer blocks, who blocks the viewer or whom the viewer mutes is dropped (counted under the right cause: 4 blocked, 2 muted on the likes page); the unrelated author's copy and the viewer's own copies stay; the author sees all of their own; unblock and unmute bring rows back; **blockedBy overflow fails closed** for every foreign copy; a viewer who blocks or mutes the AUTHOR still gets the posts; a deleted and a taken-down media post leave the Media tab and `removed_ids` lists the takedown |
| Unlike between pages | `TestW320_LikesResidualCasesAndTrim` (likes_list), `TestW320_LikesForgedTokens`, `TestW320_LikesAreOwnerOnly` | Page size 10 over 25 likes: both anchors unliked, a double unlike, Last unliked plus a row above it, a trim of the 5 oldest, a trim that reaches Next: each walk terminates, no row twice inside the remainder, exact expected remainders. The residual "Last unliked, Next unliked and re-liked" case is **defect D-1** (section 5). Forged tokens (expired 25 h, wrong version, negative or non-numeric index, non-post anchors, missing and extra parts, sealed for another uid, for the bookmarks list, with a bare uid, from the future) are VALIDATION at 0 reads; two users' lists are strictly their own |
| Follows-you block matrix and NOT_FOUND byte identity | `TestW320_FollowsYouMatrix`, `TestW320_FollowsYouPairCache`, `TestW320_FollowsYouConvergesAcrossInstances`, `TestW320_TabNotFoundBytesMatchGetProfile` (profile_tabs) | 8 relationship states built with real Follow / Block / Mute calls (no relation, target follows, caller follows, mutual, muted, blocked then edge gone, block then unblock, unfollow), self id at 0 reads, malformed ids at 0 reads, blocked-by refusal at 2 reads (3 on overflow); the pair cache is evicted by the TARGET's Follow, Unfollow and by a Block in either direction and not by the caller's own; a second instance converges within the cache TTL. **Byte identity:** for a user who never existed, a SUSPENDED, a DELETING, a blocking user and a blocker the caller's overflowed blockedBy no longer names, GetUserTimeline MEDIA, REPOSTS and GetProfileRelationship answer exactly GetProfile's HTTP status, content type and body; a control row shows all are 200 for an ordinary user |
| Suggestions exclusion matrix and read cap | `TestW320_SuggestionsExclusionMatrix`, `...OverflowSuggestsNothing`, `...CuratedFallback`, `...HardCap42`, `...PerFolloweeCap`, `...KnownInactiveFolloweeIsSkipped`, `...BlockerOnAnotherInstance` (suggestions) | Self, already followed, blocked, blocks the caller, muted, SUSPENDED, DELETING and a ghost uid are never suggested, on the friends-of-friends path and on the curated list; only the 4 good candidates come back; overflow suggests nothing at 2 reads; **the cap is exactly 42** (30 followees, 30 edges, 10 hydrated) also on a dense graph (120 edges); W3-22 L-5: one followee contributes at most its newest 3 candidates, a followee the profile cache knows is suspended is left out of the edge query (7 reads against 14 for a control instance); W3-22 L-1: a user who blocks the viewer on another instance leaves the warm rows within the snapshot TTL (**2 reads** after expiry, 0 inside it) and Follow of the blocker is NOT_FOUND |
| Backfill rerun = 0 writes | `TestW320_LegacyPostIsOffTheMediaTabUntilBackfilled`, `TestW320_HasMediaOnEveryCreatePathAndTheMediaTab` (backfill) | Every create path (root, reply, quote, text, repost) writes an explicit `hasMedia` bool with both flags off; a legacy post (no key) is off the Media tab until `opsctl backfill-has-media`; the dry run writes 0; the real run writes one doc per missing key (2 writes, 3 reads); **the rerun writes 0** (3 reads); the Media tab then lists the legacy image post |
| `budgettest` on every RPC at the ADR-0024 ceilings | `TestW320_BudgetTable` (budget_table) plus the W320BUDGET lines of the other files | Section 3 |
| UpdateProfile daily cap and no-op skip (W3-22 L-4, added after the merge) | `TestW320_UpdateProfileDailyCapAndNoOpWrites` (profile_extras) | A change costs 1 read / 1 write; the same values again (trim-equal) **1 read / 0 writes**, `updatedAt` does not move, no `profile_fields_changed`; call cap+1 is RESOURCE_EXHAUSTED RATE_LIMITED `limit=profile_update_daily` at 0 reads and 0 writes; another user and GetMe are untouched |
| Cross-ticket journey | `TestW320_E2E_ProfileGraphCompletionJourney` (e2e) | One account sets banner, location, website and a pin; a visitor opens all four tabs, likes and lists the like, sees "Follows you" appear and gets suggestions; the pinned post is deleted and the post_delete job clears the pin; the account exports (location, website, pin and banner URL are in the export, the derived thumb URL is not); every flag is flipped off on a new instance over the same data (gated surfaces refuse, ungated ones work); the account is deleted and no `posts`, `media`, `follows` or `exports` document of it survives |

Not repeated here because an earlier ticket's test already asserts them: the W3-9 / W3-10 / W3-11 / W3-12 chain tests (page-50
figures are measured again in section 3), `TestProfileExtras_Chain`, `identity.TestClearIfPinned_Integration`, and on `main` since
#351 `media.TestIntegration_ConcurrentBannerFinalizeScreensOnce` (the cross-instance M-3 race with a control that proves the
test can fail) and `TestIntegration_ScreeningClaimPreconditions`.

## 3. Measured budgets against the ADR-0024 ceilings

Cold means a chain booted after the data was written (nothing cached) and includes the account-status interceptor's read (the
ADR convention). Measured with the request-log `fs_reads` / `fs_writes` / `fs_deletes` of the real chain and asserted with
`budgettest.Assert`. Source: the `W320BUDGET` lines of the `-v` run (`docs/reviews` quotes, not a gate).

| RPC | Case | Reads | Writes | Deletes | ADR-0024 ceiling (reads / writes) |
|---|---|---|---|---|---|
| `GetUserTimeline` MEDIA | page 20 cold / warm | 24 / 20 | 0 | 0 | 24 / 20 |
| `GetUserTimeline` MEDIA | page 50 cold / warm | 54 / 50 | 0 | 0 | 54 / 50 |
| `GetUserTimeline` REPOSTS | page 20 cold / warm | 24 / 20 | 0 | 0 | 24 / 20 |
| `GetUserTimeline` REPOSTS | page 50 cold / warm | 54 / 50 | 0 | 0 | 54 / 50 |
| `GetUserTimeline` tab refused (flag off, unknown tab, bad token, 148 token pairs) | any | 0 | 0 | 0 | 0 |
| `GetPost` of the pinned post | cold, engagement off / on (+1 `userLikes`) / warm | 4 / 5 / 0 | 0 | 0 | 4 / 0 |
| `UpdateProfile` | banner + location + website + pin, cold | 4 | 1 | 0 | 4 / 1 (worst cold) |
| `UpdateProfile` | location only, cold / warm interceptor | 2 / 1 | 1 | 0 | 2 / 1 |
| `UpdateProfile` | **no-op re-send (W3-22 L-4)** | 1 | **0** | 0 | 1 / 1 (0 added by L-4) |
| `UpdateProfile` | refused by a flag (warm interceptor) or the daily cap | 0 | 0 | 0 | 0 |
| `UpdateProfile` | refused by a validator (187-row fixture) | not asserted | 0 | 0 | 0 writes |
| `CreateUpload` BANNER | cold | 2 | 3 | 0 | 2 / 3 (asserted exactly by `media.TestIntegration_BannerBudgetsAndResolver`, `repo_firestore_integration_test.go:409`) |
| `FinalizeUpload` BANNER | cold (claim, screen, resolve) | 2 | **3** (claim, resolve, Vision counter) | 0 | 2 / 3 (2n+1) |
| `FinalizeUpload` BANNER | claim held by another instance | 2 | 0 | 0 | n/a (no Vision call, no unit) |
| `FinalizeUpload` BANNER | failed screening (claim then release) | n/a | 2 | 0 | n/a |
| `ListLikedPosts` | page 20 cold / warm | 23 / 0 | 0 | 0 | 23 / 20 |
| `ListLikedPosts` | page 50 cold / warm | 53 / 0 | 0 | 0 | 53 / 50 |
| `ListLikedPosts` | empty `userLikes` | 2 | 0 | 0 | 2 |
| `ListLikedPosts` | forged or foreign token | 0 | 0 | 0 | 0 |
| `GetProfileRelationship` | right after the header's GetProfile | 1 | 0 | 0 | 3 cold |
| `GetProfileRelationship` | standalone, cold Directory too / overflow | 4 / 5 | 0 | 0 | 3 (+1 Directory when GetProfile did not run first, +1 overflow) |
| `GetProfileRelationship` | blocked-by refusal / with overflow | 2 / 3 | 0 | 0 | caller graph only |
| `GetProfileRelationship` | warm, self id, malformed id | 0 | 0 | 0 | 0 |
| `ListSuggestedUsers` | friends of friends, hard cap (30 followees, 30 edges, 10 hydrated) and dense graph | **42** | 0 | 0 | 42 |
| `ListSuggestedUsers` | friends of friends, 3 followees / 6 edges / 4 candidates | 12 | 0 | 0 | 42 |
| `ListSuggestedUsers` | exclusion matrix: 16 edges, 7 hydrated | 25 | 0 | 0 | 42 |
| `ListSuggestedUsers` | per-followee cap: 8 edges, 5 hydrated | 15 | 0 | 0 | 42 |
| `ListSuggestedUsers` | known-suspended followee skipped (control instance 14) | 7 | 0 | 0 | 42 |
| `ListSuggestedUsers` | curated only / friends of friends then curated | 6 / 14 | 0 | 0 | 12 / 42 |
| `ListSuggestedUsers` | no followees and no curated list / blockedBy overflow | 1 / 2 | 0 | 0 | 2 |
| `ListSuggestedUsers` | warm, snapshot cached / snapshot expired (W3-22 L-1) | 0 / 2 | 0 | 0 | 1 warm (planning), 2 when the 60 s snapshot expired |
| `post_delete` job | pin cleared: the whole job line seen in the journey (posts, media and graph steps included; observed in the pre-merge failing run, not asserted here) | 8 | 1 | 2 | the pin step alone is 2 reads / 1 write, asserted by `identity.TestClearIfPinned_Integration` |
| `opsctl backfill-has-media` | real run (2 missing of 3) / rerun | 3 / 3 | 2 / **0** | 0 | 1 read per post, 1 write per missing key |

No cell exceeds its ceiling. Mismatches between the sources, noted rather than loosened:
1. **Plan against ADR (ListLikedPosts).** The plan text for W3-10 says 24 cold at page 20; ADR-0024 D6 says "23 cold (the plan
   said 24)" and 53 at page 50. The tests use the ADR figures; the code measures 23 and 53.
2. **ADR "warm" figures are planning values, not ceilings the code reaches.** `ListLikedPosts` warm is 0 (the post cache
   serves the page) against the ADR's 20 / 50; `ListSuggestedUsers` warm is 0 inside the 60 s snapshot against the ADR's 1;
   `GetProfileRelationship` after the header's GetProfile is 1 against 3. Costs are conservative, nothing exceeds a ceiling.
3. **ADR cost table, `CreateUpload` + `FinalizeUpload` BANNER row, writes cell "3.3 + 4.4"** does not state per-call writes. The
   doc comment and the tests agree on 3 for CreateUpload (2 + n) and 3 for FinalizeUpload (2n + 1, since #351 added the claim).
   Owner: architect, to clarify whether the cell is per-DAU or per-call.
4. **The W3-1 "table" is ADR-0024's Cost impact table** (the plan has no separate W3-1 table); `budgettest` ceilings come from
   it.

## 4. Counts

- 38 top-level tests and 310 test and subtest results (flag matrix alone: 10 modes x 2 passes; token matrix: 200 pairs; shared profile text:
  187 rows; banner Racy and cap tables: 34 cases). 0 failed, 0 skipped.
- Combined `internal/` coverage (unit plus integration, `-coverpkg=./internal/...`): **92.4%**, gate 70%. The apiserver package
  alone contributes 65.1% of `internal/` statements with its integration run.

## 5. Defects

| # | Severity | Owner | Where | Detail |
|---|---|---|---|---|
| D-1 | Low | backend-developer (engagement), architect for the ADR sentence | `backend/internal/engagement/service_likes_list.go:100` (`case pn >= 0 && (pl < 0 || pn > pl): return pn`), ADR-0024 D6 "The residual" bullet | When the last returned row is unliked and the next row is unliked and **liked again** between two pages, rule 1 ("Next in `recent[]` and Last gone: resume at it") puts the re-liked Next at the **newest** end, so the walk restarts from the top and repeats the earlier pages. ADR-0024 D6 promises the residual cases "can skip or repeat at most the rows changed in that window". Observed with page size 10 over 25 likes: **9 rows of page 1 repeated** (the ADR bound is the rows changed in the window, 2 here: the last row unliked and the next row unliked then re-liked; the test asserts at most 2 lost and at most 2 repeated), 24 rows in 3 pages after page 1. Repro: `TestW320_LikesResidualCasesAndTrim/Last_unliked,_Next_unliked_and_liked_again_(residual:_see_D-1)` with `-v` (`OBSERVED ... 24 rows in 3 pages after page 1` and `DEFECT D-1 (pre-fix, expected): 9 rows of the earlier pages are repeated, documented bound 2`). Impact: wasted reads and a visible repeat only if the client did not de-duplicate; W3-18 de-duplicates by post id, so users see nothing. Constraint on any fix (no prescription: the token carries only Next, Last and `NextIndex`, and an unlike above Next also makes Next look newer than `NextIndex`, so comparing the two cannot tell a re-like from an unlike; the obvious "accept Next only if not newer than `NextIndex`" would silently skip rows in the passing case "Last unliked and a row above it unliked"): the fix must tell a re-liked Next from one that merely moved, perhaps by carrying one more fact in the token, and must keep the three non-residual remainders in `TestW320_LikesResidualCasesAndTrim` green. Until fixed the test asserts the observed behaviour behind `w320LikesRepeatsAfterLastGoneAndNextRelike = true` and **fails with "flip the constant" when the defect no longer reproduces**, so a fix cannot land unnoticed |
| D-2 | Medium for CI and parallel agents (test infrastructure) | production-deployer (`Makefile`, `scripts/dev.sh`) | `Makefile:129-133` `test-int` / `emulators:exec` | The Firebase Storage emulator keeps its blobs in `os.tmpdir()/firebase/storage/blobs`, shared by every emulator suite on one machine. A second suite starting or stopping wipes that directory and the Storage emulator dies, **taking the whole suite down** (section 7 has the evidence). Seen as a 500 on the export delivery of `TestW320_E2E_...`, then "connection refused" on the Auth emulator. Fix suggested: export a per-run `TEMP`/`TMP` (Windows) or `TMPDIR` (POSIX) for the `emulators:exec` process, as the runner used for this report does. The Makefile's existing `FIREBASE` path defect (D-T17-2) is still open |

No defect was found in the budgets, the flag gates, the authorization (owner-only likes, byte-identical NOT_FOUND, forged tokens),
the drop rules, the pin rules, the backfill or the banner moderation path.

## 6. Known open gaps (pinned by constants, not verified)

W3-22 **M-1** is not on `main` (ADR-0024 Amendment 1 only describes it, #349). Two constants in
`backend/internal/apiserver/w320_helpers_integration_test.go` hold today's behaviour; the M-1 author flips them in the same
change and the tests that read them then assert the fixed behaviour:

- `w320ClearsNeedProfileExtras = true`: today `""` for banner, location, website or pin is FEATURE_DISABLED outside the cohort and
  with the flag off for everyone (read by `TestW320_FlagModeMatrix`).
- `w320WebsiteShownWhileExtrasGloballyOff = true`: today the website keeps rendering when `profile_extras` is globally off, only
  the pin is blanked (read by `TestW320_E2E_...` step 8).

The flag matrix and the journey passing with both `true` is the empirical proof that M-1 is not on `main`. W3-22 **M-2** (the
public bucket is listable) is a Terraform role and cannot be tested on emulators. The fixed items **L-1, L-2, L-3, L-4, L-5 and
M-3** have no constant: their tests assert the fixed behaviour (the pre-merge constants for L-1, L-2, L-3 and M-3 were removed).

## 7. The export failure the previous agent was debugging

Root cause: **not a product bug; the Firebase Storage emulator crashed because another emulator suite on the same machine wiped
its blob directory.**

Evidence (reproduced once on `fcd0145`, the pre-merge commit, `-count=3` of `TestW320_E2E`):
```
w320_e2e_integration_test.go:189: export delivery = 500; job lines [... map[account_job:export ... outcome:error
  error:identity: compose export: objstore: close object: Post "http://127.0.0.1:9199/upload/storage/v1/b/demo-exports-.../o?...":
  read tcp 127.0.0.1:58711->127.0.0.1:9199: wsarecv: An existing connection was forcibly closed by the remote host. ...
w320_e2e_integration_test.go:36: mint token: Post "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key":
  dial tcp 127.0.0.1:9099: connectex: No connection could be made because the target machine actively refused it.
```
and in `firebase-debug.log` of that run:
```
[warn] !  emulators: It seems that you are running multiple instances of the emulator suite for project demo-dzeroth-local. This may result in unexpected behavior.
[debug] Error: ENOENT: no such file or directory, open 'C:\Users\skmk1\AppData\Local\Temp\firebase\storage\blobs\cb2f8f1d-2b89-487d-ad5b-d9add25baa82'
    at Persistence.appendBytes (...\firebase-tools\lib\emulator\storage\persistence.js:30:12)
    at UploadService.multipartUpload (...\firebase-tools\lib\emulator\storage\upload.js:58:27)
[error] Error: An unexpected error has occurred.
```
The export is the only step of the journey that uploads a Storage object; the identity job reported `outcome:error` (a retryable
5xx, as designed), then the unhandled ENOENT killed the CLI process that hosts the Storage and Auth emulators. The assertion
was not weakened and no skip or retry was added. With the Storage emulator's temp directory isolated per run (`TEMP` and `TMP`
pointing at a private directory) the journey passed in the full W320 run, in the whole `make test-int` and 5 of 5 times in a
repeated run. It also passed 4 of 4 on the merged tree with no isolation while no other suite overlapped, which is why the
failure looked intermittent: it needs a second suite to start or stop during the export upload. The one crash was reproduced
once and then diagnosed from the logs; it was not provoked on purpose afterwards, so "isolation prevents it" rests on the
mechanism (the ENOENT path is a directory every suite shares) and on the green runs, not on a forced collision. See D-2 for
the fix to the harness.

## 8. Not covered, and why

- **Banner upload through the apiserver chain.** A signed PUT URL cannot be minted against the emulators; the chain tests seed
  READY media documents and the upload, finalize, moderation, claim and purge paths are tested at the media package on the real
  Firestore repo with a fake object store and a scripted SafeSearch (a Vision call itself is never made).
- **Cross-instance M-3 race.** Covered on `main` by `media.TestIntegration_ConcurrentBannerFinalizeScreensOnce` (with a control);
  not duplicated.
- **`-race`.** CGO is off on this machine.
- **Client tests (responsive matrix, flag-off routing).** W3-21.
- **Real Firestore behaviour** (index build state, transaction contention): the emulator enforces neither the two W3-2
  composite indexes nor the W3-8 backfill precondition; W3-24 owns both checks per project.
- **Load.** W3-23 (`make loadtest`).
- **Prod bucket listing (M-2) and the Vision cap against a real project.** Cloud only.

## 9. Repro

```
export GOWORK=off
# per-run temp dir for the Storage emulator (D-2); use a path of your own
export TEMP='C:\path\to\private\tmp' TMP='C:\path\to\private\tmp'
make test-int FIREBASE=firebase                       # whole module + the 70% gate, prints the internal/ total
firebase emulators:exec --project demo-dzeroth-local --only firestore,auth,pubsub,storage \
  'cd backend && go test -tags=integration -count=1 -v -run TestW320 ./internal/apiserver ./internal/media'
```
Windows can leave an emulator `java.exe` behind after `emulators:exec`; kill only the one still listening on 8080 / 8085 (default
ports) before the next run.

VERDICT: PASS
