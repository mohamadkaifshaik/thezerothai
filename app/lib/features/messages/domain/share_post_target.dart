import 'package:flutter/foundation.dart';

/// The post a share action sends: what the picker needs and nothing more.
@immutable
class SharePostTarget {
  const SharePostTarget({required this.postId, required this.url});

  /// A link-only share (a plan): the picker sends [url] as plain message
  /// text, with no shared post and so without `dm_post_share`.
  const SharePostTarget.link({required this.url}) : postId = '';

  /// No post is shared; only the text carries [url].
  bool get linkOnly => postId.isEmpty;

  /// The id to send: the original's for a REPOST row.
  final String postId;

  /// The canonical link of that post, built from the same id
  /// (`ShareLinks.postUrl`). It is the text of a share without a caption, so
  /// the chat can recognise it and hide it behind the card.
  final String url;
}
