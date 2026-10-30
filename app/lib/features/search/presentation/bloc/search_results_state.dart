import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/search_repository.dart';

/// Where one results tab is: [idle] before it was asked, [loading] the first
/// page (skeleton), [ready] rows or the empty state, [loadingMore] a next
/// page, [error] the first page failed (a FEATURE_DISABLED answer is the "not
/// available" state).
enum SearchResultsStatus { idle, loading, ready, loadingMore, error }

/// Why a tab shows words instead of results, without (or after) a call.
enum SearchResultsNote {
  /// Results (or an honest empty state).
  none,

  /// The query is neither a handle prefix nor one hashtag: "Search posts by
  /// #hashtag" (Stage 0 has no full-text search, ADR-0028).
  unsupported,

  /// People tab, a one-character query: no call (enumeration guard).
  peopleTooShort,

  /// Empty, too long or holding control characters: no call.
  invalid,
}

/// One tab of the results as the screen sees it (session memory only).
/// Plain immutable class (no codegen), like `BookmarksListState`.
@immutable
class SearchResultsState {
  const SearchResultsState({
    this.status = SearchResultsStatus.idle,
    this.posts = const [],
    this.people = const [],
    this.nextPageToken,
    this.note = SearchResultsNote.none,
    this.error,
    this.notice,
  });

  final SearchResultsStatus status;

  /// Post rows (Top, Latest, Media), newest first (Top: re-ranked by the
  /// server; the client never re-orders).
  final List<PostView> posts;

  /// People rows (People tab); the server sends no token.
  final List<UserListItem> people;

  /// Null when there is no next page.
  final String? nextPageToken;
  final SearchResultsNote note;

  /// Why the first page failed.
  final AppException? error;

  /// A refresh or next page failed while rows are on screen.
  final AppException? notice;

  bool get hasMore => nextPageToken != null;

  SearchResultsState copyWith({
    SearchResultsStatus? status,
    AppException? notice,
    bool clearNotice = false,
  }) {
    return SearchResultsState(
      status: status ?? this.status,
      posts: posts,
      people: people,
      nextPageToken: nextPageToken,
      note: note,
      error: error,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}
