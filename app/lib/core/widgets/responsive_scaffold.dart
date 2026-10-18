import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A destination in the app's primary navigation (Home, Profile, Settings...).
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeLabel = '',
    this.badgeSemanticLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Short text on a badge over the icon (`3`, `99+`); empty hides it.
  final String badgeLabel;

  /// Spoken form of the badge (`3 unread`); defaults to [badgeLabel].
  final String? badgeSemanticLabel;

  Widget iconWidget(IconData data) {
    final icon = Icon(data);
    if (badgeLabel.isEmpty) return icon;
    return Semantics(
      label: badgeSemanticLabel ?? badgeLabel,
      child: Badge(
        label: ExcludeSemantics(child: Text(badgeLabel)),
        child: icon,
      ),
    );
  }
}

/// Adaptive shell used by every top-level, authenticated screen:
/// - `< 600dp` (phone): bottom [NavigationBar].
/// - `600–1200dp` (tablet): [NavigationRail].
/// - `> 1200dp` (desktop/web): [NavigationRail] + an optional third column,
///   mirroring X's web layout (see the `flutter-feature` skill).
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.sideColumn,
    this.floatingActionButton,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AppNavDestination> destinations;
  final Widget body;

  /// Extra content shown only at desktop widths (e.g. trends, suggestions).
  final Widget? sideColumn;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < AppBreakpoints.mobile) {
          return Scaffold(
            body: SafeArea(child: body),
            floatingActionButton: floatingActionButton,
            bottomNavigationBar: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                destinations: [
                  for (final d in destinations)
                    NavigationDestination(
                      icon: d.iconWidget(d.icon),
                      selectedIcon: d.iconWidget(d.selectedIcon),
                      label: d.label,
                    ),
                ],
              ),
            ),
          );
        }

        final isDesktop = width >= AppBreakpoints.tablet;
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  extended: isDesktop,
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onDestinationSelected,
                  leading: floatingActionButton,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: d.iconWidget(d.icon),
                        selectedIcon: d.iconWidget(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(flex: 3, child: body),
                if (isDesktop && sideColumn != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 320,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: sideColumn,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
