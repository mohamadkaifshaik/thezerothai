import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;

/// The viewer's like/repost state and the counts of one engagement target,
/// plus whether a request for it is in flight (ADR-0018, plan T7).
///
/// A count is `null` while it is unknown: a REPOST row carries the counters
/// of the REPOST doc (always 0, plan D17), not of the original it points to,
/// so the client shows no number there until the server answers an action
/// with the real ones (and never spends a `GetPost` per row to find out).
@immutable
class EngagementEntry {
  const EngagementEntry({
    required this.liked,
    required this.reposted,
    this.likeCount,
    this.repostCount,
    this.likeBusy = false,
    this.repostBusy = false,
    this.base,
  });

  /// The state a feed row describes: [pb.PostView.likedByViewer] and
  /// friends. For a REPOST item the flags describe the original (the proto
  /// says so) and the counts are unknown.
  factory EngagementEntry.fromView(pb.PostView view) {
    final isRepost = view.post.kind == PostKind.POST_KIND_REPOST;
    return EngagementEntry(
      liked: view.likedByViewer,
      reposted: view.repostedByViewer,
      likeCount: isRepost ? null : view.post.likeCount.toInt(),
      repostCount: isRepost ? null : view.post.repostCount.toInt(),
    );
  }

  final bool liked;
  final bool reposted;
  final int? likeCount;
  final int? repostCount;
  final bool likeBusy;
  final bool repostBusy;

  /// What the feed row said when this entry was created. When a refreshed
  /// row says something else, the server's newer data wins over the entry
  /// (see [matches]), so a count never freezes at the value of the user's
  /// own last action.
  final EngagementEntry? base;

  bool get busy => likeBusy || repostBusy;

  /// The same like/repost state and counts, ignoring in-flight flags and
  /// [base].
  bool sameState(EngagementEntry other) =>
      liked == other.liked &&
      reposted == other.reposted &&
      likeCount == other.likeCount &&
      repostCount == other.repostCount;

  /// Whether this entry is still newer than [view]: a request is running, or
  /// the row still says what it said when the entry was created.
  bool matches(pb.PostView view) {
    if (busy) return true;
    final b = base;
    return b == null || b.sameState(EngagementEntry.fromView(view));
  }

  /// A copy with the given fields replaced; a null argument keeps the field
  /// (a known count never goes back to unknown).
  EngagementEntry copyWith({
    bool? liked,
    bool? reposted,
    int? likeCount,
    int? repostCount,
    bool? likeBusy,
    bool? repostBusy,
  }) => EngagementEntry(
    liked: liked ?? this.liked,
    reposted: reposted ?? this.reposted,
    likeCount: likeCount ?? this.likeCount,
    repostCount: repostCount ?? this.repostCount,
    likeBusy: likeBusy ?? this.likeBusy,
    repostBusy: repostBusy ?? this.repostBusy,
    base: base,
  );

  @override
  bool operator ==(Object other) =>
      other is EngagementEntry &&
      other.liked == liked &&
      other.reposted == reposted &&
      other.likeCount == likeCount &&
      other.repostCount == repostCount &&
      other.likeBusy == likeBusy &&
      other.repostBusy == repostBusy;

  @override
  int get hashCode => Object.hash(
    liked,
    reposted,
    likeCount,
    repostCount,
    likeBusy,
    repostBusy,
  );
}

/// The id a like/repost/quote acts on: the original for a REPOST item
/// (ADR-0018 D4: acting on a REPOST acts on its original), else the post
/// itself. Empty when a REPOST has no usable embed.
String engagementTargetId(pb.Post post) {
  if (post.kind == PostKind.POST_KIND_REPOST) {
    return post.hasEmbedded() && !post.embedded.unavailable
        ? post.embedded.postId
        : '';
  }
  return post.postId;
}
