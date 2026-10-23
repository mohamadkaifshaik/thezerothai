import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:dzeroth/core/network/service_paused_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mocktail/mocktail.dart';

class _Auth extends Mock implements AuthTokenProvider {}

class _AppCheck extends Mock implements AppCheckTokenProvider {}

/// A fake network layer under the REAL connect-dart transport.
connect.HttpClient _front(int status, {String? contentType, String body = ''}) {
  return (req) async {
    final headers = connect.Headers();
    if (contentType != null) headers.set('content-type', [contentType]);
    return connect.HttpResponse(
      status,
      headers,
      Stream.value(Uint8List.fromList(body.codeUnits)),
      connect.Headers(),
    );
  };
}

void main() {
  late int paused;

  ApiClient client(connect.HttpClient httpClient) {
    final auth = _Auth();
    final appCheck = _AppCheck();
    when(auth.getIdToken).thenAnswer((_) async => null);
    when(appCheck.getAppCheckToken).thenAnswer((_) async => null);
    return ApiClient(
      baseUrl: 'https://api.example.test',
      authTokens: auth,
      appCheckTokens: appCheck,
      httpClient: httpClient,
      onServicePaused: () => paused++,
    );
  }

  Future<Object?> callGetMe(ApiClient api) async {
    try {
      await guardApiCall(() => api.identity.getMe(identity.GetMeRequest()));
    } on AppException catch (e) {
      return e;
    }
    return null;
  }

  setUp(() => paused = 0);

  group('real connect-dart transport', () {
    test('HTML 403 (Google front end) -> ServicePausedException', () async {
      final e = await callGetMe(
        client(_front(403, contentType: 'text/html', body: '<html>Forbidden')),
      );
      expect(e, isA<ServicePausedException>());
      expect(paused, 1);
    });

    test(
      'empty 403 without a content type -> ServicePausedException',
      () async {
        final e = await callGetMe(client(_front(403)));
        expect(e, isA<ServicePausedException>());
        expect(paused, 1);
      },
    );

    test(
      'a real Connect PERMISSION_DENIED (JSON body) is not paused',
      () async {
        final e = await callGetMe(
          client(
            _front(
              403,
              contentType: 'application/json',
              body: '{"code":"permission_denied","message":"nope"}',
            ),
          ),
        );
        expect(e, isA<AccountRestrictedException>());
        expect(paused, 0);
      },
    );

    test('a transport failure (offline) is a NetworkException', () async {
      final e = await callGetMe(
        client((req) async => throw Exception('XMLHttpRequest error.')),
      );
      expect(e, isA<NetworkException>());
      expect(paused, 0);
    });
  });

  group('ServicePausedCubit', () {
    test('a recheck that still sees 403 stays paused', () async {
      final cubit = ServicePausedCubit(probe: () async => true);
      cubit.markPaused();
      expect(cubit.state, ServicePauseStatus.paused);
      await cubit.recheck();
      expect(cubit.state, ServicePauseStatus.paused);
    });

    test('a recheck that gets an answer lifts the screen', () async {
      final cubit = ServicePausedCubit(probe: () async => false)..markPaused();
      final seen = <ServicePauseStatus>[];
      final sub = cubit.stream.listen(seen.add);
      await cubit.recheck();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [ServicePauseStatus.checking, ServicePauseStatus.running]);
    });

    test('markPaused is a no-op while a recheck runs', () async {
      final cubit = ServicePausedCubit(probe: () async => false)..markPaused();
      final done = cubit.recheck();
      cubit.markPaused();
      await done;
      expect(cubit.state, ServicePauseStatus.running);
    });
  });

  group('probeServicePaused', () {
    Future<bool> probe(int status) => probeServicePaused(
      http_testing.MockClient((_) async => http.Response('', status)),
      'https://api.example.test',
    );

    test('403 is still paused; 200 and 401 are not', () async {
      expect(await probe(403), isTrue);
      expect(await probe(200), isFalse);
      expect(await probe(401), isFalse);
    });

    test('a network error keeps the screen', () async {
      final r = await probeServicePaused(
        http_testing.MockClient((_) async => throw Exception('offline')),
        'https://api.example.test',
      );
      expect(r, isTrue);
    });
  });
}
