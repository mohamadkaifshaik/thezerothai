import 'package:flutter/foundation.dart';

/// The post a share action sends: what the picker needs and nothing more.
@immutable
class SharePostTarget {
  const SharePostTarget({required this.postId, required this.url});

  /// The id to send: the original's for a REPOST row.
  final String postId;

  /// The canonical link of that post, built from the same id
  /// (`ShareLinks.postUrl`). It is the text of a share without a caption, so
  /// the chat can recognise it and hide it behind the card.
  final String url;
}
