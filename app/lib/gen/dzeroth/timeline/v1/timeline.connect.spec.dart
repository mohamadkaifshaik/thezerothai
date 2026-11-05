//
//  Generated code. Do not modify.
//  source: dzeroth/timeline/v1/timeline.proto
//

import "package:connectrpc/connect.dart" as connect;
import "timeline.pb.dart" as dzerothtimelinev1timeline;

abstract final class TimelineService {
  /// Fully-qualified name of the TimelineService service.
  static const name = 'dzeroth.timeline.v1.TimelineService';

  /// Chronological posts (excluding replies) from accounts the caller follows, plus the caller's own.
  /// Algorithm: graph/{uid} (cached 60 s) -> followees + self in chunks of 30 -> per-chunk query
  /// `authorId in chunk AND isReply == false AND createdAt (> since | < before) ORDER BY createdAt DESC
  /// LIMIT k`, k = max(1, ceil(2 * page_size / chunks)), <= 4 concurrent -> k-way merge -> return only the
  /// exact prefix (items newer than the newest k-th item of any chunk that filled its limit) -> drop
  /// blocked/muted/invisible -> hydrate viewer flags from userLikes/{uid}. Authors fully covered by the
  /// author-recent instance cache (last 20 posts, 60 s) skip Firestore.
  /// Filtering: authors the caller blocks, who block the caller (even if a stale following list
  /// still names them) or whom the caller mutes are dropped; the caller's own posts are always kept. Authors
  /// who are SUSPENDED or DELETING are not filtered at Stage 0 (moderation takedown / purge removes their posts).
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller;
  /// with either on, one cached userLikes read hydrates the page (liked / reposted only with engagement, bookmarked_by_viewer with either). A REPOST or QUOTE whose embedded author the caller
  /// blocks or mutes, or who blocks the caller, is dropped like a post by that author; a REPOST item's flags
  /// describe its original. Protected authors: Home rows are by the caller and followed accounts only,
  /// so none is hidden; a REPOST whose original is by a protected author the caller does not follow is dropped, and a
  /// QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media.
  /// Authors are queried in chunks of 30; following is capped at 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// A since_token refresh also consults the instance-cached removal log (removed_ids, behind FEATURE_REMOVED_IDS; the
  /// log is not consulted while that flag is off). The shared log refresh runs once per instance per CACHE_TTL, detached
  /// from the caller. Only a token older than the instance's log cache reads for the caller, with one bounded window
  /// query on postRemovals, only for feeds of up to 180 accounts. Other modes read nothing from the log. Suspending
  /// an account with 50 or more posts makes only the feeds that show it reset once (see removed_ids in the token
  /// contract).
  static const getHomeTimeline = connect.Spec(
    '/$name/GetHomeTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetHomeTimelineRequest.new,
    dzerothtimelinev1timeline.GetHomeTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// A user's posts, newest first. include_replies=false is the "Posts" tab (root posts), true is "Replies"
  /// (all of the user's posts incl. replies; identical to Posts until replies ship).
  /// Protected accounts: for a caller who is neither the account nor a follower of it, every tab answers
  /// author_protected = true with no posts and no tokens. It is decided before the author-recent cache or any page is
  /// read (the interceptor, target users and caller graph lookups), after the NOT_FOUND rules below. The client shows
  /// the protected view (the profile itself comes from identity) and REPLACES any cached feed for this author. In
  /// every tab, a REPOST whose original is by a protected author the caller does not follow is dropped, and a QUOTE of
  /// such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media.
  /// NOT_FOUND (byte-identical to GetProfile's missing-user error) if the user is missing, SUSPENDED or DELETING,
  /// or blocks the caller. A caller who blocks or mutes the user still gets the posts; the client shows a banner
  /// for a block. The Posts-tab first page (<= 20) comes from the author-recent instance cache
  /// (60 s). Pages use Limit(page_size); next_page_token is set whenever a page is full.
  /// The caller's profile, the target's status and the caller's graph are cached 60 s; a blocked-by overflow also
  /// consults the target's graph.
  /// A since_token refresh also consults the removal log (removed_ids), scoped to the profile's author, with the same
  /// rules as GetHomeTimeline: the shared refresh is detached from the caller, and a token older than the instance's
  /// log cache adds one window query. Behind FEATURE_REMOVED_IDS: the log is not consulted while off.
  /// Tabs: tab = UNSPECIFIED (the default, every pre-W3 client) means "use include_replies" exactly as
  /// above; any other tab WINS and include_replies is ignored with no error. POSTS and REPLIES are the two feeds above
  /// and stay ungated. MEDIA (the author's posts with their own images, replies and quotes included, REPOSTs
  /// excluded) and REPOSTS (the author's REPOST items) need FEATURE_PROFILE_TABS (wire name "profile_tabs") on for
  /// the caller, else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "profile_tabs", before any lookup. Same
  /// NOT_FOUND, block, mute and embed rules as the Posts tab (a REPOST whose embedded author the caller blocks or
  /// mutes, or who blocks the caller, is dropped; a QUOTE carries embed_viewer_state), same since_token,
  /// gap_page_token and removed_ids behaviour. MEDIA and REPOSTS use one Limit(page_size) query per page and no
  /// instance cache. Rate limit: the GetUserTimeline bucket, shared by every tab.
  static const getUserTimeline = connect.Spec(
    '/$name/GetUserTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetUserTimelineRequest.new,
    dzerothtimelinev1timeline.GetUserTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// A list's feed: chronological posts (excluding replies) by the list's members, newest first. It is
  /// Home's pull-merge run over the members instead of the followees: the same chunks of 30, k, <= 4 queries in
  /// flight, exact-prefix merge, author-recent instance cache (shared with Home, so a warm Home makes a list refresh
  /// cheaper), the same token contract above and the same removed_ids, scoped to the members. No new merge, cursor or
  /// cache.
  /// NOT_FOUND (one message, byte-identical to a list id that never existed; lists.proto header): the list is missing,
  /// private or hidden and the caller is not its owner, or its owner blocks the caller, is not ACTIVE or has an
  /// overflowed blockedBy (fail closed). A list that becomes NOT_FOUND between calls answers NOT_FOUND: the client
  /// shows the tab as unavailable and offers Unpin. An empty list answers an empty page with a since_token.
  /// Filtering, per viewer, after the cache: members who block the list's owner are dropped
  /// for every viewer (F4); members the caller blocks or mutes, or who block the caller, are dropped; the caller's own
  /// posts are kept. A caller whose blockedBy overflowed keeps only their own posts and members they follow (fail
  /// closed). Protected members: a row by a protected member who has not approved the caller is
  /// dropped, which, unlike Home, can happen here; a REPOST of such an author's post is dropped and a QUOTE of one
  /// carries embed_viewer_state = PROTECTED, exactly as on Home. These decisions may consult the instance-cached
  /// protected-author set (detached refresh); when no set younger than PROTECTED_SET_MAX_STALE can be
  /// loaded the call answers UNAVAILABLE (retryable), never an unfiltered page.
  /// list is the list's header (lists.v1.ListInfo) on every response, read with the list.
  /// Flags: FEATURE_LISTS (wire name "lists", else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "lists", before any lookup) and FEATURE_POSTS as for Home; removed_ids behind FEATURE_REMOVED_IDS.
  /// Rate limit: RATE_LIMIT_LIST_TIMELINE_PER_MIN, 12 calls/min/uid per instance (36 with 3 instances). Deadline 10 s.
  /// The shared removal-log refresh is detached, as for Home. A since_token older than the instance's removal-log cache
  /// adds one window query (lists have at most 180 members, so it always applies).
  static const getListTimeline = connect.Spec(
    '/$name/GetListTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetListTimelineRequest.new,
    dzerothtimelinev1timeline.GetListTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// A community's feed: the root posts and quotes created into the community, newest first. Replies and
  /// reposts are never in it. Query `posts where communityId == C ORDER BY __name__ DESC` with id-bound windows (id
  /// order is time order), on the automatic single-field index (proven on the dev Firestore, D3). A post a
  /// community moderator hid has left the query. The same token contract as above: tokens bound to the caller and the
  /// community, the settle window, gap_page_token, and next_page_token following the query rather than the filtered count.
  /// A Home, user or list token on a community, or a community token on another community or for another caller =>
  /// VALIDATION "since_token" / "page_token", before any lookup.
  /// NOT_FOUND "community not found" (one message, byte-identical; communities.v1 header) for a missing or SUSPENDED
  /// community, to everyone, its owner included. An ARCHIVED community is readable. A community that
  /// becomes NOT_FOUND between calls answers NOT_FOUND: the client shows the tab as unavailable and offers Unpin.
  /// Rows come from a shared per-instance entry per community (the newest 30 posts, CACHE_COMMUNITY_FEED_ENTRIES), refilled
  /// incrementally once it is older than CACHE_TTL (60 s), then from the query for anything older. Every fill reads at
  /// most page_size posts, so a call never reads more post rows than it could return. A hide, restore or new post on this
  /// instance updates the entry at once.
  /// Filtering, per viewer, after the cache:
  /// - rows the platform removed (takedown, suspended author) and rows in the community's recent removals are dropped;
  /// - rows by authors the caller blocks or mutes, or who block the caller, are dropped; the caller's own posts are kept;
  ///   for the community's OWNER or a MODERATOR the "blocks the caller" drop is waived (F14: moderators must see
  ///   raiders), and their own blocks and mutes still apply;
  /// - a caller whose blockedBy overflowed keeps only their own posts and authors they follow (fail closed), unless they
  ///   moderate this community;
  /// - protected authors as in GetListTimeline (posts.Audience): a row by a protected author who has not approved the
  ///   caller is dropped, moderators included (protection is the author's privacy choice, not a block); a QUOTE of such
  ///   an author's post carries embed_viewer_state = PROTECTED; UNAVAILABLE (retryable) when no protected-author set
  ///   younger than PROTECTED_SET_MAX_STALE can be loaded, never an unfiltered page.
  /// viewer_reply_permission: ALLOWED or NOT_ALLOWED from community.viewer_role (members-only replies, F8).
  /// removed_ids (gated by FEATURE_COMMUNITIES, not FEATURE_REMOVED_IDS): on a since_token refresh, the community's
  /// recent removals newer than the token (moderator hides, platform takedowns and suspensions of community posts; at
  /// most 50, newest first), from the community doc already read. A restored post is not listed; the
  /// author's own DeletePost is not listed (as on Home). When the community has dropped a removal newer than the token
  /// (removalsTruncatedAt), the refresh is rejected exactly as an expired token is (above), before any post is read.
  /// community is the header (communities.v1.Community, with viewer_role) on every response, read with the community and
  /// the caller's member doc: the client labels the community's Home tab from it.
  /// Flags: FEATURE_COMMUNITIES (wire name "communities", else FAILED_PRECONDITION + FEATURE_DISABLED,
  /// metadata["feature"] = "communities", before any lookup) and FEATURE_POSTS as for Home.
  /// Rate limit: RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN, 12 calls/min/uid per instance (36 with 3 instances). Deadline 10 s.
  static const getCommunityTimeline = connect.Spec(
    '/$name/GetCommunityTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetCommunityTimelineRequest.new,
    dzerothtimelinev1timeline.GetCommunityTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Replace the caller's pinned Home tabs (after the fixed Following tab) with tabs, in that order (founder decision F5).
  /// Read back through IdentityService.GetMe home_tabs.
  /// Rules: at most HOME_TABS_MAX_PINNED (5) tabs, counting stored tabs of a kind whose flag is off for the caller
  /// (those are not in GetMe and are kept after the sent ones), else FAILED_PRECONDITION + LIMIT_REACHED,
  /// metadata["limit"] = "home_tabs". A duplicate (same kind and id), kind UNSPECIFIED or a malformed id =>
  /// INVALID_ARGUMENT + VALIDATION, metadata["field"] = "tabs", before any lookup.
  /// A LIST tab needs FEATURE_LISTS on for the caller, else FEATURE_DISABLED, metadata["feature"] = "lists", before any lookup; a
  /// COMMUNITY tab needs FEATURE_COMMUNITIES, else FEATURE_DISABLED, metadata["feature"] = "communities", before any lookup; an
  /// empty tabs (unpin everything) is always accepted. A tab NOT already stored must be a list the caller may read now
  /// (GetList's rules), else VALIDATION "tabs", one answer for missing, private, hidden and blocked lists; or an ACTIVE
  /// or ARCHIVED community (membership is not required, communities are public), else VALIDATION "tabs",
  /// one answer for missing and SUSPENDED communities; a new community tab is looked up through the community instance
  /// cache. A tab already stored is kept without being re-read, so an unavailable tab can still be moved or removed.
  /// title is ignored on input; the server sets it (common.v1.HomeTab), always "" for a COMMUNITY tab.
  /// Idempotency: the standard TTL'd idempotency document, as every lists.v1 mutation (rule 4). One transaction in
  /// identity (the timeline.HomeTabsStore seam): idempotency doc and users/{uid} fresh, then a field-level update of
  /// users/{uid}.homeTabs (no other field). The same tabs again => the idempotency document only. The caller's profile
  /// cache on this instance is updated in place; other instances serve the new order within 60 s.
  /// Rate limit: the RATE_LIMIT_LISTS_WRITE_PER_MIN bucket (30/min/uid per instance), shared with the list mutations;
  /// no daily cap. DEGRADED_MODE=readonly refuses it.
  /// A request that changes nothing writes only the idempotency doc; a replay writes nothing.
  static const setHomeTabs = connect.Spec(
    '/$name/SetHomeTabs',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.SetHomeTabsRequest.new,
    dzerothtimelinev1timeline.SetHomeTabsResponse.new,
  );
}
