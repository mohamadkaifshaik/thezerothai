import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/notifications/v1/notifications.pb.dart' as pb;
import '../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'notifications_store.dart';

/// Pages fetched in a row when the server answers a short or empty page while
/// more rows exist (rows hidden by block/mute are filtered after the query;
/// the proto says to keep paging, never infer the end from a short page).
const kEmptyPageRetries = 3;

/// Talks to `NotificationService` and keeps the list in drift (ADR-0017,
/// cost-model lever 6.1: a `since_token` refresh reads only newer rows).
///
/// - [cached] renders from disk with no network call.
/// - [refresh] sends the stored `since_token`, merges by notification id
///   (a collapsed like is rewritten in place), and persists a gap marker for
///   `gap_page_token`. A token the server rejects (`since_token` /
///   `page_token`) is dropped and exactly one cold open is sent.
/// - Every call goes through the `notifications` [ServiceFeatureGate]: with
///   the flag off no RPC is ever sent.
/// - Only ListNotifications uses the shared read [RateLimitHold]; MarkSeen
///   and Register/Unregister have their own daily caps and must never freeze
///   timeline reads.
///
/// Calls are serialized and an identical call already in flight is shared.
class NotificationsRepository {
  NotificationsRepository({
    required ApiClient apiClient,
    required NotificationsStore store,
    required ServiceFeatureGate gate,
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
  final NotificationsStore _store;
  final ServiceFeatureGate _gate;
  final int _pageSize;
  final Duration Function() _elapsed;
  late final RateLimitHold _hold;

  Duration? _refreshedAt;
  Duration? _attemptedAt;
  Future<void> _tail = Future<void>.value();
  final Map<String, Future<NotificationsSnapshot>> _inflight = {};

  /// The gate, so UI can follow the flag turning off mid-session.
  ServiceFeatureGate get gate => _gate;

  /// Whether the Notifications UI and RPCs may be used at all.
  bool get enabled => _gate.enabled;

  /// Sign-out: forget in-flight work and the throttles (the shared session
  /// epoch is ended by `wipeSessionData`, which drops their writes).
  void clearSession() {
    _inflight.clear();
    _tail = Future<void>.value();
    _refreshedAt = null;
    _attemptedAt = null;
  }

  /// Time since the last successful [refresh] in this session; null if none.
  Duration? get sinceRefresh {
    final at = _refreshedAt;
    return at == null ? null : _elapsed() - at;
  }

  /// Time since the last refresh was attempted (success or not).
  Duration? get sinceRefreshAttempt {
    final at = _attemptedAt;
    return at == null ? null : _elapsed() - at;
  }

  /// The RATE_LIMITED answer list calls are held back for, with the time
  /// left; null when nothing is held.
  RateLimitedException? rateLimitedFor() => _hold.check();

  /// What is on disk. Never touches the network.
  Future<NotificationsSnapshot> cached() => _store.read();

  /// First open / pull-to-refresh / resume / push received.
  Future<NotificationsSnapshot> refresh() {
    final session = _store.session;
    return _single('refresh', () async {
      try {
        final snapshot = await _refresh(session);
        if (_store.session == session) _refreshedAt = _elapsed();
        return snapshot;
      } finally {
        if (_store.session == session) _attemptedAt = _elapsed();
      }
    });
  }

  Future<NotificationsSnapshot> _refresh(int session) async {
    final state = await _store.read();
    if (state.sinceToken.isEmpty) return _coldOpen(session);
    final page = await _listUnlessRejected(
      'since_token',
      sinceToken: state.sinceToken,
    );
    if (page == null) {
      await _store.clearSince(session: session);
      return _coldOpen(session);
    }
    await _store.applyRefresh(
      items: page.items,
      sinceToken: page.sinceToken,
      gapPageToken: page.gapPageToken,
      seenAt: page.seenAt,
      session: session,
    );
    return _store.read();
  }

  Future<NotificationsSnapshot> _coldOpen(int session) async {
    final page = await _list();
    await _store.applyColdOpen(
      items: page.items,
      sinceToken: page.sinceToken,
      nextPageToken: page.nextPageToken,
      seenAt: page.seenAt,
      session: session,
    );
    return _keepPaging(session, await _store.read());
  }

  /// Infinite scroll: the page below the oldest cached row. No call when
  /// there is nothing older.
  Future<NotificationsSnapshot> loadOlder() {
    final session = _store.session;
    return _single('older', () async {
      final state = await _store.read();
      if (state.olderPageToken.isEmpty) return state;
      final page = await _listUnlessRejected(
        'page_token',
        pageToken: state.olderPageToken,
      );
      if (page == null) return _coldOpen(session);
      await _store.applyOlderPage(
        items: page.items,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _keepPaging(session, await _store.read(), added: page.items);
    });
  }

  /// Fills the gap marker row [gapItemKey].
  Future<NotificationsSnapshot> fillGap(String gapItemKey) {
    final session = _store.session;
    return _single('gap:$gapItemKey', () async {
      final state = await _store.read();
      final gap = state.entries
          .where((e) => e.isGap && e.itemKey == gapItemKey)
          .firstOrNull;
      if (gap == null) return state;
      final page = await _listUnlessRejected(
        'page_token',
        pageToken: gap.gapToken!,
      );
      if (page == null) return _coldOpen(session);
      await _store.applyGapPage(
        gapItemKey,
        items: page.items,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _store.read();
    });
  }

  /// A page can be empty while more rows exist (filtered at read time): keep
  /// paging a few times so the screen is not left looking empty.
  Future<NotificationsSnapshot> _keepPaging(
    int session,
    NotificationsSnapshot snapshot, {
    List<pb.Notification>? added,
  }) async {
    var current = snapshot;
    var empty = added == null ? !snapshot.hasNotifications : added.isEmpty;
    for (var i = 0; i < kEmptyPageRetries; i++) {
      if (!empty || current.olderPageToken.isEmpty) break;
      final page = await _listUnlessRejected(
        'page_token',
        pageToken: current.olderPageToken,
      );
      if (page == null) break;
      await _store.applyOlderPage(
        items: page.items,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      current = await _store.read();
      empty = page.items.isEmpty;
    }
    return current;
  }

  /// Marks everything seen. Returns the server's `seen_at` (also stored).
  /// Uses its own daily cap (`notification_seen_daily`), not the read hold.
  Future<DateTime?> markSeen(String idempotencyKey) async {
    final session = _store.session;
    final response = await _gate.run(
      () => _apiClient.notifications.markNotificationsSeen(
        pb.MarkNotificationsSeenRequest(idempotencyKey: idempotencyKey),
      ),
    );
    if (!response.hasSeenAt()) return null;
    final seenAt = response.seenAt.toDateTime();
    await _store.setSeenAt(seenAt, session: session);
    return seenAt;
  }

  /// This installation's random device id (generated once, kept in drift).
  Future<String> deviceId(String Function() generate) =>
      _store.deviceId(generate);

  /// The stored device id, or '' when none was generated (nothing to
  /// unregister).
  Future<String> existingDeviceId() async {
    return _store.deviceId(() => '');
  }

  /// Registers (or refreshes) this installation's FCM token.
  Future<void> registerDevice({
    required String idempotencyKey,
    required String deviceId,
    required String fcmToken,
    required DevicePlatform platform,
  }) async {
    await _gate.run(
      () => _apiClient.notifications.registerDevice(
        pb.RegisterDeviceRequest(
          idempotencyKey: idempotencyKey,
          deviceId: deviceId,
          fcmToken: fcmToken,
          platform: platform,
        ),
      ),
    );
  }

  /// Removes this installation's device (sign-out, push turned off).
  Future<void> unregisterDevice({
    required String idempotencyKey,
    required String deviceId,
  }) async {
    await _gate.run(
      () => _apiClient.notifications.unregisterDevice(
        pb.UnregisterDeviceRequest(
          idempotencyKey: idempotencyKey,
          deviceId: deviceId,
        ),
      ),
    );
  }

  // --- internals -----------------------------------------------------------

  Future<_Page?> _listUnlessRejected(
    String field, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    try {
      return await _list(sinceToken: sinceToken, pageToken: pageToken);
    } on ValidationException catch (error) {
      if (error.field == field) return null;
      rethrow;
    }
  }

  /// One ListNotifications RPC; at most one token may be set.
  Future<_Page> _list({String sinceToken = '', String pageToken = ''}) async {
    final held = _hold.check();
    if (held != null) throw held;
    try {
      final r = await _gate.run(
        () => _apiClient.notifications.listNotifications(
          pb.ListNotificationsRequest(
            pageSize: _pageSize,
            sinceToken: sinceToken,
            pageToken: pageToken,
          ),
        ),
      );
      return _Page(
        r.notifications.toList(),
        r.nextPageToken,
        r.sinceToken,
        r.gapPageToken,
        r.hasSeenAt() ? r.seenAt.toDateTime() : null,
      );
    } on RateLimitedException catch (error) {
      _hold.record(error);
      rethrow;
    }
  }

  Future<NotificationsSnapshot> _single(
    String op,
    Future<NotificationsSnapshot> Function() body,
  ) {
    final running = _inflight[op];
    if (running != null) return running;
    final future = _tail.catchError((Object _) {}).then((_) => body());
    _inflight[op] = future;
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _tail = tail;
    future.whenComplete(() {
      if (identical(_inflight[op], future)) _inflight.remove(op);
    }).ignore();
    return future;
  }
}

Duration Function() _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

class _Page {
  _Page(
    this.items,
    this.nextPageToken,
    this.sinceToken,
    this.gapPageToken,
    this.seenAt,
  );
  final List<pb.Notification> items;
  final String nextPageToken;
  final String sinceToken;
  final String gapPageToken;
  final DateTime? seenAt;
}
