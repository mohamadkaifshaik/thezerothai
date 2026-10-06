import '../../../core/network/app_exception.dart';

/// Text of the non-blocking banner a feed shows over its cached posts when a
/// refresh or page load failed (T17). Branches on the exception type, never
/// on its text; never auto-retried by the UI.
String timelineNoticeMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e when e.isDaily =>
      "You've reached today's refresh limit. Showing saved posts; it resets "
          'later today.',
    RateLimitedException() =>
      "You're refreshing too fast. Showing saved posts for a moment.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Showing saved posts.',
    NetworkException() => "You're offline. Showing saved posts.",
    FeatureDisabledException() => "Posts aren't available right now.",
    _ => "Couldn't refresh. Showing saved posts.",
  };
}
