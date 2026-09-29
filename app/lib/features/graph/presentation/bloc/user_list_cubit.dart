import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../data/graph_repository.dart';
import 'user_list_state.dart';

/// Pages any of `ListFollowers`/`ListFollowing`/`ListBlockedUsers`/
/// `ListMutedUsers` via a [FetchGraphPage] closure supplied by the caller —
/// one cubit implementation for every graph list screen (followers/
/// following, and Settings → Blocked/Muted accounts), so pagination,
/// loading and error handling are written once (reuse-first).
class UserListCubit extends Cubit<UserListState> {
  UserListCubit({required FetchGraphPage fetchPage, this.pageSize = 20})
    : _fetchPage = fetchPage,
      super(const UserListState());

  final FetchGraphPage _fetchPage;
  final int pageSize;
  bool _loadingMore = false;

  Future<void> loadFirstPage() async {
    emit(const UserListState());
    await _load(pageToken: '', append: false);
  }

  Future<void> loadMore() async {
    if (_loadingMore ||
        !state.hasMore ||
        state.status == UserListStatus.error) {
      return;
    }
    _loadingMore = true;
    emit(state.copyWith(status: UserListStatus.loadingMore));
    await _load(pageToken: state.nextPageToken, append: true);
    _loadingMore = false;
  }

  Future<void> _load({required String pageToken, required bool append}) async {
    try {
      final page = await _fetchPage(pageSize: pageSize, pageToken: pageToken);
      emit(
        state.copyWith(
          status: UserListStatus.ready,
          items: append ? [...state.items, ...page.items] : page.items,
          nextPageToken: page.nextPageToken,
          error: null,
        ),
      );
    } on RateLimitedException catch (e) {
      emit(state.copyWith(status: UserListStatus.rateLimited, error: e));
    } on AppException catch (e) {
      emit(state.copyWith(status: UserListStatus.error, error: e));
    }
  }

  /// Optimistically removes [userId]'s row (e.g. after Unblock/Unmute).
  /// Returns the removed item and its index so the caller can restore it on
  /// undo/failure via [restoreItem].
  (graph.UserListItem, int)? removeUser(String userId) {
    final index = state.items.indexWhere((item) => item.user.userId == userId);
    if (index == -1) return null;
    final item = state.items[index];
    final items = [...state.items]..removeAt(index);
    emit(state.copyWith(items: items));
    return (item, index);
  }

  /// Restores a row removed by [removeUser] (undo, or rollback on failure).
  void restoreItem(graph.UserListItem item, int index) {
    final items = [...state.items];
    items.insert(index.clamp(0, items.length), item);
    emit(state.copyWith(items: items));
  }
}
