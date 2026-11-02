# Test report: W5-37 Part B client tests (Communities, Flutter)

Plan: `docs/plans/ui-w5-lists-communities.md`, ticket W5-37. Covers the client built by W5-31 (#616), W5-32, W5-33, W5-34 and W5-35b (#641).
Tester: tester agent. Branch `test/communities-w5-37-client-tests`. No production code was edited. No emulators were needed.

**VERDICT: PASS for W5-37 as specified.** No product defect found. Items that do not exist yet are listed in section 6.

## 1. What was added

| File | Tests | Purpose |
|---|---|---|
| `app/test/features/communities/presentation/w5_communities_matrix_test.dart` | 558 | Responsive matrix: each state at 360 / 600 / 1200 dp, light and dark, text scale 1.0 / 1.3 / 2.0, no overflow (`expectNoOverflow`), 48 dp minimum targets where relevant |
| `app/test/features/communities/presentation/w5_communities_flow_test.dart` | 33 | 1 cross-screen flow + 32 flag-product cells (16 flag combinations x 2) |

Shared harness reused: `app/test/support/theme_harness.dart` (`pumpThemed`, `forEachThemeAndWidth`), `geometry.dart`, `posts_fixtures.dart`, `timeline_fixtures.dart`. No new shared helper.
This session repaired the flow test left uncompilable by an interrupted agent: removed a debug `debugPrint` (the one analyzer info) and fixed a wrong assertion (see 4).

## 2. Acceptance criteria to tests

| Ticket bullet | Tests | Result |
|---|---|---|
| Flow: Communities, join | flow `the whole path, one account, one small server` step 1 (one JoinCommunity, "Joined" shown) | pass |
| ... open it, post from the composer | step 2-3 (Post offered, no Join; composer opens with the community preselected; `CreatePost` carries the community id) | pass |
| ... label in Home | step 4 (Home feed shows the post, the PostCard context label "Chess club" is tapped and opens the community) | pass |
| ... community tab / community page lists the post | step 5 (post listed; a plain member has no "Remove from Community" row) | pass |
| ... moderator hide | step 6 (role flips to moderator; menu row, confirm "Remove this post from Chess club?", one HidePost, post leaves the feed, Undo shown) | pass |
| ... report | step 7 (Community options > Report Community > spam > Send report; one report with target type COMMUNITY, the community id, reason SPAM) | pass |
| W5-35b Report Community on the header menu | flow step 7; matrix `Community options menu open`, `Report Community sheet open (COMMUNITY target)`; flag cell: menu only with `reports` | pass |
| Flag combinations `communities` x `lists` x `ui_shell` x `reports` | section 3 | pass |
| Every new widget at 360 / 600 / 1200, light and dark | section 5 | pass |
| No overflow at text scale 2.0 | section 5 | pass |

## 3. Flag combinations (real `AppRouter`, 900 dp so the rail shows)

All 16 combinations of the four flags (`posts` and `graph` stay on), two tests each:

- Community page `/communities/:id`: with `communities` off the screen is absent and `getCommunity` is never called; with it on the screen loads (one `getCommunity`), the "Community options" (Report) menu exists only when `reports` is also on, and "Pin to Home" shows regardless of `lists` (ADR-0031: a community tab is gated by `communities` only).
- `/communities`, `/communities/new`, `/communities/:id/members`, `/communities/:id/moderation-log`: no exception in any combination; with `communities` off no Communities screen and no `listMyCommunities` call; with it on, `/communities` renders the screen; the desktop rail lists Communities only with `communities` and `ui_shell` both on.

## 4. Test fixes made (test code only)

- Flow test line 637: the rail assertion looked for `Icons.groups_outlined`; on `/communities` the rail shows the selected icon `Icons.groups`. Four cells (`communities=true`, `ui_shell=true`) failed on it; the assertion now finds the selected icon. Production behaviour is correct.
- Debug `debugPrint` removed.

## 5. Overflow and matrix results

States covered at 3 widths x 2 themes x 3 text scales (1.0, 1.3, 2.0), each also with long, emoji, RTL and zero-width names where a name is shown:

- Communities screen: empty sections with Create, both sections failed (two Retry), RPC not served.
- Community screen: non-member header (Join, Pin, Report menu) per name kind, banned header, moderator header, NOT_FOUND, load error with Retry, options menu open, Report sheet open, moderator post menu row and the Remove confirm.
- Members screen: empty, NOT_FOUND, network error, owner member menu and the Ban confirm per name kind.
- Moderation log: empty, FORBIDDEN not_moderator, NOT_FOUND, network error.
- Create community: a refusal keeps the form and shows its sentence.
- PostCard: community label per name kind; a repost of a community post shows "reposted" and no label.

Result at text scale 2.0: no overflow in any cell (558 of 558 pass). Overlays run at the same text scale as the page.

## 6. Pending, not tested as existing behaviour

- **W5-51** (not built): moderators hiding replies.
- **W5-53** (not built): moderators cannot hide the owner's or other moderators' posts.
Add tests with those tickets.

## 7. Defects

None. No test was skipped.

## 8. Commands and results

| Command | Result |
|---|---|
| `flutter analyze` (whole `app/`) | No issues found |
| `flutter test test/features/communities/presentation/w5_communities_flow_test.dart` | 33 passed |
| `flutter test test/features/communities/presentation/w5_communities_matrix_test.dart` | 558 passed |
| `flutter test test/features/communities test/features/lists test/features/home test/guards` | 1769 passed |
| `flutter test` (whole app) | 9940 passed, 0 failed |

VERDICT: PASS
