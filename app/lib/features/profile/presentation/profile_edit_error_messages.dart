import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/format/coarse_wait.dart';
import '../../media/presentation/media_error_messages.dart';
import '../../onboarding/domain/handle_rules.dart';
import '../domain/profile_edit_feature_flag.dart';
import '../domain/profile_extras_rules.dart';
import 'bloc/edit_profile_cubit.dart';

/// Friendly, typed text for a failed UpdateProfile (never the raw server
/// message). The name-change quota is the one daily limit this form can hit.
String updateProfileErrorMessage(AppException error) {
  return switch (error) {
    ValidationException(field: 'display_name') =>
      'Your name must be 1 to 50 characters on one line and contain a visible '
          'character.',
    ValidationException(field: 'bio') =>
      'Your bio can be at most 160 characters of plain text.',
    ValidationException(field: 'location') =>
      'Your location can be at most $kMaxLocationLength characters, on one '
          'line.',
    ValidationException(field: 'website') =>
      'Your website must be a web address that starts with https:// or '
          'http:// (at most $kMaxWebsiteLength characters).',
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
    FeatureDisabledException(feature: kFeatureProfileExtras) =>
      kProfileExtrasUnavailableMessage,
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

/// Friendly text for a failed banner change (upload or UpdateProfile with
/// `banner_media_id`). A server `profile_extras` answer is the one that is not
/// about the picture itself.
String bannerErrorMessage(AppException error) {
  return switch (error) {
    FeatureDisabledException(feature: kFeatureProfileExtras) =>
      kProfileExtrasUnavailableMessage,
    _ => profileImageErrorMessage(error, noun: 'banner'),
  };
}

/// The profile extras (banner, location, website) were switched off for this
/// account while editing. The fields are hidden and the name and bio, which
/// are not affected, can still be saved.
const kProfileExtrasUnavailableMessage =
    "Banner, location and website aren't available right now. Your name and "
    'bio can still be saved.';

/// The uploaded banner was discarded server-side (MEDIA_NOT_READY on
/// UpdateProfile, whatever the cause); it must be chosen again.
const kBannerGoneMessage =
    'That banner is no longer available. Choose it again.';

/// MEDIA_NOT_READY with a new photo and a new banner in the same save: the
/// answer does not say which one, so both are dropped.
const kImagesGoneMessage =
    'Those photos are no longer available. Choose them again.';

/// Wording of the server (W5-45): the name "must ... contain a visible
/// character", and a location has no invisible characters.
const kNameVisibleCharacterMessage =
    'Your name must contain a visible character and no invisible ones.';
const kLocationInvisibleMessage = 'Use one line of plain text, with no invisible characters.';

/// The inline error under the display name field for a local check, or null.
String? displayNameFieldError(DisplayNameIssue? issue) => switch (issue) {
  DisplayNameIssue.empty => 'Your name cannot be empty.',
  DisplayNameIssue.tooLong => 'At most $kMaxDisplayNameLength characters.',
  DisplayNameIssue.forbiddenCharacter => 'Use one line of plain text.',
  DisplayNameIssue.invisibleCharacter => kNameVisibleCharacterMessage,
  null => null,
};

/// The inline error under the bio field for a local check, or null.
String? bioFieldError(BioIssue? issue) => switch (issue) {
  BioIssue.tooLong => 'At most $kMaxBioLength characters.',
  BioIssue.forbiddenCharacter => 'Use plain text with simple line breaks.',
  null => null,
};

/// The inline error under the location field for a local check, or null.
String? locationFieldError(LocationIssue? issue) => switch (issue) {
  LocationIssue.tooLong => 'At most $kMaxLocationLength characters.',
  LocationIssue.forbiddenCharacter => 'Use one line of plain text.',
  LocationIssue.invisibleCharacter => kLocationInvisibleMessage,
  null => null,
};

/// The inline error under the website field for a local check, or null.
String? websiteFieldError(WebsiteIssue? issue) => switch (issue) {
  WebsiteIssue.tooLong => 'At most $kMaxWebsiteLength characters.',
  WebsiteIssue.invalid =>
    'Enter a web address that starts with https:// or http://.',
  null => null,
};

/// The snackbar text for the failed save in [state]: the picker, the extras
/// being switched off, a dropped picture, a failed picture upload, or the
/// UpdateProfile answer itself. Null when there is no error.
String? editProfileErrorMessage(EditProfileState state) {
  final error = state.error;
  if (error == null) return null;
  if (state.pickFailed) return kPickFailedMessage;
  if (state.extrasDisabled) return kProfileExtrasUnavailableMessage;
  if (state.avatarDropped && state.bannerDropped) return kImagesGoneMessage;
  if (state.avatarDropped) return kAvatarGoneMessage;
  if (state.bannerDropped) return kBannerGoneMessage;
  if (state.bannerFailed) return bannerErrorMessage(error);
  if (state.avatarFailed) return avatarErrorMessage(error);
  return updateProfileErrorMessage(error);
}

/// Inline text when the server refused the location / website as typed
/// (VALIDATION `field=location` / `field=website`) although the local checks
/// passed. Cleared when the field is edited.
const kLocationRejectedMessage =
    'That location was not accepted. Use up to $kMaxLocationLength '
    'characters on one line.';
const kWebsiteRejectedMessage =
    'That address was not accepted. Use a full address that starts with '
    'https:// or http://.';
