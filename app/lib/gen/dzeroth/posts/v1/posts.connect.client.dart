//
//  Generated code. Do not modify.
//  source: dzeroth/posts/v1/posts.proto
//

import "package:connectrpc/connect.dart" as connect;
import "posts.pb.dart" as dzerothpostsv1posts;
import "posts.connect.spec.dart" as specs;

extension type PostServiceClient (connect.Transport _transport) {
  /// Create a post, reply or quote. Text <= 280 code points after NFC; <= 4 READY media owned by the caller;
  /// <= 10 mentions (resolved via handles/*, cached), <= 10 hashtags (extracted server-side).
  /// Requires a verified email or a Google/Apple provider. Quota: 100 posts/day (quotas/{uid}).
  /// One atomic batch: Create idempotency doc + Create post + users.postsCount + quotas (+ parent replyCount /
  /// quoted quoteCount). Replay: idempotency doc exists => read it (+1) and return the stored post.
  /// Reads worst: quotas 1 + author user 1 + media 4 + parent 1 + quoted 1 + mention handles 10 + replay 1.
  /// Async: 1 notification per mentioned user + 1 for the parent/quoted author.
  /// Firestore: reads 19/1, writes 6/4 (+<= 11 async notification writes).
  Future<dzerothpostsv1posts.CreatePostResponse> createPost(
    dzerothpostsv1posts.CreatePostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.createPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Delete own post. Sync: delete post doc, decrement users.postsCount (and parent replyCount).
  /// Async `post-delete` job: likes/reposts docs, quote embeds, media objects (batches <= 500, resumable).
  /// Replay/unknown id => success (idempotent). Instance caches evicted locally; others converge in <= 60 s.
  /// Firestore: reads 1/1, writes 2/1, deletes 1/1 (+ async deletes = likes + reposts of the post).
  Future<dzerothpostsv1posts.DeletePostResponse> deletePost(
    dzerothpostsv1posts.DeletePostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.deletePost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// A single post. NOT_FOUND if deleted, hidden by visibility, or the author blocks the caller.
  /// Reads: post (cached 60 s) + author graph (blocked-by, cached) + caller graph (cached) + userLikes (cached).
  /// Firestore: reads 4/0-1, writes 0.
  Future<dzerothpostsv1posts.GetPostResponse> getPost(
    dzerothpostsv1posts.GetPostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.getPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Post detail: the focal post, its parent and conversation root, and a page of the conversation in
  /// chronological order (posts where conversationId == root, createdAt ASC). Blocked/muted/invisible
  /// replies are dropped after the read (page may be short; follow next_page_token).
  /// Firestore: reads 56/10 (focal+parent+root 3, graphs 2, userLikes 1, page <= 50), writes 0.
  Future<dzerothpostsv1posts.GetThreadResponse> getThread(
    dzerothpostsv1posts.GetThreadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.getThread,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
