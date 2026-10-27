import 'package:flutter/foundation.dart';

/// What a post's overflow menu needs to offer "Pin to your profile" /
/// "Unpin from profile" on the viewer's own posts (W3-17, ADR-0024 D3). A
/// screen that can pin builds one (from its own cubit) and hands it down; a
/// null control means the menu has no pin rows, so the card needs no provider
/// of its own and every other screen is unchanged.
///
/// Presentation only: the callbacks do the work and throw an `AppException`
/// on failure (the menu shows the typed message). The caller builds a control
/// only when `profile_extras` is on for the viewer and the server has not
/// refused it this session.
@immutable
class PostPinControl {
  const PostPinControl({
    required this.pinnedPostId,
    required this.onPin,
    required this.onUnpin,
  });

  /// The viewer's current pin; empty for none. A different non-empty id makes
  /// "Pin" a replacement, which the menu confirms.
  final String pinnedPostId;

  /// Pins [postId]; throws on failure.
  final Future<void> Function(String postId) onPin;

  /// Unpins the current pin; throws on failure.
  final Future<void> Function() onUnpin;

  bool isPinned(String postId) => postId.isNotEmpty && postId == pinnedPostId;
}
