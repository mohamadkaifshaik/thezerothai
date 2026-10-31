import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../posts/domain/composer_attachment_rules.dart' show kFeatureGif;

/// `RATE_LIMITED` `metadata["limit"]` of the per-account daily Vision-units
/// cap (backend `media_vision_units_daily`).
const kMediaVisionUnitsDailyLimit = 'media_vision_units_daily';

/// Friendly snackbar text for a failed photo upload (CreateUpload, the PUT
/// to storage, or FinalizeUpload) while sending a post. Never the raw server
/// text. Degraded mode says text posts still work (`DEGRADED_MODE=nomedia`
/// only stops new uploads, plan D8). [gif] words the answers that name the
/// attachment for a GIF post (W6-16).
String uploadErrorMessage(AppException error, {bool gif = false}) {
  return switch (error) {
    // The per-account daily Vision-units cap (ADR-0029 Amendment 1 A5.5):
    // there is nothing to retry today.
    RateLimitedException(limitName: kMediaVisionUnitsDailyLimit) =>
      "You've reached today's image checks. Try again tomorrow.",
    // Image checks stayed unavailable after the quiet retries: the tile offers
    // a Retry and nothing is uploaded again (A5.6).
    ScreeningUnavailableException() =>
      "We couldn't check your image. Use Retry on its tile.",
    QuotaExceededException() =>
      "You've reached today's limit for photos. Post without them, or try "
          'again tomorrow.',
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Photo uploads are paused for a little while. You can still post '
          'without photos.',
    FeatureDisabledException(feature: kFeatureGif) =>
      "GIFs aren't available right now. Remove the GIF to post.",
    FeatureDisabledException() => "Photos aren't available right now.",
    NetworkException() when gif =>
      'No connection. Your GIF was not sent; check your network and try '
          'again.',
    NetworkException() =>
      'No connection. Your photos were not sent; check your network and '
          'try again.',
    ValidationException(field: 'media', :final message) => message,
    ValidationException() when gif =>
      "This GIF can't be uploaded. Remove it and try again.",
    ValidationException() =>
      "These photos can't be uploaded. Remove them and try again.",
    // Upload step: the server could not find an object we just PUT, or (a
    // GIF) it is still being checked after the quiet retries ran out.
    MediaNotReadyException() when gif =>
      'Your GIF is still being checked. Try again in a moment.',
    MediaNotReadyException() => "A photo didn't finish uploading. Try again.",
    UploadInterruptedException() => "The upload didn't finish. Try again.",
    EmailNotVerifiedException() => 'Please verify your email address to post.',
    _ => "Couldn't upload your photos. Please try again.",
  };
}

/// Friendly text for a failed avatar change (upload or UpdateProfile with
/// `avatar_media_id`).
String avatarErrorMessage(AppException error) =>
    profileImageErrorMessage(error, noun: 'photo');

/// The wording of a failed profile picture change (the avatar, the banner)
/// for the picture called [noun]: the photo quota, degraded mode, rate limit,
/// network and refusal answers are the same for every purpose, only the noun
/// differs. Never the raw server text.
String profileImageErrorMessage(AppException error, {required String noun}) {
  return switch (error) {
    QuotaExceededException() =>
      "You've reached today's limit for photo uploads. Try again tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Photo uploads are paused for a little while. Please try again '
          'shortly.',
    FeatureDisabledException() => "Photos aren't available right now.",
    NetworkException() =>
      'No connection. Your $noun was not saved; check your network and try '
          'again.',
    ValidationException(field: 'media', :final message) => message,
    MediaNotReadyException() => "The $noun didn't finish uploading. Try again.",
    UploadInterruptedException() => "The upload didn't finish. Try again.",
    _ => "Couldn't update your $noun. Please try again.",
  };
}

/// The uploaded avatar was discarded server-side; it must be chosen again.
const kAvatarGoneMessage =
    'That photo is no longer available. Choose it again.';

/// Snackbar text when the photo picker could not open or read the choice
/// (permission denied, or the platform picker failed).
const kPickFailedMessage =
    "Couldn't open your photos. Check that dZeroth is allowed to access "
    'them in Settings, then try again.';
