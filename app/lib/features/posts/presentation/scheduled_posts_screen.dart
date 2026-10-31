import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/network/app_exception.dart';
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
import '../../../shared/widgets/headline_message.dart';
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

/// Shown instead of the list when the server answers FEATURE_DISABLED
/// (scheduling is switched off for everyone): same layout as the empty state,
/// no Retry (pull down to check again).
const kScheduledUnavailableBody = 'Please check back later.';

/// `/scheduled` (CMP-D6, ADR-0021 D4): the caller's PENDING and
/// FAILED scheduled posts, oldest first. Cancel a pending one (after a
/// confirmation) or dismiss a failed one; a failed post is never rescheduled.
/// Reached from Settings, the composer's Schedule dialog and the "View" action
/// of the schedule toast. The route needs only the `posts` flag (ADR-0021
/// L-A option b: listing and cancelling need `scheduled_posts` only "not
/// globally off"); the entry points in Settings and the composer show only
/// with both flags.
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

/// The Scheduled screen: header and [ScheduledPostsBody].
class _ScheduledPostsView extends StatelessWidget {
  const _ScheduledPostsView();

  /// Back to where the user came from; with no history (a deep link) to
  /// Settings.
  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.settingsPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: 'Scheduled posts',
                onBack: () => _back(context),
              ),
              const Expanded(child: ScheduledPostsBody()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Scheduled list without a Scaffold or header (CMP-D6, W6-15): the
/// Scheduled screen puts a back header over it and the Drafts screen puts it
/// under its Scheduled tab. Needs a [ScheduledPostsCubit] above it; owns its
/// one scroll view (refresh, paging, Cancel / Dismiss).
class ScheduledPostsBody extends StatefulWidget {
  const ScheduledPostsBody({super.key});

  @override
  State<ScheduledPostsBody> createState() => _ScheduledPostsBodyState();
}

class _ScheduledPostsBodyState extends State<ScheduledPostsBody> {
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
    return BlocBuilder<ScheduledPostsCubit, ScheduledPostsState>(
      builder: (context, state) => RefreshIndicator(
        onRefresh: cubit.refresh,
        child: CustomScrollView(
          controller: _controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // A failed refresh sits on top; a failed next page sits at the end
            // of the list (see _body), where the user is, unless there are no
            // rows to put it under.
            if (state.notice != null &&
                (!cubit.noticeFromPaging || state.items.isEmpty))
              SliverToBoxAdapter(child: _notice(state, cubit)),
            ..._body(state, cubit),
          ],
        ),
      ),
    );
  }

  Widget _notice(ScheduledPostsState state, ScheduledPostsCubit cubit) {
    return AppNoticeBanner(
      message: scheduledListNoticeMessage(state.notice!),
      onRetry: noticeCanRetry(state.notice!) ? cubit.retry : null,
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
        if (state.error is FeatureDisabledException) {
          return const [
            SliverToBoxAdapter(
              child: HeadlineMessage(
                title: kScheduledUnavailableTitle,
                body: kScheduledUnavailableBody,
              ),
            ),
          ];
        }
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppErrorView(error: state.error!, onRetry: cubit.load),
          ),
        ];
      case ScheduledPostsStatus.ready:
      case ScheduledPostsStatus.loadingMore:
        if (state.items.isEmpty) {
          return const [
            SliverToBoxAdapter(
              child: HeadlineMessage(
                title: kScheduledEmptyTitle,
                body: kScheduledEmptyBody,
              ),
            ),
          ];
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
                : state.notice != null && cubit.noticeFromPaging
                ? _notice(state, cubit)
                : const SizedBox(height: AppSpacing.lg),
          ),
        ];
    }
  }
}
