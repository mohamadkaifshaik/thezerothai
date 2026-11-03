import 'package:flutter/foundation.dart';

/// Where the SDKs may run (ADR-0032 F2): Android only. iOS waits
/// (its off-switch keys are already in `Info.plist`); web has neither.
abstract final class TelemetryPlatforms {
  static const Set<TargetPlatform> supportedOn = {TargetPlatform.android};

  /// True for [platform] unless [isWeb] (web reports `android` for some
  /// browsers, so web is excluded first).
  static bool isSupported(TargetPlatform platform, {required bool isWeb}) =>
      !isWeb && supportedOn.contains(platform);

  /// True on this device.
  static bool get current => isSupported(defaultTargetPlatform, isWeb: kIsWeb);
}
