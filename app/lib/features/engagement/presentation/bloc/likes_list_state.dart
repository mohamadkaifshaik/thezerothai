import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../domain/engagement_entry.dart' show engagementTargetId;

/// Where the Likes list is: [loading] the first page (skeleton), [ready]
/// with rows (or the empty state), [loadingMore] a next page, [error] the
/// first page failed (nothing to show; a FEATURE_DISABLED answer means the
/// tab is not available).
enum LikesListStatus { loading, ready, loadingMore, error }

/// The caller's likes as the History screen's Likes tab sees them (plan
/// W3-18, ADR-0024 D6): live posts, most recent like first, paged by an
/// opaque token, in session memory only. Plain immutable class (no codegen),
/// like `BookmarksListState`.
@immutable
class LikesListState {
  const LikesListState({
    this.status = LikesListStatus.loading,
    this.items = const [],
    this.nextPageToken = '',
    this.hidden = const {},
    this.error,
    this.notice,
  });

  final LikesListStatus status;

  /// Every post of the pages loaded, in the server order, including the ones
  /// in [hidden].
  final List<pb.PostView> items;
  final String nextPageToken;

  /// Targets the caller un-liked on this screen: their rows are out of the
  /// list but stay in [items], so a rolled-back unlike puts the row back in
  /// place.
  final Set<String> hidden;

  /// Why the first page failed ([LikesListStatus.error]).
  final AppException? error;

  /// A refresh or a next page failed while rows are on screen: they stay,
  /// under a banner.
  final AppException? notice;

  /// More pages exist. A page can be short, or empty, while this is true.
  bool get hasMore => nextPageToken.isNotEmpty;

  /// The rows to draw.
  List<pb.PostView> get visibleItems => hidden.isEmpty
      ? items
      : [
          for (final view in items)
            if (!hidden.contains(engagementTargetId(view.post))) view,
        ];

  LikesListState copyWith({
    LikesListStatus? status,
    List<pb.PostView>? items,
    String? nextPageToken,
    Set<String>? hidden,
    AppException? notice,
    bool clearNotice = false,
  }) => LikesListState(
    status: status ?? this.status,
    items: items ?? this.items,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    hidden: hidden ?? this.hidden,
    error: error,
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}
