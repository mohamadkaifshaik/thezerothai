import 'package:connectrpc/connect.dart' as connect;

import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'app_exception.dart';

/// Converts a [connect.ConnectException] (or any other error thrown while
/// making a call) into a typed [AppException] the UI can branch on.
///
/// Branches on `dzeroth.common.v1.ErrorDetail.reason`, never on the message
/// text (ADR-0006 / `common.proto`).
AppException mapConnectError(Object error) {
  if (error is! connect.ConnectException) {
    return NetworkException(error.toString());
  }

  final detail = _findErrorDetail(error);
  if (detail != null) {
    final message = detail.hasMessage() ? detail.message : error.message;
    final retryAfter = detail.hasRetryAfter()
        ? Duration(
            seconds: detail.retryAfter.seconds.toInt(),
            microseconds: detail.retryAfter.nanos ~/ 1000,
          )
        : null;
    switch (detail.reason) {
      case common.ErrorReason.ERROR_REASON_VALIDATION:
        return ValidationException(message, field: detail.metadata['field']);
      case common.ErrorReason.ERROR_REASON_RATE_LIMITED:
        return RateLimitedException(
          message,
          retryAfter: retryAfter,
          limitName: detail.metadata['limit'] ?? detail.metadata['limit_name'],
        );
      case common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED:
        return QuotaExceededException(
          message,
          quota: detail.metadata['quota'],
          retryAfter: retryAfter,
        );
      case common.ErrorReason.ERROR_REASON_DEGRADED_MODE:
        return DegradedModeException(message, retryAfter: retryAfter);
      case common.ErrorReason.ERROR_REASON_APP_CHECK_REQUIRED:
        return AppCheckRequiredException(message);
      case common.ErrorReason.ERROR_REASON_PROFILE_REQUIRED:
        return ProfileRequiredException(message, fromServerReason: true);
      case common.ErrorReason.ERROR_REASON_EMAIL_NOT_VERIFIED:
        return EmailNotVerifiedException(message);
      case common.ErrorReason.ERROR_REASON_HANDLE_TAKEN:
        return HandleTakenException(message);
      case common.ErrorReason.ERROR_REASON_LIMIT_REACHED:
        // The handle cooldown names the limit under `quota`; the graph cap and the ADR-0021 scheduling limits
        // (`scheduled_pending`, `scheduled_window`) use `limit`.
        return LimitReachedException(
          message,
          quota: detail.metadata['quota'] ?? detail.metadata['limit'],
          retryAfter: retryAfter,
        );
      case common.ErrorReason.ERROR_REASON_MEDIA_NOT_READY:
        return MediaNotReadyException(
          message,
          mediaId: detail.metadata['media_id'],
        );
      case common.ErrorReason.ERROR_REASON_IDEMPOTENCY_KEY_REUSED:
        return IdempotencyKeyReusedException(message);
      case common.ErrorReason.ERROR_REASON_ACCOUNT_RESTRICTED:
        return AccountRestrictedException(message);
      // Added in the graph slice (ADR-0008 D5/D9): the caller blocks the
      // target (e.g. Follow) — unblock first, never auto-unblocked.
      case common.ErrorReason.ERROR_REASON_TARGET_BLOCKED:
        return TargetBlockedException(message);
      // ADR-0008 D6: the server feature flag is off for this caller (or the
      // RPC isn't built yet, e.g. follow requests). Clients hide the feature
      // and refresh GetMe.enabled_features; never retry.
      case common.ErrorReason.ERROR_REASON_FEATURE_DISABLED:
        final feature = detail.metadata['feature'];
        return FeatureDisabledException(
          message,
          feature: (feature == null || feature.isEmpty) ? null : feature,
        );
      // P8 (account-deletion plan Q5): the sign-in is too old for a sensitive
      // call. The caller re-authenticates once and retries with the same key.
      case common.ErrorReason.ERROR_REASON_REAUTH_REQUIRED:
        return ReauthRequiredException(message);
      // ADR-0021: the reply audience policy forbids this caller. The message
      // is fixed and generic (never the server text) so it cannot reveal why.
      case common.ErrorReason.ERROR_REASON_REPLY_NOT_ALLOWED:
        final policy = detail.metadata['policy'];
        return ReplyNotAllowedException(
          policy: (policy == null || policy.isEmpty) ? null : policy,
        );
      // ADR-0025 D14: a Repost or Quote of a protected account's post (W3-33b); the follower lists use the same
      // reason (W3-33a).
      case common.ErrorReason.ERROR_REASON_PROTECTED_ACCOUNT:
        return const ProtectedAccountException();
      // ADR-0027 D4: one refusal for blocked either way, a recipient who is not ACTIVE or outside the messaging
      // rollout, and a conversation with an erased participant. Fixed text, so it never reveals which.
      case common.ErrorReason.ERROR_REASON_CANNOT_MESSAGE:
        return const CannotMessageException();
      // ADR-0029 D6 (W6-13): VotePoll refusals. Fixed text, never the server's.
      case common.ErrorReason.ERROR_REASON_POLL_CLOSED:
        return const PollClosedException();
      case common.ErrorReason.ERROR_REASON_ALREADY_VOTED:
        return AlreadyVotedException(
          choiceIndex: int.tryParse(detail.metadata['choice'] ?? ''),
        );
      case common.ErrorReason.ERROR_REASON_UNSPECIFIED:
        break;
    }
  }

  return _mapByCode(error);
}

/// Finds and decodes the `dzeroth.common.v1.ErrorDetail` attached to a
/// Connect error, if any. Also used by the transport retry interceptor.
common.ErrorDetail? findErrorDetail(connect.ConnectException error) =>
    _findErrorDetail(error);

common.ErrorDetail? _findErrorDetail(connect.ConnectException error) {
  for (final raw in error.details) {
    if (!raw.type.endsWith('ErrorDetail')) continue;
    try {
      return common.ErrorDetail.fromBuffer(raw.value);
    } catch (_) {
      // Malformed detail payload; fall through to code-based mapping.
    }
  }
  return null;
}

/// True when [error] is connect-dart's own fallback for an HTTP 403 whose body
/// was not a Connect error (Google's front end answers an HTML page or an
/// empty body when the public invoker is removed; ADR-0022 pause).
///
/// connect-dart 2.0.0 builds `ConnectException(permissionDenied, 'HTTP 403')`
/// (no details, no cause) for that case (`ResponseValidation.validate`). A real
/// server PERMISSION_DENIED carries the server's own message and, for this
/// API, an `ErrorDetail`, so it never matches.
bool isServicePausedFailure(connect.ConnectException error) =>
    error.code == connect.Code.permissionDenied &&
    error.message == 'HTTP 403' &&
    error.details.isEmpty &&
    error.cause == null;

AppException _mapByCode(connect.ConnectException error) {
  switch (error.code) {
    case connect.Code.unauthenticated:
      return UnauthenticatedException(error.message);
    case connect.Code.permissionDenied:
      if (isServicePausedFailure(error)) return const ServicePausedException();
      return AccountRestrictedException(error.message);
    case connect.Code.notFound:
      return NotFoundException(error.message);
    case connect.Code.invalidArgument:
      return ValidationException(error.message);
    case connect.Code.resourceExhausted:
      return QuotaExceededException(error.message);
    case connect.Code.unavailable:
      // `UNAVAILABLE` without an `ErrorDetail` (checked above) is an ordinary
      // transient failure (Cloud Run cold start, network blip, LB hiccup) —
      // not necessarily the platform's degraded mode. Reserve
      // [DegradedModeException] for the case the server tells us explicitly
      // (`ERROR_REASON_DEGRADED_MODE`, handled above) so the UI doesn't show
      // a "we've disabled features" banner for a plain retryable error.
      return NetworkException(error.message);
    case connect.Code.alreadyExists:
      return HandleTakenException(error.message);
    case connect.Code.failedPrecondition:
      return ProfileRequiredException(error.message);
    case connect.Code.deadlineExceeded:
    case connect.Code.canceled:
      return NetworkException(error.message);
    case connect.Code.unknown:
    case connect.Code.aborted:
    case connect.Code.outOfRange:
    case connect.Code.unimplemented:
    case connect.Code.internal:
    case connect.Code.dataLoss:
      return UnknownApiException(error.message);
  }
}
