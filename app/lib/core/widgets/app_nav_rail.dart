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

  /// The density for [availableHeight] (the rail's height without the top
  /// and bottom safe-area insets).
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
///   over a 12 sp label (a 56 dp item); the secondary ones, after a divider,
///   are icon-only 48 dp items with a tooltip. Above a text scale of
///   [maxLabelTextScale], and in [AppNavRailDensity.compact], the primary
///   items are icon-only too. Every item is announced with its full label
///   and its badge, as selected or not; the selected one has the indicator
///   pill, the filled glyph and the bold label (never colour alone).
/// - The destination with `onActivate` is More: it opens a menu instead of
///   navigating. In [AppNavRailDensity.folded] and below, the other
///   secondary destinations fold into it and a tap calls [onMoreFolded] with
///   their indexes; More is then shown whenever it has rows (its own,
///   [moreHasOwnRows], or folded ones) and is the selected item when the
///   selected destination is folded into it.
/// - [compose] follows the items; [account] is pinned to the bottom. The
///   brand mark tops the rail when at least [brandHeight] is available
///   (decorative: no semantics).
/// - Keyboard: one Tab stop (the selected item, else the first); the arrow
///   keys move between the items, the compose button and the account; Enter
///   or Space activates.
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

  /// R1 from this available height (the full stack is 677 dp).
  static const double fullHeight = 700;

  /// R2 from this available height (the folded stack is 485 dp).
  static const double foldedHeight = 500;

  /// The brand mark shows from this available height.
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

  /// The indicator pill behind the selected glyph.
  static const Size indicatorSize = Size(56, 32);

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
        child: child,
      );

  /// Moves the focus [by] stops along the ring (arrow keys).
  void _move(int by) {
    final current = _ring.indexWhere((s) => _stops[s]?.hasFocus ?? false);
    if (current < 0) return;
    final next = (current + by).clamp(0, _ring.length - 1);
    if (next == current) return;
    final wrapper = _stops[_ring[next]];
    final target = wrapper?.descendants
        .where((n) => n.canRequestFocus)
        .firstOrNull;
    if (target == null) return;
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
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _rail(context, constraints.maxHeight),
          ),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context, double available) {
    final density = AppNavRailDensity.of(available);
    final labels =
        density != AppNavRailDensity.compact &&
        MediaQuery.textScalerOf(context).scale(1) <=
            AppNavRail.maxLabelTextScale;
    final destinations = widget.destinations;
    final more = destinations.indexWhere((d) => d.onActivate != null);
    final folded = <int>[
      if (density != AppNavRailDensity.full)
        for (var i = 0; i < destinations.length; i++)
          if (i != more && destinations[i].group == AppNavGroup.secondary) i,
    ];
    final showMore = more >= 0 && (widget.moreHasOwnRows || folded.isNotEmpty);
    final primaries = <int>[
      for (var i = 0; i < destinations.length; i++)
        if (destinations[i].group == AppNavGroup.primary && i != more) i,
    ];
    final secondaries = <int>[
      for (var i = 0; i < destinations.length; i++)
        if (destinations[i].group == AppNavGroup.secondary &&
            !folded.contains(i) &&
            (i != more || showMore))
          i,
    ];
    var selected = widget.selectedIndex;
    if (selected != null && folded.contains(selected)) {
      selected = showMore ? more : null;
    }
    final visible = [...primaries, ...secondaries];
    final tabStop = selected != null && visible.contains(selected)
        ? selected
        : visible.firstOrNull;
    _ring = [
      ...visible,
      if (widget.compose != null) _Slot.compose,
      if (widget.account != null) _Slot.account,
    ];

    Widget item(int i, {required bool labelled}) {
      final destination = destinations[i];
      Widget child = _RailItem(
        destination: destination,
        selected: i == selected,
        labelled: labelled,
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

    final compose = widget.compose == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: AppNavRail.composeGap),
            child: _stop(_Slot.compose, tabStop: false, child: widget.compose!),
          );
    // R3 pins the compose button under the scrolling destinations.
    final pinCompose = density == AppNavRailDensity.compact;
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
            if (available >= AppNavRail.brandHeight) const _BrandMark(),
            // Scrolls only when the items do not fit (R3, or a large text
            // scale): never an overflow.
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  children: [
                    for (final i in primaries) item(i, labelled: labels),
                    if (primaries.isNotEmpty && secondaries.isNotEmpty)
                      const _GroupDivider(),
                    for (final i in secondaries) item(i, labelled: false),
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
                    tabStop: false,
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
/// label when [labelled].
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.labelled,
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final bool labelled;
  final VoidCallback onTap;

  /// Space on each side of an item inside the 80 dp rail: clear of the 1 dp
  /// hairline, and no more, because the label needs the width ("Notifications"
  /// is 77 dp at 12 sp w800 in DM Sans).
  static const double _inset = 1;

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
              // A long label shrinks to the item width; it never wraps or
              // ellipsizes.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  destination.label,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: selected
                        ? AppTypeTokens.weightDisplay
                        : AppTypeTokens.weightLabel,
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
          minHeight: labelled
              ? AppNavRail.labelledItemHeight
              : AppNavRail.itemHeight,
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
