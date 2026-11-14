import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../posts/data/posts_repository.dart';
import '../data/post_history_repository.dart';
import 'bloc/post_history_cubit.dart';
import 'engagement_error_messages.dart';
import 'widgets/history_post_list.dart';

/// Empty list: a heading and one line of guidance (our own wording). It says
/// the list stays on this device and how many posts it keeps.
const kOpenedPostsEmptyTitle = 'No history yet';
const kOpenedPostsEmptyBody =
    'Posts you open are listed here, on this device only. Dzeroth keeps your '
    '100 most recent.';

/// The History tab of `/bookmarks` (`bookmark_history`): the posts this
/// device recorded as opened, newest first, as live post cards.
///
/// - Created the first time the tab is selected. Reads are local until the
///   rows are drawn: one `GetPost` per stored id, no list RPC.
/// - A post that is gone or withheld drops out (and out of the stored list).
/// - "Clear history" asks first, then wipes this account's rows on the
///   device.
/// - Display only: the rows come from [PostHistoryCubit].
class OpenedPostsTab extends StatelessWidget {
  const OpenedPostsTab({super.key, required this.uid});

  /// The signed-in account whose history this shows.
  final String uid;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PostHistoryCubit>(
      create: (context) => PostHistoryCubit(
        history: context.read<PostHistoryRepository>(),
        posts: context.read<PostsRepository>(),
        uid: uid,
      )..load(),
      child: const _OpenedPostsView(),
    );
  }
}

class _OpenedPostsView extends StatelessWidget {
  const _OpenedPostsView();

  Future<void> _confirmClear(BuildContext context) async {
    final cubit = context.read<PostHistoryCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'This removes the posts you opened from this device. The posts '
          'themselves are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await cubit.clear();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PostHistoryCubit, PostHistoryState>(
      builder: (context, state) {
        final cubit = context.read<PostHistoryCubit>();
        final empty = const AppEmptyView(
          icon: Icons.history,
          title: kOpenedPostsEmptyTitle,
          subtitle: kOpenedPostsEmptyBody,
        );
        final hasRows = state.items.isNotEmpty;
        return HistoryPostList(
          rows: state.items,
          loading: state.status == PostHistoryStatus.loading,
          loadingMore: false,
          hasMore: false,
          error: state.status == PostHistoryStatus.error ? state.error : null,
          rowKeyPrefix: 'opened',
          withheldAction: WithheldAction.removeBookmark,
          loadingLabel: 'Loading history',
          noticeMessage: (error) => listNoticeMessage(error, noun: 'history'),
          empty: empty,
          unavailable: empty,
          header: hasRows
              ? Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _confirmClear(context),
                    child: const Text('Clear history'),
                  ),
                )
              : null,
          onRefresh: cubit.load,
          onLoadMore: () {},
          onReload: () => cubit.load(),
          onRetryNotice: () => cubit.load(),
        );
      },
    );
  }
}
