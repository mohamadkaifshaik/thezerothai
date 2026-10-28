# Test report: W3 Part B client (W3-35c), 2026-10-28

Tester: tester agent. Branch `test/w3-35c-client-matrix` on `origin/main@6d4d5027` (merged before the run; the tests were written against `a38515c8`). Plan:
`docs/plans/ui-w3-profile-graph-completion.md` (W3-35c; client tickets W3-33a to W3-33d and W3-34). Design: ADR-0025. Companion
reports: `test-report-w3-client.md` (Part A client, W3-21; the helpers and the matrix format come from it) and
`test-report-w3-partb.md` (W3-35a, backend). No production code was changed; every defect is reported, not fixed.

**Result: three open defects, D-1 (low), D-2 (medium) and D-3 (low), each with a committed, skipped repro. Everything else passes.** The last line
is the verdict.

The plan names `docs/reviews/test-report-w3b-client.md` for this ticket, so this is a new file rather than a Part B section of the
Part A report.

---

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| Static analysis | `flutter analyze` in `app/` (Flutter 3.47.5, the version pinned in `ci.yml`) | no issues |
| Flutter, the whole app | `flutter test` in `app/` after `git merge origin/main` | **5,233 passed, 6 skipped, 0 failed** (about 3.5 minutes). The 6 skips are the three repros below: D-1 (1 test, `app_drawer_test.dart`), D-3 (1 test, same file) and D-2 (4 cells, `w3b_requested_matrix_test.dart`) |
| The fixed-date guard | `test/guards/fixed_date_guard_test.dart` (inside the full run) | passes. No new allowlist entry: the stale-suggestion tests use the rig's clock, which starts from the real clock |

The Part B screens already had a W3-21 matrix in their own PRs (W3-33a to W3-33d, W3-34). This ticket did not copy those cells. It
added the cells that were missing, the flows across screens, and the checks the W3-36 list left for tests. Section 2 maps every
line of the plan's acceptance list to the file that holds it, existing or new.

## 2. The matrix (360 / 600 / 1200 dp x light / dark x text scale 1.0 / 1.3 / 2.0 = 18 cells)

"Existing" means the cells were already green on `main` and are cited, not re-written. "New" is W3-35c.

| Plan item | Test (file) | Cells | What it asserts |
|---|---|---|---|
| Protected profile view, header lock, Requested | existing `w3_protected_profile_test.dart` | 18 + 18 | lock in the header, announced and inside the screen; Requested and Follow are 48 dp and clear of the name and the lock; the view replaces the tabs, the posts and the pin |
| Lock badge on `UserListRow` (W3-33c) | existing `user_list_row_badge_test.dart` | 18 + 18 + more | badge shown, fits, 48 dp; public row has none; the W3-33d wrap rule |
| Requested in a list row | new `w3b_requested_matrix_test.dart` | 18 | 48 dp, inside the screen, not over the long name, the handle or the lock |
| Cancel-request confirm | new `w3b_requested_matrix_test.dart` | 18 | Keep request and Cancel request are 48 dp and inside the screen; Keep sends nothing, Cancel sends one Unfollow and the row is Follow again |
| Protect switch and its two confirms | existing `protect_posts_row_test.dart` | 18 + 18 | row 48 dp, dialog bullets, both confirm buttons 48 dp, one `SetProtected` call |
| Protect switch visibility | new, same file | 4 | public/flag off: no row; public/flag on: switch off, opens the Protect confirm; protected/flag off and on: switch on, opens the Unprotect confirm |
| Protected embed (quote, repost) | existing `protected_embed_test.dart` | 18 | the box replaces text and media, shows the avatar, is not tappable, inside the screen |
| `/follow-requests` rows | existing `follow_requests_screen_test.dart` | 18 | Accept and Decline are 48 dp and inside the screen, with spoken labels |
| Rows: controls against the long name | new `w3b_follow_requests_states_test.dart` | 18 | Accept and Decline overlap neither the name, the handle, the lock nor each other (the D-1 lesson) |
| Empty, error, unavailable states | new, same file | 18 + 18 + 18 | copy inside the screen; Retry is 48 dp and reloads; FEATURE_DISABLED has no Retry and no row |
| Answer snackbar and Follow back | new, same file | 18 + 18 | "can now see your posts" and a 48 dp "Follow back"; a failed answer restores the row and says why |
| Drawer "Follow requests" row and badge | new cells in `app_drawer_test.dart` | 6 x 2 | 360 dp only (see D-2): the row is >= 56 dp, the badge ("7" and "1000+") and the label are inside the drawer and do not overlap |
| `follow_request` and `follow_accepted` rows | existing `follow_request_row_test.dart`, widened | 18 + 18 | the words, a 48 dp tap target, and now: the row is inside the screen |

## 3. Flag-off routing and gating

`/follow-requests` on the real `AppRouter` (`app_router_follow_requests_test.dart`). All eight cells of `graph` x
`private_accounts` x protected now exist (four were new):

| `graph` | `private_accounts` | caller | Result |
|---|---|---|---|
| on | on | public | stays |
| on | on | protected | stays (new) |
| on | off | protected | stays (the undo rule) |
| on | off | public | redirects Home |
| off | on | protected | redirects Home |
| off | on | public | redirects Home (new) |
| off | off | protected | redirects Home (new) |
| off | off | public | redirects Home (new) |

Flows on the real router (new):

- A protected caller with only `graph` in `enabled_features` lands on the screen, sees the request, taps Accept and `RespondToFollowRequest` goes
  out; "Follow back" is offered from the Respond answer, with no `relationshipsFor`, `relationshipFor` or `profileRelationshipFor` call.
- Signing out while on `/follow-requests` leaves for `/sign-in`, sends no further list or answer.

Turn-off and withdraw stay visible with the flag off: existing `protect_posts_row_test.dart` ("a protected account sees the switch on,
whatever the flag") and `w3_protected_profile_test.dart` ("withdraw is offered with flags ..."); both pass.

## 4. Owed items

| Owed | Test | Result |
|---|---|---|
| **W3-35a section 2.3**: a who-to-follow row cached up to 48 h keeps its old `is_private`; a Follow from it answers REQUESTED; the client renders the response, not the cached row, and the next list refreshes the badge | `w3b_stale_suggestion_privacy_test.dart` | A stale non-protected row (no lock) shows "Follow"; the server answers REQUESTED; the button becomes "Requested" (never "Following", never the cached "Follow"); the row's lock is still its own field (none); the shared graph cache holds REQUESTED for other surfaces. In the card the requested row leaves like a followed one. The next list (past 48 h) drops the requested account and carries the new `is_private` for the others |
| **W3-33c**: the badge on a cached who-to-follow row follows the row's field | same file | cached answer: lock on the protected row only; restart from the disk entry asks for nothing (one `ListSuggestedUsers` call) and keeps the same locks; at 47 h an account protected since shows no lock and no call is made; past 48 h one call and the lock appears; the reverse (unprotected) loses the lock |
| W3-36: Accept and Decline reachable for a protected caller while `private_accounts` is globally off | router flow above, `follow_requests_screen_test.dart` ("Accept is not gated") and `app_drawer_test.dart` | pass |
| W3-36: the badge only from `pending_follow_request_count` | drawer test "the badge is the GetMe count and nothing else": a mock `GraphRepository` in the tree would answer a page of 20, the drawer shows "3" and never calls `listFollowRequests`; `onboarding_bloc_test.dart` lowers the count by one per answer | pass |
| W3-36: `follow_request` push to `/follow-requests`, `follow_accepted` to the actor's profile | existing `notification_location_test.dart` (rows and `PushMessage.location`) | pass, cited not copied |
| W3-36: the requests list cleared on sign-out | the router sign-out flow above (screen gone, no calls); `graph_repository_test.dart` and `follow_requests_repository_test.dart` ("clearCache forgets ... the backoff"); `bootstrap.dart:272` calls `graphRepository.clearCache()` on sign-out. The list itself lives only in the screen's cubit, never in a repository or on disk | pass |
| W3-36: "Follow back" uses the Respond response | `w3b_follow_requests_states_test.dart` and the router flow: one `Follow`, no relationship lookup | pass |
| W3-36: FEATURE_DISABLED hides the entry with the 10-minute backoff | screen: calm copy, no Retry, all 18 cells (new); repository: backs off for 10 minutes, 0 RPCs meanwhile (existing `follow_requests_repository_test.dart:105`). **The drawer does not consult the backoff**: D-3 | screen and repository pass; the drawer entry is D-3 |
| Client caches clearing on `author_protected` | existing `timeline_repository_test.dart` ("author_protected", every tab of that author deleted, other authors untouched) and `w3_protected_profile_test.dart` ("a cached feed is not shown once the server says protected") | pass |
| Client caches clearing on sign-out | `session_wiring_test.dart`, `session_epoch_guard_test.dart`, the sign-out flow above | pass |

## 5. Defects

### D-1 (low): the drawer shows "Follow requests" for a public caller whose route redirects Home

- **Where:** `app/lib/core/widgets/app_drawer.dart:45-47` (shown when `graph` and (`protected` or `pending > 0`)) against
  `app/lib/core/router/app_router.dart:495-498` (allowed only when `graph` and (`private_accounts` or protected)). The plan's W3-34
  states both rules, so they disagree by design in one window.
- **Scenario:** `private_accounts` is off for the caller, the account is public, and `pending_follow_request_count` is above 0. The
  server only counts for protected accounts (`identity/service.go:257`), so this needs the caller to unprotect from the app (the
  profile in state flips to public, the count is not reset until the next `GetMe`, up to 30 s of server cache) or a flag change in
  that window. The drawer then shows a badge and the tap lands on Home.
- **Severity:** low. One tap with no effect for a short window; nothing is lost.
- **Repro:** `app_drawer_test.dart`, "D-1: a public account with a stale count and private_accounts off has no entry that the router
  sends Home", skipped with `d1Open = true`.
- **Owner:** frontend-developer (W3-34). Fix either by dropping the count from the drawer condition when the router would redirect,
  or by clearing `pendingFollowRequestCount` on `OnboardingProfileUpdated` with `isPrivate == false`.

### D-2 (medium): no way to open Follow requests on tablet, desktop or the web

- **Where:** `app/lib/core/widgets/app_account_chip.dart:51-61` (the menu is Profile, Settings, Sign out), `app_drawer.dart:70-85`
  (the only entry), `app_top_bar.dart:129` (the avatar that opens the drawer is drawn below 600 dp only).
- **Scenario:** a protected account with pending requests, on a window 600 dp or wider. The drawer cannot be opened there, the rail
  has no entry (Bookmarks has one, marked `railOnly`), and the chip menu does not list it. The only way in is a `follow_request`
  notification row or a typed URL. The chip's own doc comment says it works "like the drawer on phones".
- **Severity:** medium. The feature is unreachable from the main navigation on every wide layout, including the Flutter web build,
  with a workaround through notifications (and the row is easy to lose once read). The protected account's 500-request cap and
  "pending" badge are then invisible on those layouts.
- **Repro:** `w3b_requested_matrix_test.dart`, "D-2: a protected account finds Follow requests in the chip menu", 4 cells (light and
  dark, 600 and 1200 dp), skipped with `d2Open = true`. With the skip removed all four fail with "Found 0 widgets with text
  Follow requests".
- **Owner:** frontend-developer (W3-34). Add the entry (with the badge) to `AppAccountChip` using the same condition as the drawer, or a
  rail entry like Bookmarks.

### D-3 (low): the drawer entry is not hidden while `ListFollowRequests` is backed off

- **Where:** `app/lib/core/widgets/app_drawer.dart:44-47` never reads `GraphRepository.followRequestsUnavailable`
  (`graph_repository.dart:428`); nothing outside the repository reads it.
- **Scenario:** `ListFollowRequests` answers FEATURE_DISABLED (a sub-feature disable) or UNIMPLEMENTED (a rolled-back revision
  without W3-28a, the W3-36 M-1 case). The repository maps both to `FeatureDisabledException` and stops asking for 10 minutes, but
  nothing hides the entry: a sub-feature disable does not refresh `GetMe` (`session_wiring_test.dart`, "a sub-feature disable does
  not refresh GetMe"), and a rolled-back server's `GetMe` still lists `graph`. A protected caller keeps the entry and its badge and
  each tap lands on "Follow requests aren't available right now".
- **Severity:** low. The screen explains itself and sends no request; the plan's W3-34 wording ("FEATURE_DISABLED hides it with a
  10-minute backoff") is not met for the entry.
- **Repro:** `app_drawer_test.dart`, "D-3: while the repository is backed off the entry is hidden", skipped with `d3Open = true`.
  With the skip off it fails with "Found 1 widget with text Follow requests".
- **Owner:** frontend-developer (W3-34). Have the drawer read `followRequestsUnavailable` (`GraphRepository` is provided in `app_widget.dart:264`, above
  the shell), or publish the backoff through the `OnboardingBloc` state.

## 6. Observations (not defects)

| # | Observation |
|---|---|
| O-1 | **The Ahem font limits what a widget test can say** (same as Part A O-1). In the "Accept: the snackbar offers a 48dp Follow back" cell at 360 dp x 2.0 (light and dark) the Material `SnackBar` action ("Follow back", 11 glyphs at 28 dp each) overflows by 43 dp and sits past the right edge. That cell tolerates the overflow message and skips the two inside-the-screen checks; the other 17 cells assert both. With a real font the width is about half, so no defect is claimed; a device check at the largest text size decides |
| O-2 | A requested row leaves the "Who to follow" card the way a followed row does (`onFollowed` fires on REQUESTED, `user_list_row.dart:_isConfirmedFollow`), so "Requested" is not visible in the card. It is visible wherever a list row stays (followers, following, search) and in the profile header. The test asserts both the card behaviour and the standalone row |
| O-3 | A whole-service FEATURE_DISABLED does hide the drawer entry: it refreshes `GetMe`, which drops `graph` from `enabled_features` (`session_wiring_test.dart`, "whole-service FEATURE_DISABLED refreshes GetMe"). Only the sub-feature and UNIMPLEMENTED paths leave the entry (D-3) |
| O-4 | W3-36 I-2 residuals are as documented and not testable on the client: a profile feed cached on disk shows on a cold start until the first refresh returns `author_protected` (the protected map is memory-only), quotes already embedded in Home keep their copy, delivered notifications stay |
| O-5 | The drawer is a phone surface (below 600 dp), so its matrix has one width. That is what makes D-2 matter |
| O-6 | No pixel goldens (opt-in, `RUN_GOLDENS=1`) and no `integration_test` run for these screens: no such harness exists for them yet |

## 7. Reuse report

- **Reused:** `forEachThemeAndWidth`, `MatrixEnv`, `pumpThemed`, `kMatrixTextScalesLarge`, `expectMinTarget`,
  `expectInsideHorizontally`, `expectNoOverflow`, `SuggestionsRig`, `suggestedUser`, `notif`, `kNotifBase`, and the in-file harnesses
  of `app_drawer_test.dart`, `app_router_follow_requests_test.dart` and `protect_posts_row_test.dart` (extended in place, not copied).
- **Extended:** `app_router_follow_requests_test.dart` (four cells, an `arrange` hook and an `authStates` stream on `openAt`, two flows),
  `app_drawer_test.dart` (the badge matrix and three tests), `protect_posts_row_test.dart` (the visibility table),
  `follow_request_row_test.dart` (inside-the-screen check).
- **Created:** `w3b_follow_requests_states_test.dart`, `w3b_requested_matrix_test.dart`, `w3b_stale_suggestion_privacy_test.dart`. The
  screen test harness in `follow_requests_screen_test.dart` is private to its file, so the states file carries a 25-line copy of its
  `open`; the rest is new.
- **Catalog updated:** no (no shared helper was added).

## 8. Files

Final `flutter test` line per file (passed, skipped):

| File | Result | New in W3-35c |
|---|---|---|
| `test/features/graph/presentation/w3b_follow_requests_states_test.dart` (new) | 110 | all 110 |
| `test/features/graph/presentation/w3b_requested_matrix_test.dart` (new) | 36, 4 skipped (D-2) | all 36 + 4 |
| `test/features/graph/presentation/w3b_stale_suggestion_privacy_test.dart` (new) | 6 | all 6 |
| `test/core/router/app_router_follow_requests_test.dart` | 10 | 6 (four cells, two flows) |
| `test/core/widgets/app_drawer_test.dart` | 42, 2 skipped (D-1, D-3) | 14 + 2 skipped |
| `test/features/settings/presentation/protect_posts_row_test.dart` | 47 | 4 |
| `test/features/notifications/presentation/follow_request_row_test.dart` | 37 | 0 (an assertion added to 36 cells) |

Total: 176 new passing tests, 6 skipped repros, 36 existing cells widened.


New: `app/test/features/graph/presentation/w3b_follow_requests_states_test.dart`, `w3b_requested_matrix_test.dart`,
`w3b_stale_suggestion_privacy_test.dart`.
Extended: `app/test/core/router/app_router_follow_requests_test.dart`, `app/test/core/widgets/app_drawer_test.dart`,
`app/test/features/settings/presentation/protect_posts_row_test.dart`,
`app/test/features/notifications/presentation/follow_request_row_test.dart`.

## 9. Handoff

- D-1, D-2 and D-3 go to the **frontend-developer** (W3-34 owner). None blocks the W3-38 dev allowlist rollout of `private_accounts`
  for a phone-only tester; D-2 should be fixed before testers use the web build.
- After D-2, or the owner's decision that notifications are enough, hand to `code-reviewer`.

VERDICT: FAIL — D-2 (medium): a protected account has no entry to Follow requests at 600 dp or wider (`app_account_chip.dart:51-61`, `app_drawer.dart:70-85`, `app_top_bar.dart:129`), skipped repro in `w3b_requested_matrix_test.dart`; D-1 (low): the drawer entry shows for a public caller the router sends Home (`app_drawer.dart:45-47` vs `app_router.dart:495-498`); D-3 (low): the drawer entry ignores the 10-minute backoff (`app_drawer.dart:44-47`); skipped repros in `app_drawer_test.dart`
