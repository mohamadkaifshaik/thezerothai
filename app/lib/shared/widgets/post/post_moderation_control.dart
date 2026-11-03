import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;

/// What a post's overflow menu needs to offer "Remove from Community" to a
/// community moderator (ADR-0031 D2). The community screen builds one
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
    this.repliesOnly = false,
  });

  /// The community whose feed this is. Only its own posts get the row.
  final String communityId;
  final String communityName;

  /// Hides [postId] from the community view; throws on failure.
  final Future<void> Function(String postId) onHide;

  /// Restores [postId] (the snackbar's Undo); throws on failure.
  final Future<void> Function(String postId) onRestore;

  /// ADR-0031 D4a: the control of a community conversation's open
  /// thread. A reply carries no community label of its own, so the row goes to
  /// every reply instead. The thread screen builds one only for the root's
  /// community and a `viewer_role` of owner or moderator; the server still
  /// refuses what the role may not do (F16 `not_owner`).
  final bool repliesOnly;

  /// The menu of [post] has the row: a reply (replies-only control), or a post
  /// labelled with this community.
  bool offersRowFor(pb.Post post) => repliesOnly
      ? post.kind == PostKind.POST_KIND_REPLY || post.replyToPostId.isNotEmpty
      : post.hasCommunity() && post.community.id == communityId;
}
