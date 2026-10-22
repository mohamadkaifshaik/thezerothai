import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/app_empty_view.dart';
import '../../../../shared/widgets/user_list_skeleton.dart';
import '../bloc/user_list_cubit.dart';
import '../bloc/user_list_state.dart';
import 'user_list_row.dart';

/// Renders a [UserListCubit]'s loading/ready/error/rate-limited/empty
/// states as a paged, pull-to-refreshable list — shared by the followers/
/// following screen and Settings' managed-accounts screens.
///
/// Prefetches the next page once the user has scrolled 70% of the way down
/// (CLAUDE.md: incremental refresh, no eager over-fetching), and never
/// auto-retries a rate-limited response.
class PagedUserList extends StatefulWidget {
  const PagedUserList({
    super.key,
    required this.cubit,
    required this.emptyMessage,
    this.emptyIcon = Icons.people_outline,
    this.rowBuilder,
  });

  final UserListCubit cubit;
  final String emptyMessage;

  /// The icon above [emptyMessage] in the empty state.
  final IconData emptyIcon;

  /// Overrides the default [UserListRow] rendering (e.g. Settings' managed-
  /// accounts screens, which show an Unblock/Unmute action instead of a
  /// [FollowButton]).
  final Widget Function(BuildContext context, graph.UserListItem item)?
  rowBuilder;

  @override
  State<PagedUserList> createState() => _PagedUserListState();
}

class _PagedUserListState extends State<PagedUserList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent * 0.7) {
      widget.cubit.loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.cubit,
      child: BlocBuilder<UserListCubit, UserListState>(
        builder: (context, state) {
          if (state.status == UserListStatus.loading) {
            // Never scrolls: a few static rows, clipped on a short screen.
            return const SingleChildScrollView(
              physics: NeverScrollableScrollPhysics(),
              child: UserListSkeleton(),
            );
          }
          if (state.status == UserListStatus.error ||
              state.status == UserListStatus.rateLimited) {
            return AppErrorView(
              error: state.error!,
              onRetry: widget.cubit.loadFirstPage,
            );
          }
          if (state.items.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                child: AppEmptyView(
                  icon: widget.emptyIcon,
                  title: widget.emptyMessage,
                ),
              ),
            );
          }
          final showLoadingFooter = state.status == UserListStatus.loadingMore;
          return RefreshIndicator(
            onRefresh: widget.cubit.loadFirstPage,
            child: ListView.builder(
              controller: _scrollController,
              itemCount: state.items.length + (showLoadingFooter ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= state.items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final item = state.items[index];
                return widget.rowBuilder?.call(context, item) ??
                    UserListRow(key: ValueKey(item.user.userId), item: item);
              },
            ),
          );
        },
      ),
    );
  }
}
