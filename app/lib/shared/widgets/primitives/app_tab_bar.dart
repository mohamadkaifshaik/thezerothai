import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
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
///
/// [style] picks the Dz artboards' looks (see [AppTabBarStyle]): a sliding
/// underline that moves and resizes from tab to tab, following [controller]
/// (a swipe between pages included) when one is given, else easing to a
/// new [selectedIndex]; it jumps under reduce-motion.
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
    this.style = AppTabBarStyle.classic,
    this.controller,
  }) : assert(tabs.length > 0, 'a tab bar needs at least one tab'),
       assert(
         !autoWidth || (trailing == null && fixedTrailing == null),
         'autoWidth does not lay out trailing / fixedTrailing',
       );

  final List<AppTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// The look; see [AppTabBarStyle]. [equalWidth] and [autoWidth] apply to
  /// [AppTabBarStyle.classic] only (each Dz style fixes its own layout).
  final AppTabBarStyle style;

  /// Drives the Dz underline while its pages animate or are swiped
  /// (`controller.animation`); null eases it on [selectedIndex] changes.
  /// Ignored by [AppTabBarStyle.classic].
  final TabController? controller;

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
  static double heightFor(
    BuildContext context, {
    AppTabBarStyle style = AppTabBarStyle.classic,
  }) {
    if (style != AppTabBarStyle.classic) {
      return _DzTabSpec.of(style).heightFor(context);
    }
    return _classicHeight(context);
  }

  static double _classicHeight(BuildContext context) {
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
    if (style != AppTabBarStyle.classic) {
      return _DzTabBar(
        spec: _DzTabSpec.of(style),
        tabs: tabs,
        selectedIndex: selectedIndex,
        onChanged: onChanged,
        controller: controller,
        semanticLabel: semanticLabel,
        onMove: _move,
      );
    }
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
              height: _classicHeight(context),
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

/// The looks of an [AppTabBar]. Every Dz look has 15/700 selected and 15/600
/// idle labels at the bottom of the row, a gap, then the underline in the
/// accent text colour (tealText on light) with rounded top corners, and the
/// 1 dp hairline under the row (CSS content-box: under the row's height, not
/// inside it).
///
/// * [classic]: the bar every screen has today (unchanged).
/// * [dzFeed]: DzHome and DzMedia: content-sized tabs (12 dp side padding)
///   in a 46 dp row padded 8 dp at each end, a 3 dp underline as wide as the
///   label, 10 dp under it. Scrolls when it overflows.
/// * [dzProfile]: DzProfile: equal tabs (`flex: 1`) in a 50 dp row padded
///   8 dp at each end, a fixed 3 x 44 underline 12 dp under the label.
/// * [zExplore]: ZExplore: content-sized tabs (12 dp side padding), 46 dp, a
///   4 dp underline as wide as the label (radius 4), 10 dp under it.
/// * [zSearch]: ZSearch: [zExplore] with 14 dp side padding.
/// * [zNotifications]: ZNotifications: equal tabs in a 46 dp row padded 8 dp
///   at each end, a fixed 4 x 56 underline (radius 4), 10 dp under the label.
enum AppTabBarStyle {
  classic,
  dzFeed,
  dzProfile,
  zExplore,
  zSearch,
  zNotifications,
}

/// The numbers of one Dz look (artboard px = dp).
class _DzTabSpec {
  const _DzTabSpec({
    required this.height,
    required this.barHeight,
    required this.gap,
    this.barWidth,
    this.equal = false,
    this.tabPadding = 0,
    this.rowPadding = 0,
  });

  static _DzTabSpec of(AppTabBarStyle style) => switch (style) {
    AppTabBarStyle.dzFeed => const _DzTabSpec(
      height: AppSize.dzTabRow,
      barHeight: 3,
      gap: 10,
      tabPadding: 12,
      rowPadding: 8,
    ),
    AppTabBarStyle.dzProfile => const _DzTabSpec(
      height: AppSize.dzTabRowProfile,
      barHeight: 3,
      barWidth: 44,
      gap: 12,
      equal: true,
      rowPadding: 8,
    ),
    AppTabBarStyle.zExplore => const _DzTabSpec(
      height: AppSize.dzTabRow,
      barHeight: 4,
      gap: 10,
      tabPadding: 12,
    ),
    AppTabBarStyle.zSearch => const _DzTabSpec(
      height: AppSize.dzTabRow,
      barHeight: 4,
      gap: 10,
      tabPadding: 14,
    ),
    AppTabBarStyle.zNotifications => const _DzTabSpec(
      height: AppSize.dzTabRow,
      barHeight: 4,
      barWidth: 56,
      gap: 10,
      equal: true,
      rowPadding: 8,
    ),
    AppTabBarStyle.classic => throw ArgumentError.value(style),
  };

  /// The row's height (the hairline is under it).
  final double height;

  /// Underline thickness; its top corners are rounded by the same amount.
  final double barHeight;

  /// Fixed underline width; null is the label's width.
  final double? barWidth;

  /// Between the label and the underline.
  final double gap;

  /// Tabs share the width (`flex: 1`) instead of sizing to their labels.
  final bool equal;

  /// Side padding of a content-sized tab.
  final double tabPadding;

  /// Padding at both ends of the row.
  final double rowPadding;

  /// The row grows when a large text scale needs it, plus the hairline.
  double heightFor(BuildContext context) {
    final label = AppTextStyles.dzTab(Theme.of(context), selected: true);
    final line =
        MediaQuery.textScalerOf(context).scale(label.fontSize ?? 15) *
        (label.height ?? 1.25);
    final row = math.max(height, (line + gap + barHeight + AppSpacing.sm));
    return row.ceilToDouble() + AppSize.dzHeaderBorder;
  }
}

class _DzTabBar extends StatefulWidget {
  const _DzTabBar({
    required this.spec,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    required this.controller,
    required this.semanticLabel,
    required this.onMove,
  });

  final _DzTabSpec spec;
  final List<AppTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final TabController? controller;
  final String? semanticLabel;
  final ValueChanged<int> onMove;

  @override
  State<_DzTabBar> createState() => _DzTabBarState();
}

class _DzTabBarState extends State<_DzTabBar>
    with SingleTickerProviderStateMixin {
  /// How long the underline takes to slide without a controller.
  static const Duration _slide = Duration(milliseconds: 250);

  final GlobalKey _rowKey = GlobalKey();
  late List<GlobalKey> _labelKeys;
  late List<GlobalKey> _cellKeys;

  /// The underline's position as a fractional tab index when there is no
  /// controller.
  late final AnimationController _own;

  @override
  void initState() {
    super.initState();
    _own = AnimationController.unbounded(
      vsync: this,
      value: widget.selectedIndex.toDouble(),
    );
    _keys();
  }

  void _keys() {
    _labelKeys = [for (final _ in widget.tabs) GlobalKey()];
    _cellKeys = [for (final _ in widget.tabs) GlobalKey()];
  }

  @override
  void didUpdateWidget(_DzTabBar old) {
    super.didUpdateWidget(old);
    if (old.tabs.length != widget.tabs.length) _keys();
    if (widget.controller == null &&
        old.selectedIndex != widget.selectedIndex) {
      final target = widget.selectedIndex.toDouble();
      if (MediaQuery.disableAnimationsOf(context)) {
        _own.value = target;
      } else {
        _own.animateTo(target, duration: _slide, curve: Curves.easeOutCubic);
      }
    }
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final Animation<double> position = widget.controller?.animation ?? _own;
    final total = spec.heightFor(context);
    Widget cell(int i) {
      final tab = widget.tabs[i];
      final selected = i == widget.selectedIndex;
      final color = selected ? colors.onSurface : colors.onSurfaceVariant;
      final label = Row(
        key: _labelKeys[i],
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tab.icon != null) ...[
            Icon(tab.icon, size: AppIconSize.md, color: color),
            const SizedBox(width: AppSpacing.sm),
          ],
          Flexible(
            child: Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.dzTab(
                theme,
                selected: selected,
              ).copyWith(color: color),
            ),
          ),
        ],
      );
      return Semantics(
        key: tab.key,
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: tab.label,
        onTap: () => widget.onChanged(i),
        excludeSemantics: true,
        child: InkWell(
          key: _cellKeys[i],
          onTap: () => widget.onChanged(i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: spec.tabPadding),
            // The label sits on the underline's gap at the bottom of the
            // row (`flex-direction: column; justify-content: flex-end`).
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                label,
                SizedBox(height: spec.gap + spec.barHeight),
              ],
            ),
          ),
        ),
      );
    }

    final cells = [for (var i = 0; i < widget.tabs.length; i++) cell(i)];
    final indicator = _DzUnderlinePainter(
      position: position,
      reduce: reduce,
      spec: spec,
      color: context.appColors.accentText,
      rowKey: _rowKey,
      labelKeys: _labelKeys,
      cellKeys: _cellKeys,
    );
    Widget row = CustomPaint(
      key: _rowKey,
      foregroundPainter: indicator,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: spec.equal ? MainAxisSize.max : MainAxisSize.min,
        children: [for (final c in cells) spec.equal ? Expanded(child: c) : c],
      ),
    );
    if (!spec.equal) {
      row = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: spec.rowPadding),
        child: row,
      );
    } else {
      row = Padding(
        padding: EdgeInsets.symmetric(horizontal: spec.rowPadding),
        child: row,
      );
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              widget.onMove(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              widget.onMove(1),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: SizedBox(
            width: double.infinity,
            height: total,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSize.dzHeaderBorder),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Dz underline: between the tabs on each side of the fractional
/// [position], its left edge and width interpolated, so it slides and
/// resizes as the pages move. Repaints on [position] only (no rebuild).
class _DzUnderlinePainter extends CustomPainter {
  _DzUnderlinePainter({
    required this.position,
    required this.reduce,
    required this.spec,
    required this.color,
    required this.rowKey,
    required this.labelKeys,
    required this.cellKeys,
  }) : super(repaint: position);

  final Animation<double> position;
  final bool reduce;
  final _DzTabSpec spec;
  final Color color;
  final GlobalKey rowKey;
  final List<GlobalKey> labelKeys;
  final List<GlobalKey> cellKeys;

  /// The underline's span (left, width) under tab [i], in the row's
  /// coordinates; null before layout.
  (double, double)? _span(int i, RenderBox row) {
    final key = spec.barWidth == null ? labelKeys[i] : cellKeys[i];
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final left = box.localToGlobal(Offset.zero, ancestor: row).dx;
    final width = spec.barWidth;
    if (width == null) return (left, box.size.width);
    return (left + (box.size.width - width) / 2, width);
  }

  /// The rect for a fractional [at] (exposed for tests through paint).
  Rect? rectAt(double at, RenderBox row, Size size) {
    final last = labelKeys.length - 1;
    final t = reduce ? at.roundToDouble() : at;
    final clamped = t.clamp(0.0, last.toDouble());
    final from = clamped.floor();
    final to = math.min(from + 1, last);
    final a = _span(from, row);
    final b = _span(to, row);
    if (a == null || b == null) return null;
    final f = clamped - from;
    final left = a.$1 + (b.$1 - a.$1) * f;
    final width = a.$2 + (b.$2 - a.$2) * f;
    return Rect.fromLTWH(
      left,
      size.height - spec.barHeight,
      width,
      spec.barHeight,
    );
  }

  /// The rect painted last (row coordinates), for [debugDzUnderlineRect].
  Rect? lastRect;

  @override
  void paint(Canvas canvas, Size size) {
    final row = rowKey.currentContext?.findRenderObject();
    if (row is! RenderBox || !row.hasSize) return;
    final rect = rectAt(position.value, row, size);
    lastRect = rect;
    if (rect == null) return;
    final radius = Radius.circular(spec.barHeight);
    canvas.drawRRect(
      RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DzUnderlinePainter old) =>
      old.position != position ||
      old.reduce != reduce ||
      old.color != color ||
      !identical(old.spec, spec) ||
      !identical(old.labelKeys, labelKeys);
}

/// The Dz underline last painted by the [AppTabBar] whose row paints with
/// [renderObject] (a `RenderCustomPaint`), in global coordinates; null for
/// any other render object or before the first paint.
@visibleForTesting
Rect? debugDzUnderlineRect(RenderObject renderObject) {
  if (renderObject is! RenderCustomPaint) return null;
  final painter = renderObject.foregroundPainter;
  if (painter is! _DzUnderlinePainter) return null;
  final rect = painter.lastRect;
  if (rect == null) return null;
  return rect.shift(renderObject.localToGlobal(Offset.zero));
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
