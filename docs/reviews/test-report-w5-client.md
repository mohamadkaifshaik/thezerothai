# Test report: W5 Part A client (Lists and Home tabs) — W5-16

Date: 2026-10-31 (PR #551) · Tester: `tester` · Branch `test/ui-w5-16-lists-client-tests` (from `origin/main` 99d5b9e0, which has W5-10 to W5-14) ·
Plan: `docs/plans/ui-w5-lists-communities.md` W5-16 · ADR-0030.

Scope: Lists screen and editor (W5-11), list detail, list timeline and members (W5-12), Add to Lists and `/u/:id/lists` (W5-13), Home tab bar
and Manage pinned (W5-14), the data layer (W5-10). Client only; no production code was changed and no production seam was added. Everything
runs without a network (fakes, `FakeTransport` under the real repositories, a real in-memory drift database where noted).

## Method

The developers' tests were read first (about 20 files, roughly 4,000 lines; list in "Already covered"). The new tests target what the
ticket and the gap list left open, with checks that fail when the behaviour is wrong. Two of them did fail against the product; those are
committed with `skip:` and a reason (D2, D3) and were confirmed red once with the skip removed.

## What was added

| File | Tests | Covers |
|---|---|---|
| `app/test/core/router/w5_lists_flag_product_test.dart` | 40 | `lists` x `ui_shell` x `engagement` (8 cells) x the five Lists routes (`/lists`, `/lists/77`, `/lists/77/members`, `/u/u9/lists`, `/home/pinned`) on the REAL `AppRouter` with the REAL `ListsRepository` and `HomeTabsRepository` over a recording transport: the redirect target for every cell; with `lists` off, zero requests and no list-feed read; with `lists` on, only `ListService` / `SetHomeTabs` procedures |
| `app/test/app/lists_session_test.dart` | 7 (1 skipped) | real `wireAuthSession` + real drift: list timelines cached under `FeedKey.list` (A out then B in; direct A to B; a late write that started for A is dropped), pinned tabs and title overrides across a direct switch, a late GetMe of A ignored, `ListsRepository.clearSession`; **D2** (skipped) |
| `app/test/app/app_widget_test.dart` (+2) | 2 (1 skipped) | `AppWidget` with the real Lists repositories: sign-out forgets list headers; **D3** direct A to B (skipped) |
| `app/test/features/home/presentation/home_tabs_test.dart` (+26) | 26 | pinned list that turns private or deleted on a cold start (cache first, then NOT_FOUND removes the rows, Unpin offered, other tab untouched); offline cold start keeps the cached rows; failed Unpin from the unavailable view; Manage pinned: failed reorder rolls the order back, failed Unpin keeps the row, a retried Pin reuses the idempotency key, first row only "Move down" and last only "Move up"; five long / emoji / RTL / zero-width titles on Home and in Manage pinned (full 360 / 600 / 1200 x light / dark x 1.0 / 1.3 / 2.0); keyboard focus after an arrow key switches tab |
| `app/test/features/lists/presentation/w5_lists_matrix_test.dart` | 342 | Lists screen empty / error / disabled / 20-lists cap with long, emoji, RTL and zero-width names; create sheet (with a 300 dp software keyboard); edit sheet with a 100-character mixed-script description and Delete; User lists screen (empty, NOT_FOUND, error, disabled, names); `ListUnavailableView` (no Unpin, Unpin, busy; 48 dp button; no cause in the text); `ListDetailHeader` x5 variants (private + long description + owner, emoji and 0 members and pinned, RTL and five pinned, pinning not available yet, no header + failed fallback). Full matrix on each |
| `app/test/features/lists/presentation/w5_members_manage_matrix_test.dart` | 126 | Members: empty, NOT_FOUND (no Unpin, no cause), network error, owner with long / emoji / RTL / zero-width names; Manage pinned: Lists fail to load (Retry reachable by scrolling at 2.0), UNIMPLEMENTED (calm note, no Retry), all Lists pinned. Full matrix on each |
| `app/test/features/lists/presentation/w5_lists_flow_test.dart` | 1 | **cross-screen flow** on real repositories over a small stateful fake server: Lists (empty) -> create (private) -> Add to Lists from a profile stub -> list page (no extra GetList, Pin) -> Members -> Home shows the tab and its rows -> list page, Unpin -> Home without the tab |

Totals: 544 new test cases; 542 pass, 2 skipped on purpose (D2, D3).

## Acceptance criterion: "Every new widget is covered at 360 / 600 / 1200, light and dark; no overflow at 2.0"

| Widget | Matrix | Source |
|---|---|---|
| `ListsScreen` rows, long name, private lock | yes | `lists_screen_test.dart:64` (dev) |
| `ListsScreen` empty / error / disabled / capped | yes | `w5_lists_matrix_test.dart` (new; dev had single cells) |
| `ListEditorSheet` create (360 and 1200 only, scale 1.0) | partial (dev) | `lists_screen_test.dart:177` |
| `ListEditorSheet` create and edit, all cells, keyboard inset, Delete | yes | `w5_lists_matrix_test.dart` (new) |
| `ListRow` (incl. long, emoji, RTL, zero-width) | yes | `w5_lists_matrix_test.dart` |
| `ListDetailScreen` loaded, private, unavailable | yes | `list_detail_screen_test.dart:129,150,229` (dev) |
| `ListDetailHeader` variants | yes | `w5_lists_matrix_test.dart` (new; dev had no direct matrix) |
| `ListUnavailableView` (alone, with Unpin, busy) | yes | `w5_lists_matrix_test.dart` (new) |
| `ListMembersScreen` member / owner | yes | `list_members_screen_test.dart:100,114` (dev) |
| `ListMembersScreen` empty / NOT_FOUND / error / long names | yes | `w5_members_manage_matrix_test.dart` (new) |
| `AddToListsSheet` | yes, incl. checked semantics | `add_to_lists_sheet_test.dart:67` (dev) |
| `UserListsScreen` rows | yes | `user_lists_screen_test.dart:49` (dev) |
| `UserListsScreen` empty / NOT_FOUND / error / disabled | yes | `w5_lists_matrix_test.dart` (new) |
| Home tab bar (`HomeTabBar`, "+") with 2 tabs | yes | `home_tabs_test.dart:229` (dev) |
| Home tab bar with 5 long / emoji / RTL / zero-width titles | yes | `home_tabs_test.dart` (new) |
| `ManagePinnedScreen` rows | yes | `home_tabs_test.dart:487` (dev) |
| `ManagePinnedScreen` five long titles, error, disabled, all pinned | yes | `home_tabs_test.dart`, `w5_members_manage_matrix_test.dart` (new) |

## Developer gaps, answered

| Gap named | Result |
|---|---|
| Flag product `lists` x `ui_shell` x `engagement` | Done on the real router (40 cells). `engagement` is not read by any Lists screen (`grep kFeatureEngagement app/lib/features/lists app/lib/features/home`: none; its only user nearby is `pinned_post_section.dart`), so its cells prove it changes nothing. `/home/pinned` and `/lists/:id/members` with `lists` off were the missing router cells. With `lists` off: zero requests and no list-feed read. The Home tab bar with `lists` or `ui_shell` off is `home_tabs_test.dart:404-470` (dev). |
| Shared device: drift tables | No defect. List timelines are stored in `timelineItemEntries` under `FeedKey.list`; `wireAuthSession` wipes them on sign-out and on a direct switch, and a late write that started for A is dropped by the epoch. Tested with real drift. |
| Shared device: `HomeTabsRepository` title overrides | No defect. They live behind `SessionEpoch` and are cleared on the first access after a direct switch (`tabs`, `isPinned`, `labelFor` path); a late GetMe of A is ignored. Tested. The wipe is lazy (it emits only on the next access), harmless because `HomeTabsCubit` is rebuilt with each Home mount. |
| Shared device: `ListsRepository` headers | **Defects D2 and D3** (below). |
| A to B directly | D3 (headers). Pinned tabs and drift are covered by `wireAuthSession` and are correct. |
| Pinned list becomes private, deleted or hidden | Done. A cold start shows the cached rows first and removes them when the server answers NOT_FOUND (this is the accepted security L-6 behaviour, now pinned); other tabs unaffected; Unpin works; a network failure keeps the cache. See O1 for the failed-Unpin selection jump. |
| Pin, unpin, reorder: rollback, cap, key reuse | Done at widget level for Manage pinned (reorder, unpin, pin) and the unavailable view. The 5-pin cap was already covered (`home_tabs_test.dart:593`, `list_detail_screen_test.dart:207`, repository `:176`). |
| Responsive and accessibility | Done (table above). Semantics: Move up / Move down on first and last row; checkbox rows were already covered (`add_to_lists_sheet_test.dart:90`). |
| Cross-screen flow | Done (one test, real repositories). The list timeline is a mocked `TimelineRepository` (drift does not run in `testWidgets`). |
| Keyboard focus across tab switches | Pinned: after an arrow key switches tab, no focus lands in the newly shown bar (each tab has its own bar), and Tab brings it back. No document names this regression precisely; the existing comment at `home_tabs_test.dart:350-352` describes it, and I found no W5-14 note naming it. See O2. |

## Defects

| ID | Severity | Where | Summary |
|---|---|---|---|
| D2 | Medium, **fixed in #553** (W5-50) | `app/lib/features/lists/data/lists_repository.dart:244` (`_seen`), `:87` (`noteListInfo`), `:95` (`clearSession`); second entry `app/lib/features/timeline/data/timeline_repository.dart:374` | `ListsRepository` has no `SessionEpoch` (unlike `HomeTabsRepository`, `LikesRepository` and `BookmarksRepository`). A `GetList`, `ListUserLists`, `CreateList` etc. answer that arrives **after** sign-out puts the list header back into `_headers` after `clearSession()`. The list timeline path is the same: `_fetchList` calls `_onListSeen` for every `GetListTimeline` answer with no epoch check, and the answer of a signed-out user's request still lands in `ListsRepository` and `HomeTabsRepository.noteListInfo`. Reachable on every ordinary sign-out that happens while a list screen or Home list tab is loading. |
| D3 | Low, **fixed in #553** (W5-50) | `app/lib/app/app_widget.dart:266`, `app/lib/app/bootstrap.dart:296-303` | `listsRepository.clearSession()` runs only when auth becomes `unauthenticated`; `wireAuthSession`'s `onSignedOut` in bootstrap only clears the graph cache. On a direct A to B switch A's list headers (name, description, owner, member count, privacy) survive. Same root cause and fix as D1 of W6-19 and D2. |

Why D2 and D3 matter (rule 10, shared device): `ListDetailCubit` shows a cached header at once (`list_detail_cubit.dart:28`, status `ready`,
no request needed) and `ListMembersScreen` computes ownership from it (`list_members_screen.dart:128`). If B opens the URL of one of A's
private lists, B reads A's list name, description, owner and member count until the list timeline answers NOT_FOUND. The server remains
authoritative and B needs the list id (a Snowflake in the URL or in A's shared link), which keeps D3 at Low; D2 is reachable without any
account swap, so it is Medium.

Repro and tests (both committed with a reason; remove the skip when fixed):

- D2: `app/test/app/lists_session_test.dart`, group "ListsRepository headers (in memory, no epoch)", test "a GetList answer that arrives AFTER
  sign-out is not kept for the next account". Expected `header('77')` is null after `clearSession()` and a late answer; actual
  `ListInfo(listId: 77, name: A private list)`. Confirmed red with the skip removed.
- D3: `app/test/app/app_widget_test.dart`, group "Lists state belongs to the account (W5-16)", test "a direct switch to another account forgets
  list headers too". Expected null after the auth stream moves from `uid-1` to `uid-2`; actual the header. Confirmed red with the skip removed.

Suggested fix owner: `frontend-developer`. Give `ListsRepository` a `SessionEpoch` (as `HomeTabsRepository` has) and take the epoch value before each
request and in `TimelineRepository._fetchList` before it calls `onListSeen`; compare in `noteListInfo`.

## Observations (not defects)

- **O1** A failed Unpin from the unavailable view jumps to Following. The optimistic unpin removes the tab and `HomeTabsCubit` moves the
  selection to Following; the rollback restores the tab but not the selection. The snackbar says why and the tab is back in the bar
  (pinned by `home_tabs_test.dart`, "a failed Unpin keeps the tab..."). Info.
- **O2** Keyboard focus is not kept across tab switches (each tab renders its own `HomeTabBar` inside its own scrolling feed). Pinned as the
  documented W5-14 behaviour. A shared sticky bar would fix it. Info.
- **O3** `IconButton` actions render at 40 dp on desktop platforms (`VisualDensity.adaptivePlatformDensity` in `app_theme.dart:453`), for example
  the Lists "Create" button; 48 dp on phones. Theme-wide, not Lists-specific; the matrix asserts 40 dp as the floor for this one control.
- **O4** On the Lists "Retry" at 360 dp and text scale 2.0 the button falls below the fold in Manage pinned; it is reachable by scrolling and the test
  scrolls to it.
- **O5** The router runs the real `/lists/:id` route with `lists` on and `posts` off (no `posts` gate on list routes). The server stays authoritative. Info.

## Already covered by the developers (not repeated)

Repository tests (`lists_repository_test.dart`, `home_tabs_repository_test.dart`: key reuse, coalescing, rollback, 5-pin cap, UNIMPLEMENTED, lists
off, sign-out), cubits, the Lists, detail, members, Add to Lists and User lists screens, the profile header menu, the router cells for `/lists`,
`/lists/:id`, `/u/:id/lists` and `/home/pinned`, the Home tab bar basics (scroll kept per tab, hidden tab does not tick, arrow keys, unlabelled
tab costs one GetList), and Manage pinned (drag, Move down, Unpin, Pin failure rollback, five-pin cap, empty).

## Not run

- Real emulators or a real device: all of this is widget and unit level. `integration_test` was not run.
- A full `TimelineFeedView` with drift-backed list rows (drift does not run in `testWidgets`); the flow test and Home tests use a mocked
  `TimelineRepository`, and the store is tested separately with plain `test()`.
- Pixel goldens (deferred, B-01).
- Server-side behaviour (`GetListTimeline` filtering, authz): W5-15 and W5-17.
- The late-`GetListTimeline` path of D2 was found by reading `timeline_repository.dart:374`; it has no test of its own (the `ListsRepository` test shows the
  effect).
- Engagement, bookmarks, suggestions and trends cubits on a direct A to B switch (D1 of W6-19 and its siblings).

## Verification commands (final tree)

Run on the final tree (Windows, Flutter 3.47 pinned toolchain, `--no-pub`):

- `flutter analyze --no-pub` (whole `app/`, run before the last three lint fixes): 3 infos/warnings, all in the new tests and fixed
  afterwards (unused local, unused import, string interpolation); the re-run on `test/features/lists`, `test/app`, `test/features/home` and the new
  router file: **No issues found**.
- `flutter test --no-pub` (whole `app/`): **8,246 passed, 3 skipped, 0 failed**. The 3 skips are W6-19 D1 (poll votes on a direct switch) and
  W5-16 D2 and D3.
- The three files touched by the lint fixes were re-run: 469 passed.
- Each skipped defect test was run once with its skip removed and failed as described (`Expected: null`, actual the list header).

VERDICT: FAIL — D2 (medium): `ListsRepository` keeps list headers after sign-out when a response arrives late (`lists_repository.dart:244`), skipped repro in `app/test/app/lists_session_test.dart`; D3 (low): list headers survive a direct account switch (`app_widget.dart:266`), skipped repro in `app/test/app/app_widget_test.dart`
