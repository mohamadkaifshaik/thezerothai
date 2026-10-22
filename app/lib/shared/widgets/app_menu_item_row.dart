import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The content of one popup-menu entry: a leading outline [icon] and a
/// [label]. With [destructive] both use the theme's error colour, so an
/// action that removes something is told apart by more than its wording.
///
/// Put it in a `PopupMenuItem` (which supplies the 48dp target, the tap and
/// the button semantics); the icon is decorative and excluded from semantics,
/// so a screen reader speaks the label once. Purely presentational.
class AppMenuItemRow extends StatelessWidget {
  const AppMenuItemRow({
    super.key,
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return Row(
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: AppIconSize.md,
            color: destructive
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyLarge?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
