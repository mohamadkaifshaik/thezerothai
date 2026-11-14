import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/explore_media.dart';
import '../bloc/explore_media_cubit.dart';
import '../bloc/explore_media_state.dart';
import '../bloc/trends_cubit.dart';
import '../bloc/trends_state.dart';
import 'explore_media_tile.dart';
import 'explore_section_header.dart';

/// Opens a tile's photo viewer (the route index is 1-based).
void openExploreMediaTile(BuildContext context, ExploreMediaTile tile) =>
    context.push(AppRouter.postPhotoPath(tile.postId, tile.index + 1));

/// Starts [cubit] with the top trends once the shared list has rows, and
/// never again ([ExploreMediaCubit.start] latches), so a refreshed list or a
/// rebuild asks nothing. Needs [TrendsCubit] in scope.
class ExploreMediaStarter extends StatefulWidget {
  const ExploreMediaStarter({
    super.key,
    required this.cubit,
    required this.child,
  });

  final ExploreMediaCubit cubit;
  final Widget child;

  @override
  State<ExploreMediaStarter> createState() => _ExploreMediaStarterState();
}

class _ExploreMediaStarterState extends State<ExploreMediaStarter> {
  void _maybe(TrendsState state) {
    if (state.trends.isEmpty) return;
    widget.cubit.start([
      for (final t in state.trends.take(kExploreTopTrends)) t.tag,
    ]);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybe(context.read<TrendsCubit>().state);
    });
  }

  @override
  Widget build(BuildContext context) => BlocListener<TrendsCubit, TrendsState>(
    listener: (_, state) => _maybe(state),
    child: widget.child,
  );
}

/// The "Media" section of Explore, as a sliver: a header with "See all >"
/// ([AppRouter.exploreMediaPath], handing over [cubit] so the page keeps
/// the same photos and asks nothing again) over one row of the newest photos
/// (as many as fit at about [AppExplorePeopleLayout.mediaTileTarget] dp,
/// 3 to 6). Draws nothing while loading, failed or empty. Mount it only with
/// `search`, `media` and `trends` on.
class ExploreMediaSection extends StatelessWidget {
  const ExploreMediaSection({super.key, required this.cubit});

  final ExploreMediaCubit cubit;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ExploreMediaCubit, ExploreMediaState>(
      bloc: cubit,
      builder: (context, state) {
        if (state.status != ExploreMediaStatus.ready || state.tiles.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final tiles = state.tiles;
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(
              top: AppExplorePeopleLayout.sectionGap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExploreSectionHeader(
                  title: 'Media',
                  onSeeAll: () =>
                      context.push(AppRouter.exploreMediaPath, extra: cubit),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                    0,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = exploreMediaColumns(constraints.maxWidth);
                      final shown = tiles.take(columns).toList();
                      const gap = AppExplorePeopleLayout.mediaGap;
                      final side =
                          (constraints.maxWidth - gap * (columns - 1)) /
                          columns;
                      return Row(
                        children: [
                          for (var i = 0; i < shown.length; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            SizedBox(
                              width: side,
                              height:
                                  side / AppExplorePeopleLayout.mediaTileAspect,
                              child: ExploreMediaTileView(
                                key: ValueKey(
                                  'explore-media-${shown[i].postId}',
                                ),
                                tile: shown[i],
                                onOpen: () =>
                                    openExploreMediaTile(context, shown[i]),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Tiles per row for a row [width] dp wide: about
/// [AppExplorePeopleLayout.mediaTileTarget] dp each, 3 to 6.
int exploreMediaColumns(double width) => math.max(
  AppExplorePeopleLayout.mediaMinColumns,
  math.min(
    AppExplorePeopleLayout.mediaMaxColumns,
    (width / AppExplorePeopleLayout.mediaTileTarget).floor(),
  ),
);
