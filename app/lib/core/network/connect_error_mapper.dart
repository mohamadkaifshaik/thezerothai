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
        return ProfileRequiredException(message);
      case common.ErrorReason.ERROR_REASON_EMAIL_NOT_VERIFIED:
        return EmailNotVerifiedException(message);
      case common.ErrorReason.ERROR_REASON_HANDLE_TAKEN:
        return HandleTakenException(message);
      case common.ErrorReason.ERROR_REASON_LIMIT_REACHED:
        return LimitReachedException(message);
      case common.ErrorReason.ERROR_REASON_MEDIA_NOT_READY:
        return MediaNotReadyException(message);
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

AppException _mapByCode(connect.ConnectException error) {
  switch (error.code) {
    case connect.Code.unauthenticated:
      return UnauthenticatedException(error.message);
    case connect.Code.permissionDenied:
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
