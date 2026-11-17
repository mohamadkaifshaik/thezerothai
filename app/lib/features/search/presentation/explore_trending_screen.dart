import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../domain/search_feature_flags.dart';
import 'bloc/trends_cubit.dart';
import 'bloc/trends_state.dart';
import 'widgets/explore_trends_section.dart';
import 'widgets/trends_loader.dart';
import 'widgets/trends_status_views.dart';

/// `/explore/trending`: Explore's "See all" for Trending, the whole list (up
/// to [kExploreTrendsMaxRows]) in the same ranked rows. Reads the shared
/// [TrendsCubit], so it costs no call of its own. Loading, failed (with Retry)
/// and empty states. With `trending_posts` or `trending_media` on (the
/// Posts and Media sections of Explore's Trending tab) a row opens that
/// hashtag in the tab (`/explore?tag=`) instead of the search results; the
/// media feed lives in the tab, not here. The route needs `search`,
/// `trends` and `ui_shell`.
class ExploreTrendingScreen extends StatelessWidget {
  const ExploreTrendingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inExplore =
        isFeatureEnabled(context, kFeatureSearch) &&
        (isFeatureEnabled(context, kFeatureTrendingPosts) ||
            isFeatureEnabled(context, kFeatureTrendingMedia));
    final content = BlocBuilder<TrendsCubit, TrendsState>(
      builder: (context, state) => _body(context, state, inExplore: inExplore),
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppMainColumn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBackHeader(
                title: 'Trending',
                onBack: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRouter.explorePath),
              ),
              Expanded(child: TrendsLoader(child: content)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    TrendsState state, {
    required bool inExplore,
  }) {
    // Pull to refresh asks the shared cubit again, past its 5 minute reuse window.
    Future<void> refresh() =>
        context.read<TrendsCubit>().ensureLoaded(force: true);
    final trends = state.trends.take(kExploreTrendsMaxRows).toList();
    final latest = state.latest;
    final empty = trends.isEmpty && latest == null;
    if (empty) {
      switch (state.status) {
        case TrendsStatus.initial:
        case TrendsStatus.loading:
          return const SingleChildScrollView(
            primary: false,
            child: TrendsSkeleton(rows: 8),
          );
        case TrendsStatus.failed:
          return RefreshIndicator(
            onRefresh: refresh,
            child: SingleChildScrollView(
              primary: false,
              physics: const AlwaysScrollableScrollPhysics(),
              child: TrendsErrorNotice(
                error: state.error,
                onRetry: () =>
                    context.read<TrendsCubit>().ensureLoaded(force: true),
              ),
            ),
          );
        case TrendsStatus.unavailable:
        case TrendsStatus.ready:
          break;
      }
    }
    return RefreshIndicator(
      onRefresh: refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (empty)
            const SliverToBoxAdapter(
              child: AppEmptyView(
                icon: Icons.trending_up,
                title: 'Nothing is trending yet',
                subtitle:
                    'Hashtags show up here as people use them. '
                    'The newest one is always shown.',
              ),
            )
          else
            SliverList.builder(
              itemCount: trends.length + 1 + (latest == null ? 0 : 1),
              itemBuilder: (context, i) {
                if (i == 0) return ExploreTrendsNote(state: state);
                if (i <= trends.length) {
                  return exploreTrendRow(
                    context,
                    trends[i - 1],
                    last: i == trends.length && latest == null,
                    inExplore: inExplore,
                  );
                }
                // The Latest row closes the list (or is the only row, "Just posted").
                return exploreLatestRow(
                  context,
                  latest!,
                  kicker: trends.isEmpty ? 'Just posted' : 'Latest',
                  inExplore: inExplore,
                );
              },
            ),
          const ShellBottomInsetSliver(),
        ],
      ),
    );
  }
}
