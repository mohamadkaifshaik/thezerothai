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
/// rewrites `/api/**` to Cloud Run — see the reference architecture):
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

/// The default share origins (founder): the prod custom domain and the
/// dev Hosting site.
const String kProdShareOrigin = 'https://dzeroth.com';
const String kDevShareOrigin = 'https://dzeroth-dev.web.app';

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
    required this.shareOrigin,
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

  /// reCAPTCHA Enterprise (Google Cloud Fraud Defense) site key for App Check
  /// on Flutter Web. Empty at Stage 0: web App Check is deferred,
  /// and the app skips App Check on web while this is empty.
  final String recaptchaSiteKey;

  /// Web OAuth client id of this build's Firebase project. Mobile Google
  /// sign-in uses it as `serverClientId`, so ID tokens target the right project.
  /// Web sign-in uses Firebase Auth's popup and doesn't need it.
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

  /// Public origin of the web app, used to build the links people share
  /// (`<origin>/post/<id>`): `https://dzeroth.com` for prod builds,
  /// `https://dzeroth-dev.web.app` for dev ones, or the validated
  /// `--dart-define=PUBLIC_WEB_ORIGIN=...` override. See [resolveShareOrigin].
  final String shareOrigin;

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
    const definedShareOrigin = String.fromEnvironment('PUBLIC_WEB_ORIGIN');

    final firebaseEnv = resolveFirebaseEnv(definedFirebaseEnv);
    final apiBaseUrl = resolveApiBaseUrl(
      definedApiBaseUrl: definedApiBaseUrl,
      releaseMode: kReleaseMode,
      isWeb: kIsWeb,
    );
    final shareOrigin = resolveShareOrigin(
      definedOrigin: definedShareOrigin,
      firebaseEnv: firebaseEnv,
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
      shareOrigin: shareOrigin,
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

  /// The origin shared post links are built on. Empty [definedOrigin] means
  /// the build's default: [kProdShareOrigin] for [FirebaseEnv.prod],
  /// [kDevShareOrigin] for [FirebaseEnv.dev]. An override must be a bare
  /// `https` origin, and the value returned is the canonical one (lower-case
  /// scheme and host, no trailing slash, no default port):
  ///
  /// - the host is ASCII `[a-z0-9-]` labels with at least one dot (no IP
  ///   literal, no single label such as `localhost`, no trailing dot, no
  ///   IDN: write the punycode form), matched after lower-casing;
  /// - no user info, path, query, fragment, whitespace, control character,
  ///   backslash or percent sign anywhere in the input; one trailing slash
  ///   is dropped;
  /// - an explicit port (1-65535) is allowed only on a host that is not one
  ///   of the two defaults ([kProdShareOrigin], [kDevShareOrigin]); `:443`
  ///   is dropped as the https default.
  ///
  /// Anything else throws [AppConfigError], so a typo cannot put a wrong or
  /// credential-bearing host into links that users send to other people.
  ///
  /// The page's own `Uri.base` is deliberately not a fallback: a localhost or
  /// preview-channel origin would end up in shared links.
  @visibleForTesting
  static String resolveShareOrigin({
    required String definedOrigin,
    required FirebaseEnv firebaseEnv,
  }) {
    if (definedOrigin.isEmpty) {
      return switch (firebaseEnv) {
        FirebaseEnv.dev => kDevShareOrigin,
        FirebaseEnv.prod => kProdShareOrigin,
      };
    }
    final origin = _canonicalShareOrigin(definedOrigin);
    if (origin == null) {
      throw AppConfigError(
        'PUBLIC_WEB_ORIGIN must be an https origin such as '
        '$kProdShareOrigin (ASCII host with a dot; no path, query, fragment, '
        'user info or IP address).',
      );
    }
    return origin;
  }

  static final _unsafeOriginChars = RegExp(r'[\x00-\x20\x7f\%]');
  static final _originHost = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');
  static final _numericTld = RegExp(r'\.[0-9]+$');

  /// The canonical form of [raw], or null when it is not a bare https origin
  /// (see [resolveShareOrigin]).
  static String? _canonicalShareOrigin(String raw) {
    // Parsers differ on these; none belongs in an origin.
    if (_unsafeOriginChars.hasMatch(raw)) return null;
    final trimmed = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    // `?`, `#` and a bare `:` leave no trace in a parsed Uri.
    if (trimmed.endsWith('?') ||
        trimmed.endsWith('#') ||
        trimmed.endsWith(':')) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    // A numeric last label is an IPv4 address, never a registrable name.
    if (!_originHost.hasMatch(host) || _numericTld.hasMatch(host)) return null;
    final port = uri.hasPort ? uri.port : 443;
    if (port < 1 || port > 65535) return null;
    final isDefaultHost =
        'https://$host' == kProdShareOrigin ||
        'https://$host' == kDevShareOrigin;
    if (port != 443 && isDefaultHost) return null;
    return port == 443 ? 'https://$host' : 'https://$host:$port';
  }

  /// Resolves [apiBaseUrl] from an explicit `--dart-define=API_BASE_URL=...`
  /// plus build-mode/platform fallbacks. Pulled out of [fromEnvironment] as a
  /// pure function (rather than inlined `kReleaseMode`/`kIsWeb` checks) so
  /// tests can exercise every branch without recompiling with different
  /// dart-defines:
  ///
  /// - An explicit value wins, but only if it passes the URL policy (https
  ///   with a host, no userinfo/query/fragment and the default port in
  ///   release builds; plain http only for local hosts otherwise).
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
      return _validatedApiBaseUrl(
        definedApiBaseUrl,
        releaseMode: releaseMode,
        isWeb: isWeb,
      );
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

const _cleartextDevHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// Accepts an explicit API base URL only when it is safe to attach ID and App
/// Check tokens to: the interceptors send both to whatever host this names.
///
/// - Release: `https` with a host, no userinfo/query/fragment and the default
///   port; on web also a same-origin relative path (`/api`).
/// - Non-release: the same, plus `http` for local development hosts
///   (`localhost`, `127.0.0.1`, the Android emulator's `10.0.2.2`) on any port.
///
/// The error message deliberately never echoes the rejected value, which may
/// carry credentials.
String _validatedApiBaseUrl(
  String value, {
  required bool releaseMode,
  required bool isWeb,
}) {
  AppConfigError reject(String why) => AppConfigError(
    'API_BASE_URL is not allowed in this build ($why). Release builds need an '
    'https URL with a host, no credentials, query or fragment, and the '
    'default port.',
  );

  if (value.trim() != value) {
    throw reject('surrounding whitespace');
  }
  final uri = Uri.tryParse(value);
  if (uri == null) throw reject('not a valid URI');
  if (uri.hasQuery) throw reject('query string');
  if (uri.hasFragment) throw reject('fragment');
  if (uri.userInfo.isNotEmpty) throw reject('credentials in the URL');

  if (!uri.hasScheme) {
    final sameOriginPath =
        isWeb &&
        !uri.hasAuthority &&
        value.startsWith('/') &&
        !value.startsWith('//');
    if (sameOriginPath) return value;
    throw reject('relative URLs are only valid on web');
  }
  if (uri.host.isEmpty) throw reject('no host');

  switch (uri.scheme) {
    case 'https':
      if (releaseMode && uri.hasPort && uri.port != 443) {
        throw reject('non-default port');
      }
      return value;
    case 'http':
      if (!releaseMode && _cleartextDevHosts.contains(uri.host)) {
        return value;
      }
      throw reject('cleartext http');
    default:
      throw reject('unsupported scheme');
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
