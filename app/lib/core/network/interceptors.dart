import 'dart:async';
import 'dart:math';

import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'auth_token_provider.dart';

/// Adds a fresh `X-Request-Id` to every call, so backend logs and client
/// error reports can be correlated (CLAUDE.md rule 8).
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

/// Attaches the Firebase ID token and the Firebase App Check token to every
/// outgoing call (ADR-0006 §2). Both are refreshed lazily by the providers,
/// which cache the underlying platform tokens for their own TTL.
final class AuthHeadersInterceptor {
  const AuthHeadersInterceptor(this._authTokens, this._appCheckTokens);

  final AuthTokenProvider _authTokens;
  final AppCheckTokenProvider _appCheckTokens;

  connect.AnyFn<I, O> call<I extends Object, O extends Object>(
    connect.AnyFn<I, O> next,
  ) {
    return (request) async {
      final idToken = await _authTokens.getIdToken();
      if (idToken != null) {
        request.headers.set('authorization', ['Bearer $idToken']);
      }
      // App Check is enforced server-side in monitor mode at Stage 0 (ADR-0006
      // §2): a token fetch failure (e.g. attestation hiccup, App Check not
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
      return next(request);
    };
  }
}

/// Retries transient failures with jittered exponential backoff, but only for
/// calls the server marked side-effect-free (`Idempotency.noSideEffects` —
/// e.g. GetMe, GetProfile, CheckHandleAvailability). Mutations are never
/// retried automatically: a client-side retry of a write could double it
/// unless it flows through the `idempotency_key` mechanism, which is a
/// deliberate per-call decision, not a transport default (CLAUDE.md rule 4).
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
          final jitter = Duration(
            milliseconds: Random().nextInt(100),
          );
          await Future<void>.delayed(backoff + jitter);
        }
      }
    };
  }
}
