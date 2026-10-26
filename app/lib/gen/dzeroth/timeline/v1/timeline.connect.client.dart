//
//  Generated code. Do not modify.
//  source: dzeroth/timeline/v1/timeline.proto
//

import "package:connectrpc/connect.dart" as connect;
import "timeline.pb.dart" as dzerothtimelinev1timeline;
import "timeline.connect.spec.dart" as specs;

extension type TimelineServiceClient (connect.Transport _transport) {
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
  /// describe its original.
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
  Future<dzerothtimelinev1timeline.GetHomeTimelineResponse> getHomeTimeline(
    dzerothtimelinev1timeline.GetHomeTimelineRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.TimelineService.getHomeTimeline,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// A user's posts, newest first. include_replies=false is the "Posts" tab (root posts), true is "Replies"
  /// (all of the user's posts incl. replies; identical to Posts until replies ship, ADR-0010 D11).
  /// Private accounts: only the owner and approved followers (others get an empty list + profile via identity).
  /// Deferred with private accounts (ADR-0008 D1): every post is PUBLIC today.
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
  Future<dzerothtimelinev1timeline.GetUserTimelineResponse> getUserTimeline(
    dzerothtimelinev1timeline.GetUserTimelineRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.TimelineService.getUserTimeline,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
