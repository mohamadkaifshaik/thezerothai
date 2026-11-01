import 'telemetry_consent_store.dart';

/// Every user-visible string of the consent card and the Settings switches
/// (TEL-7). The founder approves this text together with TEL-12; keep each
/// string here so the PR lists them verbatim.
abstract final class TelemetryConsentCopy {
  static const cardTitle = 'Help us fix and improve Dzeroth';
  static const cardIntro =
      'Both are off until you choose. You can change them any time in '
      'Settings.';
  static const save = 'Save';
  static const notNow = 'Not now';

  /// The Settings subtitle of both rows.
  static const settingsSubtitle =
      'This device only. Not linked to your account.';

  static String label(TelemetryKind kind) => switch (kind) {
    TelemetryKind.crash => 'Send crash reports',
    TelemetryKind.usage => 'Share usage statistics',
  };

  /// One sentence on what is sent, ending in the "not linked" promise.
  static String sentence(TelemetryKind kind) => switch (kind) {
    TelemetryKind.crash =>
      'If the app crashes, it sends the error and what the app was doing, '
          'with your device model. Not linked to your account.',
    TelemetryKind.usage =>
      'Which screens and features are used, such as posting or following, '
          'never what you write. Not linked to your account.',
  };
}
