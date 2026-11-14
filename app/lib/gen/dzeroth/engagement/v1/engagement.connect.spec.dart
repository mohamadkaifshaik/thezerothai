//
//  Generated code. Do not modify.
//  source: dzeroth/engagement/v1/engagement.proto
//

import "package:connectrpc/connect.dart" as connect;
import "engagement.pb.dart" as dzerothengagementv1engagement;

abstract final class EngagementService {
  /// Fully-qualified name of the EngagementService service.
  static const name = 'dzeroth.engagement.v1.EngagementService';

  /// Like a post. Idempotent: liking a liked post succeeds and writes nothing. No daily quota: the per-user bucket
  /// RATE_LIMIT_LIKES_PER_MIN (30/min, shared with unlike and repost) is the only limit.
  /// One transaction: writes likes/{id} (Create; AlreadyExists at commit is the replay),
  /// posts/{id}.likeCount (Increment), userLikes/{uid} (ArrayUnion; trimmed to the newest 1,000 by a separate
  /// best-effort write).
  static const likePost = connect.Spec(
    '/$name/LikePost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.LikePostRequest.new,
    dzerothengagementv1engagement.LikePostResponse.new,
  );

  /// Remove a like. Idempotent: not liked => success and writes nothing. Needs no visibility check (a user can always
  /// retract), so a post that became invisible or was deleted can still be unliked.
  /// One batch: Delete likes/{id} (Exists precondition), posts/{id}.likeCount (Increment -1, skipped when the post
  /// is gone) and userLikes/{uid} (ArrayRemove). The post is read cache-first for the returned counts; a no-op writes nothing.
  static const unlikePost = connect.Spec(
    '/$name/UnlikePost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.UnlikePostRequest.new,
    dzerothengagementv1engagement.UnlikePostResponse.new,
  );

  /// Repost a post: creates reposts/{postId}_{uid} and a posts doc with kind REPOST, an embedded snapshot of the
  /// original, authored by the caller (it appears in the caller's profile and in followers' home timelines like
  /// any root post, and is removed by DeletePost or UndoRepost). Reposting a post you already reposted succeeds and
  /// returns the existing repost without writing. A repost of a REPOST resolves to the original. Counts toward
  /// users.postsCount; there is no daily repost quota (the like bucket, 30/min, is the only limit).
  /// One transaction: writes reposts/{id}, posts/{newId}, posts/{id}.repostCount,
  /// users/{uid}.postsCount and userLikes/{uid}.recentReposts. A replay writes nothing.
  /// Protected authors: reposting a protected account's post is refused for everyone but that account. A
  /// caller who may not see the post gets NOT_FOUND "post not found" (the visibility check); an approved follower gets
  /// FAILED_PRECONDITION + PROTECTED_ACCOUNT; both write nothing. The account may repost its own post.
  static const repostPost = connect.Spec(
    '/$name/RepostPost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RepostPostRequest.new,
    dzerothengagementv1engagement.RepostPostResponse.new,
  );

  /// Undo a repost. post_id is the ORIGINAL post (use embedded.post_id of a REPOST item). Idempotent: not
  /// reposted => success and writes nothing. One read of reposts/{id}, then one batch: deletes reposts/{id} (Exists
  /// precondition) and the REPOST post doc, decrements the original's repostCount (skipped when it is gone) and
  /// users.postsCount, ArrayRemove on userLikes.recentReposts. The original is read cache-first for the returned counts.
  static const undoRepost = connect.Spec(
    '/$name/UndoRepost',
    connect.StreamType.unary,
    dzerothengagementv1engagement.UndoRepostRequest.new,
    dzerothengagementv1engagement.UndoRepostResponse.new,
  );

  /// Bookmark a post. A REPOST id bookmarks its original (the returned post_id). The post must be visible to the
  /// caller by the GetPost rules (missing, deleted, hidden, suspended or blocking author, or a QUOTE whose embedded
  /// author blocks the caller => NOT_FOUND "post not found", writing nothing).
  /// Idempotency (rule 4): idempotency/{hash(uid, "AddBookmark", key)} is stored in the same transaction (TTL'd); a
  /// replay returns the stored state and writes nothing even if the bookmark was removed since, and a different post_id
  /// under the same key => INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED. Bookmarking an already bookmarked post with a
  /// fresh key succeeds, writing only the idempotency doc, so a late retry replays (bookmarked_at is unchanged).
  /// Caps: at most BOOKMARKS_MAX_PER_USER bookmarks (1,000; exact: counted from userLikes/{uid}.bookmarks read inside
  /// the transaction) => FAILED_PRECONDITION + LIMIT_REACHED metadata["limit"] = "bookmarks". Rate limits: the
  /// bookmarks bucket (RATE_LIMIT_BOOKMARKS_PER_MIN, 30/min, shared with RemoveBookmark) and the in-memory
  /// bookmark_mutation_daily cap shared with RemoveBookmark (BOOKMARK_MUTATIONS_PER_DAY per uid per instance, counting
  /// every call) => RESOURCE_EXHAUSTED + RATE_LIMITED, metadata["limit"] = "bookmark_mutation_daily". There is no
  /// persisted bookmark quota.
  /// One transaction: reads idempotency and userLikes fresh; Create users/{uid}/bookmarks/{postId}, Create
  /// the idempotency doc, ArrayUnion userLikes/{uid}.bookmarks (the complete set of the
  /// caller's bookmarked post ids, which hydrates viewer state without an extra lookup).
  /// A replay, and a refusal at the cap, write nothing; bookmarking an already bookmarked post writes only
  /// the idempotency doc.
  static const addBookmark = connect.Spec(
    '/$name/AddBookmark',
    connect.StreamType.unary,
    dzerothengagementv1engagement.AddBookmarkRequest.new,
    dzerothengagementv1engagement.AddBookmarkResponse.new,
  );

  /// Remove a bookmark. post_id is the id AddBookmark returned (the original for a REPOST; a REPOST id here is a
  /// no-op). Needs no visibility check: a user can always remove a bookmark of a post that was deleted or became
  /// invisible. Shares the bookmark_mutation_daily cap with AddBookmark. Idempotent: not bookmarked => success, writing only the idempotency doc.
  /// Idempotency (rule 4): as AddBookmark ("RemoveBookmark" in the hash); a replay returns the stored state and
  /// writes nothing, so a late retry never removes a bookmark that was added again after it.
  /// One transaction: reads idempotency; Delete users/{uid}/bookmarks/{postId} (Exists precondition), Create the
  /// idempotency doc and ArrayRemove userLikes/{uid}.bookmarks; a failed Exists is the no-op (only the idempotency doc is written).
  /// A no-op writes only the idempotency doc; a replay writes nothing.
  static const removeBookmark = connect.Spec(
    '/$name/RemoveBookmark',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RemoveBookmarkRequest.new,
    dzerothengagementv1engagement.RemoveBookmarkResponse.new,
  );

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
  static const listBookmarks = connect.Spec(
    '/$name/ListBookmarks',
    connect.StreamType.unary,
    dzerothengagementv1engagement.ListBookmarksRequest.new,
    dzerothengagementv1engagement.ListBookmarksResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

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
  static const listLikedPosts = connect.Spec(
    '/$name/ListLikedPosts',
    connect.StreamType.unary,
    dzerothengagementv1engagement.ListLikedPostsRequest.new,
    dzerothengagementv1engagement.ListLikedPostsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Vote in a post's poll. One vote per account per poll, final: it cannot be changed or withdrawn.
  /// Owns pollVotes/{postId}_{uid} {postId, uid, choice, createdAt, expireAt = closes_at + 30 d, TTL}. Nobody, the
  /// author included, can list who voted or for what; no notification is sent.
  /// Order (each refusal writes nothing):
  /// 1. Interceptors, before any handler read: per-uid bucket RATE_LIMIT_POLL_VOTE_PER_MIN (30/min per instance, at
  ///    most 90/min with 3 instances) => RESOURCE_EXHAUSTED + RATE_LIMITED. There is no daily vote cap.
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
  static const votePoll = connect.Spec(
    '/$name/VotePoll',
    connect.StreamType.unary,
    dzerothengagementv1engagement.VotePollRequest.new,
    dzerothengagementv1engagement.VotePollResponse.new,
  );

  /// Report that the caller shared a post outside the app: "Copy link" succeeded, or the native share sheet reported a
  /// completed share (not a dismissal; where the platform cannot tell, the client does not call). Feeds Post.share_count.
  /// Client-reported and therefore unverifiable: it counts at most ONCE per (caller, post), merged with direct-message
  /// shares (MessagingService.SendMessage shared_post_id) into one marker, so one account can move a post's count by at
  /// most 1 however it shares and however often it calls. The author's own shares are never counted.
  /// Order (each refusal writes nothing):
  /// 1. Interceptors: per-uid bucket RATE_LIMIT_SHARES_PER_MIN (20/min per instance, at most 60/min with 3 instances)
  ///    and the in-memory daily cap SHARES_RECORDED_PER_DAY (300 per uid per instance, counting every call) =>
  ///    RESOURCE_EXHAUSTED + RATE_LIMITED, metadata["limit"] = "shares_daily" for the cap. DEGRADED_MODE=readonly =>
  ///    UNAVAILABLE + DEGRADED_MODE.
  /// 2. Flags, before any lookup: FEATURE_SHARE_COUNT (wire name "share_count") on for the caller, else
  ///    FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "share_count". FEATURE_POSTS must be on.
  /// 3. Shape, before any lookup: idempotency_key format, post_id 19 digits, channel not UNSPECIFIED, verified email or
  ///    Google/Apple provider; else VALIDATION (field "idempotency_key" | "post_id" | "channel") or EMAIL_NOT_VERIFIED.
  /// 4. The post must be visible to the caller by the GetPost rules (else NOT_FOUND "post not found", byte-identical); a
  ///    REPOST id records a share of its original. A protected author's post may be copied by a follower who can see it
  ///    (the link opens only for followers), but it is not counted: success, nothing written.
  /// 5. The caller is the author => success, nothing written.
  /// 6. One read of postShares/{postId}_{uid}; present => success, nothing written (the replay and the repeat). Absent
  ///    => one batch: Create postShares/{postId}_{uid} {postId, uid, createdAt} and Increment posts/{id}.shareCount
  ///    (Exists precondition). A concurrent first share loses the Create and commits nothing, so the count moves once.
  /// Idempotency (the like rule): state-setting and keyed by (post_id, caller); the key is validated but not stored.
  /// channel is logged as a request field for aggregate metrics and is NOT stored.
  /// Worst case: the visibility check (cache-first, 0-3 reads) + 1 read + 2 writes on a first share; 1 read otherwise.
  /// A hot post's counter contention after the bounded retry => UNAVAILABLE with retry_after: the client drops it (the
  /// share itself already happened; never retry in a loop).
  static const recordPostShare = connect.Spec(
    '/$name/RecordPostShare',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RecordPostShareRequest.new,
    dzerothengagementv1engagement.RecordPostShareResponse.new,
  );

  /// Report posts the caller saw (F1 post views, feeds Post.view_count). The client collects the ids of posts that were
  /// on screen, removes the ones it already sent today (its own dedupe), and flushes at most 50 per call, every 30 s and
  /// when the app is paused. Client-reported and therefore unverifiable: the server counts at most ONE impression per
  /// (caller, post, IST day) and never the author's own views. Fire and forget: the response is empty and identical
  /// whatever each id turned out to be (counted, already seen today, the caller's own, missing, hidden, or not visible to
  /// the caller), so it is not an existence oracle. Never retry a success; an error may be retried once with the same key.
  /// Order (each refusal writes nothing):
  /// 1. Interceptors: per-uid bucket RATE_LIMIT_IMPRESSIONS_PER_MIN (6/min per instance) and the in-memory daily cap
  ///    IMPRESSIONS_RECORDED_PER_DAY (500 calls per uid per instance, counting every call) => RESOURCE_EXHAUSTED +
  ///    RATE_LIMITED, metadata["limit"] = "impressions_daily" for the cap. DEGRADED_MODE=readonly => UNAVAILABLE +
  ///    DEGRADED_MODE.
  /// 2. Flags, before any lookup: FEATURE_POST_VIEWS (wire name "post_views") on for the caller, else
  ///    FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "post_views". FEATURE_POSTS must be on.
  /// 3. Shape, before any lookup: idempotency_key format, 1 to 50 post_ids, each 19 digits (duplicates are merged);
  ///    else VALIDATION (field "idempotency_key" | "post_ids").
  /// 4. The posts, in one cache-first read: a REPOST id counts its original; ids that are missing, hidden, by an author
  ///    who blocks the caller or whom the caller may not see (a protected author the caller does not follow), and the
  ///    caller's own posts are dropped silently. A viewer the author blocks is counted but never identified.
  /// 5. One GetAll of users/{uid}/impressions/{postId}_{yyyymmdd} (IST day) for what is left; for each absent doc, in
  ///    one batch: Create the impression {postId, day, createdAt, expireAt = createdAt + 48 h} and increment one of 10
  ///    shard docs posts/{id}/viewShards/{n}. The impression doc is the dedupe record (a concurrent duplicate loses its
  ///    Create and commits nothing). A rollup folds the shards into posts/{id}.viewCount.
  /// Idempotency (the like rule): keyed by (caller, post, IST day); the key is validated but not stored.
  /// Worst case: the post read (cache-first, 0-2 batch reads of up to 50) + 50 reads + 100 writes (plus one small
  /// rollup marker per post and instance every 5 minutes). Hot-post shard contention after the bounded retry =>
  /// UNAVAILABLE with retry_after: the client drops the batch.
  static const recordImpressions = connect.Spec(
    '/$name/RecordImpressions',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RecordImpressionsRequest.new,
    dzerothengagementv1engagement.RecordImpressionsResponse.new,
  );
}
