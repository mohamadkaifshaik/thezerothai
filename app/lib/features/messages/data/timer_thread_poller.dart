import 'dart:async';

import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../domain/thread_poller.dart';

/// Poll cadence of ADR-0027 D7.
const Duration kThreadHotInterval = Duration(seconds: 15);
const Duration kThreadHotIntervalWithPush = Duration(seconds: 30);
const Duration kThreadWarmInterval = Duration(seconds: 45);
const Duration kThreadHotWindow = Duration(minutes: 2);
const Duration kThreadIdleStop = Duration(minutes: 5);

/// [ThreadPoller] on a [Timer]. Pure Dart: time comes from [monotonic] (the
/// same shape as `RateLimitHold`'s clock) and visibility is an input.
///
/// - Hot (input or a new message within 2 min): every 15 s, or 30 s when
///   [pushRegistered] (Android with push; the caller decides, the poller does
///   not detect the platform). Warm: every 45 s. Idle for 5 min: stops.
/// - Hidden: no timers, no pulls. Visible again: one immediate pull.
/// - While the shared [RateLimitHold] is set nothing is pulled; the next
///   attempt waits for the hold to clear.
/// - One pull at a time. A push or resume during a pull is coalesced into a
///   single follow-up pull; a timer tick during a pull is dropped.
class TimerThreadPoller implements ThreadPoller {
  TimerThreadPoller({
    required Future<PollResult> Function() pull,
    required RateLimitHold rateLimitHold,
    Duration Function()? monotonic,
    this.pushRegistered = false,
    bool visible = true,
    void Function(Object error, StackTrace stack)? onError,
  }) : _pull = pull,
       _hold = rateLimitHold,
       _elapsed = monotonic ?? _stopwatchClock(),
       _onError = onError,
       _visible = visible;

  final Future<PollResult> Function() _pull;
  final RateLimitHold _hold;
  final Duration Function() _elapsed;
  final void Function(Object error, StackTrace stack)? _onError;

  /// Push is registered: the hot interval is 30 s instead of 15 s.
  final bool pushRegistered;

  bool _visible;
  bool _started = false;
  bool _stoppedIdle = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _followUp = false;
  Duration _lastActivity = Duration.zero;
  Timer? _timer;
  Duration? _due;

  @override
  bool get isRunning => _started && !_stoppedIdle && !_disposed;

  Duration get _hotInterval =>
      pushRegistered ? kThreadHotIntervalWithPush : kThreadHotInterval;

  bool get _isHot => _elapsed() - _lastActivity < kThreadHotWindow;

  @override
  void start() {
    if (_disposed) return;
    _started = true;
    _stoppedIdle = false;
    _lastActivity = _elapsed();
    _schedule();
  }

  @override
  void stop() {
    _started = false;
    _stoppedIdle = false;
    _followUp = false;
    _cancelTimer();
  }

  @override
  void noteInput() {
    if (_disposed || !_started) return;
    _lastActivity = _elapsed();
    if (_stoppedIdle) {
      _stoppedIdle = false;
      _schedule();
      return;
    }
    // Shorten a pending warm wait; never push a due poll later.
    final due = _due;
    if (due != null && due > _elapsed() + _hotInterval) _schedule();
  }

  @override
  void setVisible(bool visible) {
    if (_disposed || visible == _visible) return;
    _visible = visible;
    if (!visible) {
      _followUp = false;
      _cancelTimer();
      return;
    }
    _trigger();
  }

  @override
  void onPush() {
    if (_disposed || !_started || !_visible) return;
    _trigger();
  }

  @override
  void dispose() {
    _disposed = true;
    _started = false;
    _followUp = false;
    _cancelTimer();
  }

  // Immediate pull for a push or a resume.
  void _trigger() {
    if (!_started) return;
    if (_inFlight) {
      _followUp = true;
      return;
    }
    if (_holdLeft() != null) {
      // Keep an armed timer: it already waits for the hold.
      if (_timer == null) _schedule();
      return;
    }
    unawaited(_poll());
  }

  Duration? _holdLeft() => _hold.check()?.retryAfter;

  void _schedule() {
    _cancelTimer();
    if (_disposed || !_started || !_visible || _stoppedIdle || _inFlight) {
      return;
    }
    var delay = _isHot ? _hotInterval : kThreadWarmInterval;
    final held = _holdLeft();
    if (held != null && held > delay) delay = held;
    _due = _elapsed() + delay;
    _timer = Timer(delay, _onTick);
  }

  void _onTick() {
    _timer = null;
    _due = null;
    if (_disposed || !_started || !_visible) return;
    if (_elapsed() - _lastActivity >= kThreadIdleStop) {
      _stoppedIdle = true;
      return;
    }
    if (_inFlight) return;
    if (_holdLeft() != null) {
      _schedule();
      return;
    }
    unawaited(_poll());
  }

  Future<void> _poll() async {
    _inFlight = true;
    try {
      final result = await _pull();
      if (result.newMessages) _lastActivity = _elapsed();
    } on RateLimitedException catch (error) {
      _hold.record(error);
    } catch (error, stack) {
      _onError?.call(error, stack);
    } finally {
      _inFlight = false;
    }
    if (_disposed || !_started || !_visible) return;
    if (_followUp) {
      _followUp = false;
      _trigger();
      if (_inFlight) return;
    }
    _schedule();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _due = null;
  }
}

Duration Function() _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}
