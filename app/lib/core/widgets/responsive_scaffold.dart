import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A destination in the app's primary navigation (Home, Profile, Settings...).
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
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
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                  ),
              ],
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
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
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
