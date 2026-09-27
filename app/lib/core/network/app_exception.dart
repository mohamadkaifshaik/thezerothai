import 'package:flutter/foundation.dart';

/// Typed domain errors the UI branches on. Callers must never pattern-match
/// on a raw error message string (see ADR-0006 / `dzeroth.common.v1.ErrorReason`).
///
/// These mirror `ErrorReason` in `proto/dzeroth/common/v1/common.proto`, plus
/// a couple of transport-level cases (`network`, `unauthenticated`, `unknown`)
/// that never reach the server.
@immutable
sealed class AppException implements Exception {
  const AppException(this.message);

  /// Safe to show to the user as-is.
  final String message;

  @override
  String toString() => message;
}

/// The request body failed server-side validation.
final class ValidationException extends AppException {
  const ValidationException(super.message, {this.field});
  final String? field;
}

/// Short-window token bucket exceeded (ADR-0006 §3). Do not auto-retry before
/// [retryAfter] elapses.
final class RateLimitedException extends AppException {
  const RateLimitedException(super.message, {this.retryAfter});
  final Duration? retryAfter;
}

/// A per-user daily quota (posts, follows, uploads, exports...) was reached.
final class QuotaExceededException extends AppException {
  const QuotaExceededException(super.message, {this.quota, this.retryAfter});
  final String? quota;
  final Duration? retryAfter;
}

/// The platform is in degraded (readonly/no-media) mode. Show a banner, do
/// not auto-retry.
final class DegradedModeException extends AppException {
  const DegradedModeException(super.message, {this.retryAfter});
  final Duration? retryAfter;
}

/// Missing/invalid Firebase App Check token — usually a client bug or a
/// tampered build. Not user-actionable beyond "update the app".
final class AppCheckRequiredException extends AppException {
  const AppCheckRequiredException(super.message);
}

/// The caller has a Firebase account but has not called CreateProfile yet.
final class ProfileRequiredException extends AppException {
  const ProfileRequiredException(super.message);
}

/// Email must be verified before this action.
final class EmailNotVerifiedException extends AppException {
  const EmailNotVerifiedException(super.message);
}

/// The requested handle is taken.
final class HandleTakenException extends AppException {
  const HandleTakenException(super.message);
}

/// A fixed cap was reached (e.g. following 5,000 accounts).
final class LimitReachedException extends AppException {
  const LimitReachedException(super.message);
}

/// Referenced media is not READY or not owned by the caller.
final class MediaNotReadyException extends AppException {
  const MediaNotReadyException(super.message);
}

/// The same idempotency key was reused with a different request body.
final class IdempotencyKeyReusedException extends AppException {
  const IdempotencyKeyReusedException(super.message);
}

/// The account is suspended or pending deletion.
final class AccountRestrictedException extends AppException {
  const AccountRestrictedException(super.message);
}

/// The resource does not exist (or is hidden from the caller, e.g. blocked).
final class NotFoundException extends AppException {
  const NotFoundException(super.message);
}

/// The caller is not signed in, or their session/App Check token is invalid.
final class UnauthenticatedException extends AppException {
  const UnauthenticatedException(super.message);
}

/// No network connectivity, or the API/Cloud Run instance is unreachable.
final class NetworkException extends AppException {
  const NetworkException(super.message);
}

/// Anything else (mapped from an unrecognized Connect `Code`).
final class UnknownApiException extends AppException {
  const UnknownApiException(super.message);
}
