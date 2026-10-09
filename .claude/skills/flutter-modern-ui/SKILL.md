---
name: flutter-modern-ui
description: Target design and implementation rules for premium, modern X/Twitter-like Flutter UI (feed items, slivers, states, spacing, dark palette, accessibility). Use when building or polishing any Flutter screen or widget in app/.
---

# Flutter modern UI

This skill defines the **target design**. It does not authorize unrelated refactors or feature changes. Inspect existing screens, tokens, BLoCs, models, routing and tests first; apply incrementally, reuse existing components (`reuse-first`, `docs/ui-catalog.md`), keep diffs small, and leave screens that already comply alone. Keep BLoC. Never touch ranking/rank-cron code.

## State management boundary (BLoC only)
- All high-density components (feeds, action bars, profile views) are driven strictly by `BlocBuilder` or `BlocConsumer` over freezed bloc states. No Riverpod/`ConsumerWidget`/`AsyncNotifier`, and no state held in widgets beyond ephemeral UI (focus, animation).
- `BlocBuilder`/`BlocSelector` render; `BlocListener` (or `BlocConsumer.listener`) handles one-off effects (snackbar on failed like, navigation). Never navigate or show UI from `builder`.
- Widgets are dumb: they dispatch events and never call repositories or API clients.
  - Like/unlike: `context.read<TimelineBloc>().add(TimelineLike(postId))`; the bloc applies the optimistic update, calls the repository, and rolls back on error.
  - Repost/Retweet: dispatch the equivalent event (e.g. `TimelineRepost(postId)`) with the same optimistic/rollback contract.
  - Pagination: a `ScrollController`/`NotificationListener` near the end dispatches `TimelineLoadMore` (bloc guards concurrent loads, owns the cursor, and exposes a `hasReachedEnd`/loading-more state for the footer). Pull-to-refresh dispatches `TimelineLoad`/refresh.
  - Profile views follow the same pattern with their own bloc (`ProfileLoad`, `ProfileFollowToggled`).
- Per-item action bars use `BlocSelector` on that post's slice (like state + count) so a like rebuilds one item, not the list. Use existing event names/blocs in the repo rather than the examples above.

## Tokens
- Spacing: 8dp grid (4dp only for icon↔text micro-gaps). Use existing spacing tokens; add missing ones to `lib/core/theme/`, never inline magic numbers.
- Dark palette: background `0xFF0F1419` (reference); surfaces slightly lighter; primary text soft off-white, secondary muted; never pure black text on light, never pure `#000` surfaces. Borders: 1dp, low-contrast divider color. All text ≥ AA contrast. Light theme must remain working.
- Typography: from `Theme.of(context).textTheme`/tokens only; respect dynamic type (no fixed-height text boxes).
- Icons: one consistent outline set (the project's existing one); 20–24dp visuals inside 48dp targets.

## Feed item
- `Row`: avatar (left, fixed size, top-aligned) + `Expanded` `Column` for content. No `ListTile`.
- Metadata row: bold display name (ellipsis, `Flexible`), muted `@username`, `·` timestamp, optional overflow action (`IconButton`, right-aligned).
- Body text: `height: 1.35`, selectable/linkified as existing, 8dp gaps between meta, text, media, actions.
- Media: `ClipRRect` (12–16dp radius) + `AspectRatio` from server dimensions (fallback 16:9); thumbnails with `cacheWidth`; placeholder + error state; never overflow the column.
- Action bar: `Row(mainAxisAlignment: MainAxisAlignment.spaceBetween)` of equal-weight outline icon + count items (reply, repost, like, share); counts compact-formatted; active state changes color/fill; each has `Semantics` label and 48dp target.
- Extract one `const`-friendly item widget with a stable `ValueKey(post.id)`; no per-screen duplicates.

## Scrolling & navigation
- One scroll view per screen: `CustomScrollView` with `SliverAppBar` (floating/snap for feeds), `SliverList.builder` (or `SliverList.separated`) for items, `SliverToBoxAdapter`/`SliverFillRemaining` for headers and states, `SliverPadding` for gutters. Add `RefreshIndicator`/`CupertinoSliverRefreshControl` as appropriate.
- No nested scrolling views, no `shrinkWrap: true` lists inside scrollables.

## States (every list screen)
- Loading: skeleton/shimmer rows matching item layout (not a lone spinner), after cache-first render.
- Empty: icon/short title + one-line guidance + primary action if one exists.
- Error: friendly message + Retry; distinguish quota (`RESOURCE_EXHAUSTED`) and degraded mode; keep stale cached items visible with a banner.
- Pagination: trigger near end (cursor in BLoC, guard concurrent loads); footer shows small spinner, inline retry on failure, and nothing when exhausted.
- Map BLoC states to these via the shared state view widget if one exists; do not add parallel ones.

## Responsive
- `LayoutBuilder` breakpoints per `flutter-feature` (<600 bottom nav, 600–1200 rail, >1200 3-column). Constrain feed width (~600dp) and center on wide screens. Test narrow phone and large text scale without overflow.

## Avoid
- Arbitrary spacing/colors, stock Material-looking screens, decoration with no purpose (gradients, shadows, animations that carry no meaning).
- Rebuild churn: `const` constructors, `BlocSelector`/`buildWhen` for narrow state, no widget creation in `build` helpers that duplicate existing widgets, no `setState` of whole screens for local toggles.

## Accessibility
- `Semantics` labels on icon-only buttons and media (alt text when available), logical reading order, 48dp targets, AA contrast, visible focus for keyboard/web, honor reduced motion and text scale.

## Tests
- Widget tests for changed/new screens: loading, empty, error, data, pagination footer; text-scale 2.0 and narrow-width no-overflow; semantics for action bar. Golden for the feed item in dark mode where goldens already exist.
- Run `flutter analyze` and the relevant `flutter test` paths before declaring done; report what was actually run.
- Add new shared widgets to `docs/ui-catalog.md` in the same PR.
