import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/pending_posts_section.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../../../shared/widgets/post_pin_control.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import 'bloc/timeline_cubit.dart';
import 'bloc/timeline_state.dart';
import 'timeline_error_messages.dart';
import 'widgets/feed_post_row.dart';
import 'widgets/new_posts_pill.dart';
import '../../../shared/widgets/timeline_gap_row.dart';

/// How often the foreground tick fires: it re-renders relative times
/// ("5m", no RPC) and asks the cubit for a throttled refresh, which sends at
/// most one request per `kAutoRefreshInterval`. Stopped while backgrounded.
const kFeedTickInterval = Duration(seconds: 30);

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
    this.emptyAction,
    this.headerSlivers = const [],
    this.showPending = true,
    this.pendingAuthorId,
    this.hideAuthorsOnRelationship = true,
    this.onRelationshipChanged,
    this.newPostsPillTop = kToolbarHeight + AppSpacing.sm,
    this.nested = false,
    this.scrollViewKey,
    this.fillViewport = false,
    this.pinControl,
    this.hideEmptyState = false,
    this.unavailableView,
    this.active = true,
  });

  /// Whether this feed is the one on screen. A feed kept alive behind another
  /// (the Home tabs, W5-14) passes false: its 30 s tick and resume refresh
  /// stand still, and becoming active again asks once for the throttled
  /// refresh (no RPC when it was refreshed less than 60 s ago).
  final bool active;

  /// What a feed the server calls NOT_FOUND shows (a private or deleted List,
  /// `TimelineState.unavailable`). Null = a plain "unavailable" empty view.
  final Widget? unavailableView;

  final String? viewerUserId;
  final String emptyTitle;
  final String? emptySubtitle;

  /// An optional call to action under the empty state (a pill button).
  final Widget? emptyAction;

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

  /// Where the floating "N new posts" pill sits, from the top: just under the
  /// screen's header. It floats, so it never shifts the list.
  final double newPostsPillTop;

  /// Inside a `NestedScrollView` body (the profile tabs): the feed scrolls on
  /// the nested view's inner controller (so the screen's header collapses
  /// with it), starts with a `SliverOverlapInjector`, and leaves pull-to-
  /// refresh to the screen: a body's own `RefreshIndicator` never sees the
  /// overscroll of a nested scroll, so the screen wraps the whole nested view.
  final bool nested;

  /// Key of the scroll view; give a `PageStorageKey` in a nested body so the
  /// tab keeps its offset while another tab is shown.
  final Key? scrollViewKey;

  /// Follow `next_page_token` while the rows do not fill the view (and never
  /// show the empty state while a next page exists). A page can be shorter
  /// than asked, or empty, and still carry a token (the server drops cards
  /// whose embedded author the caller blocks or mutes: the profile Reposts
  /// and Media tabs, ADR-0024 D5); a view that is not tall enough to scroll
  /// would never ask for the next page. Off for Home and the Posts and
  /// Replies tabs, whose pages are full.
  final bool fillViewport;

  /// Pin / Unpin rows on the viewer's own posts (W3-17): the own profile
  /// passes one; every other feed leaves it null.
  final PostPinControl? pinControl;

  /// Show nothing instead of the empty state: the profile's Posts tab when
  /// its only post is the one in the Pinned row above.
  final bool hideEmptyState;

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

  @override
  void didUpdateWidget(TimelineFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      // Not during the build: the refresh emits at once.
      WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    }
  }

  void _tick() {
    if (!mounted || !widget.active) return;
    // Relative times have minute granularity, so rebuild the feed only when a
    // minute boundary was crossed, not on every 30 s tick.
    final now = DateTime.now();
    if (_minuteOf(now) != _minuteOf(_now)) setState(() => _now = now);
    unawaited(context.read<TimelineCubit>().refreshIfStale());
  }

  static int _minuteOf(DateTime t) =>
      t.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;

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

  /// After the rows changed and were laid out: asks for the next page while
  /// the rows leave nothing to scroll (see [TimelineFeedView.fillViewport]).
  /// The cubit ignores the ask while it is loading or after a failed page, so
  /// a failing page is retried by the user, not in a loop. While a
  /// RATE_LIMITED answer is held back the ask is skipped here too: the cubit
  /// would answer it with a new state (a new notice), which schedules the
  /// next ask, one per frame, for as long as the hold lasts.
  void _fillIfShort() {
    if (!mounted) return;
    final cubit = context.read<TimelineCubit>();
    final state = cubit.state;
    if (!state.hasMore ||
        state.loadingMore ||
        state.refreshing ||
        state.loadMoreFailed ||
        state.notice is RateLimitedException ||
        state.status == TimelineStatus.error) {
      return;
    }
    // No row at all: there is nothing to scroll (the skeleton in its place
    // may be taller than the view), so ask for the next page at once.
    if (state.entries.isEmpty) {
      unawaited(cubit.loadMore());
      return;
    }
    final controller = widget.nested
        ? PrimaryScrollController.maybeOf(context)
        : _controller;
    if (controller == null || !controller.hasClients) return;
    if (controller.position.maxScrollExtent <= 0) {
      unawaited(cubit.loadMore());
    }
  }

  void _showNewPosts(TimelineCubit cubit) {
    cubit.showNewPosts();
    // Nested: the body's own (inner) controller; the header stays as it is.
    final controller = widget.nested
        ? PrimaryScrollController.maybeOf(context)
        : _controller;
    if (controller != null && controller.hasClients) controller.jumpTo(0);
  }

  /// Nested bodies have no controller of their own: the prefetch reads the
  /// inner scroll view's notifications instead.
  bool _onNestedScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (metrics.maxScrollExtent > 0 &&
        metrics.pixels >= kPrefetchFraction * metrics.maxScrollExtent) {
      unawaited(context.read<TimelineCubit>().loadMore());
    }
    return false;
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
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final engagementEnabled = isFeatureEnabled(context, kFeatureEngagement);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap the content width on tablet/desktop, centered.
        final inset = math.max(
          0.0,
          (constraints.maxWidth - AppBreakpoints.mobile) / 2,
        );
        return BlocBuilder<TimelineCubit, TimelineState>(
          builder: (context, state) {
            final scrollView = CustomScrollView(
              key: widget.scrollViewKey,
              controller: widget.nested ? null : _controller,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (widget.nested)
                  SliverOverlapInjector(
                    handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                      context,
                    ),
                  ),
                for (final sliver in widget.headerSlivers)
                  _inset(inset, sliver),
                if (state.notice != null)
                  _inset(
                    inset,
                    SliverToBoxAdapter(
                      child: AppNoticeBanner(
                        message: timelineNoticeMessage(state.notice!),
                        onRetry: noticeCanRetry(state.notice!)
                            ? cubit.refresh
                            : null,
                      ),
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
                ..._body(
                  context,
                  cubit,
                  state,
                  inset,
                  graphEnabled,
                  reportsEnabled,
                  engagementEnabled,
                ),
              ],
            );
            final stack = Stack(
              fit: StackFit.expand,
              children: [
                if (widget.nested)
                  NotificationListener<ScrollNotification>(
                    onNotification: _onNestedScroll,
                    child: scrollView,
                  )
                else
                  RefreshIndicator(onRefresh: cubit.refresh, child: scrollView),
                if (state.newPosts > 0)
                  Positioned(
                    top: widget.newPostsPillTop,
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
            if (!widget.fillViewport) return stack;
            // After every change of the rows, once laid out.
            return BlocListener<TimelineCubit, TimelineState>(
              listener: (context, state) => WidgetsBinding.instance
                  .addPostFrameCallback((_) => _fillIfShort()),
              child: stack,
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
    bool reportsEnabled,
    bool engagementEnabled,
  ) {
    if (state.entries.isEmpty) {
      final Widget child;
      if (state.unavailable) {
        child =
            widget.unavailableView ??
            const AppEmptyView(
              icon: Icons.dynamic_feed_outlined,
              title: "This timeline is unavailable",
            );
      } else if (state.error is FeatureDisabledException) {
        child = const AppEmptyView(
          icon: Icons.dynamic_feed_outlined,
          title: "This timeline isn't available yet",
          subtitle: "Please try again in a little while.",
        );
      } else if (state.status == TimelineStatus.error && state.error != null) {
        child = AppErrorView(error: state.error!, onRetry: cubit.refresh);
      } else if (state.status == TimelineStatus.loading || state.refreshing) {
        child = const PostListSkeleton();
      } else if (widget.fillViewport && state.hasMore) {
        // No post yet but a next page exists: not empty, keep looking.
        child = state.loadMoreFailed
            ? _footer(cubit, state)
            : const PostListSkeleton();
      } else if (widget.hideEmptyState) {
        child = const SizedBox.shrink();
      } else {
        child = AppEmptyView(
          icon: Icons.dynamic_feed_outlined,
          title: widget.emptyTitle,
          subtitle: widget.emptySubtitle,
          action: widget.emptyAction,
        );
      }
      return [_inset(inset, SliverToBoxAdapter(child: child))];
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
            return FeedPostRow(
              key: key,
              view: entry.postView!,
              viewerUserId: widget.viewerUserId,
              now: _now,
              graphEnabled: graphEnabled,
              reportsEnabled: reportsEnabled,
              engagementEnabled: engagementEnabled,
              onDelete: cubit.deletePost,
              onRelationshipChanged: (r) => _onRelationship(cubit, r),
              pinControl: widget.pinControl,
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
