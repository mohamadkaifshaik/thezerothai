# Test report: W4 search and discovery, client (W4-21), 2026-10-31

Tester: tester agent. Branch `test/ui-w4-21-search-client-tests` on `main@e3e28c23`. Plan: `docs/plans/ui-w4-discovery-search.md`
(W4-21; client tickets W4-13 to W4-19). Design: ADR-0028. Backend half: `docs/reviews/test-report-w4.md` (W4-20). No production code was
changed; the one defect found is reported, with a committed and skipped repro.

**Result: one open defect, D-1 (Low: layout at the largest text size on a 360 dp phone). Everything else passes.**

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| New file | `flutter test test/features/search/presentation/search_flow_test.dart` | 27 passed, 1 skipped (D-1) |
| D-1 repro | `W421_RUN_DEFECTS=1 flutter test ... --plain-name D-1` | fails as expected: `A RenderFlex overflowed by 4.9 pixels on the right` (`app_search_field.dart:406`) |
| Fixed-date guard | `flutter test test/guards/fixed_date_guard_test.dart` | passes (the new file builds its one date from the real clock) |
| Static analysis | `flutter analyze --no-pub` (whole app) | see section 5 |
| Whole app | `flutter test` in `app/` | see section 5 |

Client only: no emulators, no RPC, nothing against dev or prod. Per-RPC budget: not applicable.

## 2. Audit result

The W4-13 to W4-19 widgets already had matrix tests of their own (`app_search_field_test` and `search_results_screen_test` at 360 / 600 /
1200 x light / dark x 1.0 / 1.3 / 2.0, `explore_who_to_follow_test`, `main_shell_explore_test` at four widths x light / dark x 1.0 / 1.5 / 2.0,
`post_card_hashtag_test`, `app_router_search_test`, the parser, store and cubit tests). What no test had, and what W4-21 asks for, is the
**cross-screen** behaviour on the **real router**: the walk from the field to Explore and the side column, the flag product on the real
`MainShell`, and sign-out through the overlay. The new file `app/test/features/search/presentation/search_flow_test.dart` covers those.

## 3. W4-21 description, one by one

| Bullet | Test(s) |
|---|---|
| field -> overlay -> results -> hashtag tap -> Explore -> side column | `the walk: Explore -> field -> overlay -> results -> hashtag tap -> back -> Explore` (real `AppRouter`, `MainShell`, `TrendsCubit`, `SuggestionsCubit`; the overlay shows Recent, the typed tag, Enter opens `/search?q=%23launch` on Top, the search is recorded, a `#other` tap inside a result opens its results, two Backs return to `/explore` with the list intact and **one** GetTrends in total); `a trend row opens its results`; `at 1200 the side column and the centre share one GetTrends` (Home pill + card, search, back to Explore: pill only in the centre header, card still there, one call) |
| flag combinations `search` x `trends` x `ui_shell` x W3's `follow_suggestions` | 16 generated cells `flag product (...) search=a trends=b ui_shell=c follow_suggestions=d` at 1200 dp on the real router: the Explore destination and the side pill need `search` + `ui_shell`; the "What's happening" card also needs `trends`; "You might like" needs `ui_shell` + `follow_suggestions`; `/explore` redirects to `/home` unless `search` + `ui_shell`; "Trending today" needs `trends`; "Who to follow" needs `follow_suggestions`; GetTrends is asked exactly once when something shows trends and never otherwise; W3's list is asked only when a card can show it; plus `the Explore destination ... in the phone bar` |
| sign-out clears recent searches | `sign-out clears recent searches`: the real `DatabaseRecentSearchesStore` over an in-memory database; the overlay lists the saved tag; sessionEpoch ends and `clearAll` runs; the next user's overlay shows no Recent and the store reads empty. The unit tests of the store (`recent_searches_store_test`) already covered the data layer |
| text scale 2.0 overflow checks | `the whole walk at the widest accessibility setting`: Explore, the overlay with person and hashtag rows, the results and a tap on every tab (Latest, People, Media, Top), at 360 / 600 / 1200 x light / dark x 2.0, with `noException` printing the diagnostics. **Finds D-1** (kept out of this walk, see section 4) |

W4-21 acceptance: "all new widgets are covered at 360 / 600 / 1200, light and dark; no overflow at 2.0". Each new widget has its own matrix (table
below); the only overflow found is D-1.

| Widget / screen | Matrix test |
|---|---|
| `AppSearchField` and overlay | `app_search_field_test.dart` (360 / 600 / 1200 x light / dark x 1.0 / 1.3 / 2.0) |
| `SearchResultsScreen` (Top, tabs, People) | `search_results_screen_test.dart` (two matrices, same axes) |
| `ExploreScreen`, `AppSearchField` in its header | `main_shell_explore_test.dart` (360 / 600 / 1200 / 1536 x light / dark x 1.0 / 1.5 / 2.0) |
| trends section, `TrendRow`, "What's happening" card | `main_shell_explore_test.dart` (360 and 1536 x light / dark x 2.0, 30 rows) |
| "Who to follow" slot | `explore_who_to_follow_test.dart` (360 / 600 / 1200 x light / dark x 2.0) |
| hashtag span in `PostRichText` | `post_card_hashtag_test.dart` (360 dp x 2.0) |

## 4. Defect

**D-1 (Low). The overlay's "Recent" header overflows by 4.9 px on Explore at 360 dp and text scale 2.0.**
`app/lib/features/search/presentation/widgets/app_search_field.dart:406`, `_recentHeader`: a `Row` of `Expanded(Text('Recent'))` and a
`TextButton('Clear all')` with a 48 dp minimum. In the Explore header the pill is only 264 dp wide (the drawer avatar button and the margins), so
at 2.0 "Clear all" keeps its natural width and "Recent" wraps; the row's content is 4.9 px wider than its box. `app_search_field_test` only
runs the full-width pill, so it never sees it.
- Repro: `W421_RUN_DEFECTS=1 flutter test test/features/search/presentation/search_flow_test.dart --plain-name D-1` (the test is
  committed and skipped otherwise).
- Expected: no overflow (the repo's rule is no overflow at 2.0). Actual: `A RenderFlex overflowed by 4.9 pixels on the right.`
- Suggested fix for the owner (frontend-developer): `Wrap` the header, or give "Clear all" `Flexible` and an ellipsis, or drop its horizontal padding.

Observations (no defect): after a search, Back returns to Explore with the typed query still in the Explore field (the pill's controller is
kept), so `#launch` appears both in the field and in the trend row. The plan does not say which is wanted. A product decision, not a bug.

## 5. Whole-app runs

`flutter analyze --no-pub` in `app/`: **No issues found** (114 s). `flutter test` in `app/`: **6,617 passed, 1 skipped (D-1), 0 failed** (8 min 36 s), the fixed-date guard included. `dart format` clean on the new file.

## 6. Not run

`integration_test` (needs a device or Chrome driver; none of the W4 widgets needed new platform channels), goldens (W4 has none), the 600-entry
typeahead burst and the hot-tag load (W4-23, `sre-performance`), anything against dev.

VERDICT: PASS with one open Low defect: D-1 (Recent header overflows 4.9 px at 360 dp x 2.0 on Explore)
