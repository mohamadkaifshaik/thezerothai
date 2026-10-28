/// What one pull of a conversation found.
class PollResult {
  const PollResult({required this.newMessages});

  /// True when the pull brought messages the client did not have; keeps the
  /// thread "hot" (ADR-0027 D7).
  final bool newMessages;
}

/// Pulls a visible conversation (ADR-0027 D7). Implementations decide when to
/// pull; the pull itself is injected, so screens depend on this seam only and
/// a listener or SSE transport can replace the timer implementation later.
///
/// Counts are never live: delivery is bounded by the interval (15 s hot,
/// 45 s warm, stopped after 5 min idle).
abstract class ThreadPoller {
  /// True while a schedule is armed (started and not stopped by idleness).
  bool get isRunning;

  /// Opens the thread: counts as input, then polls on the schedule while
  /// visible. Does not pull at once; the screen loads from its cache first.
  void start();

  /// Leaves the thread: cancels timers; [start] may be called again.
  void stop();

  /// User input (typing, send, scroll) keeps the thread hot, and restarts a
  /// schedule that stopped from idleness.
  void noteInput();

  /// App or tab visibility, fed from `AppLifecycleState` / `visibilitychange`
  /// by the widget layer. Hidden pauses all polling; becoming visible pulls
  /// at once (resume).
  void setVisible(bool visible);

  /// A push arrived for this conversation: pull at once (when visible).
  void onPush();

  /// Cancels timers for good; later calls are ignored.
  void dispose();
}
