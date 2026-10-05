import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/pending_posts_section.dart';
import '../../../shared/widgets/post_card.dart';
import '../../graph/domain/graph_feature_flag.dart';
import 'bloc/timeline_cubit.dart';
import 'bloc/timeline_state.dart';
import 'timeline_error_messages.dart';
import 'widgets/new_posts_pill.dart';
import 'widgets/timeline_gap_row.dart';

/// How often the foreground tick fires: it re-renders relative times
/// ("5m", no RPC) and asks the cubit for a throttled refresh, which sends at
/// most one request per `kAutoRefreshInterval`. Stopped while backgrounded.
const kFeedTickInterval = Duration(seconds: 30);

/// Fraction of the scroll extent after which the next page is prefetched.
const kPrefetchFraction = 0.7;

/// The scrolling body of a cached feed (T17 Home, T18 profile Posts tab):
/// pull-to-refresh, "N new posts" pill, non-blocking notice, optimistic
/// pending posts, gap rows, infinite scroll and the empty state. It reads the
/// [TimelineCubit] above it and renders everything as slivers, so a screen
/// can put its own [headerSlivers] (the profile header) above the posts.
///
/// - Foreground only: the tick timer stops when the app leaves the
///   foreground and a resume asks for a throttled refresh (no polling).
/// - Cards are rebuilt every tick with a fresh `now`, so "5m" does not go
///   stale while the list stays open.
/// - Post cards open `/post/:id` on tap.
class TimelineFeedView extends StatefulWidget {
  const TimelineFeedView({
    super.key,
    required this.viewerUserId,
    required this.emptyTitle,
    this.emptySubtitle,
    this.headerSlivers = const [],
    this.showPending = true,
    this.pendingAuthorId,
    this.hideAuthorsOnRelationship = true,
    this.onRelationshipChanged,
  });

  final String? viewerUserId;
  final String emptyTitle;
  final String? emptySubtitle;

  /// Slivers shown above the posts (they scroll with the feed).
  final List<Widget> headerSlivers;

  /// Show the viewer's optimistic posts above the feed (T16).
  final bool showPending;

  /// Only show pending posts of this author (the own profile); null shows
  /// all (Home).
  final String? pendingAuthorId;

  /// Home hides a post's author after Block/Mute and restores them after
  /// Unblock/Unmute (ADR-0010 D6). A profile keeps its posts.
  final bool hideAuthorsOnRelationship;

  /// Also told about every Block/Mute/Unblock/Unmute result.
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  @override
  State<TimelineFeedView> createState() => _TimelineFeedViewState();
}

class _TimelineFeedViewState extends State<TimelineFeedView>
    with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  Timer? _ticker;
  late DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
    _startTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(kFeedTickInterval, (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
    unawaited(context.read<TimelineCubit>().refreshIfStale());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!mounted) return;
      _startTicker();
      _tick();
    } else {
      // Never poll in the background.
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent > 0 &&
        position.pixels >= kPrefetchFraction * position.maxScrollExtent) {
      unawaited(context.read<TimelineCubit>().loadMore());
    }
  }

  void _showNewPosts(TimelineCubit cubit) {
    cubit.showNewPosts();
    if (_controller.hasClients) _controller.jumpTo(0);
  }

  void _onRelationship(TimelineCubit cubit, graph.Relationship relationship) {
    // The request can outlive the card and the screen: act on the cubit
    // (guarded), never on a BuildContext.
    if (!cubit.isClosed && widget.hideAuthorsOnRelationship) {
      if (relationship.blocking || relationship.muting) {
        cubit.hideAuthor(relationship.userId);
      } else {
        cubit.restoreAuthor(relationship.userId);
      }
    }
    widget.onRelationshipChanged?.call(relationship);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TimelineCubit>();
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap the content width on tablet/desktop, centered.
        final inset = math.max(
          0.0,
          (constraints.maxWidth - AppBreakpoints.mobile) / 2,
        );
        return BlocBuilder<TimelineCubit, TimelineState>(
          builder: (context, state) {
            return Stack(
              fit: StackFit.expand,
              children: [
                RefreshIndicator(
                  onRefresh: cubit.refresh,
                  child: CustomScrollView(
                    controller: _controller,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      for (final sliver in widget.headerSlivers)
                        _inset(inset, sliver),
                      if (state.notice != null)
                        _inset(
                          inset,
                          SliverToBoxAdapter(
                            child: _NoticeBanner(error: state.notice!),
                          ),
                        ),
                      if (widget.showPending)
                        _inset(
                          inset,
                          SliverToBoxAdapter(
                            child: PendingPostsSection(
                              authorId: widget.pendingAuthorId,
                            ),
                          ),
                        ),
                      ..._body(context, cubit, state, inset, graphEnabled),
                    ],
                  ),
                ),
                if (state.newPosts > 0)
                  Positioned(
                    top: AppSpacing.sm,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: NewPostsPill(
                        count: state.newPosts,
                        onTap: () => _showNewPosts(cubit),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _inset(double inset, Widget sliver) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: inset),
    sliver: sliver,
  );

  List<Widget> _body(
    BuildContext context,
    TimelineCubit cubit,
    TimelineState state,
    double inset,
    bool graphEnabled,
  ) {
    if (state.entries.isEmpty) {
      final Widget child;
      if (state.status == TimelineStatus.error && state.error != null) {
        child = AppErrorView(error: state.error!, onRetry: cubit.refresh);
      } else if (state.status == TimelineStatus.loading || state.refreshing) {
        child = const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: CircularProgressIndicator(),
          ),
        );
      } else {
        child = _EmptyView(
          title: widget.emptyTitle,
          subtitle: widget.emptySubtitle,
        );
      }
      return [
        _inset(inset, SliverToBoxAdapter(child: child)),
      ];
    }
    final entries = state.entries;
    return [
      _inset(
        inset,
        SliverList.builder(
          itemCount: entries.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = entries.indexWhere(
              (e) => 'row-${e.itemKey}' == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final entry = entries[index];
            final key = ValueKey('row-${entry.itemKey}');
            if (entry.isGap) {
              return TimelineGapRow(
                key: key,
                loading: state.loadingGapKey == entry.itemKey,
                onTap: () => cubit.fillGap(entry.itemKey),
              );
            }
            final view = entry.postView!;
            return Column(
              key: key,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => context.push(
                    AppRouter.postPath(view.post.postId),
                  ),
                  child: PostCard(
                    view: view,
                    viewerUserId: widget.viewerUserId,
                    now: _now,
                    graphActionsEnabled: graphEnabled,
                    onDelete: cubit.deletePost,
                    onRelationshipChanged: (r) => _onRelationship(cubit, r),
                  ),
                ),
                const Divider(height: 1),
              ],
            );
          },
        ),
      ),
      _inset(inset, SliverToBoxAdapter(child: _footer(cubit, state))),
    ];
  }

  Widget _footer(TimelineCubit cubit, TimelineState state) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (state.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Center(
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: cubit.retryLoadMore,
            child: const Text("Couldn't load more posts. Retry"),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.lg);
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.error});

  final AppException error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: colors.secondaryContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Text(
          timelineNoticeMessage(error),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dynamic_feed_outlined,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle!,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
