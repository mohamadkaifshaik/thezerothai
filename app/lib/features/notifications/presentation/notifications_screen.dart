import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../../../shared/widgets/timeline_gap_row.dart';
import '../data/notifications_repository.dart';
import '../domain/notification_location.dart';
import '../domain/notifications_feature_flag.dart';
import 'bloc/notifications_cubit.dart';
import 'bloc/push_cubit.dart';
import 'bloc/unread_badge_cubit.dart';
import 'notifications_error_messages.dart';
import 'widgets/notification_row.dart';

/// `/notifications` (P6, ADR-0017): the cached list renders at once, one
/// throttled `since_token` refresh follows, and opening it marks everything
/// seen (once per refresh). With the `notifications` flag off, the Phase 0
/// placeholder shows (the route also redirects away).
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureNotifications)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
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

class _NotificationsView extends StatefulWidget {
  const _NotificationsView();

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView>
    with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  late DateTime _now = DateTime.now();

  /// 0 = All, 1 = Mentions: a filter of the loaded rows, no extra RPC.
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

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
    return BlocListener<PushCubit, PushState>(
      // An FCM nudge while the screen is open: one throttled refresh.
      listenWhen: (a, b) => b.received > a.received,
      listener: (context, _) => unawaited(cubit.refreshIfStale()),
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final inset = math.max(
              0.0,
              (constraints.maxWidth - AppBreakpoints.mobile) / 2,
            );
            return BlocBuilder<NotificationsCubit, NotificationsState>(
              builder: (context, state) {
                return RefreshIndicator(
                  onRefresh: cubit.refresh,
                  child: CustomScrollView(
                    controller: _controller,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      AppTopBar.sliver(title: 'Notifications'),
                      _inset(
                        inset,
                        SliverToBoxAdapter(
                          child: AppTabBar(
                            equalWidth: true,
                            semanticLabel: 'Notifications timelines',
                            selectedIndex: _tab,
                            onChanged: (index) => setState(() => _tab = index),
                            tabs: const [
                              AppTab(label: 'All'),
                              AppTab(label: 'Mentions'),
                            ],
                          ),
                        ),
                      ),
                      _inset(inset, const _PushPrompt()),
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
                      ..._body(context, cubit, state, inset),
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

  Widget _inset(double inset, Widget sliver) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: inset),
    sliver: sliver,
  );

  List<Widget> _body(
    BuildContext context,
    NotificationsCubit cubit,
    NotificationsState state,
    double inset,
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
    final mentions = _tab == 1;
    // The Mentions tab filters the loaded rows (gap markers stay so a gap
    // can still be filled); it asks the server for nothing extra.
    final entries = mentions
        ? [
            for (final e in state.entries)
              if (e.isGap || isMentionType(e.value!.type)) e,
          ]
        : state.entries;
    if (mentions && !entries.any((e) => !e.isGap)) {
      return [
        _inset(
          inset,
          SliverToBoxAdapter(
            child: Column(
              children: [
                const AppEmptyView(
                  icon: Icons.alternate_email,
                  title: 'No mentions yet',
                  subtitle:
                      'When someone mentions you or replies to you, it will '
                      'show up here.',
                ),
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
              type: n.type == NotificationType.NOTIFICATION_TYPE_FOLLOW
                  ? kNotificationTypeFollow
                  : '',
              postId: n.postId,
              actorId: n.actor.userId,
            );
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

/// The in-app push prompt: shown only where push exists (iOS/Android), only
/// while the OS has not been asked. The OS dialog opens on the tap, never at
/// app start.
class _PushPrompt extends StatelessWidget {
  const _PushPrompt();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PushCubit, PushState>(
      buildWhen: (a, b) => a.canPrompt != b.canPrompt,
      builder: (context, state) {
        if (!state.canPrompt) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  color: colors.primary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'Get a heads-up when someone follows or mentions you.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTapTarget),
                  ),
                  onPressed: () => context.read<PushCubit>().enable(),
                  child: const Text('Turn on'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
