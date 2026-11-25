import 'package:material_ui/material_ui.dart';

import '../../shared/widgets/primitives/app_badge.dart';
import '../icons/dz_icon.dart';
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
/// ADR-0034), drawn as the Dz artboards do: a navy pill, 64 tall (radius 32),
/// inset 16 from the sides and 14 above the bottom safe area, with
/// [AppShadows.navBar]. Navy in both themes.
///
/// Cells are equal width and five 50 dp round items sit in them. The selected
/// one has the teal glyph on a tinted pill ([activePill]); a destination's
/// `dzIcon` draws the design's stroke icon.
/// The bar is icon-only: each cell carries a tooltip and is announced with
/// the full label of its destination, as selected or not, and its badge
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

  /// The selected item's pill (artboards: #123B44; the drawer's dark teal
  /// tile is the nearest token).
  static const Color activePill = AppPalette.drawerTileTealDark;

  /// The pill's and the filled glyph's change of state (reduce-motion: none).
  static const Duration fadeTime = Duration(milliseconds: 160);

  /// Horizontal padding inside the pill, on each side of the cells.
  static const double pillPadding = AppSpacing.sm;

  /// The space the bar takes at the bottom of the screen, above the safe
  /// area: the pill and its bottom margin.
  static const double reservedHeight =
      AppSize.floatingNavHeight + AppSize.floatingNavBottom;

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
                child: Row(
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      Expanded(
                        child: _FloatingCell(
                          destination: destinations[i],
                          selected: i == selectedIndex,
                          onTap: () => onSelected(i),
                        ),
                      ),
                  ],
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
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final color = selected ? colors.navBarSelected : colors.navBarUnselected;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final dz = destination.dzIcon;
    final Widget glyph = dz == null
        ? Icon(
            selected ? destination.selectedIcon : destination.icon,
            color: color,
            size: AppIconSize.lg,
          )
        : DzIcon(
            dz,
            color: color,
            fill: selected && destination.dzFilledWhenSelected ? 1 : 0,
            fillDuration: reduce
                ? Duration.zero
                : AppFloatingBottomBar.fadeTime,
            size: AppIconSize.lg,
          );
    final counted =
        destination.badgeCount != null && destination.badgeCount! > 0;
    final disc = AnimatedContainer(
      duration: reduce ? Duration.zero : AppFloatingBottomBar.fadeTime,
      width: AppSize.floatingNavItem,
      height: AppSize.floatingNavItem,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        shape: const CircleBorder(),
        // The active pill is #123B44 in the artboards; the drawer's dark
        // teal tile (#123A3C) is the nearest token.
        color: selected ? AppFloatingBottomBar.activePill : Colors.transparent,
      ),
      child: destination.badgeLabel.isEmpty
          ? glyph
          : Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                glyph,
                // The unread dot sits 12 from the top and end of the item
                // (the artboards); a count badge rides the glyph's corner.
                PositionedDirectional(
                  // Offsets from the 24 dp glyph; the glyph sits 13 dp in.
                  top: counted ? -AppSpacing.xs : -1,
                  end: counted ? -AppSpacing.xs : -1,
                  child: _FloatingBadge(destination: destination),
                ),
              ],
            ),
    );
    // The 50 dp round item sits in a cell that is at least 48 dp wide.
    final Widget content = Center(child: disc);
    final overlay = colors.navBarSelected;
    final cell = InkResponse(
      onTap: onTap,
      containedInkWell: true,
      highlightShape: BoxShape.rectangle,
      customBorder: const CircleBorder(),
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
      child: Tooltip(
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
