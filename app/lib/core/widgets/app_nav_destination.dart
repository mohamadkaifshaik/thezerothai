import 'package:material_ui/material_ui.dart';

import '../icons/dz_icon_data.dart';

/// Where a destination lives (ADR-0034): [primary] ones are the phone bottom
/// bar and the first rail items; [secondary] ones are rail-only on >= 600dp
/// and live in the drawer on phones.
enum AppNavGroup { primary, secondary }

/// A destination in the app's navigation (Home, Notifications, Profile...),
/// shared by the bottom bar and the navigation rail.
///
/// [group] decides the placement: primary destinations show on every form
/// factor, secondary ones only on the rail (phones reach them through the
/// drawer). The list order is the display order; the shell lists primaries
/// first.
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeLabel = '',
    this.badgeSemanticLabel,
    this.badgeCount,
    this.group = AppNavGroup.primary,
    this.tooltip,
    this.onActivate,
    this.semanticsLabel,
    this.dzIcon,
    this.dzFilledWhenSelected = false,
  });

  /// The design's stroke icon for the floating phone bar (see `DzIcons`);
  /// null draws [icon] / [selectedIcon] instead. The rail always uses the
  /// Material pair.
  final DzIconData? dzIcon;

  /// Fill [dzIcon] when selected (the Home house is solid when active; the
  /// other bar icons only turn teal).
  final bool dzFilledWhenSelected;

  /// Primary (bar and rail) or secondary (rail only, the drawer on phones).
  final AppNavGroup group;

  /// Shown by the navigation rail (>= 600dp) only: below that the bottom bar
  /// leaves it out and the drawer carries the entry (Lists, History...).
  bool get railOnly => group == AppNavGroup.secondary;

  /// Hover/long-press text for icon-only presentations; defaults to [label].
  final String? tooltip;

  /// When set, the rail calls this with a context at the item's icon (the
  /// anchor of a menu) instead of `onDestinationSelected`: the destination is
  /// a menu button, not a page (the "More" item). Only the rail honours it,
  /// so pair it with a secondary [group].
  final void Function(BuildContext anchor)? onActivate;

  /// Spoken form of the rail label (`More, menu`); defaults to [label].
  final String? semanticsLabel;

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  String get tooltipText => tooltip ?? label;

  /// The number behind [badgeLabel]. The floating phone bar draws a count
  /// badge when it is set and the unread dot when it is null (activity).
  final int? badgeCount;

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
