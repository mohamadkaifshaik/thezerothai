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

    test('the W2-14 probes are refused (L-4)', () {
      for (final bad in [
        // Newline, space, percent-encoded fragment, backslash.
        'https://a.com\nb',
        'https://a.com\r\nb',
        'https://dzeroth.com\n',
        'https://a b.com',
        'https://evil.com%23.dzeroth.com',
        r'https://evil.com\@dzeroth.com',
        // Trailing dot, IDN, IP literals, single label.
        'https://dzeroth.com.',
        'https://bücher.example',
        'https://münchen.de',
        'https://[::1]',
        'https://[::1]:8443',
        'https://127.0.0.1',
        'https://127.0.0.1:8443',
        'https://2130706433.1',
        'https://localhost',
        // Ports: empty, out of range, non-default on a default host.
        'https://a.com:',
        'https://a.com:0',
        'https://a.com:99999',
        'https://a.com:abc',
        'https://dzeroth.com:8443',
        'https://DZEROTH-DEV.web.app:444',
        // User info, path, query, fragment, wrong shape.
        'https://user@dzeroth.com',
        'https://dzeroth.com/x',
        'https://dzeroth.com?',
        'https://dzeroth.com#',
        'https:a.com',
        'https:///a.com',
        '//',
        '/',
        'https:',
        'https://-',
        'ftp://dzeroth.com',
      ]) {
        expect(() => resolve(bad), throwsA(isA<AppConfigError>()), reason: bad);
      }
    });

    test('an accepted origin comes back canonical (L-4)', () {
      expect(resolve('HTTPS://DZEROTH.COM'), 'https://dzeroth.com');
      expect(resolve('https://DZEROTH.COM/'), 'https://dzeroth.com');
      expect(resolve('https://dzeroth.com:443'), 'https://dzeroth.com');
      expect(resolve('https://Example.Test:8443'), 'https://example.test:8443');
      expect(
        resolve('https://xn--bcher-kva.example'),
        'https://xn--bcher-kva.example',
      );
      expect(resolve('https://a-b.c1.example'), 'https://a-b.c1.example');
      expect(resolve('https://app.example2'), 'https://app.example2');
    });

    test('fromEnvironment carries the dev default', () {
      expect(
        AppConfig.fromEnvironment().shareOrigin,
        'https://dzeroth-dev.web.app',
      );
    });
  });
}
