import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:flutter_test/flutter_test.dart';

import '../../support/session_tokens.dart';

const _a = 'uid-a';
const _b = 'uid-b';

/// Ruling 1 (removal design §4, PR 3 security audit L1): a SESSION_ENDED
/// answer gets ONE forced token refresh and ONE retry of that call; only a
/// second SESSION_ENDED reports the session ended (the auth bloc then signs
/// out, keeping the vault). One refresh and one report per burst, in the one
/// ApiClient chain.
void main() {
  late String? session;
  late ScriptedAuthTokens auth;
  late ScriptedAppCheck appCheck;
  late RecordingHttp http;

  setUp(() {
    session = _a;
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

  Future<Object?> outcome(Future<Object?> Function() call) =>
      guardApiCall(call).then<Object?>((_) => null, onError: (Object e) => e);

  Future<Object?> createPost(ApiClient api) => outcome(
    () => api.posts.createPost(
      posts.CreatePostRequest(idempotencyKey: 'k1', text: 'hello'),
    ),
  );

  Future<Object?> getMe(ApiClient api) =>
      outcome(() => api.identity.getMe(identity.GetMeRequest()));

  /// Answers the queued responses in order, then success.
  void script(List<connect.HttpResponse Function()> answers) {
    var i = 0;
    http.respond = (_) => i < answers.length ? answers[i++]() : protoOk(null);
  }

  test('SESSION_ENDED after my own REMOTE removal (a token from before the '
      're-sign-in): one forced refresh, the same call (a mutation) retried '
      'once with the new token, no sign-out', () async {
    auth
      ..answer(idTokenFor(_a, iat: 1))
      ..answer(idTokenFor(_a, iat: 2));
    script([sessionEndedError]);

    expect(await createPost(client()), isNull);
    expect(http.sent, hasLength(2));
    expect(auth.refreshes, 1);
    expect(http.sentBearers, [
      'Bearer ${idTokenFor(_a, iat: 1)}',
      'Bearer ${idTokenFor(_a, iat: 2)}',
    ]);
    expect(auth.ended, isEmpty);
  });

  test('the retry answers SESSION_ENDED too: reported once for the bound '
      'account, SessionEndedException, nothing sent a third time', () async {
    auth
      ..answer(idTokenFor(_a, iat: 1))
      ..answer(idTokenFor(_a, iat: 2));
    script([sessionEndedError, sessionEndedError]);

    expect(await getMe(client()), isA<SessionEndedException>());
    expect(http.sent, hasLength(2));
    expect(auth.refreshes, 1);
    expect(auth.ended, [_a]);
  });

  test('a burst: three calls refused at once share one refresh, each is '
      'retried once, and the session end is reported once', () async {
    for (var i = 0; i < 6; i++) {
      auth.answer(idTokenFor(_a, iat: i));
    }
    http.respond = (_) => sessionEndedError();
    auth.holdRefresh = true;
    final api = client();
    final results = [getMe(api), getMe(api), createPost(api)];
    await pumpEventQueue();
    expect(http.sent, hasLength(3));
    expect(auth.refreshes, 1);
    auth.finishRefresh();

    for (final r in results) {
      expect(await r, isA<SessionEndedException>());
    }
    expect(http.sent, hasLength(6));
    expect(auth.refreshes, 1);
    expect(auth.ended, [_a]);
  });

  test('a call refused after the burst was reported is not retried or '
      'reported again', () async {
    for (var i = 0; i < 4; i++) {
      auth.answer(idTokenFor(_a, iat: i));
    }
    http.respond = (_) => sessionEndedError();
    final api = client();
    expect(await getMe(api), isA<SessionEndedException>());
    expect(await getMe(api), isA<SessionEndedException>());

    expect(http.sent, hasLength(3));
    expect(auth.refreshes, 1);
    expect(auth.ended, [_a]);
  });

  test('a call sent before the refresh finished is retried without a second '
      'refresh', () async {
    for (var i = 0; i < 4; i++) {
      auth.answer(idTokenFor(_a, iat: i));
    }
    // Every network answer is held until the test gives it.
    final held = <Completer<connect.HttpResponse>>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      authTokens: auth,
      appCheckTokens: appCheck,
      sessionUid: () => session,
      httpClient: (_) {
        final c = Completer<connect.HttpResponse>();
        held.add(c);
        return c.future;
      },
    );
    final first = getMe(api);
    final second = getMe(api);
    await pumpEventQueue();
    expect(held, hasLength(2));

    held[0].complete(sessionEndedError());
    await pumpEventQueue();
    expect(auth.refreshes, 1);
    expect(held, hasLength(3));
    held[2].complete(protoOk(null));
    expect(await first, isNull);

    // Sent with the old token before the refresh; refused only now.
    held[1].complete(sessionEndedError());
    await pumpEventQueue();
    expect(held, hasLength(4));
    held[3].complete(protoOk(null));
    expect(await second, isNull);
    expect(auth.refreshes, 1);
    expect(auth.ended, isEmpty);
  });

  test('a refresh that fails still retries once; a second refusal '
      'reports', () async {
    auth
      ..answer(idTokenFor(_a, iat: 1))
      ..answer(idTokenFor(_a, iat: 1))
      ..refreshError = StateError('offline');
    script([sessionEndedError, sessionEndedError]);

    expect(await getMe(client()), isA<SessionEndedException>());
    expect(http.sent, hasLength(2));
    expect(auth.ended, [_a]);
  });

  test('the account changed during the refresh: the retry is refused '
      'locally (never sent under B), nothing is reported', () async {
    auth.answer(idTokenFor(_a, iat: 1));
    auth.holdRefresh = true;
    script([sessionEndedError]);
    final result = createPost(client());
    await pumpEventQueue();
    expect(auth.hasRefreshWaiting, isTrue);
    session = _b;
    auth.answer(idTokenFor(_b));
    auth.finishRefresh();

    expect(await result, isA<UnauthenticatedException>());
    expect(http.sent, hasLength(1));
    expect(auth.ended, isEmpty);
  });

  test('UNAUTHENTICATED without SESSION_ENDED is neither retried nor '
      'reported', () async {
    auth.answer(idTokenFor(_a));
    script([() => connectError(401, 'unauthenticated')]);

    expect(await getMe(client()), isA<UnauthenticatedException>());
    expect(http.sent, hasLength(1));
    expect(auth.refreshes, 0);
    expect(auth.ended, isEmpty);
  });

  test('a call with no session bound is not retried and reports '
      'nothing', () async {
    session = null;
    auth.answer(idTokenFor(_a));
    script([sessionEndedError]);

    expect(await getMe(client()), isA<SessionEndedException>());
    expect(http.sent, hasLength(1));
    expect(auth.refreshes, 0);
    expect(auth.ended, isEmpty);
  });

  test('after a success the burst is over: a later cut is refreshed, '
      'retried and reported again', () async {
    for (var i = 0; i < 8; i++) {
      auth.answer(idTokenFor(_a, iat: i));
    }
    final api = client();
    script([sessionEndedError, sessionEndedError]);
    expect(await getMe(api), isA<SessionEndedException>());
    script([]);
    expect(await getMe(api), isNull);
    script([sessionEndedError, sessionEndedError]);
    expect(await getMe(api), isA<SessionEndedException>());

    expect(auth.refreshes, 2);
    expect(auth.ended, [_a, _a]);
  });
}
