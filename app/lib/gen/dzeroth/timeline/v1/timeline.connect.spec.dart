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
  /// Filtering (ADR-0010 D6): authors the caller blocks, who block the caller (even if a stale following list
  /// still names them) or whom the caller mutes are dropped; the caller's own posts are always kept. Authors
  /// who are SUSPENDED or DELETING are not filtered at Stage 0 (moderation takedown / purge removes their posts).
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller (ADR-0010 D3);
  /// with either on, one cached userLikes read hydrates the page (P5; liked / reposted only with engagement, bookmarked_by_viewer with either). A REPOST or QUOTE whose embedded author the caller
  /// blocks or mutes, or who blocks the caller, is dropped like a post by that author; a REPOST item's flags
  /// describe its original. Protected authors (ADR-0025 D4): Home rows are by the caller and followed accounts only,
  /// so none is hidden; a REPOST whose original is by a protected author the caller does not follow is dropped, and a
  /// QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media. 0 extra
  /// reads.
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50; 2 = caller users via the
  ///            account-status interceptor + graph; +1 userLikes with FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS on) / planning: refresh
  ///            4 + new posts (F=60: C=3, graph expired because refreshes are >= 60 s apart), older page or
  ///            cold open 30 (F=60, page 20), writes 0.
  /// A since_token refresh also consults the instance-cached removal log (removed_ids, behind FEATURE_REMOVED_IDS:
  /// 0 reads while that flag is off). The shared log refresh (0 on a warm hit, 1 to 50 once per instance per
  /// CACHE_TTL, 100 worst) runs on a detached counter and is NOT charged to the caller's read budget (request log
  /// field removal_log_reads). Only a token older than the instance's log cache reads for the caller: at most 107
  /// (one bounded window query on postRemovals, only for feeds of up to 180 accounts), so a refresh stays bounded
  /// by 2 + C + 2 * page_size = 269 at 5,000 following, page 50. Other modes read nothing from the log. Suspending
  /// an account with 50 or more posts makes only the feeds that show it reset once (see removed_ids in the token
  /// contract).
  /// Every call is charged to the per-uid daily Firestore read budget (ADR-0010 D5).
  static const getHomeTimeline = connect.Spec(
    '/$name/GetHomeTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetHomeTimelineRequest.new,
    dzerothtimelinev1timeline.GetHomeTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// A user's posts, newest first. include_replies=false is the "Posts" tab (root posts), true is "Replies"
  /// (all of the user's posts incl. replies; identical to Posts until replies ship, ADR-0010 D11).
  /// Protected accounts (ADR-0025 D4): for a caller who is neither the account nor a follower of it, every tab answers
  /// author_protected = true with no posts and no tokens. It is decided before the author-recent cache or any page is
  /// read (3 cold reads: interceptor, target users, caller graph), after the NOT_FOUND rules below. The client shows
  /// the protected view (the profile itself comes from identity) and REPLACES any cached feed for this author. In
  /// every tab, a REPOST whose original is by a protected author the caller does not follow is dropped, and a QUOTE of
  /// such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media.
  /// NOT_FOUND (byte-identical to GetProfile's missing-user error) if the user is missing, SUSPENDED or DELETING,
  /// or blocks the caller. A caller who blocks or mutes the user still gets the posts; the client shows a banner
  /// for a block (ADR-0010 D6). The Posts-tab first page (<= 20) comes from the author-recent instance cache
  /// (60 s). Pages use Limit(page_size); next_page_token is set whenever a page is full (ADR-0010 D16).
  /// Reads: caller users (account-status interceptor) + user users (status) + caller graph (blocked-by), all
  /// cached 60 s, + page; +1 user graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 3 + max(page_size, 20) cold (a cold Posts tab fills the 20-post author-recent entry, so
  /// page_size < 20 still reads 20; 53 at page 50) / 0 warm, planning 11; since_token refresh with 0 new
  /// posts 4 cold / 0-1 warm; +1 userLikes (cold, cached 60 s) with FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS on. Writes 0.
  /// A since_token refresh also consults the removal log (removed_ids), scoped to the profile's author, with the same
  /// cost rules as GetHomeTimeline: the shared refresh is detached from the caller's budget; a token older than the
  /// instance's log cache adds at most 107 reads (one window query). Behind FEATURE_REMOVED_IDS: 0 reads while off.
  /// Tabs (ADR-0024 D5): tab = UNSPECIFIED (the default, every pre-W3 client) means "use include_replies" exactly as
  /// above; any other tab WINS and include_replies is ignored with no error. POSTS and REPLIES are the two feeds above
  /// and stay ungated. MEDIA (the author's posts with their own images, replies and quotes included, REPOSTs
  /// excluded) and REPOSTS (the author's REPOST items) need FEATURE_PROFILE_TABS (wire name "profile_tabs") on for
  /// the caller, else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "profile_tabs", 0 reads. Same
  /// NOT_FOUND, block, mute and embed rules as the Posts tab (a REPOST whose embedded author the caller blocks or
  /// mutes, or who blocks the caller, is dropped; a QUOTE carries embed_viewer_state), same since_token,
  /// gap_page_token and removed_ids behaviour. MEDIA and REPOSTS use one Limit(page_size) query per page and no
  /// instance cache. Rate limit: the GetUserTimeline bucket, shared by every tab.
  /// Firestore (MEDIA or REPOSTS): reads 24 cold at page 20 / 54 at page 50 (interceptor, target users, caller
  /// graph, page, userLikes), 20 warm at page 20 (planning 20), writes 0.
  static const getUserTimeline = connect.Spec(
    '/$name/GetUserTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetUserTimelineRequest.new,
    dzerothtimelinev1timeline.GetUserTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// A list's feed (ADR-0030 D5): chronological posts (excluding replies) by the list's members, newest first. It is
  /// Home's pull-merge run over the members instead of the followees: the same chunks of 30, k, <= 4 queries in
  /// flight, exact-prefix merge, author-recent instance cache (shared with Home, so a warm Home makes a list refresh
  /// cheaper), the same token contract above and the same removed_ids, scoped to the members. No new merge, cursor or
  /// cache.
  /// NOT_FOUND (one message, byte-identical to a list id that never existed; lists.proto header): the list is missing,
  /// private or hidden and the caller is not its owner, or its owner blocks the caller, is not ACTIVE or has an
  /// overflowed blockedBy (fail closed). A list that becomes NOT_FOUND between calls answers NOT_FOUND: the client
  /// shows the tab as unavailable and offers Unpin. An empty list answers an empty page with a since_token.
  /// Filtering, per viewer, after the cache (ADR-0030 D4, ADR-0010 D6): members who block the list's owner are dropped
  /// for every viewer (F4); members the caller blocks or mutes, or who block the caller, are dropped; the caller's own
  /// posts are kept. A caller whose blockedBy overflowed keeps only their own posts and members they follow (fail
  /// closed). Protected members (ADR-0025 D3, D4): a row by a protected member who has not approved the caller is
  /// dropped, which, unlike Home, can happen here; a REPOST of such an author's post is dropped and a QUOTE of one
  /// carries embed_viewer_state = PROTECTED, exactly as on Home. These decisions may consult the instance-cached
  /// protected-author set (detached refresh, 0 reads charged); when no set younger than PROTECTED_SET_MAX_STALE can be
  /// loaded the call answers UNAVAILABLE (retryable), never an unfiltered page.
  /// list is the list's header (lists.v1.ListInfo) on every response, read with the list: 0 extra reads.
  /// Flags: FEATURE_LISTS (wire name "lists", else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "lists", 0 reads) and FEATURE_POSTS as for Home; removed_ids behind FEATURE_REMOVED_IDS.
  /// Rate limit: RATE_LIMIT_LIST_TIMELINE_PER_MIN, 12 calls/min/uid per instance (36 with 3 instances). Deadline 10 s.
  /// Firestore: C = ceil(members / 30) <= 5 at LIST_MAX_MEMBERS 150. Reads worst 6 + C + 2 * page_size for a non-owner
  /// caller (interceptor, list, caller graph, owner graph, owner profile, userLikes) = 111 at 150 members and page 50,
  /// 51 at page 20; the owner 4 + C + 2 * page_size. A since_token older than the instance's removal-log cache adds at
  /// most 107 (the ADR-0016 window query; lists have <= 180 members, so it always applies): 218 worst, under the
  /// per-call hold of 269. The shared removal-log refresh is detached, as for Home. Planning: refresh 4 + new posts,
  /// cold open or older page 30; an empty since refresh by the owner, cold, 3 + C. Writes 0.
  /// Every call is charged to the per-uid daily Firestore read budget (ADR-0010 D5).
  static const getListTimeline = connect.Spec(
    '/$name/GetListTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetListTimelineRequest.new,
    dzerothtimelinev1timeline.GetListTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Replace the caller's pinned Home tabs (after the fixed Following tab) with tabs, in that order (ADR-0030 D6,
  /// founder decision F5). Read back through IdentityService.GetMe home_tabs.
  /// Rules: at most HOME_TABS_MAX_PINNED (5) tabs, counting stored tabs of a kind whose flag is off for the caller
  /// (those are not in GetMe and are kept after the sent ones), else FAILED_PRECONDITION + LIMIT_REACHED,
  /// metadata["limit"] = "home_tabs". A duplicate (same kind and id), kind UNSPECIFIED, kind COMMUNITY (until W5 Part
  /// B ships its timeline) or a malformed id => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "tabs", 0 reads.
  /// A LIST tab needs FEATURE_LISTS on for the caller, else FEATURE_DISABLED, metadata["feature"] = "lists", 0 reads;
  /// an empty tabs (unpin everything) is always accepted. A tab NOT already stored must be a list the caller may read
  /// now (GetList's rules), else VALIDATION "tabs", one answer for missing, private, hidden and blocked lists; a tab
  /// already stored is kept without being re-read, so an unavailable tab can still be moved or removed. title is
  /// ignored on input; the server sets it (common.v1.HomeTab).
  /// Idempotency: the standard TTL'd idempotency document, as every lists.v1 mutation (rule 4). One transaction in
  /// identity (the timeline.HomeTabsStore seam): idempotency doc and users/{uid} fresh, then a field-level update of
  /// users/{uid}.homeTabs (no other field). The same tabs again => the idempotency document only. The caller's profile
  /// cache on this instance is updated in place; other instances serve the new order within 60 s.
  /// Rate limits: the RATE_LIMIT_LISTS_WRITE_PER_MIN bucket (30/min/uid per instance) and the list_mutation_daily cap
  /// (LIST_MUTATIONS_PER_DAY 500 per uid per instance), shared with the list mutations. DEGRADED_MODE=readonly refuses
  /// it.
  /// Firestore: reads worst 19 cold (interceptor, idempotency, users/{uid}, <= 5 new list docs, caller graph, and for
  /// another user's list its owner's profile and graph, <= 5 owners, all cache-first), typical 4; writes 2 (users
  /// field-level, idempotency), 1 when nothing changes, + 1 TTL delete later; replay reads 2, writes 0.
  static const setHomeTabs = connect.Spec(
    '/$name/SetHomeTabs',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.SetHomeTabsRequest.new,
    dzerothtimelinev1timeline.SetHomeTabsResponse.new,
  );
}
