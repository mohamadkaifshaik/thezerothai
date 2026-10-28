import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/private_accounts_feature_flag.dart';

/// The Settings row title.
const kProtectPostsTitle = 'Protect your posts';

/// The Settings row subtitle: what the switch does, before the confirm.
const kProtectPostsSubtitle =
    'Only people you approve can see your posts. Current followers stay.';

/// The confirm dialog for turning protection ON (ADR-0025; founder answer B1
/// 2026-10-28: images already shared may still open from their link).
const kProtectConfirmTitle = 'Protect your posts?';
const kProtectConfirmPoints = <String>[
  'Only people you approve can see your posts, past and future.',
  'People who already follow you stay.',
  'It takes effect within about a minute.',
  'Images you already shared may still open for anyone who has their link.',
  'If you turn this off later, pending follow requests are approved.',
];
const kProtectConfirmAction = 'Protect posts';

/// The confirm dialog for turning protection OFF.
const kUnprotectConfirmTitle = 'Make your posts public?';
const kUnprotectConfirmBody =
    'Anyone can see your posts again. Follow requests that are waiting are '
    'approved automatically.';
const kUnprotectConfirmAction = 'Make public';

/// Friendly, typed message for a failed protection change (a snackbar; never
/// the server text).
String protectPostsErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException(quota: kPrivacyTogglesQuotaName) =>
      'You can change this 4 times a day. Try again tomorrow.',
    LimitReachedException(quota: kPrivateAccountsLimitName) =>
      'Protected accounts are full right now, so this can\'t be turned on. '
          'Please try again later.',
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() =>
      "Protecting your posts isn't available right now.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so this is paused. '
          'Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    _ => "Couldn't change this setting. Please try again.",
  };
}
