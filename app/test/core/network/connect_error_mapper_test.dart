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

    test('maps RATE_LIMITED carrying limit and retryAfter', () {
      final error = _withDetail(
        connect.Code.resourceExhausted,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          metadata: {'limit': 'read_budget_inflight'}.entries,
          retryAfter: pb_duration.Duration(seconds: Int64(1)),
        ),
      );

      final result = mapConnectError(error) as RateLimitedException;

      expect(result.limitName, 'read_budget_inflight');
      expect(result.isInflightHold, isTrue);
      expect(result.isDaily, isFalse);
      expect(result.retryAfter, const Duration(seconds: 1));
    });

    test('maps RATE_LIMITED limit_name and treats *_daily as daily', () {
      final error = _withDetail(
        connect.Code.resourceExhausted,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          metadata: {'limit_name': 'check_handle_daily'}.entries,
        ),
      );

      final result = mapConnectError(error) as RateLimitedException;

      expect(result.isDaily, isTrue);
      expect(result.isInflightHold, isFalse);
    });

    test('maps ERROR_REASON_EMAIL_NOT_VERIFIED', () {
      final error = _withDetail(
        connect.Code.failedPrecondition,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_EMAIL_NOT_VERIFIED,
          message: 'Verify your email',
        ),
      );

      expect(mapConnectError(error), isA<EmailNotVerifiedException>());
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

      final mapped = mapConnectError(error) as FeatureDisabledException;
      expect(mapped.feature, isNull);
    });

    test('FEATURE_DISABLED carries metadata["feature"] (ADR-0010 D2)', () {
      final error = _withDetail(
        connect.Code.failedPrecondition,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          message: 'Media is not enabled',
          metadata: {'feature': 'media'}.entries,
        ),
      );

      final mapped = mapConnectError(error) as FeatureDisabledException;
      expect(mapped.feature, 'media');
    });
    test('maps ERROR_REASON_REAUTH_REQUIRED to ReauthRequiredException', () {
      final error = _withDetail(
        connect.Code.failedPrecondition,
        'fallback',
        common.ErrorDetail(
          reason: common.ErrorReason.ERROR_REASON_REAUTH_REQUIRED,
          message: 'Please sign in again',
        ),
      );

      final mapped = mapConnectError(error);
      expect(mapped, isA<ReauthRequiredException>());
      expect(mapped.message, 'Please sign in again');
    });

    test('account-lifecycle reasons keep their typed mapping', () {
      AppException map(
        connect.Code code,
        common.ErrorReason reason, [
        Map<String, String> metadata = const {},
      ]) {
        return mapConnectError(
          _withDetail(
            code,
            'x',
            common.ErrorDetail(
              reason: reason,
              message: 'm',
              metadata: metadata.entries,
            ),
          ),
        );
      }

      final quota = map(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
        {'quota': 'exports'},
      );
      expect((quota as QuotaExceededException).quota, 'exports');

      final limited = map(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        {'limit': 'account_ops_daily'},
      );
      expect((limited as RateLimitedException).isDaily, isTrue);

      expect(
        map(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          {'feature': 'account_lifecycle'},
        ),
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          'account_lifecycle',
        ),
      );
      expect(
        map(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_DEGRADED_MODE,
        ),
        isA<DegradedModeException>(),
      );
    });
  });
}
