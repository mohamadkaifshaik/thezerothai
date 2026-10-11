//
//  Generated code. Do not modify.
//  source: dzeroth/engagement/v1/engagement.proto
//

import "package:connectrpc/connect.dart" as connect;
import "engagement.pb.dart" as dzerothengagementv1engagement;

abstract final class EngagementService {
  /// Fully-qualified name of the EngagementService service.
  static const name = 'dzeroth.engagement.v1.EngagementService';

  /// Like a post. Idempotent: liking a liked post succeeds with 0 writes. Quota: 500 likes/day/user (100 for
  /// accounts younger than 24 h), RESOURCE_EXHAUSTED + QUOTA_EXCEEDED metadata["quota"]="likes". Per-user bucket
  /// RATE_LIMIT_LIKES_PER_MIN (30/min).
  /// One transaction: reads quotas/{uid}; writes likes/{id} (Create; AlreadyExists at commit is the replay),
  /// posts/{id}.likeCount (Increment), userLikes/{uid} (ArrayUnion; trimmed to the newest 1,000 by a separate
  /// best-effort write) and quotas/{uid}.
  /// Firestore: reads 1 in the transaction (+ the visibility check: post, author users, caller graph = 3 cold /
  /// 0 warm, + the account-status interceptor's users read; +2 when post_id is a REPOST), writes 4. Replay: same
  /// reads, 0 writes.
  static const likePost = connect.Spec(
    '/$name/LikePost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.LikePostRequest.new,
    dzerothengagementv1engagement.LikePostResponse.new,
  );

  /// Remove a like. Idempotent: not liked => success with 0 writes. Needs no visibility check (a user can always
  /// retract), so a post that became invisible or was deleted can still be unliked.
  /// One batch: Delete likes/{id} (Exists precondition), posts/{id}.likeCount (Increment -1, skipped when the post
  /// is gone) and userLikes/{uid} (ArrayRemove). Firestore: reads <= 1 (the post for the returned counts, cache
  /// first, +1 when post_id is a REPOST), writes 2 + 1 delete; a no-op writes 0.
  static const unlikePost = connect.Spec(
    '/$name/UnlikePost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.UnlikePostRequest.new,
    dzerothengagementv1engagement.UnlikePostResponse.new,
  );

  /// Repost a post: creates reposts/{postId}_{uid} and a posts doc with kind REPOST, an embedded snapshot of the
  /// original, authored by the caller (it appears in the caller's profile and in followers' home timelines like
  /// any root post, and is removed by DeletePost or UndoRepost). Reposting a post you already reposted succeeds and
  /// returns the existing repost (0 writes). A repost of a REPOST resolves to the original. Counts toward the posts
  /// quota (100/day, 20 for new accounts) and users.postsCount.
  /// One transaction: reads quotas/{uid}; writes reposts/{id}, posts/{newId}, posts/{id}.repostCount,
  /// users/{uid}.postsCount, userLikes/{uid}.recentReposts and quotas/{uid}. Firestore: reads 1 in the transaction
  /// (+ visibility check 3 cold / 0 warm, + interceptor; +2 when post_id is a REPOST), writes 6. Replay: +1 read
  /// (reposts/{id}), 0 writes.
  static const repostPost = connect.Spec(
    '/$name/RepostPost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RepostPostRequest.new,
    dzerothengagementv1engagement.RepostPostResponse.new,
  );

  /// Undo a repost. post_id is the ORIGINAL post (use embedded.post_id of a REPOST item). Idempotent: not
  /// reposted => success with 0 writes. One read of reposts/{id}, then one batch: deletes reposts/{id} (Exists
  /// precondition) and the REPOST post doc, decrements the original's repostCount (skipped when it is gone) and
  /// users.postsCount, ArrayRemove on userLikes.recentReposts. Firestore: reads 1 (+ the original for the returned
  /// counts, cache first), writes 3 + 2 deletes.
  static const undoRepost = connect.Spec(
    '/$name/UndoRepost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.UndoRepostRequest.new,
    dzerothengagementv1engagement.UndoRepostResponse.new,
  );
}
