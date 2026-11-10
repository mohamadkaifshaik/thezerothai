import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// One 48dp row of a bottom sheet: a leading icon and a label, with an
/// optional [trailing] widget (a radio, a check). Used by the repost sheet
/// and the "Who can reply?" sheet; no default list tile.
///
/// With [selected] set the row is one choice of a mutually exclusive group:
/// it is announced as selected or not. A selected row shows its label and a
/// check glyph in the accent text colour (tealText on light, 5.4:1 and up),
/// so selection is never colour alone; a caller's [trailing] replaces the
/// check. With [selected] null it is a plain button. [role] gives the row
/// an ARIA role on the web (the audience picker's rows are `menuItem`s).
class SheetOptionRow extends StatelessWidget {
  const SheetOptionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.selected,
    this.role,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool? selected;
  final SemanticsRole? role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final accent = context.appColors.accentText;
    final isSelected = selected == true;
    final tint = enabled ? null : theme.disabledColor;
    final labelColor = enabled && isSelected ? accent : tint;
    final end =
        trailing ??
        (isSelected
            ? ExcludeSemantics(
                child: Icon(Icons.check, size: AppIconSize.lg, color: accent),
              )
            : null);
    return Semantics(
      button: true,
      role: role,
      enabled: enabled,
      selected: selected,
      inMutuallyExclusiveGroup: selected == null ? null : true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.xxl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: AppIconSize.lg,
                  color: enabled && isSelected ? accent : tint,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: labelColor,
                    ),
                  ),
                ),
                if (end != null) ...[const SizedBox(width: AppSpacing.md), end],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
