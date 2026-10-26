import 'package:flutter/foundation.dart';

/// Rules of the in-app "Turn on notifications" card (W2-12).
abstract final class PushOptIn {
  /// After "Not now" the card stays away for this long (per account).
  static const notNowWindow = Duration(days: 30);

  /// Where the card may be offered: Android only for now. Web has no push
  /// (ADR-0017 D11), and iOS stays off until the Apple launch: when it ships,
  /// add `TargetPlatform.iOS` here (the one place to flip). This gates the
  /// card only; `FirebasePushMessaging.supported` is unchanged, so a device
  /// that already granted push keeps registering.
  static bool supportedOn({
    required bool isWeb,
    required TargetPlatform platform,
  }) => !isWeb && platform == TargetPlatform.android;

  /// [supportedOn] for the platform the app is running on.
  static bool get supportedOnThisPlatform =>
      supportedOn(isWeb: kIsWeb, platform: defaultTargetPlatform);
}
