import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' show PostView;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;

/// How many top trends Explore draws from, for both the Trending rows and the
/// Media section: the top 3.
const kExploreTopTrends = 3;

/// What a media tile shows. Photos only today; a reel or a video tile is a
/// new value here and a new case in the tile widget, nothing else.
enum ExploreMediaKind { photo }

/// One tile of Explore's Media section: the first image of a post found under
/// a trending hashtag. [index] is the 0-based place of [media] in the post.
@immutable
class ExploreMediaTile {
  const ExploreMediaTile({
    required this.postId,
    required this.index,
    required this.media,
    required this.createdAt,
    this.kind = ExploreMediaKind.photo,
  });

  final String postId;
  final int index;
  final common.MediaRef media;
  final DateTime createdAt;
  final ExploreMediaKind kind;
}

/// The tile of one post, or null when it has no usable image: no post, a
/// repost, or no image with a thumbnail (a grid never falls back to the full
/// image).
ExploreMediaTile? exploreMediaTileOf(PostView view) {
  if (!view.hasPost()) return null;
  final post = view.post;
  if (post.kind == PostKind.POST_KIND_REPOST) return null;
  for (var i = 0; i < post.media.length && i < 4; i++) {
    final media = post.media[i];
    if (media.thumbUrl.isEmpty) continue;
    return ExploreMediaTile(
      postId: post.postId,
      index: i,
      media: media,
      createdAt: post.hasCreatedAt()
          ? post.createdAt.toDateTime()
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
  return null;
}

/// Merges the posts of several hashtags into one list of tiles, newest first
/// (ties by post id, larger first), one tile per post id.
List<ExploreMediaTile> mergeMediaTiles(Iterable<Iterable<PostView>> pages) {
  final byId = <String, ExploreMediaTile>{};
  for (final page in pages) {
    for (final view in page) {
      final tile = exploreMediaTileOf(view);
      if (tile != null) byId.putIfAbsent(tile.postId, () => tile);
    }
  }
  return byId.values.toList()..sort((a, b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    return byTime != 0 ? byTime : b.postId.compareTo(a.postId);
  });
}
