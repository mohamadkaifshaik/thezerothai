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
