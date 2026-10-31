import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import '../../posts/domain/posts_feature_flag.dart';
import '../domain/feed_key.dart';
import '../domain/profile_tabs_feature_flag.dart';
import 'timeline_store.dart';

/// Talks to `TimelineService` and keeps feeds in drift (CLAUDE.md: the client
/// is the cheapest cache; ADR-0004 / ADR-0010 D13-D14).
///
/// - [cached] renders from disk with no network call (offline cold start).
/// - [refresh] sends the stored `since_token` (never refetches what it has),
///   dedupes by `post_id`, and persists a gap marker for `gap_page_token`.
/// - A token the server rejects (INVALID_ARGUMENT + VALIDATION with
///   `field` = `since_token` / `page_token`) is dropped and exactly one cold
///   open is sent that REPLACES the cached feed (ADR-0010 D14 amendment
///   2026-10-18: a since_token is also rejected when the removal log cannot
///   list `removed_ids`, so merging could keep a removed card). Cached items
///   stay visible until that cold open succeeds.
/// - A `since_token` refresh also drops the post ids in `removed_ids`
///   (moderation removals, ADR-0016 D10) from the cached feed; the field is
///   empty while `FEATURE_REMOVED_IDS` is off, so that is a no-op.
/// - Every call goes through [PostsFeatureGate.run]: with the posts flag off
///   no timeline RPC is ever sent.
/// - Each tab of a user's timeline is its own feed ([FeedKey.tab]): its own
///   rows, tokens and refresh clock, so a token is never sent to another tab
///   (ADR-0024 D5). Posts and Replies are requested with `include_replies`
///   only; Reposts and Media set `tab` and need `profile_tabs` (after one
///   FEATURE_DISABLED answer for it no further call is sent).
///
/// Calls for one feed are serialized, and an identical call already in
/// flight is shared, so a double pull-to-refresh costs one request.
class TimelineRepository {
  TimelineRepository({
    required ApiClient apiClient,
    required TimelineStore store,
    required PostsFeatureGate gate,
    int pageSize = 0,
    Duration Function()? monotonic,
    RateLimitHold? rateLimitHold,
  }) : _apiClient = apiClient,
       _store = store,
       _gate = gate,
       _pageSize = pageSize,
       _elapsed = monotonic ?? _stopwatchClock() {
    _hold = rateLimitHold ?? RateLimitHold(monotonic: _elapsed);
  }

  final ApiClient _apiClient;
  final TimelineStore _store;
  final PostsFeatureGate _gate;

  /// 0 lets the server pick its default (20).
  final int _pageSize;

  /// Monotonic time (never wall-clock: a clock change must not suppress or
  /// double a refresh).
  final Duration Function() _elapsed;
  final Map<String, Duration> _refreshedAt = {};
  final Map<String, Duration> _attemptedAt = {};

  /// The RATE_LIMITED hold shared with the other read repositories.
  late final RateLimitHold _hold;

  final Map<String, Future<void>> _lockTails = {};

  /// Authors the server reported as protected for this viewer (`author_protected`,
  /// ADR-0025 D4), with the session they were learned in. Memory only: the
  /// cached rows of such an author are deleted, so a screen opened inside the
  /// refresh throttle still knows to show the protected view, not an empty feed.
  final Map<String, int> _protectedAuthors = {};
  final Map<String, Future<TimelineSnapshot>> _inflight = {};

  /// Sign-out: forget in-flight and queued work and invalidate every write
  /// it would still make, so nothing of the signed-out user lands in the
  /// database after it is wiped. Call before wiping the database.
  void clearSession() {
    _store.endSession();
    _inflight.clear();
    _lockTails.clear();
    _refreshedAt.clear();
    _attemptedAt.clear();
    _protectedAuthors.clear();
    _hold.clear();
  }

  /// Time since the last successful [refresh] of [feed] in this session, or
  /// null when it was never refreshed. Screens use it to throttle automatic
  /// refreshes (ADR-0004: at most one per 60 s) across screen re-creations.
  Duration? sinceRefresh(FeedKey feed) {
    final at = _refreshedAt[feed.value];
    return at == null ? null : _elapsed() - at;
  }

  /// Time since the last [refresh] of [feed] was *attempted*, whether it
  /// succeeded or failed; null when none was. The foreground tick throttles
  /// on this, so an outage retries at most once per interval instead of
  /// every tick.
  Duration? sinceRefreshAttempt(FeedKey feed) {
    final at = _attemptedAt[feed.value];
    return at == null ? null : _elapsed() - at;
  }

  /// The RATE_LIMITED answer timeline calls are still held back for
  /// (ADR-0010 D5: no timeline RPC before `retry_after`), with `retryAfter`
  /// reduced to the time left; null when nothing is held back. The short
  /// in-flight hold is excluded: the API client already retries it once.
  RateLimitedException? rateLimitedFor() => _hold.check();

  /// What is on disk for [feed]. Never touches the network.
  Future<TimelineSnapshot> cached(FeedKey feed) async {
    if (_isProtected(feed)) {
      return const TimelineSnapshot(authorProtected: true);
    }
    return _store.read(feed);
  }

  bool _isProtected(FeedKey feed) {
    final userId = feed.userId;
    return userId != null && _protectedAuthors[userId] == _store.session;
  }

  /// The server answered `author_protected` for [userId]: forget the cached
  /// rows of every tab (a warm start must never show what the server now
  /// hides, ADR-0025 D4) and remember the answer for this session.
  Future<void> _markProtected(String userId, int session) async {
    if (_store.session != session) return;
    _protectedAuthors[userId] = session;
    for (final tab in UserFeedTab.values) {
      await _store.removeFeed(FeedKey.user(userId, tab: tab));
    }
  }

  /// Pull-to-refresh / app resume / first open. Returns the merged feed.
  Future<TimelineSnapshot> refresh(FeedKey feed) {
    final session = _store.session;
    return _single(feed, 'refresh', () async {
      try {
        final snapshot = await _refresh(feed, session);
        if (_store.session == session) _refreshedAt[feed.value] = _elapsed();
        return snapshot;
      } finally {
        if (_store.session == session) _attemptedAt[feed.value] = _elapsed();
      }
    });
  }

  Future<TimelineSnapshot> _refresh(FeedKey feed, int session) async {
    final state = await _store.read(feed);
    if (state.sinceToken.isEmpty) return _coldOpen(feed, session);
    final page = await _fetchUnlessRejected(
      feed,
      'since_token',
      sinceToken: state.sinceToken,
    );
    if (page == null) {
      await _store.clearSince(feed, session: session);
      // Replace, never merge (ADR-0010 D14 amendment 2026-10-18).
      return _coldOpen(feed, session, replace: true);
    }
    await _store.applyRefresh(
      feed,
      posts: page.posts,
      removedIds: page.removedIds,
      sinceToken: page.sinceToken,
      gapPageToken: page.gapPageToken,
      session: session,
    );
    return _store.read(feed);
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
    // A held RATE_LIMITED answer applies to every read: send nothing.
    final held = _hold.check();
    if (held != null) throw held;
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
          r.removedIds.toList(),
        );
      }
      if (feed.isList) {
        // GetListTimeline is wired by W5-12; until then a list feed is "not
        // available yet", never a null-tab crash (and no RPC).
        throw const FeatureDisabledException(
          "Lists aren't available yet.",
          feature: 'lists',
        );
      }
      final tab = feed.tab!;
      final session = _store.session;
      final r = await _gate.run(
        () => _apiClient.timeline.getUserTimeline(
          tl.GetUserTimelineRequest(
            userId: feed.userId,
            includeReplies: feed.includeReplies,
            tab: _wireTab(tab),
            pageSize: _pageSize,
            sinceToken: sinceToken,
            pageToken: pageToken,
          ),
        ),
        // A tab the server serves only with profile_tabs on: once it said
        // FEATURE_DISABLED, no further call is sent (0 RPCs) until a fresh
        // GetMe resets the gate.
        requires: [if (tab.requiresProfileTabs) kFeatureProfileTabs],
      );
      if (r.authorProtected) {
        await _markProtected(feed.userId!, session);
        throw const _AuthorProtected();
      }
      _protectedAuthors.remove(feed.userId);
      return _Page(
        r.posts.toList(),
        r.nextPageToken,
        r.sinceToken,
        r.gapPageToken,
        r.removedIds.toList(),
      );
    } on RateLimitedException catch (error) {
      _hold.record(error);
      rethrow;
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
    final future = previous
        .catchError((Object _) {})
        .then((_) => body())
        .catchError(
          (Object _) => const TimelineSnapshot(authorProtected: true),
          test: (error) => error is _AuthorProtected,
        );
    _inflight[key] = future;
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _lockTails[feed.value] = tail;
    future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
      if (identical(_lockTails[feed.value], tail)) {
        _lockTails.remove(feed.value);
      }
    }).ignore();
    return future;
  }
}

/// The `tab` field of a GetUserTimeline request, or null (UNSPECIFIED: the
/// field is not sent) for the two tabs the server also reaches through
/// `include_replies`. Posts and Replies therefore go out exactly as they did
/// before the field existed, so an older server (or a cache of an older
/// client) answers them identically; only Reposts and Media set it, and they
/// are shown only while `profile_tabs` is on, which a server that knows the
/// field is the one to list.
tl.UserTimelineTab? _wireTab(UserFeedTab tab) => switch (tab) {
  UserFeedTab.posts || UserFeedTab.replies => null,
  UserFeedTab.reposts => tl.UserTimelineTab.USER_TIMELINE_TAB_REPOSTS,
  UserFeedTab.media => tl.UserTimelineTab.USER_TIMELINE_TAB_MEDIA,
};

Duration Function() _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

/// Thrown inside the repository when a page says `author_protected`; [_single]
/// turns it into a snapshot with [TimelineSnapshot.authorProtected].
class _AuthorProtected implements Exception {
  const _AuthorProtected();
}

class _Page {
  _Page(
    this.posts,
    this.nextPageToken,
    this.sinceToken,
    this.gapPageToken, [
    this.removedIds = const [],
  ]);
  final List<pb.PostView> posts;
  final String nextPageToken;
  final String sinceToken;
  final String gapPageToken;
  final List<String> removedIds;
}
