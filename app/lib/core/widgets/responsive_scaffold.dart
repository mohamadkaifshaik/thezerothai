import 'package:flutter/material.dart';

import '../../shared/widgets/app_gradient_button.dart';
import '../../shared/widgets/app_rail_brand.dart';
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
/// - `< 600dp` (phone): bottom [NavigationBar]; [floatingActionButton] floats.
/// - `600–1200dp` (tablet): [NavigationRail] (icons) and the body centred in a
///   column at most [AppLayout.mainColumnMaxWidth] wide between 1dp borders.
/// - `>= 1200dp` (desktop/web): the rail extended (labels, a "Post" button),
///   the same centred body column and an optional third column
///   ([sideColumn], [AppLayout.sideColumnWidth] wide).
/// The rail carries the brand and, when [onCompose] is set, the compose entry
/// (an icon button on tablet, a gradient "Post" button on desktop).
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.sideColumn,
    this.floatingActionButton,
    this.onCompose,
    this.composeTooltip = 'New post',
    this.composeLabel = 'Post',
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AppNavDestination> destinations;
  final Widget body;

  /// Extra content shown only at desktop widths (for example a profile card
  /// and quick links).
  final Widget? sideColumn;

  /// The floating compose entry of the phone layout (below 600dp).
  final Widget? floatingActionButton;

  /// The compose entry of the rail (600dp and up); null hides it. The caller
  /// decides when composing is allowed, exactly as for [floatingActionButton].
  final VoidCallback? onCompose;
  final String composeTooltip;
  final String composeLabel;

  Widget _railLeading({required bool extended}) {
    final onCompose = this.onCompose;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppRailBrand(extended: extended),
          if (onCompose != null) ...[
            const SizedBox(height: AppSpacing.md),
            if (extended)
              SizedBox(
                width: AppLayout.railExtendedWidth - 2 * AppSpacing.md,
                child: AppGradientButton(
                  label: composeLabel,
                  icon: Icons.edit_outlined,
                  onPressed: onCompose,
                ),
              )
            else
              IconButton.filled(
                tooltip: composeTooltip,
                onPressed: onCompose,
                constraints: const BoxConstraints(
                  minWidth: AppSpacing.minTapTarget,
                  minHeight: AppSpacing.minTapTarget,
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ],
      ),
    );
  }

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
        final borderColor = Theme.of(context).colorScheme.outlineVariant;
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                // Desktop platforms default to a compact visual density, which
                // shrinks the destinations below the 48dp tap target.
                Theme(
                  data: Theme.of(context)
                      .copyWith(visualDensity: VisualDensity.standard),
                  child: NavigationRail(
                    extended: isDesktop,
                    selectedIndex: selectedIndex,
                    onDestinationSelected: onDestinationSelected,
                    leading: _railLeading(extended: isDesktop),
                    destinations: [
                      for (final d in destinations)
                        NavigationRailDestination(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppLayout.railItemVerticalPadding,
                          ),
                          icon: d.iconWidget(d.icon),
                          selectedIcon: d.iconWidget(d.selectedIcon),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppLayout.mainColumnMaxWidth,
                      ),
                      child: SizedBox.expand(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.symmetric(
                              vertical: BorderSide(color: borderColor),
                            ),
                          ),
                          child: body,
                        ),
                      ),
                    ),
                  ),
                ),
                if (isDesktop && sideColumn != null)
                  SizedBox(
                    width: AppLayout.sideColumnWidth,
                    height: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: sideColumn,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
