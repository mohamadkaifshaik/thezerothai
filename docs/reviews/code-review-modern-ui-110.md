# Code review: PR #110, modern dark UI redesign

Reviewer: code-reviewer (read-only), 2026-10-10. Scope: `git diff d9ff3d0..07752c4 -- app/` (12 non-generated files),
reviewed on `origin/main` after the merge. #110 was merged with no review; this is the retroactive review (readiness F4).

Checks run: `flutter analyze` clean; `flutter test test/shared test/features/{home,profile,timeline,posts} test/core`
295 passed; `dart format` dry run: two changed files unformatted (N1).

**Data and network behavior: unchanged.** No new RPC, repository call, cubit or Firestore read. `PostActionBar` is not
reachable in production (no caller passes `actions`); `PostMedia` does not render yet (the backend does not populate
`Post.media`). Removing `RepositoryProvider.value(postsGate)` is safe (nothing reads `PostsFeatureGate` from the tree).
State stays BLoC/Cubit only; navigation stays on go_router.

## Blocker
None.

## Major
- **M1. Snackbar action and close icon fail contrast in both themes (live today).** `app_theme.dart:215-222` sets
  `SnackBarThemeData.backgroundColor: surfaceContainerHighest` but leaves `actionTextColor` and `closeIconColor` at the
  Material 3 defaults, which assume an inverse-surface snackbar. Dark: about 2:1; light: about 1.3:1. The "Undo" in
  `managed_accounts_screen.dart:91` is nearly invisible (WCAG AA fail). Fix: `actionTextColor: colorScheme.primary`,
  `closeIconColor: colorScheme.onSurfaceVariant` (dark: `#4DA3F5` on `#29343F` is about 4.8:1) plus a widget test.
  **Must be fixed before the web build ships at 100%.**
- **M2. `PostMedia` falls back to the full-size image in lists** (`post_media.dart:111`,
  `thumbUrl.isNotEmpty ? thumbUrl : url`). `MediaRef.thumb_url` says lists must use the thumbnail, so this would load
  1600 px originals in the feed (GCS egress and Class B ops). Fix: show a placeholder in list contexts when `thumbUrl` is
  empty; add `PostMedia(useFullImage: true)` for the detail view; add a test. **Must be fixed before the media
  sub-feature flag (`kPostsSubFeatureMedia`) is turned on**; does not block web at 100% (dormant).

## Minor
- m1. New-posts pill offset is wrong on Profile (`timeline_feed_view.dart:207`, `kToolbarHeight + sm` assumes the Home
  `SliverAppBar`): add a `pillTopOffset` parameter.
- m2. Media decode size can blur cropped tiles (`post_media.dart:130`, only `memCacheWidth` with `BoxFit.cover`).
- m3. Changed `PostCard` branches have no tests (`actions == null`, media rendered, 320 dp at text scale 2.0).
- m4. Bottom nav is icon-only with no selection indicator (`app_theme.dart:186-187`): product call.

## Nit
- N1 two files not `dart format` clean (`profile_header.dart:115`, `composer_screen.dart:146-155`).
- N2 hardcoded sizes and spacing tokens used as sizes (profile avatar silently grows from 64 to 80 dp: confirm intended).
- N3 hoist `NumberFormat.compact()` in `post_action_bar.dart:122` to a `static final`.
- N4 test named "320dp" tests 280 dp; move `PostMedia` tests to their own file.
- N5 `app_widget.dart:36,48` still stores the unused `postsGate`; the startup-crash fix was bundled into a UI PR.
- N6 `PostActionBar` must be wired through a per-post `BlocSelector` (P5) before `actions` is passed.

## What checked out
Contrast: primary text 15.2:1, secondary 6.29:1 (4.87:1 on `surfaceContainerHigh`), accent 6.94:1. Loading uses a static
skeleton with a live-region label; empty and error states unchanged; one `CustomScrollView` with `SliverList.builder`,
no `shrinkWrap`; action bar has 48 dp targets and semantics labels; media decoded at display width; `docs/ui-catalog.md`
updated; light theme still built from `ColorScheme.fromSeed`.

VERDICT: REQUEST CHANGES
