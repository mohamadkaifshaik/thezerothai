import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart'
    as pb_duration;
import 'package:flutter_test/flutter_test.dart';

connect.ConnectException _withDetail(
  connect.Code code,
  String message,
  common.ErrorDetail detail,
) {
  return connect.ConnectException(
    code,
    message,
    details: [
      connect.ErrorDetail(
        'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
        detail.writeToBuffer(),
      ),
    ],
  );
}

void main() {
  group('mapConnectError', () {
    test('maps a non-Connect error to NetworkException', () {
      final result = mapConnectError(Exception('socket closed'));
      expect(result, isA<NetworkException>());
    });

    test('maps ERROR_REASON_VALIDATION using the detail message and field', () {
      final error = _withDetail(
        connect.Code.invalidArgument,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_VALIDATION,
          message: 'Handle is required',
          metadata: {'field': 'handle'}.entries,
        ),
      );

      final result = mapConnectError(error);

      expect(result, isA<ValidationException>());
      expect(result.message, 'Handle is required');
      expect((result as ValidationException).field, 'handle');
    });

    test('maps ERROR_REASON_QUOTA_EXCEEDED with retryAfter', () {
      final error = _withDetail(
        connect.Code.resourceExhausted,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
          message: "You've hit today's limit",
          metadata: {'quota': 'posts'}.entries,
          retryAfter: pb_duration.Duration(seconds: Int64(3600)),
        ),
      );

      final result = mapConnectError(error);

      expect(result, isA<QuotaExceededException>());
      final quota = result as QuotaExceededException;
      expect(quota.quota, 'posts');
      expect(quota.retryAfter, const Duration(hours: 1));
    });

    test('maps ERROR_REASON_PROFILE_REQUIRED', () {
      final error = _withDetail(
        connect.Code.failedPrecondition,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_PROFILE_REQUIRED,
          message: 'Create a profile first',
        ),
      );

      expect(mapConnectError(error), isA<ProfileRequiredException>());
    });

    test('falls back to Code-based mapping when there is no detail', () {
      final error = connect.ConnectException(connect.Code.notFound, 'gone');
      expect(mapConnectError(error), isA<NotFoundException>());
    });

    test('maps unauthenticated code without a detail', () {
      final error = connect.ConnectException(
        connect.Code.unauthenticated,
        'no token',
      );
      expect(mapConnectError(error), isA<UnauthenticatedException>());
    });

    test('maps a bare UNAVAILABLE (no ErrorDetail) to a generic retryable '
        'NetworkException, not DegradedModeException', () {
      final error = connect.ConnectException(
        connect.Code.unavailable,
        'connection reset',
      );

      expect(mapConnectError(error), isA<NetworkException>());
    });

    test('maps UNAVAILABLE with ERROR_REASON_DEGRADED_MODE to '
        'DegradedModeException', () {
      final error = _withDetail(
        connect.Code.unavailable,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_DEGRADED_MODE,
          message: 'Read-only mode right now',
        ),
      );

      expect(mapConnectError(error), isA<DegradedModeException>());
    });

    test(
      'maps ERROR_REASON_TARGET_BLOCKED (ADR-0008) to TargetBlockedException',
      () {
        final error = _withDetail(
          connect.Code.failedPrecondition,
          'fallback',
          common.ErrorDetail(
            reason: common.ErrorReason.ERROR_REASON_TARGET_BLOCKED,
            message: 'Unblock this account first',
          ),
        );

        final result = mapConnectError(error);

        expect(result, isA<TargetBlockedException>());
        expect(result.message, 'Unblock this account first');
      },
    );

    test('maps ERROR_REASON_FEATURE_DISABLED (ADR-0008) to '
        'FeatureDisabledException', () {
      final error = _withDetail(
        connect.Code.failedPrecondition,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          message: 'Not enabled for this caller',
        ),
      );

      expect(mapConnectError(error), isA<FeatureDisabledException>());
    });
  });
}
