import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The small "GIF" pill on a GIF's still (composer tile and posted media). A
/// purely visual mark: the surrounding control carries the semantics ("GIF,
/// play"), so this is excluded from the tree. Place it with
/// `PositionedDirectional`.
class GifBadge extends StatelessWidget {
  const GifBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            'GIF',
            maxLines: 1,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
