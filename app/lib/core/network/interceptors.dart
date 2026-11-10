import 'dart:async';
import 'dart:math';

import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'auth_token_provider.dart';
import 'connect_error_mapper.dart';
import 'request_session.dart';

/// Adds a fresh `X-Request-Id` to every call, so backend logs and client
/// error reports can be correlated (the health and logging rule).
final class RequestMetadataInterceptor {
  const RequestMetadataInterceptor();

  static const _uuid = Uuid();

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) {
      request.headers.set('x-request-id', [_uuid.v4()]);
      return next(request);
    };
  }
}

/// Tells [onServicePaused] when a call fails with connect-dart's HTTP 403
/// fallback (`isServicePausedFailure`), then rethrows unchanged. This is the
/// one place every API call passes, so the root can show the "service paused"
/// screen without any feature screen knowing about it.
final class ServicePausedInterceptor {
  const ServicePausedInterceptor(this._onServicePaused);

  final void Function() _onServicePaused;

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      try {
        return await next(request);
      } on connect.ConnectException catch (e) {
        if (isServicePausedFailure(e)) _onServicePaused();
        rethrow;
      }
    };
  }
}

/// The account uid each in-flight request was built for, set by
/// [AuthHeadersInterceptor] and read again by [RequestSessionGuard] before
/// every attempt (a retry re-sends the same request object).
final Expando<String> _boundSession = Expando('request session');

/// Attaches the Firebase ID token and the Firebase App Check token to every
/// outgoing call. Both are refreshed lazily by the providers,
/// which cache the underlying platform tokens for their own TTL.
///
/// With [sessionUid] wired, a call is bound to the account signed in when it
/// was built (read before any await). After both token fetches the call is
/// refused with [RequestSessionChangedException], and never sent, when the
/// session moved to another account or signed out, or when the ID token is
/// not that account's (the auth SDK answers with whoever is signed in by
/// then). A call built with no session is not bound and goes as before.
final class AuthHeadersInterceptor {
  const AuthHeadersInterceptor(
    this._authTokens,
    this._appCheckTokens, {
    SessionUidReader? sessionUid,
  }) : _sessionUid = sessionUid;

  final AuthTokenProvider _authTokens;
  final AppCheckTokenProvider _appCheckTokens;
  final SessionUidReader? _sessionUid;

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      // Synchronous, before the first await: the account this call is for.
      final bound = _sessionUid?.call();
      if (bound != null) _boundSession[request] = bound;
      final idToken = await _authTokens.getIdToken();
      if (idToken != null) {
        request.headers.set('authorization', ['Bearer $idToken']);
      }
      // App Check is enforced server-side in monitor mode at Stage 0:
      // a token fetch failure (e.g. attestation hiccup, App Check not
      // yet warmed up) must not take down every API call. Send the request
      // without the header and let the server decide (accept in monitor
      // mode, reject with APP_CHECK_REQUIRED once enforced) rather than
      // failing it client-side.
      String? appCheckToken;
      try {
        appCheckToken = await _appCheckTokens.getAppCheckToken();
      } catch (e) {
        debugPrint('App Check token fetch failed, sending no header: $e');
      }
      if (appCheckToken != null) {
        request.headers.set('x-firebase-appcheck', [appCheckToken]);
      }
      if (bound != null &&
          (_sessionUid?.call() != bound ||
              idToken == null ||
              idTokenUid(idToken) != bound)) {
        throw const RequestSessionChangedException();
      }
      return next(request);
    };
  }
}

/// Re-checks, right before every send (the first attempt and each
/// [RetryInterceptor] retry), that the session is still the account
/// [AuthHeadersInterceptor] bound the call to. Sits innermost, after
/// [RetryInterceptor]: a retry after a switch is refused with
/// [RequestSessionChangedException] and never sent. Unbound calls pass.
final class RequestSessionGuard {
  const RequestSessionGuard(this._sessionUid);

  final SessionUidReader _sessionUid;

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      final bound = _boundSession[request];
      if (bound != null && _sessionUid() != bound) {
        throw const RequestSessionChangedException();
      }
      return next(request);
    };
  }
}

/// Retries transient failures with jittered exponential backoff, but only for
/// calls the server marked side-effect-free (`Idempotency.noSideEffects` —
/// e.g. GetMe, GetProfile, CheckHandleAvailability). Mutations are never
/// retried automatically: a client-side retry of a write could double it
/// unless it flows through the `idempotency_key` mechanism, which is a
/// deliberate per-call decision, not a transport default (the idempotency rule).
final class RetryInterceptor {
  const RetryInterceptor({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
  });

  final int maxAttempts;
  final Duration baseDelay;

  static const _retryableCodes = {
    connect.Code.unavailable,
    connect.Code.deadlineExceeded,
    connect.Code.unknown,
  };

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      final canRetry =
          request.spec.idempotency == connect.Idempotency.noSideEffects;
      if (!canRetry) {
        return next(request);
      }

      var attempt = 0;
      while (true) {
        attempt++;
        try {
          return await next(request);
        } on connect.ConnectException catch (e) {
          final isLastAttempt = attempt >= maxAttempts;
          if (isLastAttempt || !_retryableCodes.contains(e.code)) {
            rethrow;
          }
          final backoff = baseDelay * pow(2, attempt - 1).toInt();
          final jitter = Duration(milliseconds: Random().nextInt(100));
          await Future<void>.delayed(backoff + jitter);
        }
      }
    };
  }
}
