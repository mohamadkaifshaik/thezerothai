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

  group('AppConfig.resolveFirebaseEnv', () {
    test('empty and "dev" map to dev', () {
      expect(AppConfig.resolveFirebaseEnv(''), FirebaseEnv.dev);
      expect(AppConfig.resolveFirebaseEnv('dev'), FirebaseEnv.dev);
    });

    test('"prod" maps to prod', () {
      expect(AppConfig.resolveFirebaseEnv('prod'), FirebaseEnv.prod);
    });

    test('anything else throws AppConfigError instead of guessing', () {
      expect(
        () => AppConfig.resolveFirebaseEnv('production'),
        throwsA(isA<AppConfigError>()),
      );
    });
  });

  group('AppConfig.fromEnvironment', () {
    test('defaults useEmulators to true and apiBaseUrl to localhost:8081 '
        'when nothing is passed (flutter test runs in non-release mode)', () {
      final config = AppConfig.fromEnvironment();

      expect(config.useEmulators, isTrue);
      expect(config.apiBaseUrl, 'http://localhost:8081');
      expect(config.firebaseEnv, FirebaseEnv.dev);
    });
  });
  group('AppConfig.resolveShareOrigin', () {
    String resolve(String defined, [FirebaseEnv env = FirebaseEnv.dev]) =>
        AppConfig.resolveShareOrigin(definedOrigin: defined, firebaseEnv: env);

    test('defaults follow the Firebase env', () {
      expect(resolve('', FirebaseEnv.prod), 'https://dzeroth.com');
      expect(resolve('', FirebaseEnv.dev), 'https://dzeroth-dev.web.app');
    });

    test('an https origin override wins, one trailing slash dropped', () {
      expect(
        resolve('https://staging.example.test', FirebaseEnv.prod),
        'https://staging.example.test',
      );
      expect(
        resolve('https://example.test:8443/'),
        'https://example.test:8443',
      );
    });

    test('anything that is not a bare https origin is refused', () {
      for (final bad in [
        'http://example.test',
        'example.test',
        '//example.test',
        'https://',
        'https://example.test/app',
        'https://example.test//',
        'https://example.test?x=1',
        'https://example.test/?x=1',
        'https://example.test#top',
        'https://user:pw@example.test',
        'javascript:alert(1)',
      ]) {
        expect(() => resolve(bad), throwsA(isA<AppConfigError>()), reason: bad);
      }
    });

    test('fromEnvironment carries the dev default', () {
      expect(
        AppConfig.fromEnvironment().shareOrigin,
        'https://dzeroth-dev.web.app',
      );
    });
  });
}
