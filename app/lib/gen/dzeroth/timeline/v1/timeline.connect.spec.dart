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
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT is off for the caller (ADR-0010 D3);
  /// with it on, one cached userLikes read hydrates the page (P5). A REPOST or QUOTE whose embedded author the caller
  /// blocks or mutes, or who blocks the caller, is dropped like a post by that author; a REPOST item's flags
  /// describe its original.
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50; 2 = caller users via the
  ///            account-status interceptor + graph; +1 userLikes with FEATURE_ENGAGEMENT on) / planning: refresh
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

  static const getUserTimeline = connect.Spec(
    '/$name/GetUserTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetUserTimelineRequest.new,
    dzerothtimelinev1timeline.GetUserTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
