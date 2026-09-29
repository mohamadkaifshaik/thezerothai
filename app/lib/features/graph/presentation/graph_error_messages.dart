import '../../../core/network/app_exception.dart';

/// Friendly, typed messages for graph actions (Follow/Unfollow/Block/
/// Unblock/Mute/Unmute) shown in a snackbar — never the raw server message
/// (CLAUDE.md: "Handle RESOURCE_EXHAUSTED and degraded mode with clear,
/// friendly UI"). Callers must never auto-retry after
/// [DegradedModeException].
String relationshipErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    LimitReachedException() => "You've reached the limit for this action.",
    RateLimitedException() =>
      "You're doing that a bit too fast. Try again in a moment.",
    TargetBlockedException() => 'Unblock this account first.',
    FeatureDisabledException() => "This feature isn't available yet.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    NotFoundException() => "This account doesn't exist anymore.",
    _ => error.message,
  };
}
