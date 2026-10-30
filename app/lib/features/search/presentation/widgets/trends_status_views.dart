import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/search_repository.dart';
import '../../../../core/network/app_exception.dart';

/// A trends list older than this is labelled as such: the daily sweep runs
/// once a day (ADR-0028 F1 B), so a list a day and a half old means the sweep
/// missed a run. The caption is honest, never a failure.
const kTrendsStaleAfter = Duration(hours: 36);

/// Whether [computedAt] is old enough to say so. Unset (no list yet) is not
/// stale: that is the empty state.
bool trendsAreStale(DateTime? computedAt, DateTime now) =>
    computedAt != null && now.difference(computedAt) > kTrendsStaleAfter;

/// Friendly text for a failed GetTrends, branching on the type only (never on
/// the exception's text).
String trendsErrorMessage(Object? error) {
  if (error is SearchRateLimitedException) {
    return error.isDaily
        ? "You've reached today's limit for this. It resets later today."
        : "You're doing that a bit too fast. Give it a moment and try again.";
  }
  if (error is DegradedModeException) {
    return 'Dzeroth is in a limited mode right now. Trends are paused. '
        'Please try again shortly.';
  }
  if (error is NetworkException) {
    return 'No connection. Check your network and try again.';
  }
  return "Trends couldn't be loaded right now.";
}

/// A daily limit and the limited mode do not clear by tapping again.
bool trendsErrorCanRetry(Object? error) =>
    !(error is SearchRateLimitedException && error.isDaily) &&
    error is! DegradedModeException;

/// The inline failure of a trends surface: the message and, when a retry can
/// help, a Retry button (>= 48dp). Announced politely.
class TrendsErrorNotice extends StatelessWidget {
  const TrendsErrorNotice({super.key, required this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trendsErrorMessage(error),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null && trendsErrorCanRetry(error))
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTapTarget),
                  padding: EdgeInsets.zero,
                ),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Static placeholder rows shaped like [TrendRow]s while the first call is in
/// flight (no shimmer: cheap, and respects reduced motion).
class TrendsSkeleton extends StatelessWidget {
  const TrendsSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget bar(double factor) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: factor,
      child: Container(
        height: AppSpacing.md,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    );
    return Semantics(
      label: 'Loading trends',
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Column(
                  children: [
                    bar(0.3),
                    const SizedBox(height: AppSpacing.xs),
                    bar(0.6),
                    const SizedBox(height: AppSpacing.xs),
                    bar(0.2),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
