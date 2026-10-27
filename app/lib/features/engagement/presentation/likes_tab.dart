import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../data/likes_repository.dart';
import 'bloc/engagement_cubit.dart';
import 'bloc/engagement_state.dart';
import 'bloc/likes_list_cubit.dart';
import 'bloc/likes_list_state.dart';
import 'engagement_error_messages.dart';
import 'widgets/history_post_list.dart';

/// Empty list: a heading and one line of guidance (our own wording). It says
/// how many likes are kept (the server keeps the 1,000 most recent, ADR-0024
/// D6) and that a like made on another device can take a minute to appear
/// (the server caches the list for 60 s).
const kLikesEmptyTitle = 'No likes yet';
const kLikesEmptyBody =
    'Posts you like are listed here. Dzeroth keeps your 1,000 most recent '
    'likes, and a new like can take a minute to show up.';

/// Under the last row once there is no next page.
const kLikesEndNote =
    "That's all of them. Dzeroth keeps your 1,000 most recent likes.";

/// Shown instead of the list when the server answers FEATURE_DISABLED (or
/// UNIMPLEMENTED) to the list: the screen hides the tab right after.
const kLikesUnavailableTitle = "Likes aren't available right now";
const kLikesUnavailableBody = 'Please check back later.';

/// The Likes tab of the History screen (`/bookmarks`, plan W3-18, ADR-0024
/// D6): the caller's most recent likes as live post cards, newest like first.
///
/// - Created the first time the tab is selected (not with the screen), and
///   asks the server for page 1 then: 1 `ListLikedPosts` per open, plus one
///   per scroll page. The rows are in [LikesListCubit], session memory only.
/// - Un-liking a row from its heart removes it at once; a failed unlike puts
///   it back and says why here (the card of a removed row is gone).
/// - When the server says the list is not available ([onUnavailable]) the
///   screen hides the tab.
/// - Display only: the rows come from [LikesListCubit].
class LikesTab extends StatelessWidget {
  const LikesTab({
    super.key,
    required this.active,
    required this.onUnavailable,
  });

  /// Whether this tab is the one the user is looking at (the other tab keeps
  /// its state while it is out of sight, and stays quiet).
  final bool active;

  /// The server refused the list for good (FEATURE_DISABLED / UNIMPLEMENTED).
  final VoidCallback onUnavailable;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<LikesListCubit>(
      create: (context) => LikesListCubit(
        repository: context.read<LikesRepository>(),
        engagement: context.read<EngagementCubit>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: _LikesTabView(active: active, onUnavailable: onUnavailable),
    );
  }
}

class _LikesTabView extends StatelessWidget {
  const _LikesTabView({required this.active, required this.onUnavailable});

  final bool active;
  final VoidCallback onUnavailable;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<LikesListCubit>();
    return MultiBlocListener(
      listeners: [
        BlocListener<LikesListCubit, LikesListState>(
          listenWhen: (before, after) =>
              after.error is FeatureDisabledException &&
              !identical(before.error, after.error),
          listener: (context, state) => onUnavailable(),
        ),
        // The card of a row the unlike removed is gone, so nobody else words
        // a failed unlike (the card that comes back after the rollback does
        // not see a failure that already happened).
        BlocListener<EngagementCubit, EngagementState>(
          listenWhen: (before, after) {
            final failure = after.failure;
            return active &&
                failure != null &&
                failure.action == EngagementAction.unlike &&
                before.failure?.serial != failure.serial &&
                cubit.holds(failure.postId);
          },
          listener: (context, state) {
            // A post opened over this screen shows its own failure.
            if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
            final failure = state.failure!;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    engagementErrorMessage(
                      failure.error,
                      action: failure.action,
                    ),
                  ),
                ),
              );
            context.read<EngagementCubit>().failureShown();
          },
        ),
      ],
      child: BlocBuilder<LikesListCubit, LikesListState>(
        builder: (context, state) => HistoryPostList(
          rows: state.visibleItems,
          loading: state.status == LikesListStatus.loading,
          loadingMore: state.status == LikesListStatus.loadingMore,
          hasMore: state.hasMore,
          error: state.status == LikesListStatus.error ? state.error : null,
          notice: state.notice,
          noticeFromPaging: cubit.noticeFromPaging,
          rowKeyPrefix: 'like',
          loadingLabel: 'Loading likes',
          noticeMessage: (error) => listNoticeMessage(error, noun: 'likes'),
          empty: const AppEmptyView(
            icon: Icons.favorite_border,
            title: kLikesEmptyTitle,
            subtitle: kLikesEmptyBody,
          ),
          unavailable: const AppEmptyView(
            icon: Icons.favorite_border,
            title: kLikesUnavailableTitle,
            subtitle: kLikesUnavailableBody,
          ),
          endNote: const _EndNote(),
          onRefresh: cubit.refresh,
          onLoadMore: () => unawaited(cubit.loadMore()),
          onReload: cubit.load,
          onRetryNotice: cubit.retry,
        ),
      ),
    );
  }
}

class _EndNote extends StatelessWidget {
  const _EndNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      child: Text(
        kLikesEndNote,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
