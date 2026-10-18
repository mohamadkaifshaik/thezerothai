import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/format/coarse_wait.dart';
import '../../onboarding/domain/handle_rules.dart';

/// Friendly, typed text for a failed UpdateProfile (never the raw server
/// message). The name-change quota is the one daily limit this form can hit.
String updateProfileErrorMessage(AppException error) {
  return switch (error) {
    ValidationException(field: 'display_name') =>
      'Your name must be 1 to 50 characters.',
    ValidationException(field: 'bio') =>
      'Your bio can be at most 160 characters.',
    ValidationException() =>
      "Those changes can't be saved. Check them and try again.",
    // The server counts the name change, not the bio: undoing the name edit
    // leaves a bio-only save, which the quota does not cover.
    QuotaExceededException(:final retryAfter) =>
      "You've changed your name too many times today. Undo the name change to "
          'save your bio now, or try again '
          '${retryAfter == null ? 'tomorrow' : 'in ${coarseWait(retryAfter)}'}.',
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so profile changes are '
          'paused. Please try again shortly.',
    FeatureDisabledException() =>
      "Editing your profile isn't available right now.",
    NetworkException() =>
      'No connection. Your changes were not saved; check your network and '
          'try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to edit your profile.',
    AccountRestrictedException() => "This account can't be changed right now.",
    UnauthenticatedException() => 'Your session expired. Please sign in again.',
    _ => "Couldn't save your changes. Please try again.",
  };
}

/// Friendly text for a failed ChangeHandle. The 7-day cooldown says when the
/// handle can be changed again; a taken handle repeats the live-check wording.
String changeHandleErrorMessage(AppException error) {
  return switch (error) {
    LimitReachedException(:final retryAfter) =>
      retryAfter == null
          ? 'You can only change your handle once every 7 days.'
          : 'You changed your handle recently. You can change it again in '
                '${coarseWait(retryAfter)}.',
    HandleTakenException() => kHandleTakenMessage,
    ValidationException() => kHandleFormatMessage,
    final RateLimitedException e => rateLimitedMessage(e),
    QuotaExceededException(:final retryAfter) =>
      "You've hit today's limit for this action. It resets "
          '${retryAfter == null ? 'tomorrow' : 'in about ${coarseWait(retryAfter)}'}.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so profile changes are '
          'paused. Please try again shortly.',
    FeatureDisabledException() =>
      "Changing your handle isn't available right now.",
    NetworkException() =>
      'No connection. Your handle was not changed; check your network and '
          'try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to change your handle.',
    AccountRestrictedException() => "This account can't be changed right now.",
    UnauthenticatedException() => 'Your session expired. Please sign in again.',
    _ => "Couldn't change your handle. Please try again.",
  };
}
