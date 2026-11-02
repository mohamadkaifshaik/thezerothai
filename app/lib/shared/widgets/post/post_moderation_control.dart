import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// What a post's overflow menu needs to offer "Remove from Community" to a
/// community moderator (W5-35, ADR-0031 D2). The community screen builds one
/// only when the server's `viewer_role` says the viewer moderates, and hands it
/// down like a `PostPinControl`; a null control means the menu has no
/// moderator row, so every other screen is unchanged.
///
/// Presentation only: the callbacks do the work (optimistic local removal, one
/// RPC) and throw an `AppException` on failure.
@immutable
class PostModerationControl {
  const PostModerationControl({
    required this.communityId,
    required this.communityName,
    required this.onHide,
    required this.onRestore,
  });

  /// The community whose feed this is. Only its own posts get the row.
  final String communityId;
  final String communityName;

  /// Hides [postId] from the community view; throws on failure.
  final Future<void> Function(String postId) onHide;

  /// Restores [postId] (the snackbar's Undo); throws on failure.
  final Future<void> Function(String postId) onRestore;

  /// The menu of [post] has the row: the post is labelled with this community.
  bool offersRowFor(pb.Post post) =>
      post.hasCommunity() && post.community.id == communityId;
}
