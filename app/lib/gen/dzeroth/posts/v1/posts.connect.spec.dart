//
//  Generated code. Do not modify.
//  source: dzeroth/posts/v1/posts.proto
//

import "package:connectrpc/connect.dart" as connect;
import "posts.pb.dart" as dzerothpostsv1posts;

abstract final class PostService {
  /// Fully-qualified name of the PostService service.
  static const name = 'dzeroth.posts.v1.PostService';

  /// Create a post, reply or quote. Text <= 280 code points after NFC; <= 4 READY media owned by the caller;
  /// <= 10 mentions (resolved via handles/*, cached), <= 10 hashtags (extracted server-side).
  /// Requires a verified email or a Google/Apple provider. Quota: 100 posts/day (quotas/{uid}; 20/day for
  /// accounts younger than 24 h).
  /// Slice 1 (ADR-0010 D2): root posts only. A non-empty reply_to_post_id, quote_of_post_id, media_ids or
  /// media_alt_texts => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" | "quotes" |
  /// "media" (first match in that order), 0 reads, until the replies/engagement/media slices ship.
  /// Text (ADR-0010 D9): CRLF/CR -> LF, TAB -> space, NFC, trim; empty, control characters other than LF, or bidi
  /// formatting controls (U+202A-U+202E, U+2066-U+2069) => VALIDATION field "text"; <= 280 code points, <= 10
  /// lines. Links are kept as typed and count toward the length (no server rewriting or previews).
  /// Mentions (ADR-0010 D7): "@" + handle (3-15 of [A-Za-z0-9_], not preceded by a letter/number/_@#/.:&$+-,
  /// never truncated); first 10 distinct, stored lower-cased as {user_id, handle}. Unknown handles stay plain
  /// text; mentions of users who blocked the author are dropped (all mentions are dropped if the author's
  /// blocked-by list overflowed); mentioning a user the author blocks is allowed.
  /// Hashtags (ADR-0010 D8): "#" + 1-50 of letters/marks/numbers/_ (plus ZWJ/ZWNJ inside), >= 1 letter;
  /// lower-cased, first 10 distinct stored; the text is unchanged.
  /// One transaction: idempotency doc + quotas read fresh; Create idempotency doc + Create post +
  /// users.postsCount + quotas (+ parent replyCount / quoted quoteCount once those ship). The post id (and
  /// created_at) is drawn in each transaction attempt; the transaction has a 5 s deadline (ADR-0010 D13).
  /// Replay: idempotency doc exists => return the stored post (+1 read if not cached); a different body =>
  /// INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED, 0 writes.
  /// Firestore until replies/quotes/media ship (ADR-0010): reads 14 cold / 2 warm, planning 2.5 (caller users via
  /// the account-status interceptor 1 + author graph 1, only if the text has mention candidates + handles <= 10 in
  /// one GetAll + idempotency 1 + quotas 1); writes 4/4 (idempotency, post, users.postsCount, quotas) + 1 eventual
  /// TTL delete. Replay: reads 14 cold / 1 warm, writes 0.
  /// Full contract once replies, quotes, media and notifications ship: reads 19/1, writes 6/4 (+<= 11 async
  /// notification writes: 1 per mentioned user + 1 for the parent/quoted author).
  static const createPost = connect.Spec(
    '/$name/CreatePost',
    connect.StreamType.unary,
    dzerothpostsv1posts.CreatePostRequest.new,
    dzerothpostsv1posts.CreatePostResponse.new,
  );

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
  static const deletePost = connect.Spec(
    '/$name/DeletePost',
    connect.StreamType.unary,
    dzerothpostsv1posts.DeletePostRequest.new,
    dzerothpostsv1posts.DeletePostResponse.new,
  );

  /// A single post. NOT_FOUND ("post not found", byte-identical in every case) if the post is missing or
  /// deleted, hidden by visibility, the author blocks the caller, or the author is SUSPENDED, DELETING or gone.
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner (ADR-0010 D6).
  /// Viewer flags are always false until engagement ships (no userLikes read, ADR-0010 D3).
  /// Reads: caller users (account-status interceptor) + post + author users (status) + caller graph (blocked-by),
  /// all instance-cached 60 s; +1 author graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 4 cold (+1 overflow) / 0 warm, planning 1; +1 (userLikes) once engagement ships. Writes 0.
  static const getPost = connect.Spec(
    '/$name/GetPost',
    connect.StreamType.unary,
    dzerothpostsv1posts.GetPostRequest.new,
    dzerothpostsv1posts.GetPostResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Post detail: the focal post, its parent and conversation root, and a page of the conversation in
  /// chronological order (posts where conversationId == root, createdAt ASC). Blocked/muted/invisible
  /// replies are dropped after the read (page may be short; follow next_page_token).
  /// Returns UNIMPLEMENTED until the replies slice (P3); its ADR restates this budget.
  /// Firestore: reads 56/10 (focal+parent+root 3, graphs 2, userLikes 1, page <= 50), writes 0.
  static const getThread = connect.Spec(
    '/$name/GetThread',
    connect.StreamType.unary,
    dzerothpostsv1posts.GetThreadRequest.new,
    dzerothpostsv1posts.GetThreadResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
