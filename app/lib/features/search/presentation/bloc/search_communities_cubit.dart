import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/search_repository.dart';
import 'search_results_cubit.dart' show searchErrorToApp;

/// [loading] the first page, [ready] rows (possibly none), [error] the first
/// page failed.
enum SearchCommunitiesStatus { loading, ready, error }

/// The Communities tab as the screen sees it (session memory only).
@immutable
class SearchCommunitiesState {
  const SearchCommunitiesState({
    this.status = SearchCommunitiesStatus.loading,
    this.communities = const [],
    this.nextPageToken,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.error,
  });

  final SearchCommunitiesStatus status;
  final List<Community> communities;

  /// Null when there is no next page.
  final String? nextPageToken;
  final bool loadingMore;

  /// The last next page failed: paging waits for [SearchCommunitiesCubit.loadMore]
  /// from the Retry button.
  final bool loadMoreFailed;
  final AppException? error;

  bool get hasMore => nextPageToken != null;

  SearchCommunitiesState copyWith({
    SearchCommunitiesStatus? status,
    List<Community>? communities,
    Object? nextPageToken = _keep,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => SearchCommunitiesState(
    status: status ?? this.status,
    communities: communities ?? this.communities,
    nextPageToken: identical(nextPageToken, _keep)
        ? this.nextPageToken
        : nextPageToken as String?,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    error: error,
  );
}

const Object _keep = Object();

/// One `SearchCommunities` per page of [pageSize] (20, the server's cap),
/// the next page only on [loadMore] (a scroll near the end, or Retry). The
/// query is the caller's to check (1-30 code points, `SearchQuery.directoryQuery`).
/// A page is short only at the end, but an empty page with a token is still
/// followed.
class SearchCommunitiesCubit extends Cubit<SearchCommunitiesState> {
  SearchCommunitiesCubit({
    required SearchRepository repository,
    required this.query,
    this.pageSize = 20,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _onUnexpectedError = onUnexpectedError,
       super(const SearchCommunitiesState());

  final SearchRepository _repository;
  final String query;
  final int pageSize;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  int _round = 0;

  /// First page with the skeleton (also the error view's Retry).
  Future<void> load() async {
    final round = ++_round;
    emit(const SearchCommunitiesState());
    try {
      final page = await _repository.searchCommunities(
        query,
        pageSize: pageSize,
      );
      if (isClosed || round != _round) return;
      emit(
        SearchCommunitiesState(
          status: SearchCommunitiesStatus.ready,
          communities: page.communities,
          nextPageToken: page.nextPageToken,
        ),
      );
    } catch (error, stack) {
      if (isClosed || round != _round) return;
      emit(
        SearchCommunitiesState(
          status: SearchCommunitiesStatus.error,
          error: _map(error, stack),
        ),
      );
    }
  }

  Future<void> loadMore() async {
    final token = state.nextPageToken;
    if (token == null ||
        state.status != SearchCommunitiesStatus.ready ||
        state.loadingMore) {
      return;
    }
    final round = _round;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    try {
      final page = await _repository.searchCommunities(
        query,
        pageToken: token,
        pageSize: pageSize,
      );
      if (isClosed || round != _round) return;
      final known = {for (final c in state.communities) c.communityId};
      emit(
        state.copyWith(
          communities: [
            ...state.communities,
            for (final c in page.communities)
              if (known.add(c.communityId)) c,
          ],
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } catch (error, stack) {
      if (isClosed || round != _round) return;
      _map(error, stack);
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
    }
  }

  AppException _map(Object error, StackTrace stack) {
    final mapped = searchErrorToApp(error);
    if (mapped is UnknownApiException) _onUnexpectedError?.call(error, stack);
    return mapped;
  }
}
