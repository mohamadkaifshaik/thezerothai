import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// Friendly, typed text for a failed Pin or Unpin (never the raw server
/// message). One wording for every refusal of the pin itself: the server
/// answers the same VALIDATION whatever the cause, so the client cannot say
/// more (and must not guess).
String pinErrorMessage(AppException error) {
  return switch (error) {
    ValidationException() => "This post can't be pinned.",
    FeatureDisabledException() => "Pinning isn't available right now.",
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so profile changes are '
          'paused. Please try again shortly.',
    NetworkException() =>
      'No connection. Your pinned post was not changed; check your network '
          'and try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to change your profile.',
    AccountRestrictedException() => "This account can't be changed right now.",
    UnauthenticatedException() => 'Your session expired. Please sign in again.',
    _ => "Couldn't update your pinned post. Please try again.",
  };
}

/// Whether the snackbar for [error] offers Retry: not for a refusal that the
/// same request would get again (VALIDATION, FEATURE_DISABLED), nor for a
/// rate limit or the degraded mode, which only time fixes.
bool pinErrorCanRetry(AppException error) =>
    error is! ValidationException &&
    error is! FeatureDisabledException &&
    error is! RateLimitedException &&
    error is! DegradedModeException &&
    error is! AccountRestrictedException &&
    error is! UnauthenticatedException;
