import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../data/search_repository.dart';
import 'bloc/explore_media_cubit.dart';
import 'bloc/explore_media_state.dart';
import 'bloc/search_results_cubit.dart' show searchErrorToApp;
import 'bloc/trends_cubit.dart';
import 'bloc/trends_state.dart';
import 'widgets/explore_media_section.dart';
import 'widgets/explore_media_tile.dart';
import 'widgets/trends_loader.dart';

/// `/explore/media`: Explore's "See all" for Media, a grid of the same merged
/// photos, newest first. [cubit] is Explore's, handed over by the route's
/// `extra`, so the photos are already here and nothing is asked again; with
/// none (a link, a reload) the page makes its own and starts it from the
/// shared trends. Scrolling near the end follows each tag's page token
/// ([ExploreMediaCubit.loadMore]). The route needs `search`, `media`, `trends`
/// and `ui_shell`.
class ExploreMediaScreen extends StatefulWidget {
  const ExploreMediaScreen({super.key, this.cubit});

  final ExploreMediaCubit? cubit;

  @override
  State<ExploreMediaScreen> createState() => _ExploreMediaScreenState();
}

class _ExploreMediaScreenState extends State<ExploreMediaScreen> {
  ExploreMediaCubit? _own;
  final _scroll = ScrollController();

  late final ExploreMediaCubit _cubit = () {
    final given = widget.cubit;
    if (given != null && !given.isClosed) return given;
    return _own = ExploreMediaCubit(
      repository: context.read<SearchRepository>(),
    );
  }();

  @override
  void dispose() {
    _scroll.dispose();
    _own?.close();
    super.dispose();
  }

  /// Asks the next pages near the end, and when the grid does not fill the
  /// view (short or empty pages).
  void _fill() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < _nearEnd(context)) {
      _cubit.loadMore();
    }
  }

  static double _nearEnd(BuildContext context) =>
      MediaQuery.sizeOf(context).height;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppMainColumn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBackHeader(
                title: 'Media',
                onBack: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRouter.explorePath),
              ),
              Expanded(
                child: TrendsLoader(
                  child: ExploreMediaStarter(
                    cubit: _cubit,
                    child: BlocConsumer<ExploreMediaCubit, ExploreMediaState>(
                      bloc: _cubit,
                      listener: (_, _) => WidgetsBinding.instance
                          .addPostFrameCallback((_) => _fill()),
                      builder: (context, state) => _body(context, state),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ExploreMediaState state) {
    switch (state.status) {
      case ExploreMediaStatus.initial:
      case ExploreMediaStatus.loading:
        // No trends to draw from: nothing will ever load, say so.
        final trends = context.watch<TrendsCubit>().state;
        if (state.status == ExploreMediaStatus.initial &&
            trends.status == TrendsStatus.ready &&
            trends.trends.isEmpty) {
          return const AppEmptyView(
            icon: Icons.photo_library_outlined,
            title: 'No photos yet',
            subtitle: 'Photos from trending hashtags show up here.',
          );
        }
        return _Grid(
          controller: _scroll,
          count: 9,
          itemBuilder: (context, _) => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
          semanticLabel: 'Loading media',
        );
      case ExploreMediaStatus.failed:
        return AppErrorView(
          error: searchErrorToApp(state.error ?? ''),
          onRetry: _cubit.retry,
        );
      case ExploreMediaStatus.unavailable:
      case ExploreMediaStatus.ready:
        if (state.tiles.isEmpty && !state.hasMore) {
          return const AppEmptyView(
            icon: Icons.photo_library_outlined,
            title: 'No photos yet',
            subtitle: 'Photos from trending hashtags show up here.',
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < _nearEnd(context)) _cubit.loadMore();
            return false;
          },
          child: _Grid(
            controller: _scroll,
            count: state.tiles.length,
            itemBuilder: (context, i) => ExploreMediaTileView(
              key: ValueKey('explore-media-${state.tiles[i].postId}'),
              tile: state.tiles[i],
              onOpen: () => openExploreMediaTile(context, state.tiles[i]),
            ),
            footer: state.pagingFailed
                ? _PagingFailed(error: state.error, onRetry: _cubit.retryMore)
                : state.loadingMore || state.hasMore
                ? const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: SizedBox.square(
                        dimension: AppSpacing.lg,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : null,
          ),
        );
    }
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.controller,
    required this.count,
    required this.itemBuilder,
    this.footer,
    this.semanticLabel,
  });

  final ScrollController controller;
  final int count;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? footer;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final columns = exploreMediaColumns(constraints.maxWidth);
        return CustomScrollView(
          controller: controller,
          primary: false,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                0,
              ),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppExplorePeopleLayout.mediaGap,
                  crossAxisSpacing: AppExplorePeopleLayout.mediaGap,
                  childAspectRatio: AppExplorePeopleLayout.mediaTileAspect,
                ),
                itemCount: count,
                itemBuilder: (context, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: itemBuilder(context, i),
                ),
              ),
            ),
            if (footer != null) SliverToBoxAdapter(child: footer),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),
            const ShellBottomInsetSliver(),
          ],
        );
      },
    );
    return semanticLabel == null
        ? grid
        : Semantics(
            label: semanticLabel,
            child: ExcludeSemantics(child: grid),
          );
  }
}

class _PagingFailed extends StatelessWidget {
  const _PagingFailed({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            Text(
              "More photos couldn't be loaded.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTapTarget),
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
