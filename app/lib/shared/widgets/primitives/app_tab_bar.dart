import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';

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
    this.trailing,
    this.fixedTrailing,
    this.semanticLabel,
  }) : assert(tabs.length > 0, 'a tab bar needs at least one tab');

  final List<AppTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// Share the width equally instead of sizing each tab to its label.
  final bool equalWidth;

  /// A widget after the last tab (the "manage tabs" button of Home).
  final Widget? trailing;

  /// A widget after the tabs that stays visible at the end of the row while
  /// the tabs scroll (Home's "+" for Manage pinned). Content-sized
  /// layout only.
  final Widget? fixedTrailing;

  /// Spoken name of the whole group.
  final String? semanticLabel;

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
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final padding = narrow ? AppSize.tabPaddingNarrow : AppSize.tabPaddingWide;
    final items = [
      for (var i = 0; i < tabs.length; i++)
        _TabItem(
          key: tabs[i].key,
          tab: tabs[i],
          selected: i == selectedIndex,
          horizontalPadding: equalWidth ? 0 : padding,
          onTap: () => onChanged(i),
        ),
    ];
    final Widget row = equalWidth
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
