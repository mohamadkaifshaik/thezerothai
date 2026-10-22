import 'package:flutter/material.dart';

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
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<AppNavDestination> destinations;
  final int? selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
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
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: destination.label,
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
