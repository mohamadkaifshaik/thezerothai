import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:protobuf/protobuf.dart' as $pb;

/// An unsigned Firebase-shaped ID token for [uid] (`alg: none`, empty
/// signature, like the Auth emulator's). [iat] tells two tokens of the same
/// account apart (a refresh).
String idTokenFor(String uid, {int iat = 1}) {
  String part(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = part({'alg': 'none', 'typ': 'JWT'});
  final payload = part({'sub': uid, 'user_id': uid, 'iat': iat});
  return '$header.$payload.';
}

/// An [AuthTokenProvider] whose answers the test releases by hand: every
/// [getIdToken] call takes the next queued answer, or waits on a completer
/// the test finishes with [complete].
class ScriptedAuthTokens implements AuthTokenProvider {
  final Queue<String?> _ready = Queue();
  final Queue<Completer<String?>> _waiting = Queue();

  /// How many times a token was asked for.
  int calls = 0;

  /// The next [getIdToken] answers [token] at once.
  void answer(String? token) => _ready.add(token);

  /// Finishes the oldest [getIdToken] call still waiting.
  void complete(String? token) => _waiting.removeFirst().complete(token);

  bool get hasWaiting => _waiting.isNotEmpty;

  @override
  Future<String?> getIdToken() {
    calls++;
    if (_ready.isNotEmpty) return Future.value(_ready.removeFirst());
    final c = Completer<String?>();
    _waiting.add(c);
    return c.future;
  }

  /// How many forced refreshes were asked for.
  int refreshes = 0;

  /// While set, [refreshIdToken] waits until [finishRefresh].
  bool holdRefresh = false;

  /// What a forced refresh throws instead of answering (a network failure).
  Object? refreshError;
  final Queue<Completer<String?>> _refreshWaiting = Queue();

  /// Finishes the oldest held [refreshIdToken].
  void finishRefresh() => _refreshWaiting.removeFirst().complete(null);

  bool get hasRefreshWaiting => _refreshWaiting.isNotEmpty;

  /// The forced refresh answers nothing the interceptor reads: the next
  /// [getIdToken] answer (queued with [answer]) is the refreshed token.
  /// When set, [refreshIdToken] throws synchronously (before returning a
  /// future).
  bool refreshThrowsSync = false;

  @override
  Future<String?> refreshIdToken() {
    refreshes++;
    if (refreshThrowsSync) throw StateError('sync');
    final error = refreshError;
    if (error != null) return Future.error(error);
    if (!holdRefresh) return Future.value(null);
    final c = Completer<String?>();
    _refreshWaiting.add(c);
    return c.future;
  }

  /// Every account [reportSessionEnded] was told about, in order.
  final List<String> ended = [];

  @override
  void reportSessionEnded(String uid) => ended.add(uid);
}

/// A Connect UNAUTHENTICATED answer carrying ErrorDetail SESSION_ENDED (26),
/// as the server's session-cut interceptor sends it.
connect.HttpResponse sessionEndedError() => connectErrorWithReason(
  401,
  'unauthenticated',
  reasonNumber: 26,
  message: 'this session has ended',
);

/// A Connect error with [code] and an `ErrorDetail` whose `reason` is
/// [reasonNumber] (`dzeroth.common.v1.ErrorReason`), JSON-encoded the way
/// the server sends it.
connect.HttpResponse connectErrorWithReason(
  int status,
  String code, {
  required int reasonNumber,
  String message = '',
}) {
  // ErrorDetail: field 1 (reason, varint), field 2 (message, bytes).
  final text = utf8.encode(message);
  final detail = <int>[
    0x08,
    reasonNumber,
    if (text.isNotEmpty) ...[0x12, text.length, ...text],
  ];
  final headers = connect.Headers()..set('content-type', ['application/json']);
  return connect.HttpResponse(
    status,
    headers,
    Stream.value(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'code': code,
            'message': message,
            'details': [
              {
                'type': 'dzeroth.common.v1.ErrorDetail',
                'value': base64.encode(detail).replaceAll('=', ''),
              },
            ],
          }),
        ),
      ),
    ),
    connect.Headers(),
  );
}

/// An [AppCheckTokenProvider] that answers [token] at once, or waits on a
/// completer the test finishes with [complete] while [hold] is set.
class ScriptedAppCheck implements AppCheckTokenProvider {
  String? token = 'app-check-token';
  bool hold = false;
  final Queue<Completer<String?>> _waiting = Queue();

  void complete() => _waiting.removeFirst().complete(token);

  bool get hasWaiting => _waiting.isNotEmpty;

  @override
  Future<String?> getAppCheckToken() {
    if (!hold) return Future.value(token);
    final c = Completer<String?>();
    _waiting.add(c);
    return c.future;
  }
}

/// A fake network under the REAL connect-dart transport and the real
/// `ApiClient` interceptor chain: records every request that reached the
/// wire and answers from [respond] (a 200 with an empty body by default).
class RecordingHttp {
  RecordingHttp({connect.HttpResponse Function(connect.HttpRequest)? respond})
    : respond = respond ?? ((_) => protoOk(null));

  connect.HttpResponse Function(connect.HttpRequest) respond;

  /// Every request handed to the network, in order.
  final List<connect.HttpRequest> sent = [];

  /// The `Authorization` header of each request as it was when sent (a
  /// retry re-sends the same request object, whose headers then change).
  final List<String?> sentBearers = [];

  connect.HttpClient get client => (request) async {
    sent.add(request);
    sentBearers.add(request.header['authorization']);
    return respond(request);
  };

  /// The `Authorization` header of the [i]th request sent.
  String? bearerOf(int i) => headerOf(i, 'authorization');

  /// Header [name] of the [i]th request sent.
  String? headerOf(int i, String name) => sent[i].header[name];
}

/// A Connect unary success carrying [message] (an empty message when null).
connect.HttpResponse protoOk($pb.GeneratedMessage? message) {
  final headers = connect.Headers()..set('content-type', ['application/proto']);
  return connect.HttpResponse(
    200,
    headers,
    Stream.value(message?.writeToBuffer() ?? Uint8List(0)),
    connect.Headers(),
  );
}

/// A Connect unary error with [code] (e.g. `unavailable`) and HTTP [status].
connect.HttpResponse connectError(int status, String code) {
  final headers = connect.Headers()..set('content-type', ['application/json']);
  return connect.HttpResponse(
    status,
    headers,
    Stream.value(
      Uint8List.fromList(
        utf8.encode(jsonEncode({'code': code, 'message': code})),
      ),
    ),
    connect.Headers(),
  );
}
