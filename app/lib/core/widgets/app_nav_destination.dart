import 'package:flutter/material.dart';

/// A destination in the app's primary navigation (Home, Notifications,
/// Profile...), shared by the bottom bar and the navigation rail.
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeLabel = '',
    this.badgeSemanticLabel,
    this.railOnly = false,
    this.onActivate,
    this.semanticsLabel,
  });

  /// Shown by the navigation rail (>= 600dp) only: below that the bottom bar
  /// leaves it out and the drawer carries the entry (Bookmarks).
  final bool railOnly;

  /// When set, the rail calls this with a context at the item's icon (the
  /// anchor of a menu) instead of `onDestinationSelected`: the destination is
  /// a menu button, not a page (the "More" item). Only the rail honours it,
  /// so pair it with [railOnly].
  final void Function(BuildContext anchor)? onActivate;

  /// Spoken form of the rail label (`More, menu`); defaults to [label].
  final String? semanticsLabel;

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
