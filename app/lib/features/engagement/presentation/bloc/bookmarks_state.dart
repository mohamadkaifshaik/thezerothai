import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../domain/bookmark_entry.dart';

/// One failed bookmark toggle, shown once by the card of [postId].
@immutable
class BookmarkFailure {
  const BookmarkFailure({
    required this.postId,
    required this.saving,
    required this.error,
    required this.serial,
  });

  final String postId;

  /// The failed intent: true = add, false = remove.
  final bool saving;
  final AppException error;

  /// Distinguishes two consecutive identical failures.
  final int serial;
}

/// A toggle that settled: the toast "Added to Bookmarks" / "Removed from
/// Bookmarks", shown once.
@immutable
class BookmarkNotice {
  const BookmarkNotice({
    required this.postId,
    required this.saved,
    required this.serial,
  });

  final String postId;
  final bool saved;
  final int serial;
}

/// The session's bookmark overlay as the widgets see it. Plain immutable
/// class (no codegen), like `EngagementState`.
@immutable
class BookmarksState {
  const BookmarksState({this.entries = const {}, this.failure, this.notice});

  final Map<String, BookmarkEntry> entries;
  final BookmarkFailure? failure;
  final BookmarkNotice? notice;

  BookmarksState copyWith({
    Map<String, BookmarkEntry>? entries,
    BookmarkFailure? failure,
    BookmarkNotice? notice,
    bool clearFailure = false,
    bool clearNotice = false,
  }) => BookmarksState(
    entries: entries ?? this.entries,
    failure: clearFailure ? null : (failure ?? this.failure),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}
