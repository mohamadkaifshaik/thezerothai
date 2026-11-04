//
//  Generated code. Do not modify.
//  source: dzeroth/engagement/v1/engagement.proto
//

import "package:connectrpc/connect.dart" as connect;
import "engagement.pb.dart" as dzerothengagementv1engagement;
import "engagement.connect.spec.dart" as specs;

extension type EngagementServiceClient (connect.Transport _transport) {
  /// Like a post. Idempotent: liking a liked post succeeds and writes nothing. Quota: 500 likes/day/user (100 for
  /// accounts younger than 24 h), RESOURCE_EXHAUSTED + QUOTA_EXCEEDED metadata["quota"]="likes". Per-user bucket
  /// RATE_LIMIT_LIKES_PER_MIN (30/min).
  /// One transaction: reads quotas/{uid}; writes likes/{id} (Create; AlreadyExists at commit is the replay),
  /// posts/{id}.likeCount (Increment), userLikes/{uid} (ArrayUnion; trimmed to the newest 1,000 by a separate
  /// best-effort write) and quotas/{uid}.
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

  /// Remove a like. Idempotent: not liked => success and writes nothing. Needs no visibility check (a user can always
  /// retract), so a post that became invisible or was deleted can still be unliked.
  /// One batch: Delete likes/{id} (Exists precondition), posts/{id}.likeCount (Increment -1, skipped when the post
  /// is gone) and userLikes/{uid} (ArrayRemove). The post is read cache-first for the returned counts; a no-op writes nothing.
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
  /// returns the existing repost without writing. A repost of a REPOST resolves to the original. Counts toward the posts
  /// quota (100/day, 20 for new accounts) and users.postsCount.
  /// One transaction: reads quotas/{uid}; writes reposts/{id}, posts/{newId}, posts/{id}.repostCount,
  /// users/{uid}.postsCount, userLikes/{uid}.recentReposts and quotas/{uid}. A replay writes nothing.
  /// Protected authors: reposting a protected account's post is refused for everyone but that account. A
  /// caller who may not see the post gets NOT_FOUND "post not found" (the visibility check); an approved follower gets
  /// FAILED_PRECONDITION + PROTECTED_ACCOUNT; both write nothing. The account may repost its own post.
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
  /// reposted => success and writes nothing. One read of reposts/{id}, then one batch: deletes reposts/{id} (Exists
  /// precondition) and the REPOST post doc, decrements the original's repostCount (skipped when it is gone) and
  /// users.postsCount, ArrayRemove on userLikes.recentReposts. The original is read cache-first for the returned counts.
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

  /// Bookmark a post. A REPOST id bookmarks its original (the returned post_id). The post must be visible to the
  /// caller by the GetPost rules (missing, deleted, hidden, suspended or blocking author, or a QUOTE whose embedded
  /// author blocks the caller => NOT_FOUND "post not found", writing nothing).
  /// Idempotency (rule 4): idempotency/{hash(uid, "AddBookmark", key)} is stored in the same transaction (TTL'd); a
  /// replay returns the stored state and writes nothing even if the bookmark was removed since, and a different post_id
  /// under the same key => INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED. Bookmarking an already bookmarked post with a
  /// fresh key succeeds, writing only the idempotency doc, so a late retry replays (bookmarked_at is unchanged).
  /// Caps: at most BOOKMARKS_MAX_PER_USER bookmarks (1,000; exact: counted from userLikes/{uid}.bookmarks read inside
  /// the transaction) => FAILED_PRECONDITION + LIMIT_REACHED metadata["limit"] = "bookmarks"; QUOTA_BOOKMARKS_PER_DAY
  /// adds per IST day (200; 50 for accounts younger than 24 h) => RESOURCE_EXHAUSTED + QUOTA_EXCEEDED
  /// metadata["quota"] = "bookmarks". A replay or an already bookmarked post is not charged.
  /// One transaction: reads idempotency, quotas and userLikes fresh; Create users/{uid}/bookmarks/{postId}, Create
  /// the idempotency doc, set quotas/{uid}.bookmarks, ArrayUnion userLikes/{uid}.bookmarks (the complete set of the
  /// caller's bookmarked post ids, which hydrates viewer state without an extra lookup).
  /// A replay, and a refusal at the cap or the quota, write nothing; bookmarking an already bookmarked post writes only
  /// the idempotency doc.
  Future<dzerothengagementv1engagement.AddBookmarkResponse> addBookmark(
    dzerothengagementv1engagement.AddBookmarkRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.addBookmark,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Remove a bookmark. post_id is the id AddBookmark returned (the original for a REPOST; a REPOST id here is a
  /// no-op). Needs no visibility check: a user can always remove a bookmark of a post that was deleted or became
  /// invisible. Not charged to a daily quota. Idempotent: not bookmarked => success, writing only the idempotency doc.
  /// Idempotency (rule 4): as AddBookmark ("RemoveBookmark" in the hash); a replay returns the stored state and
  /// writes nothing, so a late retry never removes a bookmark that was added again after it.
  /// One transaction: reads idempotency; Delete users/{uid}/bookmarks/{postId} (Exists precondition), Create the
  /// idempotency doc and ArrayRemove userLikes/{uid}.bookmarks; a failed Exists is the no-op (only the idempotency doc is written).
  /// A no-op writes only the idempotency doc; a replay writes nothing.
  Future<dzerothengagementv1engagement.RemoveBookmarkResponse> removeBookmark(
    dzerothengagementv1engagement.RemoveBookmarkRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.removeBookmark,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's bookmarks, most recently bookmarked first, each rendered from the LIVE post (current text, author
  /// snapshot and counts; viewer flags as in timelines). page_size 0 => 20, clamped to 1..50. Opaque page_token
  /// bound to the caller (cursor (bookmarkedAt, postId)); expired, foreign or tampered => INVALID_ARGUMENT +
  /// VALIDATION metadata["field"] = "page_token", before any lookup: drop it and reload the first page.
  /// Client contract: there is no since_token and no removed_ids. On every open, REPLACE the cached first page with
  /// the response, then scroll with next_page_token.
  /// Rows are dropped after the read: the post is missing (deleted, or its author's account was
  /// purged), hidden by a moderator (takedown or author suspension), or its author (or a QUOTE's embedded author) is
  /// blocked by, blocks, or is muted by the caller (the same drop rule as Home). A page may therefore be short or
  /// empty while next_page_token is non-empty: keep following it while it is non-empty. A post whose author is
  /// DELETING is shown until the purge deletes it, as in Home.
  /// A row whose post no longer exists is pruned (its bookmark doc deleted and its id removed from
  /// userLikes.bookmarks, best effort, once); hidden and blocked rows are kept, because a restore or an unblock
  /// brings them back. No pruning under DEGRADED_MODE=readonly.
  /// Protected authors: a post by a protected account the caller does not follow, or a REPOST of one, is
  /// dropped too, and kept, not pruned: it comes back when the caller follows the account or the account unprotects.
  /// A QUOTE of such a post is shown with embed_viewer_state = PROTECTED and its embed stripped.
  /// The graph and userLikes are cached 60 s. A page that prunes also removes each pruned row's bookmark and updates
  /// userLikes (a deleted post's bookmark is pruned once); any other page writes nothing.
  Future<dzerothengagementv1engagement.ListBookmarksResponse> listBookmarks(
    dzerothengagementv1engagement.ListBookmarksRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.listBookmarks,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's own likes, most recently liked first. OWNER-ONLY: the request has no user id and
  /// must never get one; the source is userLikes/{caller}.recent (the newest 1,000 likes, read through engagement's
  /// 60 s cache), so nobody can list another user's likes. Likes older than the newest 1,000 are not listed, and there
  /// is no liked-at time (recent[] stores none). Each row is the LIVE post (one cache-first posts GetMany of the
  /// page's ids) with viewer flags from the same userLikes read.
  /// Needs FEATURE_LIKES_LIST (wire name "likes_list") on for the caller, and FEATURE_POSTS; it does not need
  /// FEATURE_ENGAGEMENT (it lists likes made while that was on). Otherwise FAILED_PRECONDITION + FEATURE_DISABLED,
  /// metadata["feature"] = "likes_list", before any lookup. Rate limit: RATE_LIMIT_LIKES_LIST_PER_MIN, 10/min/uid per instance
  /// (at most 30/min with 3 instances).
  /// Rows are dropped after the read, as in ListBookmarks: the post is missing, hidden by a moderator, or its author
  /// (or a QUOTE's or REPOST's embedded author) is blocked by, blocks, or is muted by the caller. Nothing is pruned
  /// (the like path owns recent[]), so a page may be short or empty while next_page_token is non-empty: keep
  /// following it while it is non-empty. Protected authors: the ListBookmarks rule (dropped, never
  /// pruned; a QUOTE kept with embed_viewer_state = PROTECTED).
  /// page_size 0 => 20, clamped to 1..50. page_token is opaque, bound to the caller ("likes" feed), 24 h TTL; it
  /// resumes by post id (the next and last returned ids, then an offset from the newest end), so an unlike, re-like
  /// or trim between pages skips or repeats nothing beyond the rows changed at the page boundary. Expired, foreign or
  /// tampered => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", before any lookup: reload the first page.
  /// Client contract: no since_token, no removed_ids; on every open REPLACE the cached first page.
  Future<dzerothengagementv1engagement.ListLikedPostsResponse> listLikedPosts(
    dzerothengagementv1engagement.ListLikedPostsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.listLikedPosts,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Vote in a post's poll. One vote per account per poll, final: it cannot be changed or withdrawn.
  /// Owns pollVotes/{postId}_{uid} {postId, uid, choice, createdAt, expireAt = closes_at + 30 d, TTL}. Nobody, the
  /// author included, can list who voted or for what; no notification is sent.
  /// Order (each refusal writes nothing):
  /// 1. Interceptors, before any handler read: per-uid bucket RATE_LIMIT_POLL_VOTE_PER_MIN (30/min per instance, at
  ///    most 90/min with 3 instances) and the daily cap POLL_VOTES_PER_DAY (300; 50 for new accounts; per instance, so
  ///    at most 900) => RESOURCE_EXHAUSTED + RATE_LIMITED (metadata["limit"] = "poll_votes_daily" for the cap).
  ///    DEGRADED_MODE=readonly => UNAVAILABLE + DEGRADED_MODE.
  /// 2. Flags, before any lookup: FEATURE_ENGAGEMENT on for the caller and FEATURE_POLLS not globally off (a caller outside a
  ///    "polls" allowlist may vote in an existing poll); else FAILED_PRECONDITION + FEATURE_DISABLED,
  ///    metadata["feature"] = "engagement" or "polls". FEATURE_POSTS must be on.
  /// 3. Shape, before any lookup: idempotency_key format, post_id 19 digits, choice_index 0..3, verified email or Google/Apple
  ///    provider; else VALIDATION (field "idempotency_key" | "post_id" | "choice_index") or EMAIL_NOT_VERIFIED.
  /// 4. The post must be visible to the caller by the GetPost rules (else NOT_FOUND "post not found", byte-identical);
  ///    a REPOST id votes in its original.
  /// 5. On that post, by server time: no poll => VALIDATION field "post_id"; the caller is the author => VALIDATION
  ///    field "post_id"; closed => FAILED_PRECONDITION + POLL_CLOSED; choice_index beyond its choices => VALIDATION
  ///    field "choice_index".
  /// 6. One batch, no read in it: Create the vote doc, Increment the post's poll counters (Exists precondition) and
  ///    ArrayUnion the choice into userLikes/{uid}. A concurrent or repeated vote commits at most once.
  /// 7. The vote doc already exists: the same choice is a replay (success, the current state, nothing written); another choice
  ///    => FAILED_PRECONDITION + ALREADY_VOTED with metadata["choice"] = the stored 0-based index; call again with that
  ///    choice to get the results view. The response's viewer_poll_choice and results come from the vote, never from
  ///    userLikes.
  /// Accepted in principle 2026-10-31, behaviour arrives later: a vote is changeable until
  /// closes_at, and a caller who blocks the poll's author cannot vote or change. Step 5 gains, after the choice_index
  /// check: the caller blocks the poll's author (a REPOST id: the original's author) => FAILED_PRECONDITION +
  /// TARGET_BLOCKED, writing nothing, for a cast, a change and a replay alike. An author who blocks the caller, or a mutual
  /// block, still answers the byte-identical NOT_FOUND of step 4; a mute is not a block. Steps 6 and 7 become, with the
  /// stored vote cs and change count n, the requested choice_index c and e = expected_choice:
  ///    no vote doc => a new vote (step 6), any e;
  ///    cs == c => replay, the current view, nothing written, any e;
  ///    cs != c and e == cs+1 and n < POLL_VOTE_CHANGES_MAX => a change;
  ///    cs != c and e == cs+1 and n >= POLL_VOTE_CHANGES_MAX => FAILED_PRECONDITION + LIMIT_REACHED with
  ///      metadata["limit"] = "poll_vote_changes" and metadata["choice"] = cs (0-based), nothing written;
  ///    cs != c and e != cs+1 (0 from an older client, or a stale value) => FAILED_PRECONDITION + ALREADY_VOTED with
  ///      metadata["choice"] = cs, nothing written.
  /// After closes_at every call answers POLL_CLOSED, changes and replays included. Until lands the server ignores
  /// expected_choice and keeps a vote final, as steps 6 and 7 below say.
  /// 8. Write contention on a hot poll after the server's bounded retry => UNAVAILABLE with retry_after; retry once with
  ///    the same idempotency_key.
  /// Idempotency (the idempotency rule is bent here, founder decision 2026-10-27): the key is validated
  /// but not stored; pollVotes/{postId}_{uid} is the record.
  /// All lookups but the interceptor's are cached 60 s. A replay, ALREADY_VOTED and a refusal at step 5 write nothing.
  Future<dzerothengagementv1engagement.VotePollResponse> votePoll(
    dzerothengagementv1engagement.VotePollRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.EngagementService.votePoll,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
