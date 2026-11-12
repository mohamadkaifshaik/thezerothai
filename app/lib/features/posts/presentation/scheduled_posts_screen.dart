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
import '../../../core/feature_flags/feature_flags.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_alert_confirm.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/post/post_list_skeleton.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import 'bloc/scheduled_posts_cubit.dart';
import 'bloc/scheduled_posts_state.dart';
import 'post_error_messages.dart';
import 'widgets/cancel_scheduled_dialog.dart';
import 'widgets/edit_scheduled_post.dart';
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

/// The Post now confirmation.
const kPostNowTitle = 'Post this now?';
const kPostNowMessage =
    'It goes out right away instead of at its scheduled time.';

/// `/scheduled`: the caller's PENDING and
/// FAILED scheduled posts, oldest first. Cancel a pending one (after a
/// confirmation) or dismiss a failed one; a failed post is never rescheduled.
/// Reached from Settings, the composer's Schedule dialog and the "View" action
/// of the schedule toast. The route needs only the `posts` flag (listing and cancelling
/// need `scheduled_posts` only "not globally off"); the entry points in Settings and the composer show only
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
                titleContent: const _ScheduledTitle(),
              ),
              const Expanded(child: ScheduledPostsBody()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Scheduled list without a Scaffold or header: the
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
      // Only Post now answers this; a cancel of a gone item is `done`.
      case ScheduledRemovalOutcome.noLongerScheduled:
        if (!failed) _snack('Scheduled post cancelled.');
      case ScheduledRemovalOutcome.tooLate:
        _snack('That post was already sent.');
      case ScheduledRemovalOutcome.failed:
        _snack(cancelScheduledErrorMessage(result.error!, dismiss: failed));
    }
  }

  /// Post now, after a confirmation: the post goes out at once instead of
  /// at its time.
  Future<void> _postNow(pb.ScheduledPost item) async {
    final cubit = context.read<ScheduledPostsCubit>();
    final confirmed = await showAppAlertConfirm(
      context,
      title: kPostNowTitle,
      message: kPostNowMessage,
      confirmLabel: 'Post now',
    );
    if (!confirmed || !mounted) return;
    final result = await cubit.postNow(item);
    if (!mounted) return;
    switch (result.outcome) {
      case ScheduledRemovalOutcome.done:
      case ScheduledRemovalOutcome.tooLate:
        _snack('Your post is out.');
      case ScheduledRemovalOutcome.noLongerScheduled:
        _snack('That post is no longer scheduled.');
      case ScheduledRemovalOutcome.failed:
        _snack(postNowScheduledErrorMessage(result.error!));
    }
  }

  /// The editor; it closes itself once the save is answered.
  Future<void> _edit(pb.ScheduledPost item) async {
    final cubit = context.read<ScheduledPostsCubit>();
    final outcome = await showEditScheduledPost(
      context,
      item: item,
      onSave: ({text, publishAt}) =>
          cubit.edit(item, text: text, publishAt: publishAt),
    );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case ScheduledEditOutcome.saved:
        _snack('Scheduled post updated.');
      case ScheduledEditOutcome.tooLate:
        _snack('That post was already sent.');
      case ScheduledEditOutcome.noLongerScheduled:
        _snack('That post is no longer scheduled.');
      case ScheduledEditOutcome.failed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ScheduledPostsCubit>();
    // Edit and Post now need scheduling on for this caller; Cancel and
    // Dismiss only need the list (the route's own rule).
    final canAct = isFeatureEnabled(context, kFeatureScheduledPosts);
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
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
            ..._body(state, cubit, canAct: canAct, wide: wide),
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

  List<Widget> _body(
    ScheduledPostsState state,
    ScheduledPostsCubit cubit, {
    required bool canAct,
    required bool wide,
  }) {
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
          SliverPadding(
            padding: wide
                ? const EdgeInsets.symmetric(
                    vertical: AppScheduledLayout.wideCardGap / 2,
                  )
                : const EdgeInsets.symmetric(
                    horizontal: AppScheduledLayout.phoneListPaddingH,
                    vertical: AppScheduledLayout.phoneListPaddingV,
                  ),
            sliver: SliverList.builder(
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
                return Padding(
                  key: ValueKey('scheduled-${item.scheduledId}'),
                  padding: EdgeInsets.only(
                    top: wide || index == 0
                        ? 0
                        : AppScheduledLayout.phoneCardGap,
                  ),
                  child: ScheduledPostRow(
                    item: item,
                    wide: wide,
                    onRemove: () => _remove(item),
                    onEdit: canAct ? () => _edit(item) : null,
                    onPostNow: canAct ? () => _postNow(item) : null,
                  ),
                );
              },
            ),
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

/// "Scheduled posts" over the count of what is loaded ("2 posts"; "20+
/// posts" while more pages exist), as in the Scheduled mocks. The count
/// shows only once the list is in.
class _ScheduledTitle extends StatelessWidget {
  const _ScheduledTitle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<ScheduledPostsCubit>().state;
    final ready =
        state.status == ScheduledPostsStatus.ready ||
        state.status == ScheduledPostsStatus.loadingMore;
    final count = state.items.length;
    final more = state.hasMore ? '+' : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Scheduled posts',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (ready && count > 0)
          Text(
            '$count$more ${count == 1 && more.isEmpty ? 'post' : 'posts'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
