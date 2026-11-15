import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// The server's `metadata["reason"]` of a SetArea without a usable consent.
const kLocationConsentRequiredReason = 'consent_required';

/// The `LIMIT_REACHED` name of the daily consent-change cap.
const kLocationConsentChangesLimit = 'location_consent_changes';

/// Whether [error] is the server asking for a (new) consent.
bool isConsentRequired(Object error) =>
    error is StateConflictException &&
    error.reason == kLocationConsentRequiredReason;

/// Friendly text for a failed read, set or clear (never the server text).
/// `consent_required` is handled by the flow (the rationale runs again); the
/// text here is only the fallback.
String locationErrorMessage(AppException error) => switch (error) {
  StateConflictException(reason: kLocationConsentRequiredReason) =>
    'Please agree to the location notice to continue.',
  LimitReachedException(quota: kLocationConsentChangesLimit) =>
    "You've changed your location choice too many times today. Try again "
        'tomorrow.',
  StateConflictException(reason: kLocationUpdateRequiredReason) =>
    'Update the app to change your location settings.',
  FeatureDisabledException() =>
    'Location is not available for your account right now.',
  final RateLimitedException e => rateLimitedMessage(e),
  UnauthenticatedException() => 'Please sign in again.',
  NetworkException() => "Couldn't reach Dzeroth. Check your connection.",
  _ => 'Something went wrong. Please try again.',
};

/// Raised locally (never sent) when the server wants a newer consent text
/// than this build has.
const kLocationUpdateRequiredReason = 'update_required';
const locationUpdateRequired = StateConflictException(
  kLocationUpdateRequiredReason,
);
