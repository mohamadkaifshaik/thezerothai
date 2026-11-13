import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_skeleton.dart';

/// Keys the tests read.
const kPlanCardSkeletonKey = ValueKey('plan-card-skeleton');
const kPlanHeroSkeletonKey = ValueKey('plan-hero-skeleton');

/// Placeholders shaped like the plan card ([BeaconRow]): a card at the card
/// radius with an eyebrow, a title and two lines. Announced once as
/// [semanticsLabel].
class PlanCardListSkeleton extends StatelessWidget {
  const PlanCardListSkeleton({
    super.key,
    this.cards = 3,
    this.semanticsLabel = 'Loading plans',
  });

  final int cards;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        child: Column(
          children: [
            for (var i = 0; i < cards; i++) ...[
              const _PlanCardSkeleton(),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCardSkeleton extends StatelessWidget {
  const _PlanCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: kPlanCardSkeletonKey,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.appColors.hairline),
      ),
      child: const Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Bar(0.35, AppSpacing.sm + AppSpacing.xs),
            SizedBox(height: AppSpacing.sm),
            _Bar(0.7, AppSpacing.lg),
            SizedBox(height: AppSpacing.sm),
            _Bar(0.5, AppSpacing.md),
            SizedBox(height: AppSpacing.xs),
            _Bar(0.4, AppSpacing.md),
          ],
        ),
      ),
    );
  }
}

/// PlanDetail's loading state: a navy-card-shaped hero block (eyebrow, title,
/// fact lines) and the organiser row, announced once as [semanticsLabel].
class PlanDetailSkeleton extends StatelessWidget {
  const PlanDetailSkeleton({super.key, this.semanticsLabel = 'Loading plan'});

  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              key: kPlanHeroSkeletonKey,
              decoration: BoxDecoration(
                color: context.appColors.hairline,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Bar(0.3, AppSpacing.sm + AppSpacing.xs),
                    SizedBox(height: AppSpacing.md),
                    _Bar(0.8, AppSpacing.xl),
                    SizedBox(height: AppSpacing.md),
                    _Bar(0.6, AppSpacing.md),
                    SizedBox(height: AppSpacing.sm),
                    _Bar(0.5, AppSpacing.md),
                    SizedBox(height: AppSpacing.sm),
                    _Bar(0.4, AppSpacing.md),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const AppSkeletonRow(
              avatarSize: AppSpacing.xl + AppSpacing.sm,
              barWidths: [0.4, 0.25],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.fraction, this.height);

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: fraction,
    alignment: AlignmentDirectional.centerStart,
    child: AppSkeletonBlock(height: height),
  );
}
