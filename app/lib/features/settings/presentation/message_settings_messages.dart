import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// The page (`/settings/messages`), its Settings row and the Messages gear.
const kMessageSettingsTitle = 'Message settings';

/// The choice's heading and spoken group label.
const kWhoCanMessageTitle = 'Who can message you';

/// The note under the choice: what "People you follow" does and does not do.
const kWhoCanMessageNote =
    'Conversations you already accepted keep working whatever you choose.';

/// The "Read receipts" switch (F3; the owner's third-round ruling: it is
/// reciprocal).
const kReadReceiptsTitle = 'Read receipts';
const kReadReceiptsSubtitle = "When off, you won't send or see read receipts.";

/// The page with none of its controls available to the caller.
const kMessageSettingsUnavailableTitle = "Message settings aren't available";
const kMessageSettingsUnavailableBody =
    'There is nothing to change here right now. Please check back later.';

/// Friendly, typed message for a failed message-privacy change (a snackbar;
/// never the server text). The control keeps showing the server's value.
String messagePrivacyErrorMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() => "This setting isn't available right now.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so this is paused. '
          'Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    _ => "Couldn't change this setting. Please try again.",
  };
}
