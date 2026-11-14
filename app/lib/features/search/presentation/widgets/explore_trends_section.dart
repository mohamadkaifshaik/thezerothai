import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../data/search_repository.dart' show Trend;
import '../../domain/explore_media.dart' show kExploreTopTrends;
import '../../domain/search_routes.dart';
import '../bloc/trends_cubit.dart';
import '../bloc/trends_state.dart';
import 'explore_section_header.dart';
import 'trend_row.dart';
import 'trends_loader.dart';
import 'trends_status_views.dart';

/// Rows the Trending page lists, at most: the one `GetTrends` asks for 30.
const kExploreTrendsMaxRows = kTrendsFetchLimit;

/// The "Trending" section of Explore, as a sliver: a header with "See all >"
/// (the full list, [AppRouter.exploreTrendingPath]) over the top
/// [kExploreTopTrends] [TrendRow]s, or the loading, empty ("Nothing is
/// trending yet") and failed states. Mount it only with `trends` on; needs
/// [TrendsCubit] in scope.
class ExploreTrendsSection extends StatelessWidget {
  const ExploreTrendsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return TrendsLoader(
      child: BlocBuilder<TrendsCubit, TrendsState>(
        builder: (context, state) {
          final trends = state.trends;
          Widget? body;
          switch (state.status) {
            case TrendsStatus.unavailable:
              return const SliverToBoxAdapter(child: SizedBox.shrink());
            case TrendsStatus.initial:
            case TrendsStatus.loading:
              if (trends.isEmpty) body = const TrendsSkeleton(rows: 3);
            case TrendsStatus.failed:
              if (trends.isEmpty) {
                body = TrendsErrorNotice(
                  error: state.error,
                  onRetry: () =>
                      context.read<TrendsCubit>().ensureLoaded(force: true),
                );
              }
            case TrendsStatus.ready:
              if (trends.isEmpty) {
                body = const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: AppEmptyView(
                    icon: Icons.trending_up,
                    title: 'Nothing is trending yet',
                    subtitle:
                        'Popular hashtags show up here once enough '
                        'people use them.',
                  ),
                );
              }
          }
          final shown = trends.take(kExploreTopTrends).toList();
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: AppExplorePeopleLayout.sectionGap,
                  ),
                  child: ExploreSectionHeader(
                    title: 'Trending',
                    onSeeAll: () => context.push(AppRouter.exploreTrendingPath),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: ExploreTrendsNote(state: state)),
              if (body != null)
                SliverToBoxAdapter(child: body)
              else
                SliverList.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, i) => exploreTrendRow(
                    context,
                    shown[i],
                    last: i == shown.length - 1,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One ranked trend row that opens the tag's results (Explore's section and
/// the Trending page share it).
Widget exploreTrendRow(
  BuildContext context,
  Trend trend, {
  bool last = false,
}) => TrendRow(
  key: ValueKey(trend.tag),
  trend: trend,
  ranked: true,
  last: last,
  onTap: () => context.push(searchResultsLocation('#${trend.tag}')),
);

/// The honest one-liner under the Trending title: "Couldn't refresh" while a
/// failed call keeps the last list on screen, or "more than a day old" when the
/// daily sweep missed a run. Nothing otherwise.
class ExploreTrendsNote extends StatelessWidget {
  const ExploreTrendsNote({super.key, required this.state, this.now});

  final TrendsState state;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    if (state.trends.isEmpty) return const SizedBox.shrink();
    final note = state.status == TrendsStatus.failed
        ? "Couldn't refresh. Showing the last list."
        : trendsAreStale(state.computedAt, (now ?? DateTime.now)())
        ? 'This list is more than a day old.'
        : null;
    if (note == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        note,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
