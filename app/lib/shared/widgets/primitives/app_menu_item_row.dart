import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The content of one popup-menu entry: a leading outline [icon] and a
/// [label]. With [destructive] both use the theme's error colour, so an
/// action that removes something is told apart by more than its wording.
///
/// With [selected] (a choice in a group of menu items) the label and icon take
/// the accent text colour and a check glyph ends the row, so the choice is
/// never shown by colour alone; it is also announced as selected.
///
/// Put it in a `PopupMenuItem` (which supplies the tap and the button
/// semantics) or a tappable row of an anchored menu. The row is at least 48dp
/// tall itself, and wraps a long label (text scale 2.0) instead of clipping
/// it. The icon is decorative and excluded from semantics, so a screen reader
/// speaks the label once. Purely presentational.
class AppMenuItemRow extends StatelessWidget {
  const AppMenuItemRow({
    super.key,
    required this.icon,
    required this.label,
    this.destructive = false,
    this.selected,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  /// Null: not a choice. True or false: a choice, announced as such.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.appColors.accentText;
    final isSelected = selected == true;
    final color = destructive
        ? theme.colorScheme.error
        : isSelected
        ? accent
        : theme.colorScheme.onSurface;
    final iconColor = destructive
        ? theme.colorScheme.error
        : isSelected
        ? accent
        : theme.colorScheme.onSurfaceVariant;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: AppIconSize.md, color: iconColor),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(color: color),
            ),
          ),
          if (isSelected) ...[
            const SizedBox(width: AppSpacing.md),
            ExcludeSemantics(
              child: Icon(Icons.check, size: AppIconSize.md, color: accent),
            ),
          ],
        ],
      ),
    );
    return selected == null ? row : Semantics(selected: isSelected, child: row);
  }
}
