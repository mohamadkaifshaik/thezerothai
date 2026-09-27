import 'package:dzeroth/app/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.resolveApiBaseUrl', () {
    test('an explicit dart-define always wins', () {
      expect(
        AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: 'https://example.test/api',
          releaseMode: true,
          isWeb: false,
        ),
        'https://example.test/api',
      );
      expect(
        AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: 'https://example.test/api',
          releaseMode: false,
          isWeb: true,
        ),
        'https://example.test/api',
      );
    });

    test('debug/profile builds default to the local API on :8081', () {
      // :8080 is the Firestore emulator (see Makefile) — the local API
      // itself runs on :8081.
      expect(
        AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: '',
          releaseMode: false,
          isWeb: false,
        ),
        'http://localhost:8081',
      );
      expect(
        AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: '',
          releaseMode: false,
          isWeb: true,
        ),
        'http://localhost:8081',
      );
    });

    test('release web builds default to the Firebase Hosting /api rewrite', () {
      expect(
        AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: '',
          releaseMode: true,
          isWeb: true,
        ),
        '/api',
      );
    });

    test('release mobile builds with no dart-define throw AppConfigError', () {
      expect(
        () => AppConfig.resolveApiBaseUrl(
          definedApiBaseUrl: '',
          releaseMode: true,
          isWeb: false,
        ),
        throwsA(isA<AppConfigError>()),
      );
    });
  });

  group('AppConfig.fromEnvironment', () {
    test(
      'defaults useEmulators to true and apiBaseUrl to localhost:8081 '
      'when nothing is passed (flutter test runs in non-release mode)',
      () {
        final config = AppConfig.fromEnvironment();

        expect(config.useEmulators, isTrue);
        expect(config.apiBaseUrl, 'http://localhost:8081');
      },
    );
  });
}
