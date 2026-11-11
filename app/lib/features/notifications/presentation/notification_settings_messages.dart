import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// The page title (`/settings/notifications`) and the Notifications gear.
const kNotificationSettingsTitle = 'Notification settings';

/// The Settings row (and tablet category) that opens it, with its subtitle.
const kNotificationSettingsRowTitle = 'Notifications';

/// The group header above the switches and the line under it.
const kPushNotificationsHeader = 'Push notifications';
const kPushNotificationsNote =
    'Choose what sends a push notification to your devices. Your '
    'notifications list still shows everything.';

/// The page while the preferences are off for the caller.
const kNotificationSettingsUnavailableTitle =
    "Notification settings aren't available";
const kNotificationSettingsUnavailableBody =
    'You can choose which notifications send a push here later. Please '
    'check back soon.';

/// Friendly, typed message for a failed save (a snackbar; never the server
/// text). The switch keeps showing the server's value.
String notificationPrefsErrorMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() =>
      "Notification settings aren't available right now.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so this is paused. '
          'Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    _ => "Couldn't change this setting. Please try again.",
  };
}
