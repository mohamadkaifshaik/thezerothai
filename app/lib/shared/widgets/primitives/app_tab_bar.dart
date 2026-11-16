import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import 'app_main_column.dart';

/// One tab of an [AppTabBar]: a text label with an optional leading icon.
@immutable
class AppTab {
  const AppTab({required this.label, this.icon, this.key});

  final String label;
  final IconData? icon;

  /// Optional identity for measuring or revealing a particular tab.
  final Key? key;
}

/// The text-only tab row of every screen with tabs (Home, Notifications,
/// Profile, History, Explore): a row at least 48dp tall (it grows with the
/// text scale), the active label w700 in the primary text colour, inactive
/// labels w600 in the secondary colour, and a 4 x 44dp `selectedIndicator`
/// bar centred under the active tab, flush with the 1px hairline below the
/// row. Selection therefore reads from weight and the bar, never colour
/// alone.
///
/// Two layouts, as on X:
/// - content-sized (default): labels keep their natural width with a
///   constant gap; the row scrolls horizontally when it overflows (the cut at
///   the edge is the scroll cue);
/// - [equalWidth]: tabs share the width equally (Notifications, Profile).
///
/// One tab is valid (Home shows only "Following"). It is not a `TabBar`: no
/// `TabController`, so it works inside pinned slivers. It announces each tab
/// as a selected / unselected button of one mutually exclusive group, and the
/// arrow keys move the selection while a tab has focus.
class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    this.equalWidth = false,
    this.autoWidth = false,
    this.trailing,
    this.fixedTrailing,
    this.semanticLabel,
  }) : assert(tabs.length > 0, 'a tab bar needs at least one tab'),
       assert(
         !autoWidth || (trailing == null && fixedTrailing == null),
         'autoWidth does not lay out trailing / fixedTrailing',
       );

  final List<AppTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// Share the width equally instead of sizing each tab to its label.
  final bool equalWidth;

  /// The one alignment rule of the tab bars under the main headers (Home,
  /// Explore, Notifications): see [tabsSpread]. The tabs spread evenly across
  /// the width when there are [kMaxSpreadTabs] or fewer and every label fits
  /// its share; otherwise the bar scrolls and starts at the leading edge.
  /// Overrides [equalWidth].
  final bool autoWidth;

  /// A widget after the last tab (the "manage tabs" button of Home).
  final Widget? trailing;

  /// A widget after the tabs that stays visible at the end of the row while
  /// the tabs scroll (Home's "+" for Manage pinned). Content-sized
  /// layout only.
  final Widget? fixedTrailing;

  /// Spoken name of the whole group.
  final String? semanticLabel;

  /// The painter of the hairline's bleed (tablet readable column).
  @visibleForTesting
  static const hairlineKey = ValueKey('app-tab-bar-hairline');

  /// The height of the bar at the ambient text scale: one title line plus
  /// [AppSpacing.md] above and below, never under the 48dp target. A pinned
  /// sliver header that holds the bar reserves exactly this.
  static double heightFor(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    // Scale the font size first, then apply the line height: a non-linear
    // text scaler (Android 14+) is not linear in the whole line.
    final line =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 15) *
        (style?.height ?? 1.33);
    return math.max(
      AppSpacing.minTapTarget,
      math.max(line, AppIconSize.md) + 2 * AppSpacing.md,
    );
  }

  void _move(int delta) {
    final next = (selectedIndex + delta).clamp(0, tabs.length - 1);
    if (next != selectedIndex) onChanged(next);
  }

  Widget _scrolling(List<Widget> items) {
    final scroller = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...items, ?trailing],
      ),
    );
    if (fixedTrailing == null) return scroller;
    return Row(
      children: [
        Expanded(child: scroller),
        fixedTrailing!,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!autoWidth) return _build(context, equal: equalWidth);
    return LayoutBuilder(
      builder: (context, box) =>
          _build(context, equal: tabsSpread(context, tabs, box.maxWidth)),
    );
  }

  Widget _build(BuildContext context, {required bool equal}) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final padding = narrow ? AppSize.tabPaddingNarrow : AppSize.tabPaddingWide;
    final items = [
      for (var i = 0; i < tabs.length; i++)
        _TabItem(
          key: tabs[i].key,
          tab: tabs[i],
          selected: i == selectedIndex,
          horizontalPadding: equal ? 0 : padding,
          onTap: () => onChanged(i),
        ),
    ];
    final Widget row = equal
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items) Expanded(child: item),
              ?trailing,
            ],
          )
        : _scrolling(items);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
        },
        // Inside an `AppMainColumn` on the tablet layout the hairline goes
        // on across the column's bleed, so it spans the pane; the tabs stay
        // in the column. Elsewhere the painter draws nothing.
        child: CustomPaint(
          key: hairlineKey,
          painter: _HairlineBleedPainter(
            bleed: AppMainColumnBleed.of(context),
            color: theme.colorScheme.outlineVariant,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            // Always the full width of its parent (a Column may give it a
            // loose width): the hairline spans the whole row.
            child: SizedBox(
              width: double.infinity,
              height: heightFor(context),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// Width of the selected-tab indicator (design: 44 x 4).
const double _indicatorWidth = 44;

class _TabItem extends StatelessWidget {
  const _TabItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.horizontalPadding,
    required this.onTap,
  });

  final AppTab tab;
  final bool selected;
  final double horizontalPadding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      color: selected ? colors.onSurface : colors.onSurfaceVariant,
    );
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tab.icon != null) ...[
          Icon(
            tab.icon,
            size: AppIconSize.md,
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: Text(
            tab.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: tab.label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        // The label is centred; the indicator is a fixed 4 x 44dp bar
        // centred at the bottom of the whole tab cell.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppSpacing.minTapTarget,
            minWidth: AppSpacing.minTapTarget,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: label,
              ),
              if (selected)
                Positioned(
                  bottom: 0,
                  child: Container(
                    key: const ValueKey('tab-indicator'),
                    width: _indicatorWidth,
                    height: AppSize.tabIndicator,
                    decoration: BoxDecoration(
                      color: context.appColors.selectedIndicator,
                      borderRadius: BorderRadius.circular(AppSize.tabIndicator),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two ends of the tab bar's 1dp bottom hairline that lie outside the
/// bar, [bleed] wide on each side (the `AppMainColumn`'s bleed). Nothing
/// when [bleed] is 0.
class _HairlineBleedPainter extends CustomPainter {
  const _HairlineBleedPainter({required this.bleed, required this.color});

  final double bleed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (bleed <= 0) return;
    final paint = Paint()..color = color;
    final top = size.height - 1;
    canvas
      ..drawRect(Rect.fromLTRB(-bleed, top, 0, size.height), paint)
      ..drawRect(
        Rect.fromLTRB(size.width, top, size.width + bleed, size.height),
        paint,
      );
  }

  @override
  bool shouldRepaint(_HairlineBleedPainter oldDelegate) =>
      bleed != oldDelegate.bleed || color != oldDelegate.color;
}

/// Most tabs that still spread across the width ([AppTabBar.autoWidth]).
const int kMaxSpreadTabs = 4;

/// The shared alignment rule of the tab bars under the main headers: spread
/// evenly across [width] with [kMaxSpreadTabs] or fewer tabs, scrollable and
/// start-aligned with more. Few tabs whose labels do not fit their share at
/// the ambient text scale (three labels at 360 dp, 2x) also scroll, so no
/// label is ever ellipsized.
bool tabsSpread(BuildContext context, List<AppTab> tabs, double width) {
  if (tabs.length > kMaxSpreadTabs) return false;
  final style = Theme.of(context).textTheme.titleSmall
      ?.copyWith(fontWeight: FontWeight.w700);
  final share = width / tabs.length;
  for (final tab in tabs) {
    final painter = TextPainter(
      text: TextSpan(text: tab.label, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final icon = tab.icon == null ? 0 : AppIconSize.md + AppSpacing.sm;
    final fits = painter.width + icon + AppSpacing.xs <= share;
    painter.dispose();
    if (!fits) return false;
  }
  return true;
}

/// Marks a sliver that spans the whole pane: a screen that wraps its slivers
/// in the reading column's padding (the Home feed) leaves these alone.
abstract interface class PaneWideSliver {}

/// The tab bar of a main screen as a pinned sliver: it stays at the top when
/// the floating top bar above it hides on scroll down. The bar sits in the
/// reading column ([ShellGeometry.readableInset]) and its hairline spans the
/// pane, as in the unpinned layout.
class AppPinnedTabBarSliver extends StatelessWidget implements PaneWideSliver {
  const AppPinnedTabBarSliver({super.key, required this.child});

  /// The [AppTabBar] (or a binding that builds one).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final extent = AppTabBar.heightFor(context);
    // The surface of the top bar above it, so there is no seam: 88 % with
    // `ui_shell` (the redesign), 92 % without.
    final color = Theme.of(context).colorScheme.surface.withValues(
      alpha: isFeatureEnabled(context, kFeatureUiShell) ? 0.88 : 0.92,
    );
    // The status bar: the tablet pane has no outer SafeArea, so with the top
    // bar scrolled away this header would pin under it.
    final topInset = MediaQuery.paddingOf(context).top;
    // Read here: a sliver layout builder cannot depend on inherited widgets.
    final column = ShellGeometry.readableMaxWidth(
      context,
      otherwise: AppBreakpoints.mobile,
    );
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final inset = math.max(0.0, (constraints.crossAxisExtent - column) / 2);
        // Where the header sits in the viewport: under the top bar while it is
        // shown (the bar already took the inset), at 0 once it floated away.
        final top =
            constraints.viewportMainAxisExtent -
            constraints.remainingPaintExtent;
        final reserve = math.max(0.0, topInset - top);
        return SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedBarDelegate(
            extent: extent + reserve,
            reserve: reserve,
            inset: inset,
            color: color,
            child: child,
          ),
        );
      },
    );
  }
}

class _PinnedBarDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedBarDelegate({
    required this.extent,
    required this.reserve,
    required this.inset,
    required this.color,
    required this.child,
  });

  final double extent;

  /// The top part of [extent] kept clear for the status bar.
  final double reserve;
  final double inset;
  final Color color;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  bool shouldRebuild(_PinnedBarDelegate old) =>
      extent != old.extent ||
      reserve != old.reserve ||
      inset != old.inset ||
      color != old.color ||
      !identical(child, old.child);

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(
        color: color,
        child: Padding(
          padding: EdgeInsets.only(left: inset, right: inset, top: reserve),
          child: AppMainColumnBleed(bleed: inset, child: child),
        ),
      );
}
