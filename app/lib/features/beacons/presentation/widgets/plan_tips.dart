import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';

/// The title of the plan form tips.
const kPlanTipsTitle = 'Tips for a good plan';

/// The tips of the create and edit forms (the approved designs'
/// "Tips for a good plan"). Advice only: the form's own rules (the start
/// window, the seat limits) stay with their fields.
const kPlanTips = <String>[
  "Say what you'll do, not who you want.",
  'Pick a public, named place.',
  'Keep it small: 2 to 6 people.',
];

/// The tips, one per line, each after a muted check mark (decorative).
class PlanTipsList extends StatelessWidget {
  const PlanTipsList({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.smd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final tip in kPlanTips)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check_circle_outline,
                      size: AppIconSize.sm,
                      color: muted,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(tip, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Tips for a good plan", inline at the top of the form, collapsed: a 48 dp
/// toggle row
/// that reports its expanded state, and the tips under it when [expanded].
/// The page owns [expanded], so it survives a resize.
class PlanTipsSection extends StatelessWidget {
  const PlanTipsSection({
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AppSurface(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              key: const ValueKey('plan-tips-toggle'),
              onTap: onToggle,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        size: AppIconSize.md,
                        color: muted,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          kPlanTipsTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expanded) const PlanTipsList(),
        ],
      ),
    );
  }
}
