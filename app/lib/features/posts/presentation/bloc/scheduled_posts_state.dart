import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

part 'scheduled_posts_state.freezed.dart';

/// Where the Scheduled list is: [loading] the first page (skeleton), [ready]
/// with rows (or the empty state), [loadingMore] a next page, [error] the
/// first page failed (nothing to show).
enum ScheduledPostsStatus { loading, ready, loadingMore, error }

/// The caller's PENDING and FAILED scheduled posts, oldest publish time first
/// (the server order), paged with an opaque token (CMP-D6, ADR-0021 D4).
@freezed
abstract class ScheduledPostsState with _$ScheduledPostsState {
  const factory ScheduledPostsState({
    @Default(ScheduledPostsStatus.loading) ScheduledPostsStatus status,
    @Default(<pb.ScheduledPost>[]) List<pb.ScheduledPost> items,
    @Default('') String nextPageToken,

    /// Why the first page failed ([ScheduledPostsStatus.error]).
    AppException? error,

    /// A refresh or a next page failed while rows are on screen: they stay,
    /// under a banner.
    AppException? notice,
  }) = _ScheduledPostsState;

  const ScheduledPostsState._();

  bool get hasMore => nextPageToken.isNotEmpty;
}
