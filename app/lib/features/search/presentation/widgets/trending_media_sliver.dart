import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../domain/explore_media.dart';
import '../bloc/explore_media_state.dart';
import '../bloc/trending_media_cubit.dart';
import 'explore_media_section.dart'
    show exploreMediaColumns, openExploreMediaTile;
import 'explore_media_tile.dart';

/// The global media feed on the Trending page, as slivers under the trend
/// rows: a "Media" heading, a grid of the newest photos (3 to 6 per row), a
/// spinner while the next page loads, and a retry for a failed page. Loading
/// and failed first pages, an empty feed and an unavailable feed each have
/// their own view. Needs [TrendingMediaCubit] in scope.
class TrendingMediaSliver extends StatelessWidget {
  const TrendingMediaSliver({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TrendingMediaCubit, ExploreMediaState>(
      builder: (context, state) {
        final cubit = context.read<TrendingMediaCubit>();
        switch (state.status) {
          case ExploreMediaStatus.initial:
          case ExploreMediaStatus.loading:
            return const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            );
          case ExploreMediaStatus.unavailable:
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          case ExploreMediaStatus.failed:
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ExploreSubsectionHeading('Media'),
                    const Text('Photos could not load.'),
                    TextButton(
                      onPressed: cubit.retry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          case ExploreMediaStatus.ready:
            break;
        }
        final tiles = state.tiles;
        if (tiles.isEmpty) {
          return SliverToBoxAdapter(
            child: state.hasMore
                ? TextButton(
                    onPressed: cubit.loadMore,
                    child: const Text('Show more photos'),
                  )
                : const AppEmptyView(
                    icon: Icons.photo_library_outlined,
                    title: 'No photos yet',
                    subtitle: 'Photos people post show up here.',
                  ),
          );
        }
        return SliverMainAxisGroup(
          slivers: [
            const SliverToBoxAdapter(child: ExploreSubsectionHeading('Media')),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = exploreMediaColumns(
                    constraints.crossAxisExtent,
                  );
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: AppExplorePeopleLayout.mediaGap,
                      crossAxisSpacing: AppExplorePeopleLayout.mediaGap,
                      childAspectRatio: AppExplorePeopleLayout.mediaTileAspect,
                    ),
                    itemCount: tiles.length,
                    itemBuilder: (context, i) => _tile(context, tiles[i]),
                  );
                },
              ),
            ),
            if (state.loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            if (state.pagingFailed)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton(
                    onPressed: cubit.retryMore,
                    child: const Text('Try again'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static Widget _tile(BuildContext context, ExploreMediaTile tile) =>
      ExploreMediaTileView(
        key: ValueKey('trending-media-${tile.postId}'),
        tile: tile,
        onOpen: () => openExploreMediaTile(context, tile),
      );
}

/// The small heading of a sub-section of the Trending page ("Media", and on
/// desktop "Posts"): titleMedium, announced as a header.
class ExploreSubsectionHeading extends StatelessWidget {
  const ExploreSubsectionHeading(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppExplorePeopleLayout.sectionGap,
      AppSpacing.md,
      AppSpacing.xs,
    ),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}
