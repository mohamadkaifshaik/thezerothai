import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_badge.dart';
import '../theme/app_theme.dart';
import 'app_nav_destination.dart';

/// The bottom navigation bar of narrow layouts: icon-only cells of equal
/// width on a 56dp bar with a 1px top hairline. The selected cell shows its
/// filled glyph; there is no indicator pill and no label (X's bar), and the
/// selection may be **none** ([selectedIndex] null), which a Material
/// `NavigationBar` cannot express: Settings and the drawer destinations are
/// not in the bar, so no cell is selected on them.
///
/// Each cell is a 48dp-or-taller button announced with its label, as selected
/// or not, and a badge text when it has one.
///
/// With [floating] (the redesigned chrome, `ui_shell`) it is the
/// [AppFloatingBottomBar] pill instead; everything above describes the legacy
/// docked bar.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.floating = false,
  });

  final List<AppNavDestination> destinations;
  final int? selectedIndex;
  final ValueChanged<int> onSelected;

  /// Draw the floating pill of the redesigned chrome.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    if (floating) {
      return AppFloatingBottomBar(
        destinations: destinations,
        selectedIndex: selectedIndex,
        onSelected: onSelected,
      );
    }
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppSize.bottomNav,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _Cell(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = destination.iconWidget(
      selected ? destination.selectedIcon : destination.icon,
    );
    // The cell excludes its children from semantics, so the badge is spoken
    // here: "Messages, 3 unread conversations".
    final badge = destination.badgeLabel.isEmpty
        ? null
        : (destination.badgeSemanticLabel ?? destination.badgeLabel);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: badge == null ? destination.label : '${destination.label}, $badge',
      onTap: onTap,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        child: Center(
          child: IconTheme(
            data: IconThemeData(color: colors.onSurface, size: AppIconSize.lg),
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// The floating bottom bar of the redesigned phone chrome (`ui_shell`,
/// ADR-0034): a navy pill, [AppSize.floatingNavHeight] tall, inset
/// [AppSize.floatingNavInset] from the sides and [AppSize.floatingNavBottom]
/// above the bottom safe area, with [AppShadows.navBar]. Navy in both themes.
///
/// Cells are equal width and at least 48dp. The selected one shows its filled
/// glyph in `navBarSelected` on a 12 % teal disc (shape, not colour alone).
/// A 12sp label sits under each icon while the text scale is at most
/// [maxLabelTextScale] and every label fits its cell; otherwise the bar is
/// icon-only and each cell carries a tooltip. Either way a cell is announced
/// with the full label of its destination, as selected or not, and its badge
/// ("Messages, 3 unread conversations").
///
/// Only the pill takes pointer events: the transparent area around it lets
/// taps through to the page below.
class AppFloatingBottomBar extends StatelessWidget {
  const AppFloatingBottomBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<AppNavDestination> destinations;
  final int? selectedIndex;
  final ValueChanged<int> onSelected;

  /// Above this text scale the bar is icon-only (decision D3).
  static const double maxLabelTextScale = 1.3;

  /// Opacity of the teal disc behind the selected glyph.
  static const double selectedDiscOpacity = 0.12;

  /// Horizontal padding inside the pill, on each side of the cells.
  static const double pillPadding = AppSpacing.sm;

  /// The space the bar takes at the bottom of the screen, above the safe
  /// area: the pill and its bottom margin.
  static const double reservedHeight =
      AppSize.floatingNavHeight + AppSize.floatingNavBottom;

  static TextStyle? _labelStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall;

  bool _labelsFit(BuildContext context, double cellWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler.scale(1) > maxLabelTextScale) return false;
    // The selected label is the widest a cell can get (heavier weight).
    final style = _labelStyle(context)
        ?.copyWith(fontWeight: AppTypeTokens.weightUi);
    for (final destination in destinations) {
      final painter = TextPainter(
        text: TextSpan(text: destination.barLabelText, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      if (width > cellWidth) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.symmetric(horizontal: AppSize.floatingNavInset),
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSize.floatingNavBottom),
        child: DecoratedBox(
          decoration: const ShapeDecoration(
            shape: StadiumBorder(),
            shadows: AppShadows.navBar,
          ),
          child: Material(
            color: colors.navBarSurface,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: AppSize.floatingNavHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: pillPadding),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final count = destinations.length;
                    final showLabels =
                        count > 0 &&
                        _labelsFit(context, constraints.maxWidth / count);
                    return Row(
                      children: [
                        for (var i = 0; i < count; i++)
                          Expanded(
                            child: _FloatingCell(
                              destination: destinations[i],
                              selected: i == selectedIndex,
                              showLabel: showLabels,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingCell extends StatelessWidget {
  const _FloatingCell({
    required this.destination,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  /// Height of the selected shape when a label sits under it (a 48dp-wide
  /// stadium); icon-only, it is the full 48dp disc.
  static const double _labelledDiscHeight = 32;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final color = selected ? colors.navBarSelected : colors.navBarUnselected;
    final glyph = Icon(
      selected ? destination.selectedIcon : destination.icon,
      color: color,
      size: AppIconSize.lg,
    );
    final disc = Container(
      width: AppSpacing.minTapTarget,
      height: showLabel ? _labelledDiscHeight : AppSpacing.minTapTarget,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: selected
            ? colors.navBarSelected.withValues(
                alpha: AppFloatingBottomBar.selectedDiscOpacity,
              )
            : null,
      ),
      child: destination.badgeLabel.isEmpty
          ? glyph
          : Stack(
              clipBehavior: Clip.none,
              children: [
                glyph,
                PositionedDirectional(
                  top: -AppSpacing.xs,
                  start: AppIconSize.lg / 2 + AppSpacing.xs / 2,
                  child: _FloatingBadge(destination: destination),
                ),
              ],
            ),
    );
    final Widget content = showLabel
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              disc,
              const SizedBox(height: AppSpacing.xs / 2),
              Text(
                destination.barLabelText,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: AppFloatingBottomBar._labelStyle(context)?.copyWith(
                  color: color,
                  fontWeight: selected ? AppTypeTokens.weightUi : null,
                ),
              ),
            ],
          )
        : Center(child: disc);
    final overlay = colors.navBarSelected;
    final cell = InkResponse(
      onTap: onTap,
      containedInkWell: true,
      highlightShape: BoxShape.rectangle,
      customBorder: const StadiumBorder(),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => overlay.withValues(
          alpha: states.contains(WidgetState.focused) ? 0.24 : 0.12,
        ),
      ),
      child: content,
    );
    // The cell excludes its children from semantics, so the badge is spoken
    // here: "Messages, 3 unread conversations".
    final badge = destination.badgeLabel.isEmpty
        ? null
        : (destination.badgeSemanticLabel ?? destination.badgeLabel);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: badge == null ? destination.label : '${destination.label}, $badge',
      onTap: onTap,
      excludeSemantics: true,
      child: showLabel
          ? cell
          : Tooltip(
              message: destination.tooltipText,
              excludeFromSemantics: true,
              child: cell,
            ),
    );
  }
}

/// The badge of a floating-bar cell: the count when the destination carries
/// one (messages), the unread dot otherwise (activity). The bar is navy in
/// both themes, so the badge reads the dark colour set.
class _FloatingBadge extends StatelessWidget {
  const _FloatingBadge({required this.destination});

  final AppNavDestination destination;

  @override
  Widget build(BuildContext context) {
    final spoken = destination.badgeSemanticLabel ?? destination.badgeLabel;
    final count = destination.badgeCount;
    return Theme(
      data: Theme.of(context).copyWith(extensions: const [AppColors.dark]),
      child: count != null && count > 0
          ? AppCountBadge(count: count, semanticsLabel: spoken, onNavy: true)
          : AppUnreadDot(
              semanticsLabel: spoken,
              ringColor: context.appColors.navBarSurface,
            ),
    );
  }
}
