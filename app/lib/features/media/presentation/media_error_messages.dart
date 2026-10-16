import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// Friendly snackbar text for a failed photo upload (CreateUpload, the PUT
/// to storage, or FinalizeUpload) while sending a post. Never the raw server
/// text. Degraded mode says text posts still work (`DEGRADED_MODE=nomedia`
/// only stops new uploads, plan D8).
String uploadErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException() =>
      "You've reached today's limit for photos. Post without them, or try "
          'again tomorrow.',
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Photo uploads are paused for a little while. You can still post '
          'without photos.',
    FeatureDisabledException() => "Photos aren't available right now.",
    NetworkException() =>
      'No connection. Your photos were not sent; check your network and '
          'try again.',
    ValidationException(field: 'media', :final message) => message,
    ValidationException() =>
      "These photos can't be uploaded. Remove them and try again.",
    // Upload step: the server could not find an object we just PUT.
    MediaNotReadyException() =>
      "A photo didn't finish uploading. Try again.",
    UploadInterruptedException() =>
      "The upload didn't finish. Try again.",
    EmailNotVerifiedException() => 'Please verify your email address to post.',
    _ => "Couldn't upload your photos. Please try again.",
  };
}

/// Friendly text for a failed avatar change (upload or UpdateProfile with
/// `avatar_media_id`).
String avatarErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException() =>
      "You've reached today's limit for photo uploads. Try again tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    DegradedModeException() =>
      'Photo uploads are paused for a little while. Please try again '
          'shortly.',
    FeatureDisabledException() => "Photos aren't available right now.",
    NetworkException() =>
      'No connection. Your photo was not saved; check your network and try '
          'again.',
    ValidationException(field: 'media', :final message) => message,
    MediaNotReadyException() =>
      "The photo didn't finish uploading. Try again.",
    UploadInterruptedException() =>
      "The upload didn't finish. Try again.",
    _ => "Couldn't update your photo. Please try again.",
  };
}

/// The uploaded avatar was discarded server-side; it must be chosen again.
const kAvatarGoneMessage = 'That photo is no longer available. Choose it again.';

/// Snackbar text when the photo picker could not open or read the choice
/// (permission denied, or the platform picker failed).
const kPickFailedMessage =
    "Couldn't open your photos. Check that dZeroth is allowed to access "
    'them in Settings, then try again.';
