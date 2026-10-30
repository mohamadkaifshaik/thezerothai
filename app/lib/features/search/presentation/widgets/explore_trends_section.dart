import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_empty_view.dart';
import '../../data/search_repository.dart' show Trend;
import '../bloc/trends_cubit.dart';
import '../bloc/trends_state.dart';
import '../search_navigation.dart';
import 'trend_row.dart';
import 'trends_loader.dart';
import 'trends_status_views.dart';

/// Rows Explore shows before "Show more" (ADR-0028 F6), and the most it
/// expands to.
const kExploreTrendsCollapsedRows = 10;
const kExploreTrendsMaxRows = 30;

/// The trends part of Explore's Trending tab (W4-17), as a sliver: a "Trending
/// today" caption (the list is computed once a day), up to 10 [TrendRow]s with
/// "Show more" to 30, or the loading, empty ("Nothing is trending yet") and
/// failed states. Mount it only with `trends` on; needs [TrendsCubit] in scope.
/// [now] is injectable for the staleness caption.
class ExploreTrendsSection extends StatefulWidget {
  const ExploreTrendsSection({super.key, this.now});

  final DateTime Function()? now;

  @override
  State<ExploreTrendsSection> createState() => _ExploreTrendsSectionState();
}

class _ExploreTrendsSectionState extends State<ExploreTrendsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return TrendsLoader(
      child: BlocBuilder<TrendsCubit, TrendsState>(
        builder: (context, state) {
          final trends = state.trends;
          switch (state.status) {
            case TrendsStatus.unavailable:
              return const SliverToBoxAdapter(child: SizedBox.shrink());
            case TrendsStatus.initial:
            case TrendsStatus.loading:
              if (trends.isEmpty) {
                return const SliverToBoxAdapter(child: TrendsSkeleton());
              }
            case TrendsStatus.failed:
              if (trends.isEmpty) {
                return SliverToBoxAdapter(
                  child: TrendsErrorNotice(
                    error: state.error,
                    onRetry: () =>
                        context.read<TrendsCubit>().ensureLoaded(force: true),
                  ),
                );
              }
            case TrendsStatus.ready:
              if (trends.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: AppEmptyView(
                      icon: Icons.trending_up,
                      title: 'Nothing is trending yet',
                      subtitle:
                          'Popular hashtags show up here once enough '
                          'people use them.',
                    ),
                  ),
                );
              }
          }
          final canExpand =
              !_expanded && trends.length > kExploreTrendsCollapsedRows;
          final shown = _expanded
              ? trends.take(kExploreTrendsMaxRows).toList()
              : trends.take(kExploreTrendsCollapsedRows).toList();
          final now = (widget.now ?? DateTime.now)();
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: _Caption(
                  stale: trendsAreStale(state.computedAt, now),
                  failed: state.status == TrendsStatus.failed,
                ),
              ),
              SliverList.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => _row(context, shown[i]),
              ),
              if (canExpand)
                SliverToBoxAdapter(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSpacing.minTapTarget),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                      ),
                      onPressed: () => setState(() => _expanded = true),
                      child: const Text('Show more'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, Trend trend) => TrendRow(
    key: ValueKey(trend.tag),
    trend: trend,
    onTap: () => openSearch(context, query: '#${trend.tag}'),
  );
}

class _Caption extends StatelessWidget {
  const _Caption({required this.stale, required this.failed});

  final bool stale;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = failed
        ? "Couldn't refresh. Showing the last list."
        : stale
        ? 'This list is more than a day old.'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Trending today',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (note != null)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
