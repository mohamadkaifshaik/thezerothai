import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;

import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'auth_token_provider.dart';
import 'connect_error_mapper.dart' show findErrorDetail;
import 'request_session.dart';

/// True when [error] is the server's session-cut refusal: UNAUTHENTICATED
/// with `ErrorDetail.reason` SESSION_ENDED (any RPC, removal design §3.3).
bool isSessionEndedFailure(connect.ConnectException error) =>
    error.code == connect.Code.unauthenticated &&
    findErrorDetail(error)?.reason ==
        common.ErrorReason.ERROR_REASON_SESSION_ENDED;

/// Handles SESSION_ENDED in the one place every call passes (ruling 1 of
/// lane D PR 4; PR 3 security audit L1).
///
/// A REMOTE device removal cuts every session signed in before the
/// remover's re-sign-in. The remover's own stale copies of the old token
/// (calls in flight across the re-sign-in, a background isolate, another
/// tab) are refused too, so the first refusal proves nothing:
///
/// - the ID token is force-refreshed ONCE per burst
///   ([AuthTokenProvider.refreshIdToken]; calls refused while it runs join
///   it, and a call sent before it finished retries without another);
/// - the refused call is retried ONCE, through [AuthHeadersInterceptor]
///   again (it sits inside this one), so it carries the new token. Mutations
///   too: the server refuses before the rate limiter and every handler, so
///   nothing of the call ran;
/// - only a second SESSION_ENDED reports the end
///   ([AuthTokenProvider.reportSessionEnded], once per burst: later calls
///   refused for the same account are not retried or reported again). A
///   successful call, or a call bound to another account, ends the burst.
///
/// The retry keeps the request-session binding: the call is bound to the
/// account signed in when it entered (read synchronously); if the session
/// moved on during the refresh, the retry is refused locally with
/// [RequestSessionChangedException] and never sent. A call that entered
/// with no session is not retried and reports nothing (nothing to sign out).
///
/// Always on, whatever the flags (brief ruling 5): a SESSION_ENDED answer
/// comes only when the server enforces a cut.
final class SessionEndedInterceptor {
  SessionEndedInterceptor(this._tokens, this._sessionUid);

  final AuthTokenProvider _tokens;
  final SessionUidReader _sessionUid;

  /// How many forced refreshes finished.
  int _refreshes = 0;
  Future<void>? _refreshing;

  /// The account whose end this burst already reported.
  String? _endedUid;

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      // Synchronous, before the first await: the account of this call.
      final uid = _sessionUid();
      if (_endedUid != null && uid != _endedUid) _endedUid = null;
      final seen = _refreshes;
      final connect.Response<I, O> response;
      try {
        response = await next(request);
      } on connect.ConnectException catch (e) {
        if (uid == null || !isSessionEndedFailure(e)) rethrow;
        // Already reported for this account: no refresh, no retry.
        if (_endedUid == uid) rethrow;
        if (seen == _refreshes) await _refresh();
        if (_sessionUid() != uid) throw const RequestSessionChangedException();
        return _retry(next, request, uid);
      }
      if (_endedUid == uid) _endedUid = null;
      return response;
    };
  }

  Future<connect.Response<I, O>> _retry<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
    connect.Request<I, O> request,
    String uid,
  ) async {
    final connect.Response<I, O> response;
    try {
      response = await next(request);
    } on connect.ConnectException catch (e) {
      if (isSessionEndedFailure(e) && _endedUid != uid) {
        _endedUid = uid;
        _tokens.reportSessionEnded(uid);
      }
      rethrow;
    }
    if (_endedUid == uid) _endedUid = null;
    return response;
  }

  /// One forced refresh shared by every call refused while it runs. A failed
  /// refresh is not an answer: the retry still goes (with whatever token the
  /// SDK has) and decides.
  Future<void> _refresh() => _refreshing ??= () async {
    try {
      await _tokens.refreshIdToken();
    } catch (_) {
      // See above: the retry decides.
    } finally {
      _refreshes++;
      _refreshing = null;
    }
  }();
}
