import 'dart:async';

import '../../../core/network/app_exception.dart';

/// Sends one batch of at most [ImpressionTracker.maxBatch] post ids.
typedef ImpressionSender = Future<void> Function(List<String> postIds);

/// The server's day for view dedupe: India Standard Time (UTC+05:30), as a
/// comparable number (yyyymmdd).
int istDayOf(DateTime moment) {
  final ist = moment.toUtc().add(const Duration(hours: 5, minutes: 30));
  return ist.year * 10000 + ist.month * 100 + ist.day;
}

/// Collects the post ids the viewer saw and reports them in batches
/// (`RecordImpressions`). Best effort by design: nothing here ever throws,
/// shows an error or retries.
///
/// - Does nothing while [isEnabled] is false (`post_views` off): no
///   bookkeeping, no call.
/// - Local dedupe: an id is sent at most once per IST day (the server dedupes
///   per viewer, post and day too; this only saves requests). The set is in
///   memory and resets when the IST day changes.
/// - Flush: [flushInterval] after the first pending id (30 s), at once on
///   [onBackground] (app paused / hidden, web tab hidden), in batches of
///   [maxBatch]. A failed batch is dropped, not retried.
/// - A FEATURE_DISABLED answer stops sending until [reset] (sign-out).
class ImpressionTracker {
  ImpressionTracker({
    required ImpressionSender send,
    required bool Function() isEnabled,
    DateTime Function() now = DateTime.now,
    this.flushInterval = const Duration(seconds: 30),
  }) : _send = send,
       _isEnabled = isEnabled,
       _now = now;

  /// The most ids one `RecordImpressions` call carries (server limit).
  static const maxBatch = 50;

  final ImpressionSender _send;
  final bool Function() _isEnabled;
  final DateTime Function() _now;
  final Duration flushInterval;

  /// Pending ids in arrival order.
  final Set<String> _pending = <String>{};

  /// Pending plus already sent today.
  final Set<String> _known = <String>{};
  int _day = 0;
  bool _refused = false;
  bool _disposed = false;
  int _session = 0;
  Timer? _timer;
  Future<void>? _flushing;

  /// Whether views are being collected at all right now.
  bool get active => !_disposed && !_refused && _isEnabled();

  /// Ids waiting to be sent.
  int get pendingCount => _pending.length;

  /// Whether [postId] was already counted today (pending or sent).
  bool hasSeen(String postId) {
    _rollDay();
    return _known.contains(postId);
  }

  /// Notes that the viewer saw [postId]. No-op when inactive, empty or seen.
  void markSeen(String postId) {
    if (postId.isEmpty || !active) return;
    _rollDay();
    if (!_known.add(postId)) return;
    _pending.add(postId);
    _timer ??= Timer(flushInterval, _onTimer);
  }

  /// The app or tab went to the background: send what is pending now.
  Future<void> onBackground() => flush();

  /// Sends every pending id in batches of [maxBatch].
  Future<void> flush() {
    return _flushing ??= _drain().whenComplete(() => _flushing = null);
  }

  /// Forgets everything (sign-out or a switch of account): pending ids are
  /// dropped unsent and a remembered refusal is cleared.
  void reset() {
    _session++;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _known.clear();
    _refused = false;
  }

  void dispose() {
    _disposed = true;
    reset();
  }

  void _onTimer() {
    _timer = null;
    unawaited(flush());
  }

  void _rollDay() {
    final today = istDayOf(_now());
    if (today == _day) return;
    _day = today;
    _known
      ..clear()
      ..addAll(_pending);
  }

  Future<void> _drain() async {
    _timer?.cancel();
    _timer = null;
    final session = _session;
    while (_pending.isNotEmpty) {
      if (!active) {
        _pending.clear();
        return;
      }
      final batch = _pending.take(maxBatch).toList();
      _pending.removeAll(batch);
      try {
        await _send(batch);
      } on FeatureDisabledException {
        if (session == _session) {
          _refused = true;
          _pending.clear();
        }
        return;
      } catch (_) {
        // Views are a tally: a failed batch is dropped, never retried.
      }
      if (session != _session) return;
    }
  }
}
