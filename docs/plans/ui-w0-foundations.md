# UI wave W0: foundations (colour system, tokens, shared chrome, responsive shell)
Plan owner: planner (DRAFT 2026-10-22) · Stage 0 ($0) · **Client-only: 0 RPCs, 0 Firestore reads/writes, no proto, Terraform or Firebase change** · Flag: none for the theme; the shell change has an optional kill switch (decision D3)
Inputs: `CLAUDE.md`, `docs/x_research/` (`02`, `03`, `04`, `05`, `10_light_dark_theme.md`, `11`, `12`, `14_mvp_structured_plan.md`, `screens/`, `screens/mobile/`, `screens/light/`), `docs/ui-catalog.md`, `app/lib/core/theme/app_theme.dart`, `app/lib/core/widgets/responsive_scaffold.dart`, `app/lib/core/router/main_shell.dart`, `app/lib/shared/widgets/*`.
Skills to follow: `reuse-first`, `flutter-feature`, `flutter-modern-ui`, `testing-strategy`, `pr-workflow`.

## Goal
Make the app's visual system and navigation chrome match the decisions of 2026-10-22 so every later wave (W1 core surfaces, W2–W8 features) builds on one foundation:
1. **X's colour system** in dark and light (no indigo seed, no gradient), as specified in `docs/x_research/10_light_dark_theme.md`.
2. Typography/spacing/size tokens at the observed values (dp = X's CSS px; the research scale was verified at 1.25).
3. Shared widgets that do not exist yet: **`AppTabBar`**, **`AppTopBar`**, **`AppDrawer`**.
4. A **`ResponsiveScaffold`** with the three layouts (bottom bar + top bar + drawer below 600 dp, icon rail 600–1199, extended rail with account chip and Post pill from 1200, content capped at 600 dp, 350 dp side column).
5. A **golden/geometry test harness** (none exists today) so W1+ can assert pixels, light and dark.
No screen is redesigned here beyond adopting the new chrome in Home and Notifications; W1 does the screens.

## Out of scope (belongs to later waves)
Post card changes (W1-1), profile layout (W1-3), Notifications tabs (W1-6), Settings master–detail (W1-7), bookmarks and every new feature (W2+), any backend work, X's brand assets (logo, Grok, Premium, ads), fonts (platform font stays; family not verified).

## Decisions to confirm (non-blocking; defaults apply if no answer)
| # | Decision | Default |
|---|---|---|
| D1 | Small accent **text** on white (links, hashtags, "Show more"): X-exact `#1d9bf0` (3.00:1, fails 4.5:1) or darker accessible `#1478bd` (4.72:1) | **darker token for small text on light only**; X blue for fills, indicators, icons, large bold text |
| D2 | FAB rule below 600 dp | hidden on Home (inline composer) and Notifications and Settings; shown on Profile and post detail |
| D3 | Ship the new shell (top bar, drawer, bottom-bar contents) behind a server flag `ui_shell` for rollback? | **Yes for W0-5/W0-6**, no flag for tokens/theme. Needs `FEATURE_UI_SHELL` in `backend/pkg/platform/config` + Terraform default off (deployer ticket W0-10). If declined, ship ungated and rely on `git revert` |
| D4 | `BackdropFilter` blur on the translucent top bar (X blurs; web cost on low-end devices) | optional: opaque-ish surface at ≥ 85 % alpha by default, blur only on non-web or behind a theme extension switch |
| D5 | Golden strategy | geometry assertions (`getRect`/`getSize`) for sizes/spacing + pixel goldens generated **only on CI Linux** with the pinned Flutter version (CI already pins 3.47.x via `.github/actions/setup-flutter`) |

## Tickets
| ID | Ticket | Owner | Size | Depends on | Status |
|---|---|---|---|---|---|
| W0-1 | Colour system: explicit dark/light `ColorScheme`, semantic colour extension, flat inverse pill replaces the gradient button | frontend-developer | M | W0-7 | **Done** (branch `feat/ui-w0-foundations`, local, not committed) |
| W0-2 | Typography tokens (post body 15/20, titles w700, counts 13, drawer/nav 20) | frontend-developer | S | W0-7 | **Done** |
| W0-3 | Spacing/size tokens (12 dp step, 4 dp tab bar, 16 dp action glyph, content/side widths, tab/row heights) | frontend-developer | S | – | **Done** |
| W0-4 | `AppTabBar` | frontend-developer | M | W0-1, W0-3 | **Done** |
| W0-5 | `AppTopBar` + `AppDrawer` + shell scope; adopt in Home and Notifications | frontend-developer | M | W0-1..W0-4 | **Done** |
| W0-6 | `ResponsiveScaffold` + `MainShell` rework (3 layouts, account chip, pill Post, 600/350 dp, FAB rule) | frontend-developer | L | W0-1, W0-3, W0-5 | **Done** (new `AppBottomBar`, `AppAccountChip`) |
| W0-7 | Test harness: geometry helpers + golden config (light/dark x 360/600/1200 x text scale 1.0/1.3) | tester | M | – | **Done** (geometry assertions always on; pixel goldens opt-in, see notes) |
| W0-8 | Appearance setting: System / Light / Dark with persistence | frontend-developer | S | W0-1 | **Done** (drift `AppSettingEntries`, schema v6) |
| W0-9 | Docs: `docs/ui-catalog.md`, `docs/code-map.md`, plan status, ADR note on the colour decision | frontend-developer + architect (ADR note only) | S | W0-1..W0-8 | **Done** (`ui-catalog.md` updated; `code-map.md` is backend-only, no change; `docs/adr/0020-ui-colour-system-follows-x.md` Proposed, founder to Accept) |
| W0-10 | (only if D3 = yes) `FEATURE_UI_SHELL` flag: Go config + env default off + client gate + Terraform var | backend-developer + production-deployer | S | W0-6 | **Done (D3 = yes, founder 2026-10-22).** `FEATURE_UI_SHELL[_ALLOWLIST|_PERCENT]` (wire `ui_shell`, default off): `config.go` + `apiserver.go` registry, Terraform dev/prod vars and env entries (no apply), `flag-ceiling.json` (off) + promotion fixture, Dart `kFeatureUiShell` gating `MainShell`. Off = legacy chrome (Settings as 4th destination, no drawer/chip, FAB wherever posting is offered); the flag gates structure, not colours. Tests: `main_shell_layout_test.dart`, `ui_shell_test.go` |
Branches/PRs: one ticket per PR, `feat/ui-w0-<slug>` (e.g. `feat/ui-w0-colour-system`), merge `origin/main` into the branch, no push or PR unless the founder asks (`pr-workflow`). Suggested merge order: **W0-7 → W0-1 → (W0-2, W0-3) → W0-4 → W0-5 → W0-6 → W0-8 → W0-10 → W0-9**.

---
## W0-1 Colour system
**Scope.** Replace `ColorScheme.fromSeed` + violet tertiary + `AppGradientButton` with X's palette (spec table in `10_light_dark_theme.md` §2).
**Files (existing).** `app/lib/core/theme/app_theme.dart` (constants `_seedColor`, `_lightTertiary`, `_dark*`; `_colorScheme`; component themes); `app/lib/shared/widgets/app_gradient_button.dart` → rename to `app_pill_button.dart` (**keep the API**: `label`, `onPressed`, loading state, so call sites change by name only); call sites: `features/auth/presentation/widgets/email_password_form.dart`, `features/home/presentation/widgets/home_composer_entry.dart`; `features/profile/presentation/widgets/profile_header.dart` (`_CoverBand` gradient at ~line 300 → flat `surfaceContainerHigh`); `features/onboarding/presentation/create_profile_screen.dart` (raw `Colors.green` / `Colors.red` at ~lines 126/130 → semantic tokens).
**Design.**
- Dark: `surface #000000`, `onSurface #e7e9ea`, `onSurfaceVariant #71767b`, `outlineVariant #2f3336`, `outline #333639`, `primary #1d9bf0`, `onPrimary #ffffff`. Light: `#ffffff`, `#0f1419`, `#536471`, `#eff3f4`, `#cfd9de`, `#1d9bf0`, `#ffffff`. Raised steps: dark `#080808 / #141414 / #1d1d1d`, light `#fafafa / #f9f8f7 / #f2f2f2`. `tertiary` removed.
- **Strong (inverse) pill** = `FilledButton` default: dark fill `#eff3f4` + label `#0f1419`; light fill `#0f1419` + label `#ffffff`; disabled flat (`#3c3d3d` dark; light to confirm, default `onSurface` at ≈ 40 %). **Accent button** (FAB, Subscribe-style CTA) = `#1d9bf0` + white bold label. Outlined pill unchanged in shape (`outline` colour).
- `ThemeExtension` `AppColors` with semantic tokens `like #f91880`, `repost #00ba7c`, `live #f91880`, `recommendation #794bc4`, `positive`/`negative` for the two onboarding indicators (use `repost`-green and `error`), `scrim` (dark tinted `#242d34`-like ≈ 45 %, light black ≈ 15 %), plus accent-text token per D1.
- Status-bar icon brightness per theme; web `theme-color` per theme.
**Acceptance.**
1. No `fromSeed`, no `tertiary`, no `LinearGradient` left in `lib/` outside generated code (grep check in a test).
2. No raw `Color(0x…)`/`Colors.*` outside `app_theme.dart` (grep test), including the two onboarding spots.
3. Theme test asserts the exact hex values above for both brightnesses; text pairs ≥ 4.5:1 (computed in the test) except hairlines; the accent-text token ≥ 4.5:1 on `surface` in light.
4. Pill button geometry (min height 48 dp tap target kept; visual 36 dp compact variant available) and loading/disabled states covered by widget tests (rewrite `test/shared/widgets/app_gradient_button_test.dart` → `app_pill_button_test.dart`; update `auth_screens_layout_test`, `sign_in_screen_test`, `sign_up_screen_test`, `home_screen_test`).
5. Goldens (light + dark) for: sign-in screen, Home composer entry, profile header, snackbar, dialog.
**Risks.** Wide blast radius (every screen's colours); mitigated by tests 1–3 and goldens. Light-theme values for disabled and selected rows are NOT VERIFIED on X: marked as "to confirm" and isolated in one place.

## W0-2 Typography tokens
**Files.** `app_theme.dart` (`textTheme`), `shared/widgets/post_card.dart` (`PostRichText` uses `bodyLarge`), `post_action_bar.dart` (count style), nav label style in `responsive_scaffold.dart`.
**Design.** `bodyLarge` 15 / height 1.33 (20 dp pitch); `bodyMedium` 14 → keep, counts 13 via `copyWith`; `titleSmall` 15 w700; `titleMedium` 15 w700 (news/settings titles) — check call sites; `titleLarge` 20 **w700** (was w800); `headlineSmall` capped 22 for profile name; drawer/nav labels 20 (`titleLarge`-based, w700 when selected, w400 otherwise). Font family unchanged (platform default).
**Acceptance.** `app_theme_test.dart` asserts the scale; PostCard geometry test shows body line pitch 20 ± 0.5 dp; no overflow at text scale 1.3 in the goldens of W0-7; no existing test regresses (update only intentional ones).
**Risk.** Changing `bodyLarge` affects composer, bios and others: review all `bodyLarge` uses (grep) and list them in the PR.

## W0-3 Spacing/size tokens
**Files.** `app_theme.dart` only.
**Design (dp).** `AppSpacing.smd = 12`; `AppSize`/constants: `tabIndicator 4`, `topBarRow 53`, `headerTabs 53` (header total 107), `bottomNav 56` (existing; X 54), `navRailItem 50`, `settingsRow 48`, `drawerRow 56`, `listRow 72`, `contentMax 600`, `sideColumn 350`, `drawerWidth 277`, `avatarSm 32`, `avatarMd 40`, `avatarProfile 133/88`, `actionIcon 16` (tap target stays 48), `pillCompact 36`, `pillSmall 32`. `AppBreakpoints`: keep 600/1200 (mobile < 600, tablet < 1200).
**Acceptance.** Tokens exist with doc comments citing `docs/x_research/04_spacing_and_layout.md`; unit test asserts values; no duplicates of existing constants (reuse-first review).

## W0-4 `AppTabBar`
**File.** new `app/lib/shared/widgets/app_tab_bar.dart` (no package).
**Spec (from `screens/_shared.md`, `explore.md`, `notifications.md`).** Row height 53 dp; label 15 dp, active `onSurface` w700, inactive `onSurfaceVariant` w400; indicator **4 dp `primary`, width = label width, flush with the 1 px bottom hairline**; two modes: **content-sized** (label gap ≈ 43 dp mobile / 61 dp wide, i.e. horizontal padding ≈ 22 / 30 dp per side; overflows with horizontal scroll and an edge cut) and **equal-width**; optional icon before label (History tabs); optional trailing "+" slot; selected index + `onChanged`; supports **one** tab (Home = "Following" only per decision 2).
**Semantics.** `Semantics(selected, button/tab)` per tab, container labelled; keyboard arrow navigation on web; minimum 48 dp tap height.
**Acceptance.** Widget tests: selection change, single tab, overflow scroll, equal-width distribution, indicator width equals label width (±1 dp), semantics selected flag; goldens light/dark. No `TabController` requirement (usable inside slivers/pinned headers).

## W0-5 `AppTopBar`, `AppDrawer`, shell scope
**Files.** new `core/widgets/app_top_bar.dart`, `core/widgets/app_drawer.dart`, `core/widgets/app_shell_scope.dart` (an `InheritedWidget` exposing `openDrawer()`), edits in `features/home/presentation/home_screen.dart` and `features/notifications/presentation/notifications_screen.dart` (replace the `SliverAppBar` titles).
**Top bar spec.** Row 53 dp: leading **avatar button 32 dp** (opens the drawer; `AppAvatar`), centre/leading title or logo slot, trailing action slot (e.g. gear), bottom hairline; translucent surface per D4; used **only below 600 dp** (on wide layouts the rail provides the avatar chip). Semantics: avatar button labelled "Account menu".
**Drawer spec.** Width `min(277, 85 % of width)`; scrim per theme; header: avatar 40 dp, display name (bold), `@handle` (secondary), "N Following · N Followers" linking to `/profile/:handle/following|followers`; rows 56 dp (icon 22 dp + label 20 dp bold): **Profile, Settings, Sign out** (Bookmarks/Lists added by later waves, flag-gated); closes on back, scrim tap, ESC and after navigation; focus returns to the avatar button; reads profile from the existing `OnboardingBloc` (no RPC).
**Acceptance.** Widget tests: opens from avatar, rows navigate through `AppRouter` constants, Sign out dispatches the existing auth event, closes on back/scrim, focus restoration; counts row hidden when profile absent; no new RPC (assert the fake repositories receive 0 calls); goldens light/dark at 360 dp.
**Dependencies.** Needs W0-1 tokens, W0-3 sizes, W0-4 only for Home's tab bar adoption.

## W0-6 `ResponsiveScaffold` + `MainShell`
**Files.** `core/widgets/responsive_scaffold.dart`, `core/router/main_shell.dart`, `core/router/compose_gate.dart`, tests `test/core/router/main_shell_compose_test.dart` (update) + new `responsive_scaffold_test.dart`.
**Layouts (dp).**
- **< 600:** top bar (W0-5) + bottom `NavigationBar` (56 dp, labels hidden, transparent indicator, 1 px top hairline, filled glyph when selected, dot variant for unread via `Badge`) + drawer; FAB (accent, 55 dp) per D2.
- **600–1199:** icon-only `NavigationRail`, content capped at 600 dp and centred, no side column.
- **≥ 1200:** extended rail with labels (20 dp, bold + filled icon when selected), **account chip** at the bottom (avatar 40, name, handle, menu with Profile/Settings/Sign out) and a **Post pill** (233 × 52 dp, strong pill) replacing the FAB; content `Center(ConstrainedBox(maxWidth: 600))`; **side column 350 dp** shown only when the screen supplies one (cards = `AppSurface`, 16 dp gaps); when absent the content stays capped and centred.
- Nav destinations stay as today (Home, Notifications[flag], Profile) with **Settings moved to the drawer/chip menu**; if D3 = flag, the old layout stays selectable by `ui_shell` off.
**Acceptance.** Navigation tests at 360 / 700 / 1300 dp: correct nav widget per width; content max width 600 ± 1; side column 350 when provided and absent otherwise; FAB visibility table (D2); Post pill opens `/compose` and respects `canComposeAt`; account chip menu actions; golden light/dark at the three widths; no regression of redirects/deep links (`/u/:userId`, `/profile/:handle`).
**Risks.** Moving Settings out of the bar affects tests and muscle memory: update `docs/ui-catalog.md`; Flutter-web focus order (tab key) must be verified manually once (checklist in PR).

## W0-7 Test harness
**Files.** `app/test/support/` (new `geometry.dart`, `golden_harness.dart`), CI config only if goldens need a dedicated job (D5), `docs/runbooks/` note on regenerating goldens.
**Design.** `pumpThemed(tester, child, {brightness, size, textScale})`; `expectSize`/`expectGap` helpers around `getRect`; golden helper that writes to `test/goldens/<name>_<theme>_<w>.png`; goldens enabled only when `Platform.isLinux` or an env flag, so local Windows runs stay green; regeneration command documented (`flutter test --update-goldens` on Linux/CI artefact).
**Acceptance.** One sample golden + one geometry test pass on CI; matrix helper covers light/dark × 360/600/1200 × 1.0/1.3; docs updated; `make ci` time increase measured and reported (target < 60 s).

## W0-8 Appearance setting
**Files.** `app/app_widget.dart` (`themeMode`), new small `ThemeModeCubit` in `app/lib/app/` or `core/theme/`, persistence in the existing drift cache (`core/storage/app_database.dart` key-value or a prefs table — architect to confirm the cheapest existing store), a row in `features/settings/presentation/settings_screen.dart` ("Appearance": System / Light / Dark).
**Acceptance.** Cubit tests (default system, change, persisted across restart via fake store); widget test for the settings row; web `theme-color` follows the mode; no network.

## W0-9 Docs
Update `docs/ui-catalog.md` (new widgets, removed gradient button, new tokens), `docs/code-map.md`, this plan's statuses, an ADR note recording the colour decision (architect; "ADR-00NN UI colour system follows X palette", status Proposed → founder Accepts), cross-links from `docs/x_research/README.md`.

## W0-10 (conditional) `FEATURE_UI_SHELL`
Only if D3 = yes: Go config + flag constant + `enabled_features` entry, client gate in `MainShell`, Terraform env var default OFF (dev allowlist), per `flag-rollout`. Cost: 0 reads/writes (flag read already in `GetMe`).

---
## Worst-case Firestore reads/writes
W0 adds **0 RPCs, 0 reads, 0 writes** on every path (theme, tabs, drawer, scaffold are local). Drawer header reads the cached profile (`OnboardingBloc`); the counts come from the profile already loaded. W0-8 persists locally.
## Cost line
$0. No new package, no new GCP resource, no Hosting asset growth beyond a few KB of Dart.
## Definition of Done (per ticket)
`make ci` green (lint, vet, tests, `flutter analyze`/`test`) · widget/geometry/golden tests as listed · light + dark · text scale 1.3 · semantics reviewed · `reuse-first` grep checks pass · plan status updated in the same PR · `code-reviewer` verdict recorded · no push/PR unless the founder asks.
## Risks
Wide visual blast radius of W0-1/W0-2 (mitigated by goldens and grep tests) · golden churn across Flutter versions (pin, Linux-only goldens) · Settings leaving the bar (docs + tests) · blur performance on web (D4) · research numbers are estimates from screenshots (founder visual review at the end of W0 against `docs/x_research/screens/`).
## Exit criteria for W0
All W0-1…W0-9 merged (W0-10 if chosen); golden matrix green in light and dark at 360/600/1200 dp; no gradient, indigo or raw hex in `lib/`; founder reviews the Home, Notifications and Settings chrome at 360 and 1300 dp against the research screenshots and signs off before W1 starts.

## Implementation notes (2026-10-22, branch `feat/ui-w0-foundations`, not committed or pushed)
**Verified:** `flutter analyze` clean; `flutter test` 1316 passing (baseline 1118); `dart format` clean. A temporary render with real fonts (Roboto + Material icons) of Home at 400/900/1536 dp in light and dark was inspected by eye (images not kept).
**Deviations from the plan**
1. **D5 goldens:** pixel baselines cannot be generated from the Windows dev machine (CI runs Linux), so none are committed. `test/support/theme_harness.dart` ships the matrix helpers and an opt-in `expectGolden` (`RUN_GOLDENS=1`, baselines to be generated on CI). Every acceptance check is a geometry/colour/semantics assertion that runs everywhere, over theme x width x text scale.
2. **W0-10 done** (flag `ui_shell`, default off; roll out dev allowlist -> percent -> on per `flag-rollout`). **D1 default applied** (darker accent text token on light); **D2 applied** (`showComposeFabAt`); **D4 applied** (92 % alpha, no blur).
3. **Rail order follows X:** items, then the Post control, then the account chip at the bottom (the plan had the pill above the items).
4. **Count badges are accent blue** (`badgeTheme`), not the Material error colour.
5. **Light snackbar is an inverse (dark) toast**: the accent text cannot reach 4.5:1 on a light-grey surface.
6. **`AppSurface` and `AppEmptyView`** were left unchanged (the plan mentioned them for W1).
7. A real bug was caught by the new matrix tests: a title + subtitle top bar overflowed at text scale 1.3; the bar now scales its text (fixed bar) or grows (sliver).
8. A custom `AppBottomBar` replaced Material's `NavigationBar` because a "no tab selected" state (Settings) is impossible with the latter.
**Known gaps / for the founder:** Settings left the bottom bar (now in the drawer and the rail chip menu); the dark theme's secondary text is 4.37:1 or lower on raised surfaces, so text there must use `AppColors.secondaryOnRaised`; light-theme disabled-pill and selected-row colours were not observed on X (placeholders marked "to confirm"); the Home composer entry still shows its own Post button next to the new top bar (W1-5); no screen outside Home/Notifications adopted `AppTopBar` yet (W1); the generated `app_database.g.dart` changed (+395 lines, new table only).
