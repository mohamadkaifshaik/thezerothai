import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:dzeroth/core/network/interceptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthTokenProvider extends Mock implements AuthTokenProvider {}

class MockAppCheckTokenProvider extends Mock implements AppCheckTokenProvider {}

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
  group('AuthHeadersInterceptor', () {
    late MockAuthTokenProvider authTokens;
    late MockAppCheckTokenProvider appCheckTokens;

    setUp(() {
      authTokens = MockAuthTokenProvider();
      appCheckTokens = MockAppCheckTokenProvider();
    });

    test('attaches both the ID token and the App Check token when available', () async {
      when(() => authTokens.getIdToken()).thenAnswer((_) async => 'id-token');
      when(
        () => appCheckTokens.getAppCheckToken(),
      ).thenAnswer((_) async => 'app-check-token');

      final interceptor = AuthHeadersInterceptor(authTokens, appCheckTokens);
      connect.Request<String, String>? captured;
      final wrapped = interceptor.call<String, String>((request) async {
        captured = request;
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(captured!.headers['authorization'], 'Bearer id-token');
      expect(captured!.headers['x-firebase-appcheck'], 'app-check-token');
    });

    test(
      'still makes the call with no App Check header (rather than failing '
      'it) when the App Check token fetch throws',
      () async {
        when(() => authTokens.getIdToken()).thenAnswer((_) async => 'id-token');
        when(
          () => appCheckTokens.getAppCheckToken(),
        ).thenThrow(Exception('attestation failed'));

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
      },
    );

    test('does not set the Authorization header when signed out', () async {
      when(() => authTokens.getIdToken()).thenAnswer((_) async => null);
      when(
        () => appCheckTokens.getAppCheckToken(),
      ).thenAnswer((_) async => 'app-check-token');

      final interceptor = AuthHeadersInterceptor(authTokens, appCheckTokens);
      connect.Request<String, String>? captured;
      final wrapped = interceptor.call<String, String>((request) async {
        captured = request;
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(captured!.headers.get('authorization'), isNull);
    });
  });
}
