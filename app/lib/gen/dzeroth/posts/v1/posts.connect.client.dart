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
  /// Requires a verified email or a Google/Apple provider. Quota: 100 posts/day (quotas/{uid}; 20/day for
  /// accounts younger than 24 h).
  /// Slice 1 (ADR-0010 D2): root posts only. A non-empty reply_to_post_id, quote_of_post_id, media_ids or
  /// media_alt_texts => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" | "quotes" |
  /// "media" (first match in that order), 0 reads, until the replies/engagement/media slices ship.
  /// Replies (P3, plan replies-and-threads.md): reply_to_post_id is honoured when FEATURE_REPLIES is on for the caller (else
  /// FEATURE_DISABLED, metadata["feature"]="replies"). The parent must be visible to the caller by the GetPost
  /// rules (missing, deleted, hidden, suspended author or an author who blocks the caller => NOT_FOUND
  /// "post not found", 0 writes). The reply copies the parent's conversation_id, sets reply_to_handle, increments
  /// the parent's reply_count in the same transaction and is never fanned out to the home timeline.
  /// Reply reads 15 cold / 3 warm, writes 5 (idempotency, post, users.postsCount, quotas, parent replyCount).
  /// Text (ADR-0010 D9): CRLF/CR -> LF, TAB -> space, NFC, trim; empty, control characters other than LF, or bidi
  /// formatting controls (U+202A-U+202E, U+2066-U+2069) => VALIDATION field "text"; <= 280 code points, <= 10
  /// lines. Links are kept as typed and count toward the length (no server rewriting or previews).
  /// Mentions (ADR-0010 D7): "@" + handle (3-15 of [A-Za-z0-9_], not preceded by a letter/number/_@#/.:&$+-,
  /// never truncated); first 10 distinct, stored lower-cased as {user_id, handle}. Unknown handles stay plain
  /// text; mentions never depend on the block graph (a user who blocked the author is kept, so the response
  /// cannot reveal the block, ADR-0010 D7 M2); mentioning a user the author blocks is allowed.
  /// Hashtags (ADR-0010 D8): "#" + 1-50 of letters/marks/numbers/_ (plus ZWJ/ZWNJ inside), >= 1 letter;
  /// lower-cased, first 10 distinct stored; the text is unchanged.
  /// One transaction: idempotency doc + quotas read fresh; Create idempotency doc + Create post +
  /// users.postsCount + quotas (+ parent replyCount / quoted quoteCount once those ship). The post id (and
  /// created_at) is drawn in each transaction attempt; the transaction has a 5 s deadline (ADR-0010 D13).
  /// Replay: idempotency doc exists => return the stored post (+1 read if not cached); a different body =>
  /// INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED, 0 writes.
  /// Firestore until replies/quotes/media ship (ADR-0010): reads 14 cold / 2 warm, planning 2.5 (caller users via
  /// the account-status interceptor 1 + handles <= 10 in (no author graph read since M2) if the text has mention
  /// candidates in one GetAll + idempotency 1 + quotas 1); writes 4/4 (idempotency, post, users.postsCount, quotas) + 1 eventual
  /// TTL delete. Replay: reads 14 cold / 1 warm, writes 0.
  /// Full contract once replies, quotes, media and notifications ship: reads 19/1, writes 6/4 (+<= 11 async
  /// notification writes: 1 per mentioned user + 1 for the parent/quoted author).
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

  /// Delete own post. post_id must be 19 digits (else VALIDATION). Only the author's call deletes anything:
  /// another user's post, an unknown id and an already-deleted post all return success with 0 writes,
  /// byte-identical, so the call reveals neither existence nor blocks (ADR-0010 D4). Replay => success.
  /// Sync: one batch Delete(post, Exists) + users.postsCount -1; a failed Exists precondition (a concurrent
  /// delete won) => success, 0 writes, so the counter is decremented exactly once. Instance caches are evicted
  /// locally; others converge in <= 60 s.
  /// Until replies/media/engagement ship there is no async work (a root post has no dependants).
  /// Firestore until then: reads 2 cold / 0 warm, planning 1 (interceptor caller users + post); writes 1/1,
  /// deletes 1/1 (0/0 on a no-op).
  /// Full contract later: + parent replyCount (writes 2/1) and an async `post-delete` job for likes/reposts docs,
  /// quote embeds and media objects (batches <= 500, resumable; + async deletes = likes + reposts of the post).
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

  /// A single post. NOT_FOUND ("post not found", byte-identical in every case) if the post is missing or
  /// deleted, hidden by visibility, the author blocks the caller, or the author is SUSPENDED, DELETING or gone.
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner (ADR-0010 D6).
  /// Viewer flags are always false until engagement ships (no userLikes read, ADR-0010 D3).
  /// Reads: caller users (account-status interceptor) + post + author users (status) + caller graph (blocked-by),
  /// all instance-cached 60 s; +1 author graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 4 cold (+1 overflow) / 0 warm, planning 1; +1 (userLikes) once engagement ships. Writes 0.
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
  /// chronological order (posts where conversationId == root, createdAt ASC, the root itself skipped).
  /// Behind FEATURE_REPLIES (and FEATURE_POSTS); FEATURE_DISABLED with metadata["feature"] = "replies" if off.
  /// NOT_FOUND "post not found" (the GetPost rules) if the focal post is missing, deleted, hidden, or its author
  /// blocks the caller. A parent/root that is deleted, suspended, hidden or blocks the caller is not an error:
  /// it is returned unset with parent_unavailable / root_unavailable = true so the client renders a tombstone.
  /// Replies by authors the caller blocks or mutes (and by authors who block the caller) are dropped after the
  /// read, so a page may be short; follow next_page_token while it is non-empty.
  /// page_size: default 10 (first page, cost-model lever 6.2), clamped to 1..30. Opaque page_token bound to
  /// the caller and the focal post.
  /// Firestore (plan replies-and-threads.md): reads <= 1 (interceptor) + focal 1 + parent/root 2 + <= 3 author profiles
  /// + caller graph 1 (+1 author graph on blockedBy overflow) + page <= 30 = 38 cold, <= 3 warm
  /// (one conversation query, minimum 1); writes 0.
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
