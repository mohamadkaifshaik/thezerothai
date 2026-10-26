import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../domain/engagement_entry.dart' show engagementTargetId;

/// Where the Bookmarks list is: [loading] the first page (skeleton), [ready]
/// with rows (or the empty state), [loadingMore] a next page, [error] the
/// first page failed (nothing to show; a FEATURE_DISABLED answer is the
/// "not available" state).
enum BookmarksListStatus { loading, ready, loadingMore, error }

/// A row the user un-bookmarked on the list: the screen shows "Removed from
/// Bookmarks" with an Undo, once.
@immutable
class BookmarkRemoval {
  const BookmarkRemoval({required this.view, required this.serial});

  /// The row that left the list.
  final pb.PostView view;

  /// Distinguishes two removals of the same row.
  final int serial;
}

/// A bookmark toggle of a listed row failed and was rolled back: the card of
/// that row is gone (removal) or about to be redrawn (rollback), so the
/// screen words the failure itself, once.
@immutable
class BookmarkListFailure {
  const BookmarkListFailure({
    required this.postId,
    required this.saving,
    required this.error,
    required this.serial,
  });

  final String postId;

  /// The failed intent: true = add (an Undo), false = remove.
  final bool saving;
  final AppException error;
  final int serial;
}

/// The caller's bookmarks as the Bookmarks screen sees them (plan W2-7,
/// ADR-0023 D2): live posts, newest bookmark first, paged by an opaque token.
/// Session memory only. Plain immutable class (no codegen), like
/// `BookmarksState`.
@immutable
class BookmarksListState {
  const BookmarksListState({
    this.status = BookmarksListStatus.loading,
    this.items = const [],
    this.nextPageToken = '',
    this.hidden = const {},
    this.error,
    this.notice,
    this.removal,
    this.failure,
  });

  final BookmarksListStatus status;

  /// Every post of the pages loaded, in the server order, including the ones
  /// in [hidden].
  final List<pb.PostView> items;
  final String nextPageToken;

  /// Targets the user un-bookmarked: their rows are out of the list but stay
  /// in [items], so a failed removal or an Undo puts the row back in place.
  final Set<String> hidden;

  /// Why the first page failed ([BookmarksListStatus.error]).
  final AppException? error;

  /// A refresh or a next page failed while rows are on screen: they stay,
  /// under a banner.
  final AppException? notice;
  final BookmarkRemoval? removal;
  final BookmarkListFailure? failure;

  /// More pages exist. A page can be short, or empty, while this is true.
  bool get hasMore => nextPageToken.isNotEmpty;

  /// The rows to draw.
  List<pb.PostView> get visibleItems => hidden.isEmpty
      ? items
      : [
          for (final view in items)
            if (!hidden.contains(engagementTargetId(view.post))) view,
        ];

  BookmarksListState copyWith({
    BookmarksListStatus? status,
    List<pb.PostView>? items,
    String? nextPageToken,
    Set<String>? hidden,
    AppException? notice,
    BookmarkRemoval? removal,
    BookmarkListFailure? failure,
    bool clearNotice = false,
    bool clearRemoval = false,
    bool clearFailure = false,
  }) => BookmarksListState(
    status: status ?? this.status,
    items: items ?? this.items,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    hidden: hidden ?? this.hidden,
    error: error,
    notice: clearNotice ? null : (notice ?? this.notice),
    removal: clearRemoval ? null : (removal ?? this.removal),
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}
