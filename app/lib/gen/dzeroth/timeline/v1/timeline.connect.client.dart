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
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory).
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50) / typical refresh ~8
  ///            (F=60: C=3, ~5 new posts, graph + userLikes cached), writes 0.
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

  /// A user's posts, newest first. include_replies=false is the "Posts" tab, true is "Replies".
  /// Private accounts: only the owner and approved followers (others get an empty list + profile via identity).
  /// NOT_FOUND if the author blocks the caller. First page per (author, tab) cached 60 s in the instance.
  /// Reads: author user + author graph + caller graph + userLikes (all cached) + page.
  /// Firestore: reads 54/5 (refresh via since_token) or 21 (cold page of 20), writes 0.
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
