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
  /// Not available while the sub-feature's flag is off for the caller: a non-empty reply_to_post_id
  /// (FEATURE_REPLIES), quote_of_post_id (FEATURE_ENGAGEMENT), media_ids / media_alt_texts (FEATURE_MEDIA), a
  /// reply_policy other than UNSPECIFIED (FEATURE_REPLY_AUDIENCE) or paid_partnership / made_with_ai true
  /// (FEATURE_CONTENT_DISCLOSURE) => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" |
  /// "quotes" | "media" | "reply_audience" | "content_disclosure" (first match in that order), before any lookup.
  /// Reply policy: settable on a root post or a quote only (a non-UNSPECIFIED value on a reply =>
  /// VALIDATION field "reply_policy"); FOLLOWING_OF_FOLLOWING and VERIFIED => VALIDATION field "reply_policy" ("not
  /// available yet"). UNSPECIFIED and EVERYONE are stored as absent. It covers the whole conversation: a reply stores
  /// the policy inherited from its parent. A reply into a FOLLOWING or MENTIONED_ONLY conversation is
  /// checked against the conversation root R after the parent visibility check: an unusable R (missing, not public,
  /// hidden, author not ACTIVE, a block in either direction, caller blockedBy overflow, or a quote root whose embedded
  /// author blocks the caller) => NOT_FOUND "post not found"; otherwise R's author always may reply, FOLLOWING needs
  /// R's author to follow the caller (graph cache 60 s), MENTIONED_ONLY needs the caller in R's mentions; else
  /// PERMISSION_DENIED + REPLY_NOT_ALLOWED (metadata["policy"]), with nothing stored under the idempotency key.
  /// Enforcement is not flag-gated.
  /// Disclosure: paid_partnership and made_with_ai are user-asserted labels, never rejected; copied
  /// into the embedded snapshot of quotes and reposts. Clients compare the returned post's reply_policy and labels
  /// with what they sent (UNSPECIFIED == EVERYONE) and warn on a mismatch.
  /// Quotes (plan engagement.md, FEATURE_ENGAGEMENT): quote_of_post_id is a 19-digit post id that must be visible
  /// to the caller by the GetPost rules (else NOT_FOUND "post not found", writing nothing). Quoting a REPOST quotes its
  /// original. A quote needs its own text or at least one image, cannot also set reply_to_post_id (VALIDATION), is
  /// kind QUOTE, a root post for feeds (never a reply), carries an embedded one-level snapshot of the quoted post
  /// frozen at write time, and increments the quoted post's quote_count in the same transaction.
  /// Deleting the quoted post replaces the embed with an unavailable tombstone (async job).
  /// Protected authors: quoting a protected account's post is refused for everyone but that account:
  /// a caller who may not see the post gets NOT_FOUND "post not found" (the visibility check above), and an approved
  /// follower gets FAILED_PRECONDITION + PROTECTED_ACCOUNT; both write nothing. A reply to such a post by an approved
  /// follower is allowed and is public: it shows its own text, never the parent's.
  /// Replies (plan replies-and-threads.md): reply_to_post_id is honoured when FEATURE_REPLIES is on for the caller (else
  /// FEATURE_DISABLED, metadata["feature"]="replies"). The parent must be visible to the caller by the GetPost
  /// rules (missing, deleted, hidden, suspended author or an author who blocks the caller => NOT_FOUND
  /// "post not found", writing nothing). The reply copies the parent's conversation_id, sets reply_to_handle, increments
  /// the parent's reply_count in the same transaction and is never fanned out to the home timeline.
  /// A reply writes the idempotency doc, the post, users.postsCount, quotas and the parent's replyCount.
  /// Reply audience: a reply into a restricted conversation (FOLLOWING / MENTIONED_ONLY root) is checked after
  /// the parent visibility check. The root and graph lookups behind it use 60 s caches.
  /// A refusal is PERMISSION_DENIED + ERROR_REASON_REPLY_NOT_ALLOWED with metadata "policy" = "following" | "mentioned_only",
  /// writes nothing and does the same lookups as the allowed path. A conversation root that is unusable for the caller (deleted, hidden, suspended or
  /// deleting author, or one who blocks the caller) is NOT_FOUND "post not found", never REPLY_NOT_ALLOWED.
  /// Media (FEATURE_MEDIA): media_ids are 1-4 distinct READY or READY_UNSCREENED POST images owned by the caller
  /// and not yet attached to a post; any other id (missing, someone else's, an avatar, PENDING, REJECTED, already
  /// used) => FAILED_PRECONDITION + MEDIA_NOT_READY, one answer for every cause. media_alt_texts is empty or
  /// parallel to media_ids, each <= 1,000 characters. A post with at least one image may have empty text. The
  /// image refs (url, thumb_url, size, blurhash, alt) are copied into the post; lists render thumb_url only.
  /// Text: CRLF/CR -> LF, TAB -> space, NFC, trim; empty, control characters other than LF, or bidi
  /// formatting controls (U+202A-U+202E, U+2066-U+2069) => VALIDATION field "text"; <= 280 code points, <= 10
  /// lines. Links are kept as typed and count toward the length (no server rewriting or previews).
  /// Mentions: "@" + handle (3-15 of [A-Za-z0-9_], not preceded by a letter/number/_@#/.:&$+-,
  /// never truncated); first 10 distinct, stored lower-cased as {user_id, handle}. Unknown handles stay plain
  /// text; mentions never depend on the block graph (a user who blocked the author is kept, so the response
  /// cannot reveal the block); mentioning a user the author blocks is allowed.
  /// Hashtags: "#" + 1-50 of letters/marks/numbers/_ (plus ZWJ/ZWNJ inside), >= 1 letter;
  /// lower-cased, first 10 distinct stored; the text is unchanged.
  /// One transaction: idempotency doc + quotas read fresh; Create idempotency doc + Create post +
  /// users.postsCount + quotas (+ parent replyCount / quoted quoteCount once those ship). The post id (and
  /// created_at) is drawn in each transaction attempt; the transaction has a 5 s deadline.
  /// Replay: idempotency doc exists => return the stored post (the post is read if not cached); a different body =>
  /// INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED, writing nothing.
  /// Mention candidates in the text resolve their handles in one batch (at most 10). With n images the media docs are read
  /// in one batch inside the transaction and each gets postId set; a replay re-reads no media. Notifications for
  /// mentions and for the parent or quoted author are written asynchronously.
  /// Polls (FEATURE_POLLS, wire name "polls"): a set `poll` while polls is off for the caller =>
  /// FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "polls", before any lookup, checked after "content_disclosure"
  /// in the order above. Root posts only, with non-empty text (the question) and no media: a poll together with
  /// media_ids, reply_to_post_id or quote_of_post_id, or with empty text => VALIDATION field "poll", writing nothing. 2-4
  /// choices, each 1-25 code points after the text rules (NFC, no control or bidi formatting characters, trimmed),
  /// distinct after NFC and case folding; mentions and hashtags in choices are not parsed. duration_minutes 5..10080
  /// (7 days). Otherwise VALIDATION field "poll". The server sets closes_at = created_at + duration. The poll is stored
  /// on the post doc itself. requestHash gains a poll suffix only when a poll is present, so a request
  /// without one replays exactly as before. Clients send `poll` only when GetMe.enabled_features lists "polls", and
  /// check that the returned post carries `poll` (an older server drops the field): if not, warn and offer delete.
  /// GIF media (FEATURE_GIF, wire name "gif"): a media id whose media is a GIF while gif is not enabled
  /// for the caller => FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "gif", after the media reads inside
  /// the transaction (as a MEDIA_NOT_READY refusal), writing nothing. A GIF must be the only media item, else
  /// VALIDATION field "media_ids". MediaRef.content_type is copied from the media doc.
  /// Communities (FEATURE_COMMUNITIES, wire name "communities"; dzeroth.communities.v1 header):
  /// - community_id posts a root post or a quote into that community. A set community_id while communities is off for
  ///   the caller => FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "communities", before any lookup,
  ///   checked after "polls" in the order above. Not 19 digits => VALIDATION field "community_id". With
  ///   reply_to_post_id => VALIDATION field "community_id" (a reply belongs to its root's conversation). With a
  ///   reply_policy other than UNSPECIFIED or EVERYONE => VALIDATION field "reply_policy" (F8: a community conversation
  ///   is members only and takes no policy of its own). Nothing is written.
  /// - Then, in this order (posts.CommunityGate): a protected caller => FAILED_PRECONDITION + PROTECTED_ACCOUNT, before any lookup
  ///   (F6; the interceptor's profile is held); a missing or SUSPENDED community => NOT_FOUND "community not found"
  ///   (byte-identical for both); an ARCHIVED one => FAILED_PRECONDITION + COMMUNITY_STATE metadata["reason"] =
  ///   "community_archived" (status from the 60 s community cache); inside the transaction the caller's member doc, read
  ///   fresh: BANNED => PERMISSION_DENIED + FORBIDDEN metadata["reason"] = "banned", not a member => "not_member" (a ban
  ///   made on another instance stops the next post at once); quotas.communityPosts (50 per IST day, 10 for new accounts,
  ///   on top of the posts quota) in the same quota write => QUOTA_EXCEEDED metadata["quota"] = "community_posts"; then
  ///   the in-memory cap of 20 posts per community per uid per IST day per instance => RATE_LIMITED metadata["limit"] =
  ///   "community_posts_per_community_daily". Every refusal writes nothing.
  /// - Blocks with the community's owner or moderators never refuse a post. The post is an ordinary public
  ///   post (F6, F7): it also shows on the author's profile and in followers' Home, with Post.community as its label.
  /// - The post doc gets communityId, community {id, name} (the name from the cached community doc) and the conversation's
  ///   community in the same write. The request hash covers community_id only when it is set, so a request
  ///   without one replays exactly as before; the same key with another community_id => IDEMPOTENCY_KEY_REUSED.
  /// - The community is read through the cache and the member doc fresh in the transaction.
  /// - Clients send community_id only when GetMe.enabled_features lists "communities", and check that the returned post
  ///   carries `community` (an older server drops the field): if not, warn and offer delete.
  /// Replies in a community conversation: members only. Every reply inherits its parent's conversation
  /// community (the parent is already read). While communities is not globally off, and after the existing
  /// reply rules (a block either way => NOT_FOUND): a SUSPENDED community => NOT_FOUND "community not
  /// found"; an ARCHIVED one => COMMUNITY_STATE "community_archived"; a caller who is not a JOINED member (banned
  /// included) => PERMISSION_DENIED + FORBIDDEN metadata["reason"] = "not_member", writing nothing. The member doc is cached
  /// 60 s on this path, so a ban reaches other instances' reply path within 60 s. The community and member doc are cached. With communities globally off, community posts behave as
  /// ordinary posts: no label and no reply gate (the kill switch).
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
  /// another user's post, an unknown id and an already-deleted post all return success and write nothing,
  /// byte-identical, so the call reveals neither existence nor blocks. Replay => success.
  /// Sync: one batch Delete(post, Exists) + users.postsCount -1; a failed Exists precondition (a concurrent
  /// delete won) => success, writing nothing, so the counter is decremented exactly once. Instance caches are evicted
  /// locally; others converge in <= 60 s.
  /// Every deleted post publishes one `post_delete` job after the commit (Pub/Sub, no Firestore access on the
  /// request path). The job (idempotent, resumable) deletes its public image objects and media documents, its
  /// likes and reposts documents (and the REPOST posts docs those created), and replaces the embedded snapshot of
  /// quotes of it with an unavailable tombstone.
  /// Deleting a REPOST post doc is UndoRepost: its reposts/{originalId}_{uid} doc goes in the same batch and the
  /// original's repostCount is decremented best effort after the commit. Deleting a QUOTE decrements the quoted
  /// post's quoteCount best effort, like a reply's parent replyCount.
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
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner.
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller;
  /// with either on they come from userLikes/{caller} (cache-first, 60 s): liked / reposted only with engagement, bookmarked_by_viewer with either. A REPOST or QUOTE whose embedded author
  /// blocks the caller is NOT_FOUND like a post by that author.
  /// Protected authors: a post by a protected account is NOT_FOUND (the same bytes) for a caller who is
  /// neither that account nor a follower of it, and so is a REPOST of such a post; a QUOTE of one is returned with
  /// embed_viewer_state = PROTECTED and its embed stripped of text and media. Post.visibility is FOLLOWERS while the
  /// author is protected. Decided from the instance-cached protected-author set.
  /// The caller's profile, the post, the author's status and the caller's graph are instance-cached 60 s; a blocked-by
  /// overflow also consults the author's graph.
  /// viewer_reply_permission: for a root post in a FOLLOWING conversation (viewer not the author) it uses the author's
  /// graph; a reply in a restricted conversation is always UNKNOWN. In a community conversation it is ALLOWED for a
  /// JOINED member and NOT_ALLOWED otherwise (from the caller's member doc, cached 60 s).
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
  /// Protected authors, for a caller who is neither the author nor a follower of it: a focal post by a
  /// protected account is NOT_FOUND; such a parent or root is unset with parent_unavailable / root_unavailable; reply
  /// rows by such an account are dropped (the page may be short); QUOTE embeds as in GetPost.
  /// Community moderation: a reply that a community's owner or a moderator hid
  /// (CommunityService.HideCommunityPost) is dropped from the page for every caller but its author (the page may be
  /// short), and as the parent it is unset with parent_unavailable = true; as the focal post it is returned as GetPost
  /// returns it, and the replies under it stay. A hidden root is unaffected. This holds whatever the state of
  /// FEATURE_COMMUNITIES.
  /// page_size: default 10 (first page), clamped to 1..30. Opaque page_token bound to
  /// the caller and the focal post.
  /// viewer_reply_permission: UNKNOWN when root_unavailable; otherwise computed from the root (for a FOLLOWING
  /// conversation, the root author's graph). In a community conversation ALLOWED for a JOINED member and NOT_ALLOWED
  /// otherwise (the caller's member doc).
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

  /// Scheduled posts. All three need FEATURE_POSTS. SchedulePost also needs FEATURE_SCHEDULED_POSTS on for the
  /// caller; ListScheduledPosts and CancelScheduledPost only need it not globally off, so a caller outside the allowlist or
  /// percent bucket can still list and cancel what they already scheduled. Otherwise FAILED_PRECONDITION +
  /// FEATURE_DISABLED (metadata["feature"] = "scheduled_posts" for the latter), before any lookup. They
  /// only ever touch users/{caller}/scheduled; another user's id is NOT_FOUND like an unknown id. They share the
  /// CreatePost rate-limit bucket. A published post is created by the server sweep (Cloud Scheduler, every 5 min),
  /// up to ~5 min after publish_at; an item more than 6 h late is FAILED EXPIRED instead of published.
  /// Polls and scheduled posts are not combined: this request has no poll field. GIF media are refused
  /// here: VALIDATION field "media_ids".
  /// Community posts are not scheduled: community_id is not accepted, so this request has no community_id
  /// field and a scheduled post is always an ordinary post. The composer hides its audience picker in schedule mode.
  /// Schedule a root post (no reply, quote or poll) with the CreatePost text and media rules, plus the media,
  /// reply_audience and content_disclosure sub-feature checks and a verified email, as CreatePost. publish_at is
  /// truncated to the whole minute (UTC) and must be within [now + 2 min, now + 60 d] by server time, else VALIDATION
  /// field "publish_at". Media are validated (owned, READY or READY_UNSCREENED, unattached) but not reserved: an image
  /// used elsewhere before publish fails the item MEDIA_UNAVAILABLE; it stays reachable by its public URL until then.
  /// Idempotency: the doc id is derived from (caller, idempotency_key); a replay returns the stored item (even after
  /// the lead time passed or a cap filled), a different effective body => IDEMPOTENCY_KEY_REUSED. A replay of a
  /// PUBLISHED, CANCELLED or FAILED item returns it without text or media.
  /// A call that gets a cap error (LIMIT_REACHED, QUOTA_EXCEEDED) may be a near-simultaneous duplicate of a call that just
  /// succeeded: keep the same idempotency_key and retry after any such error, and the retry returns the stored item.
  /// Caps: 25 pending (soft: counted outside the transaction, so concurrent calls can overshoot it by the number in
  /// flight) => LIMIT_REACHED metadata["limit"] = "scheduled_pending"; 3 pending within +/-4 min of publish_at (exact:
  /// counted inside the transaction, so concurrent calls cannot exceed it; a near-simultaneous duplicate that finds the
  /// window full is answered with the stored item) => LIMIT_REACHED "scheduled_window"; 50 calls per IST day (10 for
  /// accounts younger than 24 h) => QUOTA_EXCEEDED metadata["quota"] = "schedules". The posts daily quota is charged at
  /// publish.
  /// A replay and a refusal at the pending, window or daily cap write nothing.
  Future<dzerothpostsv1posts.SchedulePostResponse> schedulePost(
    dzerothpostsv1posts.SchedulePostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.schedulePost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's PENDING and FAILED scheduled posts, publish_at ascending. page_size 0 => 20, clamped to 50; opaque
  /// page_token bound to the caller.
  Future<dzerothpostsv1posts.ListScheduledPostsResponse> listScheduledPosts(
    dzerothpostsv1posts.ListScheduledPostsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.listScheduledPosts,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Cancel a PENDING item, or dismiss a FAILED one; returns the item's current state without text or media.
  /// Idempotent by state: an item already PUBLISHED (too late, not an error) or CANCELLED is returned unchanged, writing
  /// nothing. scheduled_id must match ^[0-9a-f]{32}$ (else VALIDATION); unknown => NOT_FOUND. idempotency_key is
  /// format-validated (VALIDATION when malformed) but not stored.
  /// Terminal items expire by TTL after SCHEDULED_TERMINAL_TTL (default 7 days).
  Future<dzerothpostsv1posts.CancelScheduledPostResponse> cancelScheduledPost(
    dzerothpostsv1posts.CancelScheduledPostRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.PostService.cancelScheduledPost,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
