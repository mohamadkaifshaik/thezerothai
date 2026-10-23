import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// One 48dp row of a bottom sheet: a leading icon and a label, with an
/// optional [trailing] widget (a radio, a check). Used by the repost sheet
/// and the "Who can reply?" sheet; no default list tile.
///
/// With [selected] set the row is one choice of a mutually exclusive group:
/// it is announced as selected or not (the visual mark is the caller's
/// [trailing]); with [selected] null it is a plain button.
class SheetOptionRow extends StatelessWidget {
  const SheetOptionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.selected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
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
                Icon(icon, size: AppIconSize.lg),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(label, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
