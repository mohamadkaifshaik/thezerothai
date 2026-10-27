import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

enum PinnedPostStatus {
  /// The profile has no pinned post (or the server omits it).
  none,

  /// `GetPost` of the pinned post is running.
  loading,

  /// [PinnedPostState.view] is the pinned post.
  ready,

  /// The post is gone for this viewer (NOT_FOUND: deleted, taken down or
  /// hidden by a block): nothing is shown, silently.
  hidden,

  /// The fetch failed for another reason ([PinnedPostState.error]); the row
  /// says so and offers Retry.
  failed,
}

/// What the Pinned row of a profile renders. Plain immutable class (no
/// codegen), like `TimelineState`.
@immutable
class PinnedPostState {
  const PinnedPostState({
    this.status = PinnedPostStatus.none,
    this.postId = '',
    this.view,
    this.error,
    this.deleting = false,
  });

  final PinnedPostStatus status;

  /// The profile's `pinned_post_id` this state is about; empty for none.
  final String postId;
  final pb.PostView? view;
  final AppException? error;

  /// The pinned post is being deleted: the row is gone already, but the feed
  /// keeps leaving the post out until the delete is confirmed (a failed
  /// delete brings the row back, and the post must not have flashed below).
  final bool deleting;

  /// The post the feed below must not repeat: the pin while it is loading or
  /// shown (so the card does not flash in the feed and then leave it). A
  /// hidden or failed pin is no reason to drop the post from the feed.
  String? get coveredPostId =>
      status == PinnedPostStatus.loading ||
          status == PinnedPostStatus.ready ||
          deleting
      ? postId
      : null;

  @override
  bool operator ==(Object other) =>
      other is PinnedPostState &&
      other.status == status &&
      other.postId == postId &&
      identical(other.view, view) &&
      other.error == error &&
      other.deleting == deleting;

  @override
  int get hashCode => Object.hash(status, postId, view, error, deleting);
}
