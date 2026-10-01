import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import '../../posts/domain/posts_feature_flag.dart';
import '../domain/feed_key.dart';
import 'timeline_store.dart';

/// Talks to `TimelineService` and keeps feeds in drift (CLAUDE.md: the client
/// is the cheapest cache; ADR-0004 / ADR-0010 D13-D14).
///
/// - [cached] renders from disk with no network call (offline cold start).
/// - [refresh] sends the stored `since_token` (never refetches what it has),
///   dedupes by `post_id`, and persists a gap marker for `gap_page_token`.
/// - A token the server rejects (INVALID_ARGUMENT + VALIDATION with
///   `field` = `since_token` / `page_token`) is dropped and exactly one cold
///   open is sent; cached items stay visible (D14).
/// - Every call goes through [PostsFeatureGate.run]: with the posts flag off
///   no timeline RPC is ever sent.
///
/// Calls for one feed are serialized, and an identical call already in
/// flight is shared, so a double pull-to-refresh costs one request.
class TimelineRepository {
  TimelineRepository({
    required ApiClient apiClient,
    required TimelineStore store,
    required PostsFeatureGate gate,
    int pageSize = 0,
  }) : _apiClient = apiClient,
       _store = store,
       _gate = gate,
       _pageSize = pageSize;

  final ApiClient _apiClient;
  final TimelineStore _store;
  final PostsFeatureGate _gate;

  /// 0 lets the server pick its default (20).
  final int _pageSize;

  final Map<String, Future<void>> _lockTails = {};
  final Map<String, Future<TimelineSnapshot>> _inflight = {};

  /// Sign-out: forget in-flight and queued work and invalidate every write
  /// it would still make, so nothing of the signed-out user lands in the
  /// database after it is wiped. Call before wiping the database.
  void clearSession() {
    _store.endSession();
    _inflight.clear();
    _lockTails.clear();
  }

  /// What is on disk for [feed]. Never touches the network.
  Future<TimelineSnapshot> cached(FeedKey feed) => _store.read(feed);

  /// Pull-to-refresh / app resume / first open. Returns the merged feed.
  Future<TimelineSnapshot> refresh(FeedKey feed) {
    final session = _store.session;
    return _single(feed, 'refresh', () async {
      final state = await _store.read(feed);
      if (state.sinceToken.isEmpty) return _coldOpen(feed, session);
      final page = await _fetchUnlessRejected(
        feed,
        'since_token',
        sinceToken: state.sinceToken,
      );
      if (page == null) {
        await _store.clearSince(feed, session: session);
        return _coldOpen(feed, session);
      }
      await _store.applyRefresh(
        feed,
        posts: page.posts,
        sinceToken: page.sinceToken,
        gapPageToken: page.gapPageToken,
        session: session,
      );
      return _store.read(feed);
    });
  }

  /// Infinite scroll: the page below the oldest cached item. No call when
  /// there is nothing older.
  Future<TimelineSnapshot> loadOlder(FeedKey feed) {
    final session = _store.session;
    return _single(feed, 'older', () async {
      final state = await _store.read(feed);
      if (state.olderPageToken.isEmpty) return state;
      final page = await _fetchUnlessRejected(
        feed,
        'page_token',
        pageToken: state.olderPageToken,
      );
      if (page == null) return _coldOpen(feed, session, replace: true);
      await _store.applyOlderPage(
        feed,
        posts: page.posts,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _store.read(feed);
    });
  }

  /// Fills the gap marker row [gapItemKey] (`TimelineEntry.itemKey`).
  Future<TimelineSnapshot> fillGap(FeedKey feed, String gapItemKey) {
    final session = _store.session;
    return _single(feed, 'gap:$gapItemKey', () async {
      final state = await _store.read(feed);
      final gap = state.entries
          .where((e) => e.isGap && e.itemKey == gapItemKey)
          .firstOrNull;
      if (gap == null) return state;
      final page = await _fetchUnlessRejected(
        feed,
        'page_token',
        pageToken: gap.gapToken!,
      );
      if (page == null) return _coldOpen(feed, session, replace: true);
      await _store.applyGapPage(
        feed,
        gapItemKey,
        posts: page.posts,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _store.read(feed);
    });
  }

  Future<TimelineSnapshot> _coldOpen(
    FeedKey feed,
    int session, {
    bool replace = false,
  }) async {
    final page = await _fetch(feed);
    await _store.applyColdOpen(
      feed,
      posts: page.posts,
      sinceToken: page.sinceToken,
      nextPageToken: page.nextPageToken,
      replace: replace,
      session: session,
    );
    return _store.read(feed);
  }

  /// [_fetch], or null when the server rejected the token named [field]
  /// (ADR-0010 D14). The caller drops that token and cold-opens.
  Future<_Page?> _fetchUnlessRejected(
    FeedKey feed,
    String field, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    try {
      return await _fetch(feed, sinceToken: sinceToken, pageToken: pageToken);
    } on ValidationException catch (error) {
      if (error.field == field) return null;
      rethrow;
    }
  }

  /// One RPC. Exactly one of the tokens may be set (both is a server error).
  Future<_Page> _fetch(
    FeedKey feed, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    try {
      if (feed.isHome) {
        final r = await _gate.run(
          () => _apiClient.timeline.getHomeTimeline(
            tl.GetHomeTimelineRequest(
              pageSize: _pageSize,
              sinceToken: sinceToken,
              pageToken: pageToken,
            ),
          ),
        );
        return _Page(
          r.posts.toList(),
          r.nextPageToken,
          r.sinceToken,
          r.gapPageToken,
        );
      }
      final r = await _gate.run(
        () => _apiClient.timeline.getUserTimeline(
          tl.GetUserTimelineRequest(
            userId: feed.userId,
            includeReplies: feed.includeReplies,
            pageSize: _pageSize,
            sinceToken: sinceToken,
            pageToken: pageToken,
          ),
        ),
      );
      return _Page(
        r.posts.toList(),
        r.nextPageToken,
        r.sinceToken,
        r.gapPageToken,
      );
    } on NotFoundException {
      // The user vanished or blocks the caller: forget their feed so a
      // warm start never shows what the server now hides (ADR-0010 D6).
      if (!feed.isHome) await _store.removeFeed(feed);
      rethrow;
    }
  }

  /// Serializes calls per feed and shares an identical in-flight call.
  Future<TimelineSnapshot> _single(
    FeedKey feed,
    String op,
    Future<TimelineSnapshot> Function() body,
  ) {
    final key = '${feed.value}|$op';
    final running = _inflight[key];
    if (running != null) return running;
    final previous = _lockTails[feed.value] ?? Future<void>.value();
    final future = previous.catchError((Object _) {}).then((_) => body());
    _inflight[key] = future;
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _lockTails[feed.value] = tail;
    future
        .whenComplete(() {
          if (identical(_inflight[key], future)) _inflight.remove(key);
          if (identical(_lockTails[feed.value], tail)) {
            _lockTails.remove(feed.value);
          }
        })
        .ignore();
    return future;
  }
}

class _Page {
  _Page(this.posts, this.nextPageToken, this.sinceToken, this.gapPageToken);
  final List<pb.PostView> posts;
  final String nextPageToken;
  final String sinceToken;
  final String gapPageToken;
}
