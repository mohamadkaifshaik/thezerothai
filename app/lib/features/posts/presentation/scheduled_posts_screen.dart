import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostStatus;
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../data/posts_repository.dart';
import 'bloc/scheduled_posts_cubit.dart';
import 'bloc/scheduled_posts_state.dart';
import 'post_error_messages.dart';
import 'widgets/cancel_scheduled_dialog.dart';
import 'widgets/scheduled_post_row.dart';

/// "Nothing scheduled" with its one line of guidance. Heading over a muted
/// body, left aligned near the top, no illustration (X's empty Scheduled
/// tab); our own wording.
const kScheduledEmptyTitle = 'Nothing scheduled';
const kScheduledEmptyBody = 'Schedule a post and it will show up here.';

/// `/scheduled` (CMP-D6, ADR-0021 D4): the caller's PENDING and
/// FAILED scheduled posts, oldest first. Cancel a pending one (after a
/// confirmation) or dismiss a failed one; a failed post is never rescheduled.
/// Reached from Settings, the composer's Schedule dialog and the "View" action
/// of the schedule toast; the route and every entry point exist only with the
/// `posts` and `scheduled_posts` flags.
class ScheduledPostsScreen extends StatelessWidget {
  const ScheduledPostsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ScheduledPostsCubit>(
      create: (context) => ScheduledPostsCubit(
        repository: context.read<PostsRepository>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: const _ScheduledPostsView(),
    );
  }
}

class _ScheduledPostsView extends StatefulWidget {
  const _ScheduledPostsView();

  @override
  State<_ScheduledPostsView> createState() => _ScheduledPostsViewState();
}

class _ScheduledPostsViewState extends State<_ScheduledPostsView> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent > 0 &&
        position.pixels >= kPrefetchFraction * position.maxScrollExtent) {
      unawaited(context.read<ScheduledPostsCubit>().loadMore());
    }
  }

  /// Back to where the user came from; with no history (a deep link) to
  /// Settings.
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.settingsPath);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Cancel (after a confirmation) or Dismiss (no confirmation: nothing is
  /// lost) of [item].
  Future<void> _remove(pb.ScheduledPost item) async {
    final failed =
        item.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED;
    final cubit = context.read<ScheduledPostsCubit>();
    if (!failed) {
      final confirmed = await showCancelScheduledDialog(context);
      if (!confirmed || !mounted) return;
    }
    final result = await cubit.remove(item);
    if (!mounted) return;
    switch (result.outcome) {
      case ScheduledRemovalOutcome.done:
        if (!failed) _snack('Scheduled post cancelled.');
      case ScheduledRemovalOutcome.tooLate:
        _snack('That post was already sent.');
      case ScheduledRemovalOutcome.failed:
        _snack(cancelScheduledErrorMessage(result.error!, dismiss: failed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ScheduledPostsCubit>();
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'Scheduled posts', onBack: _back),
              Expanded(
                child: BlocBuilder<ScheduledPostsCubit, ScheduledPostsState>(
                  builder: (context, state) => RefreshIndicator(
                    onRefresh: cubit.refresh,
                    child: CustomScrollView(
                      controller: _controller,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (state.notice != null)
                          SliverToBoxAdapter(
                            child: AppNoticeBanner(
                              message: scheduledListNoticeMessage(
                                state.notice!,
                              ),
                              onRetry: noticeCanRetry(state.notice!)
                                  ? cubit.retry
                                  : null,
                            ),
                          ),
                        ..._body(state, cubit),
                      ],
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

  List<Widget> _body(ScheduledPostsState state, ScheduledPostsCubit cubit) {
    switch (state.status) {
      case ScheduledPostsStatus.loading:
        return const [
          SliverToBoxAdapter(
            child: PostListSkeleton(
              rows: 4,
              mediaEvery: 0,
              semanticsLabel: 'Loading scheduled posts',
            ),
          ),
        ];
      case ScheduledPostsStatus.error:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppErrorView(error: state.error!, onRetry: cubit.load),
          ),
        ];
      case ScheduledPostsStatus.ready:
      case ScheduledPostsStatus.loadingMore:
        if (state.items.isEmpty) {
          return const [SliverToBoxAdapter(child: _ScheduledEmptyState())];
        }
        return [
          SliverList.builder(
            itemCount: state.items.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = state.items.indexWhere(
                (i) => 'scheduled-${i.scheduledId}' == key.value,
              );
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final item = state.items[index];
              return Column(
                key: ValueKey('scheduled-${item.scheduledId}'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScheduledPostRow(item: item, onRemove: () => _remove(item)),
                  const Divider(height: 1),
                ],
              );
            },
          ),
          SliverToBoxAdapter(
            child: state.status == ScheduledPostsStatus.loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : const SizedBox(height: AppSpacing.lg),
          ),
        ];
    }
  }
}

/// The empty Scheduled list: a heading over a muted line, start aligned, no
/// illustration. Not [AppEmptyView], which centres an icon.
class _ScheduledEmptyState extends StatelessWidget {
  const _ScheduledEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              kScheduledEmptyTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            kScheduledEmptyBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
