//
//  Generated code. Do not modify.
//  source: dzeroth/engagement/v1/engagement.proto
//

import "package:connectrpc/connect.dart" as connect;
import "engagement.pb.dart" as dzerothengagementv1engagement;
import "engagement.connect.spec.dart" as specs;

extension type EngagementServiceClient (connect.Transport _transport) {
  /// Like a post. Idempotent: liking a liked post succeeds with 0 writes. Quota: 500 likes/day/user (100 for
  /// accounts younger than 24 h), RESOURCE_EXHAUSTED + QUOTA_EXCEEDED metadata["quota"]="likes". Per-user bucket
  /// RATE_LIMIT_LIKES_PER_MIN (30/min).
  /// One transaction: reads quotas/{uid}; writes likes/{id} (Create; AlreadyExists at commit is the replay),
  /// posts/{id}.likeCount (Increment), userLikes/{uid} (ArrayUnion; trimmed to the newest 1,000 by a separate
  /// best-effort write) and quotas/{uid}.
  /// Firestore: reads 1 in the transaction (+ the visibility check: post, author users, caller graph = 3 cold /
  /// 0 warm, + the account-status interceptor's users read; +2 when post_id is a REPOST), writes 4. Replay: same
  /// reads, 0 writes.
  Future<dzerothengagementv1engagement.LikePostResponse> likePost(
    dzerothengagementv1engagement.LikePostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.likePost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Remove a like. Idempotent: not liked => success with 0 writes. Needs no visibility check (a user can always
  /// retract), so a post that became invisible or was deleted can still be unliked.
  /// One batch: Delete likes/{id} (Exists precondition), posts/{id}.likeCount (Increment -1, skipped when the post
  /// is gone) and userLikes/{uid} (ArrayRemove). Firestore: reads <= 1 (the post for the returned counts, cache
  /// first, +1 when post_id is a REPOST), writes 2 + 1 delete; a no-op writes 0.
  Future<dzerothengagementv1engagement.UnlikePostResponse> unlikePost(
    dzerothengagementv1engagement.UnlikePostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.unlikePost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Repost a post: creates reposts/{postId}_{uid} and a posts doc with kind REPOST, an embedded snapshot of the
  /// original, authored by the caller (it appears in the caller's profile and in followers' home timelines like
  /// any root post, and is removed by DeletePost or UndoRepost). Reposting a post you already reposted succeeds and
  /// returns the existing repost (0 writes). A repost of a REPOST resolves to the original. Counts toward the posts
  /// quota (100/day, 20 for new accounts) and users.postsCount.
  /// One transaction: reads quotas/{uid}; writes reposts/{id}, posts/{newId}, posts/{id}.repostCount,
  /// users/{uid}.postsCount, userLikes/{uid}.recentReposts and quotas/{uid}. Firestore: reads 1 in the transaction
  /// (+ visibility check 3 cold / 0 warm, + interceptor; +2 when post_id is a REPOST), writes 6. Replay: +1 read
  /// (reposts/{id}), 0 writes.
  Future<dzerothengagementv1engagement.RepostPostResponse> repostPost(
    dzerothengagementv1engagement.RepostPostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.repostPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Undo a repost. post_id is the ORIGINAL post (use embedded.post_id of a REPOST item). Idempotent: not
  /// reposted => success with 0 writes. One read of reposts/{id}, then one batch: deletes reposts/{id} (Exists
  /// precondition) and the REPOST post doc, decrements the original's repostCount (skipped when it is gone) and
  /// users.postsCount, ArrayRemove on userLikes.recentReposts. Firestore: reads 1 (+ the original for the returned
  /// counts, cache first), writes 3 + 2 deletes.
  Future<dzerothengagementv1engagement.UndoRepostResponse> undoRepost(
    dzerothengagementv1engagement.UndoRepostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.undoRepost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
