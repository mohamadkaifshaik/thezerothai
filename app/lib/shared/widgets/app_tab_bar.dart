import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

/// One tab of an [AppTabBar]: a text label with an optional leading icon.
@immutable
class AppTab {
  const AppTab({required this.label, this.icon});

  final String label;
  final IconData? icon;
}

/// The text-only tab row of every screen with tabs (Home, Notifications,
/// Profile, History, Explore): a 53dp row, the active label bold in the
/// primary text colour, inactive labels in the secondary colour, and a 4dp
/// accent bar **as wide as the label** under the active tab, flush with the
/// 1px hairline below the row (`docs/x_research/screens/_shared.md`).
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
  /// the tabs scroll (Home's "+" for Manage pinned, W5-14). Content-sized
  /// layout only.
  final Widget? fixedTrailing;

  /// Spoken name of the whole group.
  final String? semanticLabel;

  void _move(int delta) {
    final next = (selectedIndex + delta).clamp(0, tabs.length - 1);
    if (next != selectedIndex) onChanged(next);
  }

  Widget _scrolling(List<Widget> items) {
    final scroller = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [...items, ?trailing]),
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
          tab: tabs[i],
          selected: i == selectedIndex,
          horizontalPadding: equalWidth ? 0 : padding,
          onTap: () => onChanged(i),
        ),
    ];
    final Widget row = equalWidth
        ? Row(
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
            height: AppSize.headerRow,
            child: row,
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
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
      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
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
        // Centred with loose constraints: in the equal-width layout the tab
        // is wider than its label, but the indicator must stay label-wide.
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            // The Stack is as wide as the label, so the indicator (positioned
            // left and right 0) is exactly the label width.
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(widthFactor: 1, child: label),
                if (selected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      key: const ValueKey('tab-indicator'),
                      height: AppSize.tabIndicator,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(
                          AppSize.tabIndicator,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
