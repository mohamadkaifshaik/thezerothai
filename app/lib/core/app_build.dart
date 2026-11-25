import 'package:flutter/foundation.dart';

/// The app's E2EE capability level (plan 6, section 3.1). It is NOT the store
/// build number (every build is `+1`, and changing the workflows is
/// owner-gated). It is kept by hand: raise it in a PR when a later change makes
/// older builds unsafe (for example group chats), and update the pinned value
/// in `test/core/app_build_test.dart` in the same PR.
///
/// This is the level of a build that can do E2EE (Android and web). Platforms
/// with no crypto engine (`createCryptoEngine` throws; iOS today) report 0 via
/// [clientLevelFor], so the one constant is the only place a level is written.
/// A guard (`test/guards/client_capability_guard_test.dart`) keeps it that way.
const int kClientLevel = 1;

/// The request header carrying `<platform>/<level>`, for example `web/1`.
/// Lowercase so Connect's header map and the server read the same key. It
/// carries no user data: a platform word and a small integer.
///
/// Choice (the plan names the header and the `<android|web|ios>/<level>`
/// format): the header is set in `RequestMetadataInterceptor`, which already
/// runs first on every call, so it is present before sign-in and on every retry
/// attempt (retries re-send the same request object).
const String kClientHeader = 'x-dz-client';

/// The platform word for the header: `web`, `android` or `ios`. Any other
/// target (desktop shells are not shipped) is `other`, which the server's
/// lenient parser treats as an unknown platform. [isWeb] and [platform] are
/// injectable for tests.
String clientPlatformName({bool? isWeb, TargetPlatform? platform}) {
  if (isWeb ?? kIsWeb) return 'web';
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'other',
  };
}

/// The capability level of a build on [platform]: [kClientLevel] where an E2EE
/// engine exists (web, Android), 0 everywhere else (iOS cannot do E2EE yet,
/// so its builds must not be counted as capable). When the iOS binding ships,
/// add `ios` here in that PR.
int clientLevelFor(String platform) =>
    (platform == 'web' || platform == 'android') ? kClientLevel : 0;

/// The header value for [platform], for example `android/1`.
String clientHeaderValue(String platform) =>
    '$platform/${clientLevelFor(platform)}';
