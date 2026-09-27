import 'package:flutter/foundation.dart';

/// Compile-time environment configuration, provided via `--dart-define`.
///
/// Example (local dev against emulators):
/// ```
/// flutter run \
///   --dart-define=USE_EMULATORS=true \
///   --dart-define=API_BASE_URL=http://localhost:8081 \
///   --dart-define=AUTH_EMULATOR_HOST=localhost:9099
/// ```
///
/// Example (production web build served from Firebase Hosting, which
/// rewrites `/api/**` to Cloud Run — see CLAUDE.md reference architecture):
/// ```
/// flutter build web \
///   --dart-define=USE_EMULATORS=false \
///   --dart-define=RECAPTCHA_SITE_KEY=<site-key>
/// ```
///
/// Release mobile builds have no safe default for [apiBaseUrl] — see
/// [resolveApiBaseUrl] — so CI/release tooling must always pass
/// `--dart-define=API_BASE_URL=https://...`.
/// Firebase project a build is wired to (see `lib/firebase_options*.dart`).
enum FirebaseEnv { dev, prod }

@immutable
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.useEmulators,
    required this.authEmulatorHost,
    required this.appCheckDebugToken,
    required this.recaptchaSiteKey,
    required this.googleWebClientId,
    required this.appleServiceId,
    required this.appleRedirectUri,
    required this.firebaseEnv,
  });

  /// Base URL of the Connect-RPC API (Cloud Run `api` service, or its local
  /// `go run` equivalent). Never used to reach Firestore/Storage directly —
  /// the client only ever talks to the API and to signed GCS URLs.
  final String apiBaseUrl;

  /// When true, Firebase Auth points at the local emulator
  /// (`firebase emulators:start --only auth`) instead of production Firebase.
  final bool useEmulators;

  /// host:port of the Firebase Auth emulator (default `localhost:9099`).
  final String authEmulatorHost;

  /// Optional App Check debug token for local/dev builds. Empty in prod.
  final String appCheckDebugToken;

  /// reCAPTCHA v3 site key used for App Check on Flutter Web. Empty when not
  /// yet provisioned (falls back to the debug provider so the app still
  /// compiles and runs against emulators).
  final String recaptchaSiteKey;

  /// OAuth client id for Google Sign-In on Flutter Web. Ignored on mobile.
  final String googleWebClientId;

  /// "Sign in with Apple" Service ID (reverse-DNS, e.g. `com.dzeroth.app.service`).
  /// Required for Apple sign-in on web/Android only; ignored on iOS/macOS,
  /// where the native flow is used instead. Empty until provisioned in the
  /// Apple Developer portal (see the Phase-0 manual steps).
  final String appleServiceId;

  /// Redirect URI registered for [appleServiceId] (must be a backend endpoint
  /// that completes the OAuth flow — not part of this Flutter app).
  final String appleRedirectUri;

  /// Which Firebase project the build talks to: `dev` (dzeroth-dev, the
  /// default) or `prod` (dzeroth-prod). Set by release tooling with
  /// `--dart-define=FIREBASE_ENV=prod`; see [resolveFirebaseEnv].
  final FirebaseEnv firebaseEnv;

  static const String _appleServiceIdDefine = String.fromEnvironment(
    'APPLE_SERVICE_ID',
  );

  /// Whether web builds can offer "Sign in with Apple": web needs a Services
  /// ID (`--dart-define=APPLE_SERVICE_ID=...`). iOS/macOS use the native flow.
  static const bool appleSignInOnWebConfigured = _appleServiceIdDefine != '';

  static AppConfig fromEnvironment() {
    // `!kReleaseMode` is itself a compile-time constant expression (kReleaseMode
    // is `const bool.fromEnvironment('dart.vm.product')`), so this stays
    // const-compatible: emulators default on in debug/profile builds and off
    // in release builds unless a build explicitly overrides it.
    const useEmulators = bool.fromEnvironment(
      'USE_EMULATORS',
      defaultValue: !kReleaseMode,
    );
    const definedApiBaseUrl = String.fromEnvironment('API_BASE_URL');
    const authEmulatorHost = String.fromEnvironment(
      'AUTH_EMULATOR_HOST',
      defaultValue: 'localhost:9099',
    );
    const appCheckDebugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
    const recaptchaSiteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');
    const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
    const appleServiceId = _appleServiceIdDefine;
    const appleRedirectUri = String.fromEnvironment('APPLE_REDIRECT_URI');
    const definedFirebaseEnv = String.fromEnvironment('FIREBASE_ENV');

    final firebaseEnv = resolveFirebaseEnv(definedFirebaseEnv);
    final apiBaseUrl = resolveApiBaseUrl(
      definedApiBaseUrl: definedApiBaseUrl,
      releaseMode: kReleaseMode,
      isWeb: kIsWeb,
    );

    return AppConfig(
      apiBaseUrl: apiBaseUrl,
      useEmulators: useEmulators,
      authEmulatorHost: authEmulatorHost,
      appCheckDebugToken: appCheckDebugToken,
      recaptchaSiteKey: recaptchaSiteKey,
      googleWebClientId: googleWebClientId,
      appleServiceId: appleServiceId,
      appleRedirectUri: appleRedirectUri,
      firebaseEnv: firebaseEnv,
    );
  }

  /// Maps `--dart-define=FIREBASE_ENV=...` to a [FirebaseEnv]. Empty means
  /// [FirebaseEnv.dev]; anything other than `dev`/`prod` throws
  /// [AppConfigError], so a typo can never silently ship a prod build wired
  /// to the dev project (or the reverse).
  @visibleForTesting
  static FirebaseEnv resolveFirebaseEnv(String definedFirebaseEnv) {
    switch (definedFirebaseEnv) {
      case '':
      case 'dev':
        return FirebaseEnv.dev;
      case 'prod':
        return FirebaseEnv.prod;
      default:
        throw AppConfigError(
          'Unknown FIREBASE_ENV "$definedFirebaseEnv" (expected dev or prod).',
        );
    }
  }

  /// Resolves [apiBaseUrl] from an explicit `--dart-define=API_BASE_URL=...`
  /// plus build-mode/platform fallbacks. Pulled out of [fromEnvironment] as a
  /// pure function (rather than inlined `kReleaseMode`/`kIsWeb` checks) so
  /// tests can exercise every branch without recompiling with different
  /// dart-defines:
  ///
  /// - An explicit value always wins.
  /// - Debug/profile builds talk to the local API (`go run` on `:8081`;
  ///   `:8080` is the Firestore emulator — see the `Makefile`).
  /// - Release web builds go through the Firebase Hosting `/api/**` rewrite.
  /// - Release mobile builds have no safe default (never silently fall back
  ///   to localhost or a guessed prod URL): throws [AppConfigError] so
  ///   bootstrap fails loudly instead of shipping a build that talks to the
  ///   wrong backend.
  @visibleForTesting
  static String resolveApiBaseUrl({
    required String definedApiBaseUrl,
    required bool releaseMode,
    required bool isWeb,
  }) {
    if (definedApiBaseUrl.isNotEmpty) {
      return definedApiBaseUrl;
    }
    if (!releaseMode) {
      return 'http://localhost:8081';
    }
    if (isWeb) {
      return '/api';
    }
    throw const AppConfigError(
      'API_BASE_URL must be provided via --dart-define=API_BASE_URL=... for '
      'release mobile builds; there is no safe default.',
    );
  }
}

/// Thrown at bootstrap when a required compile-time config value is missing
/// for the current build mode/platform. Must never be caught silently — it
/// indicates a broken CI/release configuration, not a runtime condition.
final class AppConfigError implements Exception {
  const AppConfigError(this.message);

  final String message;

  @override
  String toString() => 'AppConfigError: $message';
}
