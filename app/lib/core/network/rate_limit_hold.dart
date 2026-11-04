import 'app_exception.dart';

/// Remembers a RATE_LIMITED answer so a repository stops sending the same
/// read until its `retry_after` has passed.
///
/// Each repository owns its own instance (a limit answered to one RPC family
/// must not freeze unrelated reads). Sign-out [clear]s it. Callers [check]
/// before sending (and throw what it returns) and [record] every
/// RateLimitedException they receive.
class RateLimitHold {
  RateLimitHold({Duration Function()? monotonic})
    : _elapsed = monotonic ?? _stopwatchClock();

  final Duration Function() _elapsed;
  Duration? _until;
  RateLimitedException? _limit;

  /// Remembers [error] until its `retry_after` (5 minutes for a daily limit
  /// and 30 seconds otherwise when the server sent none).
  void record(RateLimitedException error) {
    _limit = error;
    _until =
        _elapsed() +
        (error.retryAfter ??
            (error.isDaily
                ? const Duration(minutes: 5)
                : const Duration(seconds: 30)));
  }

  /// The answer still being held back, with `retryAfter` reduced to the time
  /// left; null when nothing is held (the hold is released on expiry).
  RateLimitedException? check() {
    final until = _until;
    final original = _limit;
    if (until == null || original == null) return null;
    final left = until - _elapsed();
    if (left <= Duration.zero) {
      clear();
      return null;
    }
    return RateLimitedException(
      original.message,
      retryAfter: left,
      limitName: original.limitName,
    );
  }

  /// Forgets the hold (sign-out).
  void clear() {
    _until = null;
    _limit = null;
  }
}

Duration Function() _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}
