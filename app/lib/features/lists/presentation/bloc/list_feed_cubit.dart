import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../data/lists_repository.dart';
import '../../domain/list_follow_rules.dart';
import 'list_feed_state.dart';

/// Fetches one page of a Lists feed.
typedef ListFeedFetch = Future<ListsPage> Function(String pageToken);

/// A paged feed of Lists with a Follow toggle per row. Two screens use it:
/// "Lists you follow" on the Lists page (`ListFollowedLists`) and Discover
/// (`DiscoverLists`, most followed first). Pages of 20 by `next_page_token`;
/// one `fetch` per page and one RPC per toggle.
///
/// - Follow / Unfollow is optimistic, with the rollback and the error
///   returned to the screen for its snackbar. NOT_FOUND on a follow drops the
///   row (the List is gone or no longer public) and is returned too.
/// - Each toggle uses its own fresh idempotency key.
class ListFeedCubit extends Cubit<ListFeedState> {
  ListFeedCubit({
    required ListsRepository repository,
    required ListFeedFetch fetch,
    this.unfollowedLeavesFeed = false,
  }) : _repository = repository,
       _fetch = fetch,
       super(const ListFeedState());

  final ListsRepository _repository;
  final ListFeedFetch _fetch;

  /// "Lists you follow" drops a List the viewer unfollows; Discover keeps it
  /// (so Follow is one tap away).
  final bool unfollowedLeavesFeed;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: ListFeedStatus.loading,
        clearError: true,
        loadMoreFailed: false,
        loadingMore: false,
      ),
    );
    try {
      final page = await _fetch('');
      if (isClosed || generation != _generation) return;
      emit(
        ListFeedState(
          status: ListFeedStatus.ready,
          lists: page.lists,
          nextPageToken: page.nextPageToken,
        ),
      );
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(ListFeedState(status: ListFeedStatus.error, error: error));
    }
  }

  Future<void> loadMore() async {
    if (state.status != ListFeedStatus.ready ||
        !state.hasMore ||
        state.loadingMore) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    try {
      final page = await _fetch(state.nextPageToken);
      if (isClosed || generation != _generation) return;
      final known = {for (final l in state.lists) l.listId};
      emit(
        state.copyWith(
          lists: [
            ...state.lists,
            for (final l in page.lists)
              if (!known.contains(l.listId)) l,
          ],
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
    }
  }

  /// Toggles the viewer's follow of [listId]. Returns the failure (already
  /// rolled back) for the snackbar, else null.
  Future<AppException?> toggleFollow(String listId) async {
    final index = state.lists.indexWhere((l) => l.listId == listId);
    if (index < 0 || state.busyIds.contains(listId)) return null;
    final before = state.lists[index];
    final following = !before.followedByViewer;
    final optimistic = withViewerFollow(before, following: following);
    _replace(listId, optimistic, busy: true);
    try {
      final key = ListsRepository.newIdempotencyKey();
      if (following) {
        final saved = await _repository.followList(
          idempotencyKey: key,
          listId: listId,
        );
        _replace(listId, saved, busy: false);
      } else {
        await _repository.unfollowList(
          idempotencyKey: key,
          listId: listId,
          current: before,
        );
        if (unfollowedLeavesFeed) {
          _drop(listId);
        } else {
          _replace(listId, optimistic, busy: false);
        }
      }
      return null;
    } on NotFoundException catch (error) {
      if (following) {
        _drop(listId);
      } else {
        _replace(listId, before, busy: false);
      }
      return error;
    } on AppException catch (error) {
      _replace(listId, before, busy: false);
      return error;
    }
  }

  void _replace(String listId, pb.ListInfo list, {required bool busy}) {
    if (isClosed) return;
    final busyIds = {...state.busyIds};
    busy ? busyIds.add(listId) : busyIds.remove(listId);
    emit(
      state.copyWith(
        lists: [for (final l in state.lists) l.listId == listId ? list : l],
        busyIds: busyIds,
      ),
    );
  }

  void _drop(String listId) {
    if (isClosed) return;
    emit(
      state.copyWith(
        lists: [
          for (final l in state.lists)
            if (l.listId != listId) l,
        ],
        busyIds: {...state.busyIds}..remove(listId),
      ),
    );
  }
}
