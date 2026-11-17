import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_notice_banner.dart';
import '../bloc/explore_media_state.dart';
import '../bloc/trending_media_cubit.dart';
import 'explore_media_section.dart'
    show exploreMediaColumns, openExploreMediaTile;
import 'explore_media_tile.dart';
import 'trending_section_scroll.dart';
import 'trending_section_views.dart';

/// Tiles of the loading placeholder grid.
const kExploreMediaSkeletonCount = 9;

/// How many columns the Trending Media grid has in a column [width] wide in a
/// window [windowWidth] wide: a fixed
/// [AppExplorePeopleLayout.mediaTabletColumns] on a tablet (600-1199), else
/// the usual [exploreMediaColumns] (3 on a phone and in a desktop pane).
int trendingMediaColumns(double windowWidth, double width) =>
    windowWidth >= AppBreakpoints.mobile && windowWidth < AppBreakpoints.tablet
    ? AppExplorePeopleLayout.mediaTabletColumns
    : exploreMediaColumns(width);

SliverGridDelegate _delegate(int columns) =>
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisSpacing: AppExplorePeopleLayout.mediaGap,
      crossAxisSpacing: AppExplorePeopleLayout.mediaGap,
      childAspectRatio: AppExplorePeopleLayout.mediaTileAspect,
    );

/// The placeholder of a media grid whose first page is on its way: a grid of
/// plain tiles under one label ("Loading photos"), static (no animation).
class ExploreMediaGridSkeleton extends StatelessWidget {
  const ExploreMediaGridSkeleton({
    super.key,
    this.count = kExploreMediaSkeletonCount,
    this.semanticsLabel = 'Loading photos',
  });

  final int count;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final color = Theme.of(context).colorScheme.surfaceContainerHigh;
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            0,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => GridView.builder(
              primary: false,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: _delegate(
                trendingMediaColumns(windowWidth, constraints.maxWidth),
              ),
              itemCount: count,
              itemBuilder: (context, _) => ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Media section of the Trending tab: the newest photos (or the newest of
/// the selected hashtag) as a grid, with the loading, empty, stalled, failed
/// and end states of the design. [slivers] draws the cubit's current state
/// inside a `TrendingSectionScroll`; the cubit is started by its owner.
class TrendingMediaSection {
  const TrendingMediaSection({
    required this.cubit,
    required this.tag,
    required this.onClearFilter,
  });

  final TrendingMediaCubit cubit;
  final String? tag;
  final VoidCallback onClearFilter;

  List<Widget> slivers(BuildContext context, TrendingSliverWrap wrap) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final state = cubit.state;
    Widget one(Widget child) => wrap(SliverToBoxAdapter(child: child));
    return switch (state.status) {
      ExploreMediaStatus.initial || ExploreMediaStatus.loading => [
        one(const ExploreMediaGridSkeleton()),
      ],
      ExploreMediaStatus.unavailable => [
        const SliverToBoxAdapter(child: SizedBox.shrink()),
      ],
      ExploreMediaStatus.failed => [
        one(TrendingFailureView(error: state.error, onRetry: cubit.retry)),
      ],
      ExploreMediaStatus.ready => [
        if (state.notice != null && state.tiles.isNotEmpty)
          one(
            AppNoticeBanner(
              message: "Couldn't refresh. Showing the last photos.",
              onRetry: cubit.refresh,
            ),
          ),
        if (state.tiles.isEmpty)
          one(_empty(state))
        else ...[
          wrap(
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                0,
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) => SliverGrid.builder(
                  gridDelegate: _delegate(
                    trendingMediaColumns(
                      windowWidth,
                      constraints.crossAxisExtent,
                    ),
                  ),
                  itemCount: state.tiles.length,
                  itemBuilder: (context, i) {
                    final tile = state.tiles[i];
                    return ExploreMediaTileView(
                      key: ValueKey('trending-media-${tile.postId}'),
                      tile: tile,
                      onOpen: () => openExploreMediaTile(context, tile),
                    );
                  },
                ),
              ),
            ),
          ),
          one(_footer(state)),
        ],
      ],
    };
  }

  Widget _empty(ExploreMediaState state) {
    if (state.stalled) {
      return TrendingStalledView(
        noun: 'photos',
        onLoadMore: cubit.continueAfterStall,
      );
    }
    if (state.pagingFailed) return _footer(state);
    if (state.hasMore) return const ExploreMediaGridSkeleton();
    return TrendingEmptyView(
      icon: Icons.photo_library_outlined,
      noun: 'photos',
      emptySubtitle: 'Photos people post show up here.',
      tag: tag,
      onClearFilter: onClearFilter,
    );
  }

  Widget _footer(ExploreMediaState state) => TrendingFooter(
    loadingMore: state.loadingMore,
    pagingFailed: state.pagingFailed,
    stalled: state.stalled,
    failedText: "More photos couldn't be loaded.",
    failedLabel: 'Retry',
    stalledLabel: 'Show more photos',
    onRetry: cubit.retryMore,
    onLoadMore: cubit.continueAfterStall,
  );
}
