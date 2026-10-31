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
  /// Protected authors (ADR-0025 D5): reposting a protected account's post is refused for everyone but that account. A
  /// caller who may not see the post gets NOT_FOUND "post not found" (the visibility check); an approved follower gets
  /// FAILED_PRECONDITION + PROTECTED_ACCOUNT; both 0 writes. The account may repost its own post.
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

  /// Bookmark a post. A REPOST id bookmarks its original (the returned post_id). The post must be visible to the
  /// caller by the GetPost rules (missing, deleted, hidden, suspended or blocking author, or a QUOTE whose embedded
  /// author blocks the caller => NOT_FOUND "post not found", 0 writes).
  /// Idempotency (rule 4): idempotency/{hash(uid, "AddBookmark", key)} is stored in the same transaction (TTL'd); a
  /// replay returns the stored state with 0 writes even if the bookmark was removed since, and a different post_id
  /// under the same key => INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED. Bookmarking an already bookmarked post with a
  /// fresh key succeeds with 1 write, the idempotency doc, so a late retry replays (bookmarked_at is unchanged).
  /// Caps: at most BOOKMARKS_MAX_PER_USER bookmarks (1,000; exact: counted from userLikes/{uid}.bookmarks read inside
  /// the transaction) => FAILED_PRECONDITION + LIMIT_REACHED metadata["limit"] = "bookmarks"; QUOTA_BOOKMARKS_PER_DAY
  /// adds per IST day (200; 50 for accounts younger than 24 h) => RESOURCE_EXHAUSTED + QUOTA_EXCEEDED
  /// metadata["quota"] = "bookmarks". A replay or an already bookmarked post is not charged.
  /// One transaction: reads idempotency, quotas and userLikes fresh; Create users/{uid}/bookmarks/{postId}, Create
  /// the idempotency doc, set quotas/{uid}.bookmarks, ArrayUnion userLikes/{uid}.bookmarks (the complete set of the
  /// caller's bookmarked post ids, which hydrates viewer state with no extra read; ADR-0023 D3).
  /// Firestore: reads 7 cold / 3 warm, planning 4 (interceptor 1, visibility check post + author users + caller graph
  /// 3 cold / 0 warm, idempotency 1, quotas 1, userLikes 1; +2 when post_id is a REPOST, +1 on blockedBy overflow);
  /// writes 4 (bookmark, idempotency, quotas, userLikes) + 1 TTL delete later. Replay: reads 5 cold / 1 warm, writes
  /// 0. Already bookmarked: writes 1 (idempotency). At the cap or at the quota: writes 0.
  static const addBookmark = connect.Spec(
    '/$name/AddBookmark',
    connect.StreamType.unary,
    dzerothengagementv1engagement.AddBookmarkRequest.new,
    dzerothengagementv1engagement.AddBookmarkResponse.new,
  );

  /// Remove a bookmark. post_id is the id AddBookmark returned (the original for a REPOST; a REPOST id here is a
  /// no-op). Needs no visibility check: a user can always remove a bookmark of a post that was deleted or became
  /// invisible. Not charged to a daily quota. Idempotent: not bookmarked => success with 1 write (the idempotency doc).
  /// Idempotency (rule 4): as AddBookmark ("RemoveBookmark" in the hash); a replay returns the stored state with 0
  /// writes, so a late retry never removes a bookmark that was added again after it.
  /// One transaction: reads idempotency; Delete users/{uid}/bookmarks/{postId} (Exists precondition), Create the
  /// idempotency doc and ArrayRemove userLikes/{uid}.bookmarks; a failed Exists is the no-op (1 write: idempotency).
  /// Firestore: reads 2 cold / 1 warm (interceptor, idempotency); writes 2 (idempotency, userLikes) + 1 delete + 1
  /// TTL delete later; a no-op writes 1 (idempotency), a replay 0.
  static const removeBookmark = connect.Spec(
    '/$name/RemoveBookmark',
    connect.StreamType.unary,
    dzerothengagementv1engagement.RemoveBookmarkRequest.new,
    dzerothengagementv1engagement.RemoveBookmarkResponse.new,
  );

  /// The caller's bookmarks, most recently bookmarked first, each rendered from the LIVE post (current text, author
  /// snapshot and counts; viewer flags as in timelines). page_size 0 => 20, clamped to 1..50. Opaque page_token
  /// bound to the caller (cursor (bookmarkedAt, postId)); expired, foreign or tampered => INVALID_ARGUMENT +
  /// VALIDATION metadata["field"] = "page_token", 0 reads: drop it and reload the first page.
  /// Client contract: there is no since_token and no removed_ids. On every open, REPLACE the cached first page with
  /// the response, then scroll with next_page_token.
  /// Rows are dropped after the read (ADR-0023 D2): the post is missing (deleted, or its author's account was
  /// purged), hidden by a moderator (takedown or author suspension), or its author (or a QUOTE's embedded author) is
  /// blocked by, blocks, or is muted by the caller (the ADR-0010 D6 Home column). A page may therefore be short or
  /// empty while next_page_token is non-empty: keep following it while it is non-empty. A post whose author is
  /// DELETING is shown until the purge deletes it, as in Home.
  /// A row whose post no longer exists is pruned (its bookmark doc deleted and its id removed from
  /// userLikes.bookmarks, best effort, once); hidden and blocked rows are kept, because a restore or an unblock
  /// brings them back. No pruning under DEGRADED_MODE=readonly.
  /// Protected authors (ADR-0025 D4): a post by a protected account the caller does not follow, or a REPOST of one, is
  /// dropped too, and kept, not pruned: it comes back when the caller follows the account or the account unprotects.
  /// A QUOTE of such a post is shown with embed_viewer_state = PROTECTED and its embed stripped. 0 extra reads.
  /// Firestore: reads 1 + page + <= page + 2 cold (interceptor, the bookmarks query, one posts GetMany cache-first,
  /// caller graph, userLikes for viewer flags; graph and userLikes cached 60 s): 43 at page 20, 103 at page 50; an
  /// empty list 2. Warm (posts in the instance cache) 1 + page. Writes 0, plus, on a page that prunes, 1 write
  /// (userLikes ArrayRemove) and 1 delete per pruned row (a deleted post's bookmark is pruned once).
  static const listBookmarks = connect.Spec(
    '/$name/ListBookmarks',
    connect.StreamType.unary,
    dzerothengagementv1engagement.ListBookmarksRequest.new,
    dzerothengagementv1engagement.ListBookmarksResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's own likes, most recently liked first (ADR-0024 D6). OWNER-ONLY: the request has no user id and
  /// must never get one; the source is userLikes/{caller}.recent (the newest 1,000 likes, read through engagement's
  /// 60 s cache), so nobody can list another user's likes. Likes older than the newest 1,000 are not listed, and there
  /// is no liked-at time (recent[] stores none). Each row is the LIVE post (one cache-first posts GetMany of the
  /// page's ids) with viewer flags from the same userLikes read (0 extra reads).
  /// Needs FEATURE_LIKES_LIST (wire name "likes_list") on for the caller, and FEATURE_POSTS; it does not need
  /// FEATURE_ENGAGEMENT (it lists likes made while that was on). Otherwise FAILED_PRECONDITION + FEATURE_DISABLED,
  /// metadata["feature"] = "likes_list", 0 reads. Rate limit: RATE_LIMIT_LIKES_LIST_PER_MIN, 10/min/uid per instance
  /// (at most 30/min with 3 instances). Charged to the per-uid daily read budget (ADR-0010 D5).
  /// Rows are dropped after the read, as in ListBookmarks: the post is missing, hidden by a moderator, or its author
  /// (or a QUOTE's or REPOST's embedded author) is blocked by, blocks, or is muted by the caller. Nothing is pruned
  /// (the like path owns recent[]), so a page may be short or empty while next_page_token is non-empty: keep
  /// following it while it is non-empty. Protected authors (ADR-0025 D4): the ListBookmarks rule (dropped, never
  /// pruned; a QUOTE kept with embed_viewer_state = PROTECTED), 0 extra reads.
  /// page_size 0 => 20, clamped to 1..50. page_token is opaque, bound to the caller ("likes" feed), 24 h TTL; it
  /// resumes by post id (the next and last returned ids, then an offset from the newest end), so an unlike, re-like
  /// or trim between pages skips or repeats nothing beyond the rows changed at the page boundary. Expired, foreign or
  /// tampered => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", 0 reads: reload the first page.
  /// Client contract: no since_token, no removed_ids; on every open REPLACE the cached first page.
  /// Firestore: reads 23 cold at page 20 / 53 at page 50 (interceptor 1, userLikes 1, GetMany <= page, caller graph
  /// 1); warm (posts cached) 20 / 50, planning 22; an empty recent[] 2. Writes 0.
  static const listLikedPosts = connect.Spec(
    '/$name/ListLikedPosts',
    connect.StreamType.unary,
    dzerothengagementv1engagement.ListLikedPostsRequest.new,
    dzerothengagementv1engagement.ListLikedPostsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Vote in a post's poll (ADR-0029 D6, D7). One vote per account per poll, final: it cannot be changed or withdrawn.
  /// Owns pollVotes/{postId}_{uid} {postId, uid, choice, createdAt, expireAt = closes_at + 30 d, TTL}. Nobody, the
  /// author included, can list who voted or for what; no notification is sent.
  /// Order (each refusal writes nothing):
  /// 1. Interceptors, before any handler read: per-uid bucket RATE_LIMIT_POLL_VOTE_PER_MIN (30/min per instance, at
  ///    most 90/min with 3 instances) and the daily cap POLL_VOTES_PER_DAY (300; 50 for new accounts; per instance, so
  ///    at most 900) => RESOURCE_EXHAUSTED + RATE_LIMITED (metadata["limit"] = "poll_votes_daily" for the cap).
  ///    DEGRADED_MODE=readonly => UNAVAILABLE + DEGRADED_MODE.
  /// 2. Flags, 0 reads: FEATURE_ENGAGEMENT on for the caller and FEATURE_POLLS not globally off (a caller outside a
  ///    "polls" allowlist may vote in an existing poll); else FAILED_PRECONDITION + FEATURE_DISABLED,
  ///    metadata["feature"] = "engagement" or "polls". FEATURE_POSTS must be on.
  /// 3. Shape, 0 reads: idempotency_key format, post_id 19 digits, choice_index 0..3, verified email or Google/Apple
  ///    provider; else VALIDATION (field "idempotency_key" | "post_id" | "choice_index") or EMAIL_NOT_VERIFIED.
  /// 4. The post must be visible to the caller by the GetPost rules (else NOT_FOUND "post not found", byte-identical);
  ///    a REPOST id votes in its original.
  /// 5. On that post, by server time: no poll => VALIDATION field "post_id"; the caller is the author => VALIDATION
  ///    field "post_id"; closed => FAILED_PRECONDITION + POLL_CLOSED; choice_index beyond its choices => VALIDATION
  ///    field "choice_index".
  /// 6. One batch, no read in it: Create the vote doc, Increment the post's poll counters (Exists precondition) and
  ///    ArrayUnion the choice into userLikes/{uid}. A concurrent or repeated vote commits at most once.
  /// 7. The vote doc already exists: the same choice is a replay (success, the current state, 0 writes); another choice
  ///    => FAILED_PRECONDITION + ALREADY_VOTED with metadata["choice"] = the stored 0-based index; call again with that
  ///    choice to get the results view. The response's viewer_poll_choice and results come from the vote, never from
  ///    userLikes.
  /// Amendment 1 (ADR-0029, accepted in principle 2026-10-31; behaviour arrives with W6-36): a vote is changeable until
  /// closes_at, and a caller who blocks the poll's author cannot vote or change. Step 5 gains, after the choice_index
  /// check: the caller blocks the poll's author (a REPOST id: the original's author) => FAILED_PRECONDITION +
  /// TARGET_BLOCKED, 0 writes, for a cast, a change and a replay alike. An author who blocks the caller, or a mutual
  /// block, still answers the byte-identical NOT_FOUND of step 4; a mute is not a block. Steps 6 and 7 become, with the
  /// stored vote cs and change count n, the requested choice_index c and e = expected_choice:
  ///    no vote doc => a new vote (step 6), any e;
  ///    cs == c => replay, the current view, 0 writes, any e;
  ///    cs != c and e == cs+1 and n < POLL_VOTE_CHANGES_MAX => a change, 4 writes;
  ///    cs != c and e == cs+1 and n >= POLL_VOTE_CHANGES_MAX => FAILED_PRECONDITION + LIMIT_REACHED with
  ///      metadata["limit"] = "poll_vote_changes" and metadata["choice"] = cs (0-based), 0 writes;
  ///    cs != c and e != cs+1 (0 from an older client, or a stale value) => FAILED_PRECONDITION + ALREADY_VOTED with
  ///      metadata["choice"] = cs, 0 writes.
  /// After closes_at every call answers POLL_CLOSED, changes and replays included. Until W6-36 lands the server ignores
  /// expected_choice and keeps a vote final, as steps 6 and 7 below say.
  /// 8. Write contention on a hot poll after the server's bounded retry => UNAVAILABLE with retry_after; retry once with
  ///    the same idempotency_key.
  /// Idempotency (CLAUDE.md rule 4, bend recorded in ADR-0029 D7, founder decision 2026-10-27): the key is validated
  /// but not stored; pollVotes/{postId}_{uid} is the record.
  /// Firestore: reads 8 worst cold (interceptor 1, post 1, author users 1, caller graph 1, +2 when post_id is a REPOST,
  /// +1 on blockedBy overflow, userLikes 1 for the response's viewer flags; all but the interceptor cached 60 s),
  /// planning 3; writes 3 (vote doc, post counters, userLikes) + 1 TTL delete at closes_at + 30 d. Replay or
  /// ALREADY_VOTED: +1 read (the vote doc), 0 writes. Refused at step 5: <= 7 reads, 0 writes. Charged to the per-uid
  /// daily read budget (ADR-0010 D5).
  static const votePoll = connect.Spec(
    '/$name/VotePoll',
    connect.StreamType.unary,
    dzerothengagementv1engagement.VotePollRequest.new,
    dzerothengagementv1engagement.VotePollResponse.new,
  );
}
