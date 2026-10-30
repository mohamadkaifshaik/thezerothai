import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/search_repository.dart';
import '../../domain/search_query.dart';
import '../../domain/search_results_tab.dart';
import 'search_results_state.dart';

/// Turns what search repositories throw into the typed errors the shared list
/// widgets draw. A daily limit carries `search_daily` so it never reads as
/// "try again in a moment".
AppException searchErrorToApp(Object error) {
  if (error is AppException) return error;
  if (error is SearchUnavailableException) {
    return FeatureDisabledException(error.toString(), feature: error.feature);
  }
  if (error is SearchRateLimitedException) {
    return RateLimitedException(
      error.toString(),
      retryAfter: error.retryAfter,
      limitName: error.isDaily ? 'search_daily' : null,
    );
  }
  if (error is SearchInvalidQueryException) {
    return ValidationException(error.toString(), field: error.field);
  }
  return const UnknownApiException('Something went wrong.');
}

/// One results tab (plan W4-15, ADR-0028): `SearchPeople` for People, one
/// `SearchPosts` per post tab, nothing else.
///
/// - **Cost.** One call on first show; a post tab asks the next page only on
///   a scroll near the end (Latest, Media). Top is one page with no token.
///   Nothing is polled, nothing is held open; a tab never shown asks nothing.
/// - **No call** when the query cannot be searched: People for a one-letter
///   or non-handle query, posts for `@handle` or a phrase ([SearchQuery]).
/// - **Short pages.** MEDIA pages can be short or empty while a token exists;
///   only an empty token ends the list, so [loadMore] follows it and the
///   screen asks again when the rows do not fill it.
/// - A failed refresh or next page keeps the rows under a banner and halts
///   automatic paging until [retry].
class SearchResultsCubit extends Cubit<SearchResultsState> {
  SearchResultsCubit({
    required SearchRepository repository,
    required this.tab,
    required this.query,
    this.pageSize = 20,
    this.peopleLimit = 10,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _onUnexpectedError = onUnexpectedError,
       super(const SearchResultsState());

  final SearchRepository _repository;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final SearchResultsTab tab;
  final SearchQuery query;
  final int pageSize;
  final int peopleLimit;

  int _round = 0;
  bool _busy = false;
  bool _pagingHalted = false;
  bool _noticeFromPaging = false;

  /// The last banner came from a next page: the screen shows it at the end.
  bool get noticeFromPaging => _noticeFromPaging;

  SearchTab get _wireTab => switch (tab) {
    SearchResultsTab.latest => SearchTab.SEARCH_TAB_LATEST,
    SearchResultsTab.media => SearchTab.SEARCH_TAB_MEDIA,
    _ => SearchTab.SEARCH_TAB_TOP,
  };

  /// The words this tab shows instead of a call, or [SearchResultsNote.none]
  /// when it can search.
  SearchResultsNote get _blockedNote {
    final isPeople = tab == SearchResultsTab.people;
    if (isPeople ? query.canSearchPeople : query.canSearchPosts) {
      return SearchResultsNote.none;
    }
    return switch (query.issue) {
      SearchQueryIssue.empty ||
      SearchQueryIssue.tooLong ||
      SearchQueryIssue.invalid => SearchResultsNote.invalid,
      _ =>
        isPeople && query.peopleTooShort
            ? SearchResultsNote.peopleTooShort
            : SearchResultsNote.unsupported,
    };
  }

  /// First page, with the skeleton (also the error view's Retry).
  Future<void> load() async {
    _round++;
    _busy = false;
    _pagingHalted = false;
    _noticeFromPaging = false;
    final blocked = _blockedNote;
    if (blocked != SearchResultsNote.none) {
      emit(
        SearchResultsState(status: SearchResultsStatus.ready, note: blocked),
      );
      return;
    }
    emit(const SearchResultsState(status: SearchResultsStatus.loading));
    await _fetchFirst();
  }

  /// Page 1 again, keeping the rows on screen (pull to refresh).
  Future<void> refresh() async {
    if (_busy) return;
    if (state.status == SearchResultsStatus.idle ||
        state.note != SearchResultsNote.none) {
      return load();
    }
    _pagingHalted = false;
    _noticeFromPaging = false;
    await _fetchFirst();
  }

  Future<void> _fetchFirst() async {
    if (_busy) return;
    _busy = true;
    final round = _round;
    try {
      if (tab == SearchResultsTab.people) {
        final result = await _repository.searchPeople(
          query.peopleQuery!,
          limit: peopleLimit,
        );
        if (isClosed || round != _round) return;
        emit(
          SearchResultsState(
            status: SearchResultsStatus.ready,
            people: result.users,
            note: result.unsupportedQuery
                ? SearchResultsNote.unsupported
                : SearchResultsNote.none,
          ),
        );
      } else {
        final page = await _repository.searchPosts(
          query.postsRequest!,
          tab: _wireTab,
          pageSize: pageSize,
        );
        if (isClosed || round != _round) return;
        emit(
          SearchResultsState(
            status: SearchResultsStatus.ready,
            posts: page.posts,
            // Top is one page with no token (ADR-0028).
            nextPageToken: tab == SearchResultsTab.top
                ? null
                : page.nextPageToken,
            note: page.unsupportedQuery
                ? SearchResultsNote.unsupported
                : SearchResultsNote.none,
          ),
        );
      }
    } catch (error, stack) {
      if (isClosed || round != _round) return;
      _failed(error, stack, paging: false);
    } finally {
      if (round == _round) _busy = false;
    }
  }

  /// The next page of a post tab, once the user is near the end (or the rows
  /// do not fill the screen). Guarded against concurrent calls.
  Future<void> loadMore() async {
    final token = state.nextPageToken;
    if (_busy ||
        _pagingHalted ||
        token == null ||
        state.status != SearchResultsStatus.ready ||
        tab == SearchResultsTab.people) {
      return;
    }
    _busy = true;
    final round = _round;
    emit(state.copyWith(status: SearchResultsStatus.loadingMore));
    try {
      final page = await _repository.searchPosts(
        query.postsRequest!,
        tab: _wireTab,
        pageToken: token,
        pageSize: pageSize,
      );
      if (isClosed || round != _round) return;
      final known = {for (final v in state.posts) v.post.postId};
      emit(
        SearchResultsState(
          status: SearchResultsStatus.ready,
          posts: [
            ...state.posts,
            for (final v in page.posts)
              if (known.add(v.post.postId)) v,
          ],
          nextPageToken: page.nextPageToken,
        ),
      );
    } catch (error, stack) {
      if (isClosed || round != _round) return;
      _failed(error, stack, paging: true);
    } finally {
      if (round == _round) _busy = false;
    }
  }

  /// The banner's Retry: the failed refresh or page again.
  Future<void> retry() async {
    _pagingHalted = false;
    final paging = _noticeFromPaging;
    emit(state.copyWith(clearNotice: true));
    await (paging ? loadMore() : refresh());
  }

  void _failed(Object error, StackTrace stack, {required bool paging}) {
    final mapped = searchErrorToApp(error);
    if (mapped is UnknownApiException) _onUnexpectedError?.call(error, stack);
    _noticeFromPaging = paging;
    if (paging) _pagingHalted = true;
    final hasRows = state.posts.isNotEmpty || state.people.isNotEmpty;
    if (mapped is FeatureDisabledException || !hasRows) {
      emit(
        SearchResultsState(status: SearchResultsStatus.error, error: mapped),
      );
    } else {
      emit(state.copyWith(status: SearchResultsStatus.ready, notice: mapped));
    }
  }
}
