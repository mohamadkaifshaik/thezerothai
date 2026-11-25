import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/app_build.dart';
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:dzeroth/core/network/interceptors.dart';
import 'package:dzeroth/core/network/request_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/session_tokens.dart';

class MockAuthTokenProvider extends Mock implements AuthTokenProvider {}

class MockAppCheckTokenProvider extends Mock implements AppCheckTokenProvider {}

String _android() => 'android';
String _web() => 'web';
String _ios() => 'ios';

connect.UnaryRequest<String, String> _request() {
  return connect.UnaryRequest<String, String>(
    connect.Spec<String, String>(
      '/test.Service/Method',
      connect.StreamType.unary,
      () => '',
      () => '',
    ),
    'https://example.test/test.Service/Method',
    connect.Headers(),
    '',
    connect.CancelableSignal(),
  );
}

connect.UnaryResponse<String, String> _echoResponse(
  connect.Request<String, String> request,
) {
  return connect.UnaryResponse<String, String>(
    request.spec,
    connect.Headers(),
    '',
    connect.Headers(),
  );
}

void main() {
  group('RequestMetadataInterceptor capability header', () {
    Future<connect.Request<String, String>> send(
      RequestMetadataInterceptor interceptor,
    ) async {
      connect.Request<String, String>? captured;
      await interceptor.call<String, String>((request) async {
        captured = request;
        return _echoResponse(request);
      })(_request());
      return captured!;
    }

    // No session and no auth interceptor in this chain: the header does not
    // depend on sign-in.
    test(
      'every request carries x-dz-client with the platform and level',
      () async {
        final sent = await send(
          const RequestMetadataInterceptor(platform: _android),
        );
        expect(sent.headers['x-dz-client'], 'android/$kClientLevel');
      },
    );

    test('the platform word is web, android or ios with its level', () async {
      expect(
        (await send(const RequestMetadataInterceptor(platform: _web)))
            .headers['x-dz-client'],
        'web/$kClientLevel',
      );
      expect(
        (await send(const RequestMetadataInterceptor(platform: _ios)))
            .headers['x-dz-client'],
        'ios/0',
      );
    });

    test('adds only x-request-id and x-dz-client', () async {
      final sent = await send(
        const RequestMetadataInterceptor(platform: _android),
      );
      final names = {for (final e in sent.headers.entries) e.name};
      expect(names, {'x-request-id', 'x-dz-client'});
    });

    test('a retried request still carries it on every attempt', () async {
      final seen = <String?>[];
      var attempts = 0;
      final chain = const RequestMetadataInterceptor(platform: _android)
          .call<String, String>(
            const RetryInterceptor(baseDelay: Duration.zero)
                .call<String, String>((request) async {
                  seen.add(request.headers['x-dz-client']);
                  if (++attempts < 3) {
                    throw connect.ConnectException(
                      connect.Code.unavailable,
                      'unavailable',
                    );
                  }
                  return _echoResponse(request);
                }),
          );
      final request = connect.UnaryRequest<String, String>(
        connect.Spec<String, String>(
          '/test.Service/Method',
          connect.StreamType.unary,
          () => '',
          () => '',
          idempotency: connect.Idempotency.noSideEffects,
        ),
        'https://example.test/test.Service/Method',
        connect.Headers(),
        '',
        connect.CancelableSignal(),
      );

      await chain(request);

      expect(seen, List.filled(3, 'android/$kClientLevel'));
    });
  });

  group('AuthHeadersInterceptor', () {
    late MockAuthTokenProvider authTokens;
    late MockAppCheckTokenProvider appCheckTokens;

    setUp(() {
      authTokens = MockAuthTokenProvider();
      appCheckTokens = MockAppCheckTokenProvider();
    });

    test(
      'attaches both the ID token and the App Check token when available',
      () async {
        when(() => authTokens.getIdToken()).thenAnswer((_) async => 'id-token');
        when(() => appCheckTokens.getAppCheckToken())
            .thenAnswer((_) async => 'app-check-token');

        final interceptor = AuthHeadersInterceptor(authTokens, appCheckTokens);
        connect.Request<String, String>? captured;
        final wrapped = interceptor.call<String, String>((request) async {
          captured = request;
          return _echoResponse(request);
        });

        await wrapped(_request());

        expect(captured!.headers['authorization'], 'Bearer id-token');
        expect(captured!.headers['x-firebase-appcheck'], 'app-check-token');
      },
    );

    test('still makes the call with no App Check header (rather than failing '
        'it) when the App Check token fetch throws', () async {
      when(() => authTokens.getIdToken()).thenAnswer((_) async => 'id-token');
      when(() => appCheckTokens.getAppCheckToken())
          .thenThrow(Exception('attestation failed'));

      final interceptor = AuthHeadersInterceptor(authTokens, appCheckTokens);
      connect.Request<String, String>? captured;
      var called = false;
      final wrapped = interceptor.call<String, String>((request) async {
        called = true;
        captured = request;
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(called, isTrue);
      expect(captured!.headers['authorization'], 'Bearer id-token');
      expect(captured!.headers.get('x-firebase-appcheck'), isNull);
    });

    test('does not set the Authorization header when signed out', () async {
      when(() => authTokens.getIdToken()).thenAnswer((_) async => null);
      when(() => appCheckTokens.getAppCheckToken())
          .thenAnswer((_) async => 'app-check-token');

      final interceptor = AuthHeadersInterceptor(authTokens, appCheckTokens);
      connect.Request<String, String>? captured;
      final wrapped = interceptor.call<String, String>((request) async {
        captured = request;
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(captured!.headers.get('authorization'), isNull);
    });

    test('a token of another account than the session refuses the call '
        'without calling next', () async {
      when(() => authTokens.getIdToken())
          .thenAnswer((_) async => idTokenFor('uid-b'));
      when(() => appCheckTokens.getAppCheckToken())
          .thenAnswer((_) async => 'app-check-token');

      final interceptor = AuthHeadersInterceptor(
        authTokens,
        appCheckTokens,
        sessionUid: () => 'uid-a',
      );
      var called = false;
      final wrapped = interceptor.call<String, String>((request) async {
        called = true;
        return _echoResponse(request);
      });

      await expectLater(
        wrapped(_request()),
        throwsA(isA<RequestSessionChangedException>()),
      );
      expect(called, isFalse);
    });

    test('a token of the session account is attached as before', () async {
      when(() => authTokens.getIdToken())
          .thenAnswer((_) async => idTokenFor('uid-a'));
      when(() => appCheckTokens.getAppCheckToken())
          .thenAnswer((_) async => 'app-check-token');

      final interceptor = AuthHeadersInterceptor(
        authTokens,
        appCheckTokens,
        sessionUid: () => 'uid-a',
      );
      connect.Request<String, String>? captured;
      final wrapped = interceptor.call<String, String>((request) async {
        captured = request;
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(
        captured!.headers['authorization'],
        'Bearer ${idTokenFor('uid-a')}',
      );
      expect(captured!.headers['x-firebase-appcheck'], 'app-check-token');
    });
  });

  group('RequestSessionGuard', () {
    connect.AnyFn<String, String> sink(void Function() onSend) =>
        (request) async {
          onSend();
          return _echoResponse(request);
        };

    test('asserts when a session exists but the request carries no binding '
        '(it skipped AuthHeadersInterceptor)', () async {
      var sent = 0;
      final guarded = RequestSessionGuard(() => 'uid-a')
          .call<String, String>(sink(() => sent++));

      await expectLater(guarded(_request()), throwsA(isA<AssertionError>()));
      expect(sent, 0);
    });

    test('passes a request bound to the current session, and one that '
        'entered with no session even after a sign-in', () async {
      final authTokens = MockAuthTokenProvider();
      final appCheckTokens = MockAppCheckTokenProvider();
      when(() => appCheckTokens.getAppCheckToken())
          .thenAnswer((_) async => null);
      var sent = 0;
      // The session the guard sees: uid-a throughout.
      final guarded = RequestSessionGuard(() => 'uid-a')
          .call<String, String>(sink(() => sent++));

      when(() => authTokens.getIdToken())
          .thenAnswer((_) async => idTokenFor('uid-a'));
      await AuthHeadersInterceptor(
        authTokens,
        appCheckTokens,
        sessionUid: () => 'uid-a',
      ).call<String, String>(guarded)(_request());
      expect(sent, 1);

      // Entered with no session (signed out at entry): unbound, never
      // refused and never asserted, whoever signs in afterwards.
      when(() => authTokens.getIdToken()).thenAnswer((_) async => null);
      await AuthHeadersInterceptor(
        authTokens,
        appCheckTokens,
        sessionUid: () => null,
      ).call<String, String>(guarded)(_request());
      expect(sent, 2);
    });
  });
}
