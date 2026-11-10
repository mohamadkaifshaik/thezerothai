import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'app_nav_destination.dart';

export 'app_nav_destination.dart';

/// How much of the rail fits the available height (tablet plan section 2.1).
enum AppNavRailDensity {
  /// R1, at least [AppNavRail.fullHeight] available: every item shows.
  full,

  /// R2, [AppNavRail.foldedHeight] up to [AppNavRail.fullHeight]: the
  /// secondary items fold into More, which lists them above its own rows.
  folded,

  /// R3, below [AppNavRail.foldedHeight] (a phone in landscape): R2, and the
  /// primary items go icon-only; the destination region scrolls while the
  /// compose button and the account stay pinned.
  compact;

  /// The height floor for [availableHeight] (the rail's height without the
  /// top and bottom safe-area insets). The rail then steps down from it while
  /// its measured stack (two-line labels included) does not fit, so the
  /// density in use may be lower than this.
  static AppNavRailDensity of(double availableHeight) {
    if (availableHeight >= AppNavRail.fullHeight) return full;
    if (availableHeight >= AppNavRail.foldedHeight) return folded;
    return compact;
  }
}

/// The navigation rail of the tablet layout (600-1199 dp with `ui_shell` and
/// `ui_tablet` on; tablet plan section 2.1). [AppSize.railCompact] wide plus
/// the leading safe-area inset, pinned to the leading edge, on the rail
/// surface of the theme with a decorative 1 dp hairline on its trailing edge.
///
/// - The [destinations] keep their order. The primary ones show the icon
///   over a 12 sp label of at most two centred lines (an item of at least
///   56 dp that grows with the lines); the secondary ones, after a divider,
///   are icon-only 48 dp items with a tooltip. Above a text scale of
///   [maxLabelTextScale], when a label does not fit the item in two lines at
///   the user's text scale (a label is never shrunk or ellipsized), and in
///   [AppNavRailDensity.compact], the primary items are icon-only too (all
///   or none). Every item is announced with its full label and its badge, as selected or not; the selected one has the indicator
///   pill, the filled glyph and the bold label (never colour alone).
/// - The destination with `onActivate` is More: it opens a menu instead of
///   navigating. In [AppNavRailDensity.folded] and below, the other
///   secondary destinations fold into it and a tap calls [onMoreFolded] with
///   their indexes; More is then shown whenever it has rows (its own,
///   [moreHasOwnRows], or folded ones) and is the selected item when the
///   selected destination is folded into it.
/// - [compose] follows the items, and is pinned under them when they do not
///   all fit above it; [account] is pinned to the bottom. The brand mark
///   tops the rail when at least [brandHeight] is available and the measured
///   stack still fits under it (decorative: no semantics).
/// - Density: [AppNavRailDensity.of] gives the floor from the height; a
///   density whose measured stack does not fit steps down, so in R1 and R2
///   nothing overlaps or scrolls away.
/// - Keyboard: one Tab stop (the selected item, else the first); the arrow
///   keys move between the items, the compose button and the account, and
///   the Tab stop moves with them, so Tab and Shift+Tab leave the rail from
///   wherever the focus is; leaving resets it. Enter or Space activates.
class AppNavRail extends StatefulWidget {
  const AppNavRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.compose,
    this.account,
    this.moreHasOwnRows = true,
    this.onMoreFolded,
  });

  final List<AppNavDestination> destinations;

  /// The selected destination, or null when none is (Settings).
  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// The compose button (already labelled, with its tooltip); null hides it.
  final Widget? compose;

  /// The account avatar that opens the account menu; null hides it.
  final Widget? account;

  /// Whether More has rows of its own (shell entries, Articles). Without
  /// them More shows only when secondary destinations are folded into it.
  final bool moreHasOwnRows;

  /// Opens More with the [folded] destinations (indexes into
  /// [destinations]) listed first. Null: More always calls its `onActivate`.
  final void Function(BuildContext anchor, List<int> folded)? onMoreFolded;

  /// R1 from this available height (the full stack is 677 dp with one-line
  /// labels; it also has to fit as measured).
  static const double fullHeight = 700;

  /// R2 from this available height (the folded stack is 485 dp with
  /// one-line labels; it also has to fit as measured).
  static const double foldedHeight = 500;

  /// The brand mark shows from this available height (when the measured
  /// stack also fits under it).
  static const double brandHeight = 900;

  /// Above this text scale the primary items are icon-only (tooltips and
  /// semantics keep the label).
  static const double maxLabelTextScale = 1.3;

  /// Item heights: a primary item with its label, and an icon-only item.
  static const double labelledItemHeight = 56;
  static const double itemHeight = AppSpacing.minTapTarget;

  /// The group divider: 8 + 1 + 8 dp.
  static const double dividerHeight = 17;

  /// Space above the first item, above the compose button, and the slot of
  /// the account avatar.
  static const double topGap = AppSpacing.sm;
  static const double composeGap = AppSpacing.md;
  static const double accountSlot = 64;

  /// The compose button's slot: the gap and the 52 dp button.
  static const double composeSlot = composeGap + AppSize.railPostHeight;

  /// The indicator pill behind the selected glyph.
  static const double indicatorWidth = 56;
  static const double indicatorHeight = 32;
  static const Size indicatorSize = Size(indicatorWidth, indicatorHeight);

  @override
  State<AppNavRail> createState() => _AppNavRailState();
}

/// The non-destination stops of the keyboard ring.
enum _Slot { compose, account }

class _AppNavRailState extends State<AppNavRail> {
  // One wrapper node per keyboard stop (a destination index or a [_Slot]).
  // A wrapper never takes focus itself; it holds the stop's focusable
  // descendant out of Tab traversal unless the stop is the Tab stop.
  final _stops = <Object, FocusNode>{};
  final _anchorKeys = <int, GlobalKey>{};

  // The keyboard ring of the last build, in visual order.
  List<Object> _ring = const [];

  // The stop the arrow keys moved to: the Tab stop while the focus stays in
  // the rail (roving tabindex), so Tab and Shift+Tab leave the rail from
  // it. Null: the selected item (else the first) is the Tab stop.
  Object? _roving;

  @override
  void dispose() {
    for (final node in _stops.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _stopNode(Object stop) => _stops.putIfAbsent(
    stop,
    () => FocusNode(
      debugLabel: 'AppNavRail $stop',
      canRequestFocus: false,
      skipTraversal: true,
    ),
  );

  Widget _stop(Object stop, {required bool tabStop, required Widget child}) =>
      Focus(
        focusNode: _stopNode(stop),
        canRequestFocus: false,
        skipTraversal: true,
        descendantsAreTraversable: tabStop,
        // Whatever brings the focus here (the arrows, or a closing menu that
        // gives it back to the stop that opened it: More, the account chip)
        // makes this stop the Tab stop.
        // Only the state here: the focus manager is mid-update, so the
        // wrappers take the new traversability from the next build.
        onFocusChange: (focused) {
          if (focused && _roving != stop) setState(() => _roving = stop);
        },
        child: child,
      );

  /// Makes [stop] the Tab stop: now (a Tab right after an arrow key, before
  /// the next frame, must already leave from it) and in the next build.
  void _rove(Object stop) {
    for (final MapEntry(key: s, value: node) in _stops.entries) {
      node.descendantsAreTraversable = s == stop;
    }
    if (_roving != stop) setState(() => _roving = stop);
  }

  /// Moves the focus [by] stops along the ring (arrow keys).
  void _move(int by) {
    final current = _ring.indexWhere((s) => _stops[s]?.hasFocus ?? false);
    if (current < 0) return;
    final next = (current + by).clamp(0, _ring.length - 1);
    if (next == current) return;
    final stop = _ring[next];
    final wrapper = _stops[stop];
    final target = wrapper?.descendants
        .where((n) => n.canRequestFocus)
        .firstOrNull;
    if (target == null) return;
    _rove(stop);
    target.requestFocus();
    final context = target.context;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: Duration.zero,
        alignmentPolicy: by > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  }

  void _activate(int index, List<int> folded) {
    final destination = widget.destinations[index];
    final activate = destination.onActivate;
    if (activate == null) {
      widget.onDestinationSelected(index);
      return;
    }
    final anchor = _anchorKeys[index]?.currentContext;
    if (anchor == null) return;
    final onFolded = widget.onMoreFolded;
    if (folded.isNotEmpty && onFolded != null) {
      onFolded(anchor, folded);
    } else {
      activate(anchor);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final padding = media.padding;
    final ltr = Directionality.of(context) == TextDirection.ltr;
    final leading = ltr ? padding.left : padding.right;
    final theme = Theme.of(context);
    final colors = context.appColors;
    // A Material, not a coloured box: the items' ink (hover, focus, press)
    // paints on it.
    return Material(
      color:
          theme.navigationRailTheme.backgroundColor ??
          theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Decorative only (never a component boundary).
          border: BorderDirectional(end: BorderSide(color: colors.hairline)),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leading,
            top: padding.top,
            bottom: padding.bottom,
          ),
          // Leaving the rail gives the Tab stop back to the selected item.
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) {
              if (!focused && _roving != null) setState(() => _roving = null);
            },
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _rail(context, constraints.maxHeight),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context, double available) {
    final destinations = widget.destinations;
    final more = destinations.indexWhere((d) => d.onActivate != null);
    final primaries = <int>[
      for (var i = 0; i < destinations.length; i++)
        if (destinations[i].group == AppNavGroup.primary && i != more) i,
    ];
    // Labels only while every one fits the item in at most two lines at the
    // user's text scale (never shrunk); otherwise every item is icon-only.
    // All or nothing, so the rail stays uniform.
    final layouts = _RailItem.labelLayouts(context, [
      for (final i in primaries) destinations[i].label,
    ]);

    // The arrangement at one density: what folds, what shows, how tall.
    _RailPlan plan(AppNavRailDensity density) {
      // Secondaries fold only into an existing More.
      final folded = <int>[
        if (density != AppNavRailDensity.full && more >= 0)
          for (var i = 0; i < destinations.length; i++)
            if (i != more && destinations[i].group == AppNavGroup.secondary) i,
      ];
      final showMore =
          more >= 0 && (widget.moreHasOwnRows || folded.isNotEmpty);
      final secondaries = <int>[
        for (var i = 0; i < destinations.length; i++)
          if (destinations[i].group == AppNavGroup.secondary &&
              !folded.contains(i) &&
              (i != more || showMore))
            i,
      ];
      final labelled = density != AppNavRailDensity.compact ? layouts : null;
      final items =
          (labelled == null
              ? primaries.length * AppNavRail.itemHeight
              : labelled.fold<double>(0, (sum, l) => sum + l.itemHeight)) +
          (primaries.isNotEmpty && secondaries.isNotEmpty
              ? AppNavRail.dividerHeight
              : 0) +
          secondaries.length * AppNavRail.itemHeight;
      return _RailPlan(
        density: density,
        folded: folded,
        showMore: showMore,
        secondaries: secondaries,
        labels: labelled,
        itemsHeight: items,
        stackHeight:
            AppNavRail.topGap +
            items +
            (widget.compose != null ? AppNavRail.composeSlot : 0) +
            (widget.account != null ? AppNavRail.accountSlot : 0),
      );
    }

    // The plan's height floors (700 / 500), then the measured stack: a
    // density whose items (two-line labels included) do not fit steps down,
    // so in R1 and R2 nothing overlaps or scrolls away.
    var current = plan(AppNavRailDensity.of(available));
    while (current.density != AppNavRailDensity.compact &&
        current.stackHeight > available) {
      current = plan(AppNavRailDensity.values[current.density.index + 1]);
    }
    final density = current.density;
    final folded = current.folded;
    final showMore = current.showMore;
    final secondaries = current.secondaries;
    final labelLayouts = current.labels;

    var selected = widget.selectedIndex;
    if (selected != null && folded.contains(selected)) {
      selected = showMore ? more : null;
    }
    final visible = [...primaries, ...secondaries];
    _ring = [
      ...visible,
      if (widget.compose != null) _Slot.compose,
      if (widget.account != null) _Slot.account,
    ];
    final roving = _roving;
    final Object? tabStop = roving != null && _ring.contains(roving)
        ? roving
        : selected != null && visible.contains(selected)
        ? selected
        : visible.firstOrNull;

    Widget item(int i, {_LabelLayout? label}) {
      final destination = destinations[i];
      Widget child = _RailItem(
        destination: destination,
        selected: i == selected,
        label: label,
        onTap: () => _activate(i, folded),
      );
      if (destination.onActivate != null) {
        child = KeyedSubtree(
          key: _anchorKeys.putIfAbsent(i, GlobalKey.new),
          child: child,
        );
      }
      return _stop(i, tabStop: i == tabStop, child: child);
    }

    // The brand mark only when the whole measured stack still fits under it.
    final brand =
        available >= AppNavRail.brandHeight &&
        current.stackHeight + _BrandMark.slot <= available;
    // The compose button follows the items while they all fit above it;
    // otherwise (R3) it is pinned under the scrolling items, never scrolled
    // out of view.
    final region =
        available -
        AppNavRail.topGap -
        (brand ? _BrandMark.slot : 0) -
        (widget.account != null ? AppNavRail.accountSlot : 0);
    final pinCompose =
        density == AppNavRailDensity.compact ||
        current.itemsHeight + AppNavRail.composeSlot > region;

    final compose = widget.compose == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: AppNavRail.composeGap),
            child: _stop(
              _Slot.compose,
              tabStop: tabStop == _Slot.compose,
              child: widget.compose!,
            ),
          );
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
        ),
      },
      child: Actions(
        actions: {DirectionalFocusIntent: _RovingFocusAction(_move)},
        child: Column(
          children: [
            const SizedBox(height: AppNavRail.topGap),
            if (brand) const _BrandMark(),
            // Scrolls only when the items do not fit (R3, or a large text
            // scale): never an overflow.
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  children: [
                    for (final (n, i) in primaries.indexed)
                      item(i, label: labelLayouts?[n]),
                    if (primaries.isNotEmpty && secondaries.isNotEmpty)
                      const _GroupDivider(),
                    for (final i in secondaries) item(i),
                    if (!pinCompose) ?compose,
                  ],
                ),
              ),
            ),
            if (pinCompose) ?compose,
            if (widget.account != null)
              SizedBox(
                height: AppNavRail.accountSlot,
                child: Center(
                  child: _stop(
                    _Slot.account,
                    tabStop: tabStop == _Slot.account,
                    child: widget.account!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The rail's arrangement at one density (see `_rail`).
class _RailPlan {
  const _RailPlan({
    required this.density,
    required this.folded,
    required this.showMore,
    required this.secondaries,
    required this.labels,
    required this.itemsHeight,
    required this.stackHeight,
  });

  final AppNavRailDensity density;
  final List<int> folded;
  final bool showMore;
  final List<int> secondaries;

  /// One per primary item, in order; null when they are icon-only.
  final List<_LabelLayout>? labels;

  /// The destination items and the divider.
  final double itemsHeight;

  /// Everything: top gap, items, compose slot and account slot.
  final double stackHeight;
}

/// How one label is laid out: the width its lines wrap at and the height
/// the item reserves for them (measured in the selected, widest weight, so
/// the item does not change height when the selection moves).
class _LabelLayout {
  const _LabelLayout({required this.width, required this.height});

  final double width;
  final double height;

  /// The item: the label lines under the pill, at least 56 dp.
  double get itemHeight => math.max(
    AppNavRail.labelledItemHeight,
    _RailItem.labelledChrome + height,
  );
}

/// Up and Down move along the rail's ring (roving focus). The stock
/// directional traversal cannot: it skips the nodes held out of Tab
/// traversal, which is every item but the Tab stop. Left and Right keep the
/// stock behaviour (to the pane beside the rail).
class _RovingFocusAction extends Action<DirectionalFocusIntent> {
  _RovingFocusAction(this.move);

  final void Function(int by) move;

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    switch (intent.direction) {
      case TraversalDirection.up:
        move(-1);
      case TraversalDirection.down:
        move(1);
      case TraversalDirection.left:
      case TraversalDirection.right:
        primaryFocus?.focusInDirection(intent.direction);
    }
    return null;
  }
}

/// One destination: the indicator pill with the glyph, and under it the
/// label laid out by [label] (none: icon-only, with a tooltip).
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.label,
  });

  final AppNavDestination destination;
  final bool selected;
  final _LabelLayout? label;
  final VoidCallback onTap;

  bool get labelled => label != null;

  /// A label wraps to at most this many lines (owner decision 2026-11-10).
  static const int maxLabelLines = 2;

  /// Space on each side of an item inside the 80 dp rail: clear of the 1 dp
  /// hairline, and no more, because the label needs the width ("Notifications"
  /// is 77 dp at 12 sp w800 in DM Sans).
  static const double _inset = 1;

  /// The widest a label may be: the item's width.
  static const double _labelMax = AppSize.railCompact - 2 * _inset;

  /// A labelled item without its label line: the 2 dp padding on each side,
  /// the 32 dp pill and the 4 dp gap.
  static const double labelledChrome =
      AppSpacing.xs + AppNavRail.indicatorHeight + AppSpacing.xs;

  static TextStyle? _labelStyle(ThemeData theme, {required bool selected}) =>
      theme.textTheme.labelSmall?.copyWith(
        fontWeight: selected
            ? AppTypeTokens.weightDisplay
            : AppTypeTokens.weightLabel,
      );

  /// How each of [labels] is laid out, when every one fits the item in at
  /// most [maxLabelLines] lines at the text scale of [context] (measured in
  /// the selected, widest weight); null when the scale is above
  /// [AppNavRail.maxLabelTextScale] or one does not fit. A label is never
  /// shrunk or ellipsized.
  ///
  /// A label wraps at its spaces at the item's width. A single word wider
  /// than the item ("Notifications" from about 1.01) can only break inside
  /// the word: it is laid out at the narrowest width that still keeps it to
  /// two lines, so the halves are balanced ("Notifi / cations", not
  /// "Notification / s"); the text itself is unchanged.
  static List<_LabelLayout>? labelLayouts(
    BuildContext context,
    List<String> labels,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler.scale(1) > AppNavRail.maxLabelTextScale) return null;
    final style = _labelStyle(Theme.of(context), selected: true);
    final direction = Directionality.of(context);
    TextPainter laidOut(String text, double width, {int? maxLines}) =>
        TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: direction,
          textAlign: TextAlign.center,
          textScaler: scaler,
          maxLines: maxLines,
        )..layout(maxWidth: width);

    final layouts = <_LabelLayout>[];
    for (final label in labels) {
      final full = laidOut(label, _labelMax, maxLines: maxLabelLines);
      final fits = !full.didExceedMaxLines;
      final lines = full.computeLineMetrics().length;
      var height = full.height;
      full.dispose();
      if (!fits) return null;
      var width = _labelMax;
      final overlong = label.split(RegExp(r'\s+')).any((word) {
        final painter = laidOut(word, double.infinity);
        final wide = painter.width > _labelMax;
        painter.dispose();
        return wide;
      });
      if (lines > 1 && overlong) {
        var lo = 0.0;
        var hi = _labelMax;
        for (var step = 0; step < 10; step++) {
          final mid = (lo + hi) / 2;
          final painter = laidOut(label, mid, maxLines: maxLabelLines);
          final ok = !painter.didExceedMaxLines;
          painter.dispose();
          if (ok) {
            hi = mid;
          } else {
            lo = mid;
          }
        }
        width = math.min(hi.ceilToDouble(), _labelMax);
        final balanced = laidOut(label, width, maxLines: maxLabelLines);
        height = balanced.height;
        balanced.dispose();
      }
      layouts.add(_LabelLayout(width: width, height: height));
    }
    return layouts;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    // The glyph sits on the pill: onPrimary is the pill's ink in both themes
    // (selectedIndicator is the primary).
    final glyph = IconTheme(
      data: IconThemeData(
        color: selected ? theme.colorScheme.onPrimary : colors.text2,
        size: AppIconSize.lg,
      ),
      child: destination.iconWidget(
        selected ? destination.selectedIcon : destination.icon,
      ),
    );
    final pill = Container(
      width: AppNavRail.indicatorSize.width,
      height: AppNavRail.indicatorSize.height,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: selected ? colors.selectedIndicator : null,
      ),
      child: glyph,
    );
    final Widget content = labelled
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              pill,
              const SizedBox(height: AppSpacing.xs),
              // Shown only when it fits ([labelLayouts]): at the user's
              // scale, never shrunk, in at most two centred lines.
              SizedBox(
                width: label!.width,
                child: Text(
                  destination.label,
                  textAlign: TextAlign.center,
                  maxLines: maxLabelLines,
                  style: _labelStyle(theme, selected: selected)?.copyWith(
                    color: selected
                        ? theme.colorScheme.onSurface
                        : colors.text2,
                  ),
                ),
              ),
            ],
          )
        : Center(child: pill);
    final cell = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: double.infinity,
          minHeight: label?.itemHeight ?? AppNavRail.itemHeight,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs / 2),
            child: content,
          ),
        ),
      ),
    );
    // The item excludes its children from semantics, so the label and the
    // badge are spoken here: "Messages, 3 unread conversations".
    final name = destination.semanticsLabel ?? destination.label;
    final badge = destination.badgeLabel.isEmpty
        ? null
        : (destination.badgeSemanticLabel ?? destination.badgeLabel);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: destination.onActivate == null,
      label: badge == null ? name : '$name, $badge',
      onTap: onTap,
      excludeSemantics: true,
      child: labelled
          ? cell
          : Tooltip(
              message: destination.tooltipText,
              excludeFromSemantics: true,
              child: cell,
            ),
    );
  }
}

/// The hairline between the primary and the secondary items.
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: AppNavRail.dividerHeight,
    thickness: 1,
    indent: AppSpacing.md,
    endIndent: AppSpacing.md,
    color: context.appColors.hairline,
  );
}

/// The app icon at the top of a tall rail. Decorative: the rail's items name
/// every destination, so it is left out of the semantics tree.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  static const double _size = AppSize.avatarMd;

  /// The mark and the space under it.
  static const double slot = _size + AppSpacing.sm;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Image.asset(
          'assets/branding/icon.png',
          width: _size,
          height: _size,
          errorBuilder: (context, error, stack) =>
              const SizedBox.square(dimension: _size),
        ),
      ),
    ),
  );
}
