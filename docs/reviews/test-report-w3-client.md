# Test report: W3 Part A client (W3-21), 2026-10-27

Tester: tester agent. Branch `feat/ui-w3-21` on `main@16524df`. Plan: `docs/plans/ui-w3-profile-graph-completion.md`
(W3-21; client tickets W3-13 to W3-19). Design: ADR-0024. No production code was changed; every defect is reported, not fixed.

**Result: one open defect, D-1 (minor, layout at the largest text size on a 360 dp phone), with a committed, skipped repro.
Everything else passes.** The last line of this file is the verdict.

---

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| Static analysis | `flutter analyze` in `app/` | no issues |
| `make ci` (the authoritative run, after the last edit) | `GOWORK=off make ci` from the worktree root | **exit 0**: gofmt, `go vet`, Go unit tests (`pkg/platform` coverage 87.0% vs the 70% gate), `buf lint`, `buf breaking`, `golangci-lint` (0 issues), `flutter analyze` (no issues), the CSP loader-hash check, and `flutter test`: **3,704 passed, 4 skipped (the D-1 repro), 0 failed** (about 14 minutes in all) |
| Flutter, the whole app, before the last 33 cells | `flutter test` in `app/` | 3,671 passed, 4 skipped, 0 failed (246 s); `make ci` supersedes it |
| Flutter, the eleven W3-21 files on their own | section 8 | all green (per-file counts there) |
| The fixed-date guard | `test/guards/fixed_date_guard_test.dart` (inside both runs) | passes. It failed once on this branch: the first draft of the backoff test injected `DateTime.utc(2000)` as the repository clock; it now starts from `DateTime.now()` (only the 10 minute difference matters), with no allowlist entry |

Client only: no emulators, no Go changes, no new RPC. Per-RPC budget: **not applicable** (W3-21 adds no request; the costs of the
client tickets are in the plan). No time-dependent test: dates are built from the real clock (`w3Profile` joins 90 days ago,
the expectation is computed with the widget's own `joinedText`), nothing sleeps for synchronisation (the one real-time wait,
decoding the on-device picture, polls up to 2 s), and `test/guards/fixed_date_guard_test.dart` passes.

## 2. The matrix

Every cell is **360 / 600 / 1200 dp x light / dark x text scale 1.0 / 1.3 / 2.0** (18 cells) unless a row says otherwise.
What each cell asserts (never "no exception" alone): no exception, the named elements are built and inside the screen
horizontally, the owning widget of every control is at least 48 x 48 dp (`expectMinTarget`), and for the profile the tab bar
pins under the app bar and the first row is not hidden under it. Goldens were not required and were not produced.

At scale 2.0 the profile header is taller than the screen, so the tab bar sliver is not built until the user scrolls to it.
The rig scrolls as a user does (`W3ProfileRig.pinTabBar`); no test raises the view height to hide that.

| Ticket and widget | Test (file, new in W3-21 unless marked) | Cells | What it asserts |
|---|---|---|---|
| W3-14 `ProfileHeader`: banner, location, website, "Follows you", "Follow back" | `w3_profile_matrix_test.dart` "header data, banner and targets fit" | 18 | each datum inside the screen; thumb below 600 dp, full image from 600 dp; the band is 3:1; Follow back, the website link (semantics node) and the profile menu are 48 dp; "Follow back" does not cover the name (except the D-1 cell) |
| W3-14 no W3 data | same file, "a profile without the W3 fields" | 18 | flat band at the same size, no pin / website, Joined still shown, tabs still pin |
| W3-14 `GetProfileRelationship`, both paths | same file, "both GetProfileRelationship paths" (the mocked repository answering `followed_by` null / false) | 18 + 12 | no chip, a plain Follow (48 dp), the rest of the header unchanged |
| W3-14 `GetProfileRelationship`, the real `GraphRepository` over a fake transport | same file, "end to end" | 8 + 16 + 8 + 1 | live: chip and "Follow back", `GetRelationships` not called; UNIMPLEMENTED and FEATURE_DISABLED: falls back to `GetRelationships`, no chip, plain Follow; a second visit inside the 10 minute backoff sends no `GetProfileRelationship`, one after it does; offline: profile shows, no Follow, no chip |
| W3-13 / W3-16 pinned tab bar and the four tabs | same file | 18 + 18 + 18 | Posts, Replies, Reposts, Media equal and inside the screen, tab bar >= 48 dp and pinned at the app bar's bottom edge; each tab shows its own rows; empty Replies, Reposts and Media copy inside the screen |
| W3-17 Pinned row and Pin / Unpin | same file, own profile | 18 + 18 + 18 + 18 | Edit profile 48 dp and clear of the name; "Pinned" above the pinned post and below the tab bar; a failed `GetPost` notice and a 48 dp Retry, the post stays listed; "Pin to your profile" is a 48 dp row inside the screen; the replace confirm dialog and its Cancel / Replace are 48 dp |
| W3-15 Edit profile, `profile_extras` + `media` | `w3_edit_profile_matrix_test.dart` | 18 + 18 | banner band 3:1, banner buttons and Save 48 dp, every field reachable, inside the screen and >= 48 dp tall, saved values intact; invalid location and website: inline errors, the "Shows as host" helper and counters inside the screen, Save off but still a 48 dp control |
| W3-15 Edit profile, `media` off | same file | 18 + 6 | a saved banner is read-only (no buttons) at the same 3:1; no saved banner: no band |
| W3-15 Edit profile, `profile_extras` off | same file | 6 | no banner, location or website; name and bio fit |
| W3-15 `BannerEditor` alone | `banner_editor_test.dart` (existing, widened from scale 1.0 to all three) | 6 groups x 18 | every state (placeholder, saved, preview, removed, busy, preparing) |
| W3-18 History and Likes | `history_likes_tab_test.dart` (existing harness, five new groups) | 5 x 18 | empty Likes copy and a reachable tab row; the end note; a failed first page with a 48 dp Retry; the failed-refresh banner words over the rows; flag off: History with no tab row and no Likes call |
| W3-19 Who to follow card | `who_to_follow_card_test.dart` (existing, matrix widened to 2.0 plus a targets matrix) | 18 + 18 | three rows, Show more to five, Follow / x / Show more are 48 dp, inside the card; at 1200 dp the card is checked at the real column width |
| W3-19 in Home | `home_screen_test.dart` | 18 | the card in `headerSlivers`, rows inside the screen, 48 dp targets, Show more opens five |
| W3-19 "You might like" in the right column | `main_shell_layout_test.dart` | 6 + 12 | at 1200 dp the card sits inside `AppSideColumn`, 48 dp targets, Show more opens five; at 360 and 600 dp no column, no request, no overflow |
| W3-14 / W3-15 `ProfileCoverBand` | `w3_profile_cover_band_test.dart` | 3 x 2 | the decoded on-device picture fills the 3:1 box (a `RawImage` holding pixels); corrupt bytes fall back to the flat surface in the same box |

Counts are tests: new files `w3_profile_matrix_test` 236 (+4 skipped), `w3_edit_profile_matrix_test` 78,
`w3_profile_banner_layout_test` 14, `w3_profile_cover_band_test` 6 (334 new passing tests); 166 further cells added to existing
files (16 router, 18 shell, 90 History, 24 Who to follow, 18 Home) and 72 widened in `banner_editor_test` (scale 1.0 to all three).

## 3. Flag-off routing and gating

All against the real `AppRouter` (`app_router_bookmarks_test.dart`, 16 new cells), the drawer and the profile screen.

| Case | Result |
|---|---|
| `/bookmarks` and `/bookmarks?tab=likes` under every combination of `posts`, `bookmarks`, `likes_list` (8 x 2) | `posts` off: redirect Home, no request for either list. `posts` on and `likes_list` off: Bookmarks, no tab row, the query ignored, no `ListLikedPosts`. `posts` and `likes_list` on: tab row; the plain path selects Bookmarks (no likes call), the link selects Likes (one likes call, no bookmarks call). `bookmarks` never changes the route |
| History drawer row | needs `bookmarks` and `posts`; `likes_list` alone, with `posts`, or with `bookmarks` does not add it (the link still works) |
| Profile tabs, `replies` x `profile_tabs` | Posts / Replies / Reposts / Media; Posts / Reposts / Media; Posts / Replies; Posts only. With `profile_tabs` off no Reposts or Media request is made |
| `graph` off | no chip, no Follow, no relationship request |
| `profile_extras` off | the Pinned row still renders (as the plan says) and the post menu has no Pin or Unpin row; Edit profile shows no banner, location or website |
| Signed-out cold open of the history link (existing) | not kept through sign-in (`deepLinkTarget` is null) |

## 4. Banner loading without a layout jump (`w3_profile_banner_layout_test.dart`)

`ProfileHeader` puts the banner in a `SizedBox(height: width / 3)` and `ProfileCoverBand` fills it, so nothing the image does can
move what is around it. Checked at 360 / 600 / 1200 dp x scale 1.0 / 2.0:

- The whole screen with a banner URL: the header size, the display name's top and the band size are identical on the frame the
  profile arrives, after settling, two seconds later, and **with no banner at all**.
- The header when a banner is added, replaced and removed after the first layout (an edit): never one dp of change.
- A failed image (403, 404, a closed connection): the `errorWidget` and the `placeholder` builders both return the same flat
  `surfaceContainerHigh` box, in light and dark, with no icon or text.
- The decoded on-device picture and corrupt bytes (above): the same box.

**Not exercised, and why.** A network banner that actually loads, and a real HTTP 403 or 404, cannot run in a widget test: every
request answers 400 and the cache manager needs the `path_provider` plugin. `ProfileCoverBand` has no seam for a fake image
provider; adding one is a production change, so none was added (it is the owner's call; the contract above does not depend
on it because the box is fixed). A 403 and a 404 are the same case at this level (both reach `errorWidget`).

## 5. Defects

### D-1 (minor): the header actions overlap the display name at 360 dp and text scale 2.0

- **Widget:** `ProfileHeader` actions, `app/lib/features/profile/presentation/widgets/profile_header.dart:192-196` (the strip
  under the banner is `max(overlap + 8, 12 + 48)` = 60 dp whatever the text size) and `:314-319` (the actions are a
  `Positioned` over that strip). Owner: frontend-developer (W3-14 for "Follow back"; "Edit profile" is older).
- **Condition:** width 360 dp, text scale 2.0, light and dark. Not at 1.0 or 1.3, and not at 600 or 1200 dp.
- **What breaks:** another user's profile that follows you: "Follow back" is 84 dp tall (its label wraps to two lines) at
  `(172, 188)-(344, 272)`, the display name starts at `y = 236`, so the button is painted over the first line of the name
  (172 x 36 dp of overlap) and over the profile menu button (48 x 18 dp). Your own profile: "Edit profile" is 56 dp tall,
  `(120, 188)-(344, 244)`, 8 dp over the name.
- **Repro:** `flutter test test/features/profile/presentation/w3_profile_matrix_test.dart --name D-1` after setting `d1Fixed` to
  `true` at `app/test/features/profile/presentation/w3_profile_matrix_test.dart:594` (it is `false`, so the four cells are
  skipped and CI stays green). Verified: with `d1Fixed = true` all four fail with
  `actions Rect.fromLTRB(172.0, 188.0, 344.0, 272.0) over the name Rect.fromLTRB(16.0, 236.0, 344.0, 338.0)`.
  Every other cell asserts the actions never cover the name (`w3_profile_matrix_test.dart:127`), so a regression elsewhere fails.
- **Caveat:** the VM draws text in the Ahem test font (1 em per glyph), wider than a real font, so the wrap and the heights are
  worst case. With Roboto at 30 sp the "Follow back" label is about 170 dp plus its padding against a 172 dp button, so it
  very likely wraps on a device too, and "Edit profile" is about 50 dp against the 48 dp strip. Confirm on a device or with a
  real-font golden (`RUN_GOLDENS=1`) before deciding the severity.
- **Suggested fix (the owner's call):** let the strip grow with the actions' measured height instead of a fixed 60 dp.
  Unskip by flipping `d1Fixed`.

## 6. Observations (not defects)

| # | Observation |
|---|---|
| O-1 | **The Ahem font limits what a widget test can say.** Text is 1 em per glyph, so ellipsis and wrap are exaggerated and cannot be judged: under it the four profile tabs ellipsize at 360 dp from scale 1.0, and the History tab row's "Likes" tab starts off-screen at 360 dp x 2.0 (it is reachable: the row scrolls sideways, and the test uses `ensureVisible`). Neither is claimed as a defect; a real-font golden or a device check decides. A first version of the matrix asserted "not ellipsized" and was dropped for this reason |
| O-2 | `who_to_follow_card_test.dart` gave the card a 16 dp margin on every side, so at 1200 dp x 2.0 it was 32 dp narrower than in `MainShell` (bottom margin only) and overflowed by 8 dp. That was the harness, not the product: the harness now uses the shell's margin for the column cells, and the real shell cells pass |
| O-3 | The UNIMPLEMENTED fallback in `GraphRepository.profileRelationshipFor` (`TODO(W3-11)`) is still there and both paths are covered. When the owner removes it, delete the "UNIMPLEMENTED", "FEATURE_DISABLED" and backoff cells of the "end to end" group in `w3_profile_matrix_test.dart` and the fallback cases of `graph_repository_test.dart` |
| O-4 | Website rendering while `profile_extras` is off is W3-22 finding M-1 (ADR-0024 Amendment 1 changes it). It is deliberately not asserted here so as not to pin the behaviour that is being changed; the M-1 client fix owns its test |
| O-5 | The UI is left-to-right only (no RTL locale). `ProfileHeader` places the avatar and the actions with physical `left` / `right`, so an RTL locale would need mirroring; no RTL cell was added |
| O-6 | No pixel goldens (not required; they are opt-in, `RUN_GOLDENS=1`) and no `integration_test` run: there is no such harness for the profile yet |

## 7. Reuse report

- **Reused:** `forEachThemeAndWidth`, `MatrixEnv`, `pumpThemed` (`theme_harness.dart`), `EditProfileRig` / `openEditProfile` /
  `reveal`, `FakeLikesServer` / `FakeBookmarksServer`, `FakeSuggestionsRepository`, the `history_likes_tab_test` and
  `home_screen_test` harnesses (extended in place instead of copied), `FakeTransport`, `joinedText`.
- **Extended:** `theme_harness.dart` (`kMatrixTextScalesLarge` = 1.0 / 1.3 / 2.0), `geometry.dart` (`expectMinTarget`,
  `expectInsideHorizontally`), `main_shell_layout_test.dart` (`pump` takes a brightness and a text scale),
  `who_to_follow_card_test.dart` (`open` takes the card margin), `banner_editor_test.dart` (scales 1.0 to all three).
- **Created:** `test/support/w3_profile_rig.dart` (`W3ProfileRig`): the profile screen over mocked repositories with a real
  `GraphRepository` option. The two existing profile rigs are private to their files and neither could script the `followed_by`
  unknown case, every tab, or a real repository.
- **Catalog updated:** yes (`docs/ui-catalog.md`: the harness row and a `W3ProfileRig` row).

## 8. Files

New: `app/test/features/profile/presentation/w3_profile_matrix_test.dart` (236 + 4 skipped),
`w3_edit_profile_matrix_test.dart` (78), `w3_profile_banner_layout_test.dart` (14), `w3_profile_cover_band_test.dart` (6),
`app/test/support/w3_profile_rig.dart`.
Extended: `test/core/router/app_router_bookmarks_test.dart` (26), `test/core/router/main_shell_layout_test.dart` (68),
`test/core/widgets/app_drawer_test.dart` (23), `test/features/engagement/presentation/history_likes_tab_test.dart` (151),
`test/features/graph/presentation/who_to_follow_card_test.dart` (57), `test/features/home/presentation/home_screen_test.dart` (95),
`test/features/profile/presentation/widgets/banner_editor_test.dart` (109), `test/support/geometry.dart`,
`test/support/theme_harness.dart`.

## 9. Handoff

- D-1 goes to the **frontend-developer** (W3-14 owner). It does not block the W3-24 dev allowlist: it needs the largest OS text
  size on a phone 360 dp wide or narrower, and nothing is lost (the button still works; it overlaps the name).
- On a pass of D-1 (or the owner's decision that it is acceptable), hand to `code-reviewer`; the W3 `security-auditor` review is
  already in `docs/reviews/security-review-w3.md`.

VERDICT: FAIL — D-1 (minor): at 360 dp and text scale 2.0 the profile header's "Follow back" / "Edit profile" buttons overlap the display name (`profile_header.dart:192-196, 314-319`); skipped repro committed in `w3_profile_matrix_test.dart`; confirm with a real font
