import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:dzeroth/core/network/interceptors.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart'
    as pb_duration;
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

connect.ConnectException _rateLimited(String limit, {int? retrySeconds}) {
  return connect.ConnectException(
    connect.Code.resourceExhausted,
    'rate limited',
    details: [
      connect.ErrorDetail(
        'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          metadata: {'limit': limit}.entries,
          retryAfter: retrySeconds == null
              ? null
              : pb_duration.Duration(seconds: Int64(retrySeconds)),
        ).writeToBuffer(),
      ),
    ],
  );
}

void main() {
  group('InflightRetryInterceptor', () {
    late List<Duration> waits;

    InflightRetryInterceptor make({int maxRetries = 2}) =>
        InflightRetryInterceptor(
          maxRetries: maxRetries,
          delay: (d) async => waits.add(d),
        );

    setUp(() => waits = []);

    test('retries read_budget_inflight after retry_after, then succeeds',
        () async {
      var calls = 0;
      final wrapped = make().call<String, String>((request) async {
        calls++;
        if (calls == 1) throw _rateLimited('read_budget_inflight', retrySeconds: 1);
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(calls, 2);
      expect(waits, hasLength(1));
      // 1 s + jitter in [0, 250 ms].
      expect(waits.single, greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(
        waits.single,
        lessThanOrEqualTo(const Duration(milliseconds: 1250)),
      );
    });

    test('is bounded: surfaces the error after maxRetries', () async {
      var calls = 0;
      final wrapped = make().call<String, String>((request) async {
        calls++;
        throw _rateLimited('read_budget_inflight', retrySeconds: 1);
      });

      await expectLater(
        wrapped(_request()),
        throwsA(isA<connect.ConnectException>()),
      );
      expect(calls, 3); // 1 + 2 retries
      expect(waits, hasLength(2));
    });

    test('clamps an absurd retry_after', () async {
      var calls = 0;
      final wrapped = make(maxRetries: 1).call<String, String>((request) async {
        calls++;
        if (calls == 1) {
          throw _rateLimited('read_budget_inflight', retrySeconds: 3600);
        }
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(waits.single, lessThanOrEqualTo(const Duration(milliseconds: 3250)));
    });

    test('defaults to 1 s when retry_after is absent', () async {
      var calls = 0;
      final wrapped = make().call<String, String>((request) async {
        calls++;
        if (calls == 1) throw _rateLimited('read_budget_inflight');
        return _echoResponse(request);
      });

      await wrapped(_request());

      expect(waits.single, greaterThanOrEqualTo(const Duration(seconds: 1)));
    });

    test('does not retry daily or other RATE_LIMITED limits', () async {
      for (final limit in ['read_budget_daily', 'check_handle_daily', 'x']) {
        var calls = 0;
        final wrapped = make().call<String, String>((request) async {
          calls++;
          throw _rateLimited(limit, retrySeconds: 3600);
        });

        await expectLater(
          wrapped(_request()),
          throwsA(isA<connect.ConnectException>()),
        );
        expect(calls, 1, reason: limit);
      }
      expect(waits, isEmpty);
    });

    test('does not retry unrelated errors', () async {
      var calls = 0;
      final wrapped = make().call<String, String>((request) async {
        calls++;
        throw connect.ConnectException(connect.Code.internal, 'boom');
      });

      await expectLater(
        wrapped(_request()),
        throwsA(isA<connect.ConnectException>()),
      );
      expect(calls, 1);
    });
  });

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
