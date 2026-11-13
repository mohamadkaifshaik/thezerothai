import 'dart:convert';

import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/core/network/request_session.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/session_tokens.dart';

const _a = 'uid-a';
const _b = 'uid-b';

/// A request is bound to the account that was signed in when it was built:
/// the account switching while it waits for its tokens refuses it before
/// anything reaches the network.
void main() {
  late String? session;
  late ScriptedAuthTokens auth;
  late ScriptedAppCheck appCheck;
  late RecordingHttp http;

  setUp(() {
    session = null;
    auth = ScriptedAuthTokens();
    appCheck = ScriptedAppCheck();
    http = RecordingHttp();
  });

  ApiClient client() => ApiClient(
    baseUrl: 'https://api.example.test',
    authTokens: auth,
    appCheckTokens: appCheck,
    sessionUid: () => session,
    httpClient: http.client,
  );

  /// Starts [call] now and returns its outcome: null on success, the thrown
  /// error otherwise.
  Future<Object?> outcome(Future<Object?> Function() call) =>
      guardApiCall(call).then<Object?>((_) => null, onError: (Object e) => e);

  Future<Object?> createPost(ApiClient api) => outcome(
    () => api.posts.createPost(
      posts.CreatePostRequest(idempotencyKey: 'k1', text: 'written by A'),
    ),
  );

  Future<Object?> getMe(ApiClient api) =>
      outcome(() => api.identity.getMe(identity.GetMeRequest()));

  group('the account changes while the request waits for its tokens', () {
    test('A to B before the ID token arrives: nothing is sent, '
        'UnauthenticatedException', () async {
      session = _a;
      final result = createPost(client());
      session = _b;
      auth.complete(idTokenFor(_b));

      expect(await result, isA<UnauthenticatedException>());
      expect(http.sent, isEmpty);
    });

    test('A to B, and the fetch still answers A\'s token: nothing is sent '
        '(the session ended)', () async {
      session = _a;
      final result = createPost(client());
      session = _b;
      auth.complete(idTokenFor(_a));

      expect(await result, isA<UnauthenticatedException>());
      expect(http.sent, isEmpty);
    });

    test('a token of another account while the app still shows A (the auth '
        'SDK switched first): nothing is sent', () async {
      session = _a;
      final result = createPost(client());
      auth.complete(idTokenFor(_b));

      expect(await result, isA<UnauthenticatedException>());
      expect(http.sent, isEmpty);
    });

    test('signed out before the ID token arrives: nothing is sent', () async {
      session = _a;
      final result = createPost(client());
      session = null;
      auth.complete(null);

      expect(await result, isA<UnauthenticatedException>());
      expect(http.sent, isEmpty);
    });

    test(
      'A to B before the App Check token arrives: nothing is sent',
      () async {
        session = _a;
        auth.answer(idTokenFor(_a));
        appCheck.hold = true;
        final result = createPost(client());
        await pumpEventQueue();
        expect(appCheck.hasWaiting, isTrue);
        session = _b;
        appCheck.complete();

        expect(await result, isA<UnauthenticatedException>());
        expect(http.sent, isEmpty);
      },
    );

    test('an ID token whose account cannot be read is not sent under a '
        'session', () async {
      session = _a;
      auth.answer('not-a-jwt');

      expect(await createPost(client()), isA<UnauthenticatedException>());
      expect(http.sent, isEmpty);
    });
  });

  group('the legitimate paths still send', () {
    test('a same-uid token refresh mid-request is sent with the new '
        'token', () async {
      session = _a;
      final result = createPost(client());
      auth.complete(idTokenFor(_a, iat: 2));

      expect(await result, isNull);
      expect(http.sent, hasLength(1));
      expect(http.bearerOf(0), 'Bearer ${idTokenFor(_a, iat: 2)}');
      expect(http.headerOf(0, 'x-firebase-appcheck'), 'app-check-token');
    });

    test('no session (signed out, a sign-in screen RPC): sent without an '
        'Authorization header', () async {
      auth.answer(null);

      expect(await getMe(client()), isNull);
      expect(http.sent, hasLength(1));
      expect(http.bearerOf(0), isNull);
      expect(http.headerOf(0, 'x-firebase-appcheck'), 'app-check-token');
    });

    test('no session when built, a sign-in during the fetch: sent as today '
        '(nothing to bind)', () async {
      final result = getMe(client());
      session = _b;
      auth.complete(idTokenFor(_b));

      expect(await result, isNull);
      expect(http.bearerOf(0), 'Bearer ${idTokenFor(_b)}');
    });

    test('GetMe right after sign-in is sent with the new account\'s '
        'token', () async {
      session = _b;
      auth.answer(idTokenFor(_b));

      expect(await getMe(client()), isNull);
      expect(http.bearerOf(0), 'Bearer ${idTokenFor(_b)}');
    });
  });

  group('retries', () {
    test('a retry after a switch to B is not sent', () {
      fakeAsync((async) {
        var calls = 0;
        http.respond = (_) =>
            calls++ == 0 ? connectError(503, 'unavailable') : protoOk(null);
        session = _a;
        auth.answer(idTokenFor(_a));
        Object? result = 'pending';
        getMe(client()).then((r) => result = r);

        async.flushMicrotasks();
        expect(http.sent, hasLength(1));
        session = _b;
        async.elapse(const Duration(seconds: 5));

        expect(http.sent, hasLength(1));
        expect(result, isA<UnauthenticatedException>());
      });
    });

    test('a retry of a call that entered with no session is sent after a '
        'sign-in (unbound, as today)', () {
      fakeAsync((async) {
        var calls = 0;
        http.respond = (_) =>
            calls++ == 0 ? connectError(503, 'unavailable') : protoOk(null);
        auth.answer(null);
        Object? result = 'pending';
        getMe(client()).then((r) => result = r);

        async.flushMicrotasks();
        expect(http.sent, hasLength(1));
        session = _b;
        async.elapse(const Duration(seconds: 5));

        expect(http.sent, hasLength(2));
        expect(result, isNull);
      });
    });

    test('a retry under the same account is sent', () {
      fakeAsync((async) {
        var calls = 0;
        http.respond = (_) =>
            calls++ == 0 ? connectError(503, 'unavailable') : protoOk(null);
        session = _a;
        auth.answer(idTokenFor(_a));
        Object? result = 'pending';
        getMe(client()).then((r) => result = r);

        async.elapse(const Duration(seconds: 5));

        expect(http.sent, hasLength(2));
        expect(http.bearerOf(1), 'Bearer ${idTokenFor(_a)}');
        expect(result, isNull);
      });
    });
  });

  test('the refusal maps to UnauthenticatedException with the existing '
      'copy', () {
    final mapped = mapConnectError(const RequestSessionChangedException());
    expect(mapped, isA<UnauthenticatedException>());
    expect(mapped.message, 'Your session expired. Please sign in again.');
  });

  group('idTokenUid', () {
    String token(Map<String, Object> payload) {
      final p = base64Url
          .encode(utf8.encode(jsonEncode(payload)))
          .replaceAll('=', '');
      return 'eyJhbGciOiJub25lIn0.$p.sig';
    }

    test('reads sub, else user_id; unpadded payloads decode', () {
      expect(idTokenUid(idTokenFor(_a)), _a);
      expect(idTokenUid(token({'sub': 'x'})), 'x');
      expect(idTokenUid(token({'user_id': 'y'})), 'y');
      // Lengths that need one and two padding characters.
      expect(idTokenUid(token({'sub': 'ab'})), 'ab');
      expect(idTokenUid(token({'sub': 'abc'})), 'abc');
    });

    test('null for anything that is not a readable JWT with a uid', () {
      expect(idTokenUid(''), isNull);
      expect(idTokenUid('opaque'), isNull);
      expect(idTokenUid('a.b'), isNull);
      expect(idTokenUid('a.%%%.c'), isNull);
      expect(idTokenUid('a.${base64Url.encode(utf8.encode('[1]'))}.c'), isNull);
      expect(idTokenUid(token({'sub': ''})), isNull);
      expect(idTokenUid(token({'sub': 7})), isNull);
      expect(idTokenUid(token({'iat': 1})), isNull);
    });
  });
}
