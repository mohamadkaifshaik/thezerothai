import 'app_exception.dart';

/// The RATE_LIMITED answer read RPCs are held back for (ADR-0010 D5: the
/// daily read budget is one budget per uid across every RPC, so a limit
/// answered to one read screen holds all of them; there are no exemptions).
///
/// One instance is created per app session and shared by the timeline and
/// posts/threads repositories only (see `bootstrap.dart`); other repositories'
/// reads (profile, graph lists) do not consult it yet. Writes never do.
/// Sign-out [clear]s it.
/// Callers [check] before sending (and throw what it returns) and [record]
/// every RateLimitedException they receive. The short in-flight hold
/// (`read_budget_inflight`) is not remembered: the API client retries it once.
class RateLimitHold {
  RateLimitHold({Duration Function()? monotonic})
    : _elapsed = monotonic ?? _stopwatchClock();

  final Duration Function() _elapsed;
  Duration? _until;
  RateLimitedException? _limit;

  /// Remembers [error] until its `retry_after` (5 minutes for a daily limit
  /// and 30 seconds otherwise when the server sent none).
  void record(RateLimitedException error) {
    if (error.isInflightHold) return;
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
