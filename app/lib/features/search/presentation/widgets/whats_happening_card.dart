import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_surface.dart';
import '../../domain/search_feature_flags.dart';
import '../bloc/trends_cubit.dart';
import '../bloc/trends_state.dart';
import '../../domain/search_routes.dart';
import 'trend_row.dart';
import 'trends_loader.dart';
import 'trends_status_views.dart';

/// How many trends the card shows.
const kWhatsHappeningRows = 5;

/// The desktop side column's "What's happening" card (W4-18): an outlined
/// [AppSurface] with the top 5 trends and "Show more" to Explore. Reads the
/// shared [TrendsCubit], so it never adds a call of its own.
///
/// Renders nothing unless `search` and `trends` are both on; nothing too while
/// loading, empty or unavailable. A failure with nothing to show says so once,
/// with Retry. Needs [TrendsCubit] in scope (only once the flag check passes).
class WhatsHappeningCard extends StatelessWidget {
  const WhatsHappeningCard({
    super.key,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureSearch) ||
        !isFeatureEnabled(context, kFeatureTrends)) {
      return const SizedBox.shrink();
    }
    return TrendsLoader(
      child: BlocBuilder<TrendsCubit, TrendsState>(
        builder: (context, state) {
          final trends = state.trends;
          if (trends.isEmpty) {
            if (state.status != TrendsStatus.failed) {
              return const SizedBox.shrink();
            }
            return _frame(
              context,
              TrendsErrorNotice(
                error: state.error,
                onRetry: () =>
                    context.read<TrendsCubit>().ensureLoaded(force: true),
              ),
            );
          }
          final theme = Theme.of(context);
          return _frame(
            context,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final trend in trends.take(kWhatsHappeningRows))
                  TrendRow(
                    key: ValueKey(trend.tag),
                    trend: trend,
                    onTap: () =>
                        context.push(searchResultsLocation('#${trend.tag}')),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppSpacing.minTapTarget),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      textStyle: theme.textTheme.bodyMedium,
                    ),
                    onPressed: () => context.go(AppRouter.explorePath),
                    child: const Text('Show more'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _frame(BuildContext context, Widget body) {
    final theme = Theme.of(context);
    return AppSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Semantics(
              header: true,
              child: Text(
                "What's happening",
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          body,
        ],
      ),
    );
  }
}
