import '../../../core/network/app_exception.dart';

/// Text of the non-blocking banner the notifications list shows over cached
/// rows when a refresh or page failed. Branches on the exception type, never
/// on its text; never auto-retried by the UI.
String notificationsNoticeMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e when e.isDaily =>
      "You've reached today's refresh limit. Showing saved notifications; "
          'it resets later today.',
    RateLimitedException() =>
      "You're refreshing too fast. Showing saved notifications for a moment.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Showing saved notifications.',
    NetworkException() => "You're offline. Showing saved notifications.",
    FeatureDisabledException() => "Notifications aren't available right now.",
    _ => "Couldn't refresh. Showing saved notifications.",
  };
}
