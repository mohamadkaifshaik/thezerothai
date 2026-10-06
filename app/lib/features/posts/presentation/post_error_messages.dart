import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// Friendly, typed messages for a failed CreatePost (shown in a snackbar;
/// never the raw server text). [EmailNotVerifiedException] is normally
/// handled by showing `VerifyEmailView` instead; the text is the fallback.
/// Callers must never auto-retry after [DegradedModeException].
String createPostErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException() =>
      "You've reached today's limit for posting. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    EmailNotVerifiedException() =>
      'Please verify your email address to post.',
    DegradedModeException() =>
      'dZeroth is in a limited mode right now, so posting is paused. '
          'Please try again shortly.',
    FeatureDisabledException() => "Posting isn't available right now.",
    NetworkException() =>
      'No connection. Your post was not sent; check your network and try '
          'again.',
    ValidationException() =>
      "This post can't be sent. Check the text and try again.",
    _ => "Couldn't send your post. Please try again.",
  };
}
