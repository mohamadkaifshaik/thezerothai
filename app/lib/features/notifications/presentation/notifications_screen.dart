import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../shared/widgets/post/post_list_skeleton.dart';
import '../../../shared/widgets/post/timeline_gap_row.dart';
import '../../beacons/domain/beacons_feature_flag.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/graph_error_messages.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../data/notifications_repository.dart';
import '../domain/notification_location.dart';
import '../domain/notifications_feature_flag.dart';
import 'bloc/follow_back_cubit.dart';
import 'bloc/follow_requests_preview_cubit.dart';
import 'bloc/notifications_cubit.dart';
import 'bloc/push_cubit.dart';
import 'bloc/unread_badge_cubit.dart';
import 'notifications_error_messages.dart';
import 'widgets/follow_back_button.dart';
import 'widgets/follow_requests_card.dart';
import 'widgets/follow_requests_row.dart';
import 'widgets/notification_row.dart';
import 'widgets/push_opt_in_card.dart';
import 'widgets/notification_settings_action.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';

/// `/notifications`: the cached list renders at once, one
/// throttled `since_token` refresh follows, and opening it marks everything
/// seen (once per refresh). With the `notifications` flag off, the Phase 0
/// placeholder shows (the route also redirects away).
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureNotifications)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications'), centerTitle: true),
        body: const Center(
          child: AppEmptyView(
            icon: Icons.notifications_none,
            title: "Notifications aren't available yet",
          ),
        ),
      );
    }
    return BlocProvider<NotificationsCubit>(
      create: (context) => NotificationsCubit(
        repository: context.read<NotificationsRepository>(),
        badge: context.read<UnreadBadgeCubit>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: const _NotificationsView(),
    );
  }
}

/// The tabs of `/notifications` (the design's order): All, Plans (F15, with
/// `beacons` on), Mentions. Plans and Mentions filter the loaded rows; they
/// ask the server for nothing extra.
enum NotificationsTab {
  all('All'),
  plans('Plans'),
  mentions('Mentions');

  const NotificationsTab(this.label);

  final String label;
}

/// The tabs the caller sees: Plans only with `beacons` on (the screen itself
/// needs `notifications`).
List<NotificationsTab> notificationsTabsFor(BuildContext context) => [
  NotificationsTab.all,
  if (isFeatureEnabled(context, kFeatureBeacons)) NotificationsTab.plans,
  NotificationsTab.mentions,
];

class _NotificationsView extends StatefulWidget {
  const _NotificationsView();

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView>
    with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  late DateTime _now = DateTime.now();

  /// A filter of the loaded rows, no extra RPC. A tab that goes away (Plans
  /// when `beacons` turns off) falls back to All.
  NotificationsTab _tab = NotificationsTab.all;

  /// F14: the relationship to each follow row's actor, one batched
  /// `GetRelationships` per page (made on first use, with `graph` on).
  FollowBackCubit? _followBackCubit;
  FollowBackCubit get _followBack => _followBackCubit ??= FollowBackCubit(
    graph: context.read<GraphRepository>(),
  );

  /// F16: the follow-requests card beside the page (tablet band B's pane,
  /// the desktop side column), made on first use and asked for only while it
  /// shows.
  FollowRequestsPreviewCubit? _requestsCubit;
  FollowRequestsPreviewCubit get _requests => _requestsCubit ??=
      FollowRequestsPreviewCubit(graph: context.read<GraphRepository>());
  final _paneLease = ContextPaneLease();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The card the pane or the side column draws, over this page's own
    // cubit (no call of the pane's own).
    _paneLease.attach(context, AppRouter.notificationsPath, {
      ContextSectionKind.followRequests: (context) =>
          BlocBuilder<FollowRequestsPreviewCubit, FollowRequestsPreviewState>(
            bloc: _requests,
            builder: (context, state) => FollowRequestsCard(
              state: state,
              onAccept: _accept,
              onRetry: _requests.reload,
            ),
          ),
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    _paneLease.dispose();
    _requestsCubit?.close();
    _followBackCubit?.close();
    super.dispose();
  }

  void _say(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  /// Accept from the card: as on the Follow requests page, the count goes
  /// down once the server took it, and "Follow back" is offered when the
  /// caller does not follow the requester yet.
  Future<void> _accept(graph.UserListItem item) async {
    final onboarding = context.read<OnboardingBloc>();
    final graphRepository = context.read<GraphRepository>();
    final result = await _requests.accept(item);
    if (result == null) return;
    final handle = item.user.handle;
    switch (result) {
      case FollowRequestAccepted(:final relationship):
        onboarding.add(const OnboardingFollowRequestAnswered());
        if (!mounted) return;
        final followsAlready =
            relationship.followState ==
                graph.FollowState.FOLLOW_STATE_FOLLOWING ||
            relationship.followState ==
                graph.FollowState.FOLLOW_STATE_REQUESTED;
        if (followsAlready) {
          _say('Accepted @$handle.');
        } else {
          _say(
            '@$handle can now see your posts.',
            action: SnackBarAction(
              label: 'Follow back',
              onPressed: () =>
                  _followBackFromSnack(graphRepository, item.user.userId),
            ),
          );
        }
      case FollowRequestAcceptFailed(:final error):
        if (!mounted) return;
        _say(followRequestErrorMessage(error, handle: handle));
    }
  }

  Future<void> _followBackFromSnack(
    GraphRepository graphRepository,
    String userId,
  ) async {
    try {
      await graphRepository.follow(
        userId: userId,
        idempotencyKey: const Uuid().v4(),
      );
    } on AppException catch (e) {
      if (!mounted) return;
      _say(relationshipErrorMessage(e));
    }
  }

  /// Whether a page of rows has landed between [a] and [b] (the cache, a
  /// refresh, an older page, a filled gap): F14 asks once for its new follow
  /// actors, never while a fetch is still running.
  static bool _pageLanded(NotificationsState a, NotificationsState b) =>
      !b.refreshing &&
      !b.loadingMore &&
      b.loadingGapKey == null &&
      (!identical(a.entries, b.entries) ||
          a.refreshing != b.refreshing ||
          a.loadingMore != b.loadingMore ||
          a.loadingGapKey != b.loadingGapKey);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume only: never poll in the background or on a timer.
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _now = DateTime.now());
      unawaited(context.read<NotificationsCubit>().refreshIfStale());
    }
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent > 0 &&
        position.pixels >= kPrefetchFraction * position.maxScrollExtent) {
      unawaited(context.read<NotificationsCubit>().loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NotificationsCubit>();
    final tabs = notificationsTabsFor(context);
    final tab = tabs.contains(_tab) ? _tab : NotificationsTab.all;
    final followBack = isGraphEnabled(context);
    // F16: asked for only while the card shows beside the page, which needs
    // pending requests (its rule); a later call does nothing.
    if (followRequestsCardBeside(context)) unawaited(_requests.loadOnce());
    // F14 turned on after a page landed (a GetMe refresh): ask for what is
    // already loaded, so no reserved line waits forever. Deduplicated, and
    // never again for a failed actor (only a new page retries those), so a
    // later build costs nothing.
    if (followBack) {
      final loaded = cubit.state;
      if (!loaded.refreshing && loaded.entries.isNotEmpty) {
        unawaited(_followBack.resolve(loaded.entries, retryFailed: false));
      }
    }
    return MultiBlocListener(
      listeners: [
        BlocListener<PushCubit, PushState>(
          // An FCM nudge while the screen is open: one throttled refresh.
          listenWhen: (a, b) => b.received > a.received,
          listener: (context, _) => unawaited(cubit.refreshIfStale()),
        ),
        BlocListener<NotificationsCubit, NotificationsState>(
          // F14 (`graph` on): once a page has landed, one batched ask for
          // its new follow actors.
          listenWhen: (a, b) => followBack && _pageLanded(a, b),
          listener: (context, state) =>
              unawaited(_followBack.resolve(state.entries)),
        ),
      ],
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final inset = ShellGeometry.readableInset(
              context,
              constraints.maxWidth,
            );
            return BlocBuilder<NotificationsCubit, NotificationsState>(
              builder: (context, state) {
                return RefreshIndicator(
                  onRefresh: cubit.refresh,
                  child: CustomScrollView(
                    controller: _controller,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      AppTopBar.sliver(
                        title: 'Notifications',
                        actions: const [NotificationSettingsAction()],
                      ),
                      _inset(
                        inset,
                        SliverToBoxAdapter(
                          // The tabs sit in the reading column; on the
                          // tablet layout their hairline spans the pane.
                          child: AppMainColumnBleed(
                            bleed: inset,
                            child: AppTabBar(
                              equalWidth: _tabsFitEqually(
                                context,
                                tabs,
                                constraints.maxWidth - 2 * inset,
                              ),
                              semanticLabel: 'Notifications timelines',
                              selectedIndex: tabs.indexOf(tab),
                              onChanged: (index) =>
                                  setState(() => _tab = tabs[index]),
                              tabs: [
                                for (final t in tabs) AppTab(label: t.label),
                              ],
                            ),
                          ),
                        ),
                      ),
                      _inset(
                        inset,
                        const SliverToBoxAdapter(child: FollowRequestsRow()),
                      ),
                      _inset(
                        inset,
                        const SliverToBoxAdapter(
                          child: PushOptInCard(
                            placement: PushOptInPlacement.notifications,
                          ),
                        ),
                      ),
                      if (state.notice != null)
                        _inset(
                          inset,
                          SliverToBoxAdapter(
                            child: AppNoticeBanner(
                              message: notificationsNoticeMessage(
                                state.notice!,
                              ),
                              onRetry: noticeCanRetry(state.notice!)
                                  ? cubit.refresh
                                  : null,
                            ),
                          ),
                        ),
                      ..._body(context, cubit, state, inset, tab, followBack),
                      const ShellBottomInsetSliver(),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Whether every tab label, at the bold weight and the user's text scale,
  /// fits its equal share of [width] (with 4 dp of air). Otherwise the tabs
  /// size to their labels and the bar scrolls (three labels at 360 dp x2.0),
  /// so no label is ever ellipsized.
  static bool _tabsFitEqually(
    BuildContext context,
    List<NotificationsTab> tabs,
    double width,
  ) {
    final style = Theme.of(context).textTheme.titleSmall
        ?.copyWith(fontWeight: FontWeight.w700);
    final share = width / tabs.length;
    for (final tab in tabs) {
      final painter = TextPainter(
        text: TextSpan(text: tab.label, style: style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final fits = painter.width + AppSpacing.xs <= share;
      painter.dispose();
      if (!fits) return false;
    }
    return true;
  }

  Widget _inset(double inset, Widget sliver) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: inset),
    sliver: sliver,
  );

  List<Widget> _body(
    BuildContext context,
    NotificationsCubit cubit,
    NotificationsState state,
    double inset,
    NotificationsTab tab,
    bool followBack,
  ) {
    if (!state.hasNotifications) {
      final Widget child;
      if (state.status == NotificationsStatus.error && state.error != null) {
        child = AppErrorView(error: state.error!, onRetry: cubit.refresh);
      } else if (state.status == NotificationsStatus.loading ||
          state.refreshing) {
        child = const PostListSkeleton(semanticsLabel: 'Loading notifications');
      } else {
        child = const AppEmptyView(
          icon: Icons.notifications_none,
          title: 'No notifications yet',
          subtitle: 'New followers, mentions and replies will show up here.',
        );
      }
      return [_inset(inset, SliverToBoxAdapter(child: child))];
    }
    // Plans and Mentions filter the loaded rows (gap markers stay so a gap
    // can still be filled); they ask the server for nothing extra.
    final bool Function(NotificationType)? filter = switch (tab) {
      NotificationsTab.all => null,
      NotificationsTab.plans => isPlanType,
      NotificationsTab.mentions => isMentionType,
    };
    final entries = filter == null
        ? state.entries
        : [
            for (final e in state.entries)
              if (e.isGap || filter(e.value!.type)) e,
          ];
    if (filter != null && !entries.any((e) => !e.isGap)) {
      final empty = tab == NotificationsTab.plans
          ? const AppEmptyView(
              icon: Icons.event_outlined,
              title: 'No plan updates yet',
              subtitle:
                  'When someone asks to join your plan, or a plan you '
                  'joined changes, it will show up here.',
            )
          : const AppEmptyView(
              icon: Icons.alternate_email,
              title: 'No mentions yet',
              subtitle:
                  'When someone mentions you or replies to you, it will '
                  'show up here.',
            );
      return [
        _inset(
          inset,
          SliverToBoxAdapter(
            child: Column(
              children: [
                empty,
                if (state.hasMore)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppSpacing.minTapTarget),
                    ),
                    onPressed: state.loadingMore ? null : cubit.loadMore,
                    child: const Text('Look through older notifications'),
                  ),
              ],
            ),
          ),
        ),
      ];
    }
    final since = state.highlightSince;
    return [
      _inset(
        inset,
        SliverList.builder(
          itemCount: entries.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = entries.indexWhere(
              (e) => 'notification-${e.itemKey}' == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final entry = entries[index];
            final key = ValueKey('notification-${entry.itemKey}');
            if (entry.isGap) {
              return TimelineGapRow(
                key: key,
                noun: 'notifications',
                loading: state.loadingGapKey == entry.itemKey,
                onTap: () => cubit.fillGap(entry.itemKey),
              );
            }
            final n = entry.value!;
            final created = n.hasCreatedAt() ? n.createdAt.toDateTime() : null;
            final unread =
                created != null && (since == null || created.isAfter(since));
            final location = notificationLocation(
              type: notificationTypeWire(n.type),
              postId: n.postId,
              actorId: n.actor.userId,
              beaconId: n.beaconId,
            );
            final followBackActor = followBack ? followBackActorOf(n) : null;
            return Column(
              key: key,
              mainAxisSize: MainAxisSize.min,
              children: [
                NotificationRow(
                  notification: n,
                  unread: unread,
                  now: _now,
                  onTap: () {
                    if (location != null) context.push(location);
                  },
                  action: followBackActor == null
                      ? null
                      : FollowBackSlot(
                          // Keyed by the actor: each row owns the cubit of
                          // its button.
                          key: ValueKey('follow-back-$followBackActor'),
                          cubit: _followBack,
                          actorId: followBackActor,
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

  Widget _footer(NotificationsCubit cubit, NotificationsState state) {
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
            child: const Text("Couldn't load more. Retry"),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.lg);
  }
}
