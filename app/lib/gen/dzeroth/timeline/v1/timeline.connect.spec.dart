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
  /// Viewer flags are false and userLikes is not read until engagement ships (ADR-0010 D3).
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50; 2 = caller users via the
  ///            account-status interceptor + graph; +1 userLikes once engagement ships) / planning: refresh
  ///            4 + new posts (F=60: C=3, graph expired because refreshes are >= 60 s apart), older page or
  ///            cold open 30 (F=60, page 20), writes 0.
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
  /// Private accounts: only the owner and approved followers (others get an empty list + profile via identity).
  /// Deferred with private accounts (ADR-0008 D1): every post is PUBLIC today.
  /// NOT_FOUND (byte-identical to GetProfile's missing-user error) if the user is missing, SUSPENDED or DELETING,
  /// or blocks the caller. A caller who blocks or mutes the user still gets the posts; the client shows a banner
  /// for a block (ADR-0010 D6). The Posts-tab first page (<= 20) comes from the author-recent instance cache
  /// (60 s). Pages use Limit(page_size); next_page_token is set whenever a page is full (ADR-0010 D16).
  /// Reads: caller users (account-status interceptor) + user users (status) + caller graph (blocked-by), all
  /// cached 60 s, + page; +1 user graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 3 + page_size cold (53 at page 50) / 0 warm, planning 11; since_token refresh with 0 new
  /// posts 4 cold / 0-1 warm; +1 (userLikes) once engagement ships. Writes 0.
  static const getUserTimeline = connect.Spec(
    '/$name/GetUserTimeline',
    connect.StreamType.unary,
    dzerothtimelinev1timeline.GetUserTimelineRequest.new,
    dzerothtimelinev1timeline.GetUserTimelineResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
