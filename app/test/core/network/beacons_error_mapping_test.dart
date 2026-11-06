import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

/// The beacons backend answers a write the beacon's state refuses with
/// FAILED_PRECONDITION, `ErrorReason` UNSPECIFIED and `metadata["reason"]`
/// (full, ended, cancelled, already_requested, ...). That shape is a typed
/// [StateConflictException]; every other FAILED_PRECONDITION keeps its
/// mapping, so a missing profile still reads as [ProfileRequiredException].
void main() {
  test('FAILED_PRECONDITION with a metadata reason is a state conflict', () {
    final e = mapConnectError(
      serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        metadata: {'reason': 'full'},
      ),
    );
    expect(
      e,
      isA<StateConflictException>().having((e) => e.reason, 'reason', 'full'),
    );
    expect(e.message, isNot(contains('server says no')));
  });

  test('FAILED_PRECONDITION without a reason is still "profile required"', () {
    expect(
      mapConnectError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        ),
      ),
      isA<ProfileRequiredException>(),
    );
    expect(
      mapConnectError(
        connect.ConnectException(connect.Code.failedPrecondition, 'raw'),
      ),
      isA<ProfileRequiredException>(),
    );
    expect(
      mapConnectError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_PROFILE_REQUIRED,
        ),
      ),
      isA<ProfileRequiredException>(),
    );
  });

  test('a metadata reason on another code is not a state conflict', () {
    expect(
      mapConnectError(
        serverError(
          connect.Code.permissionDenied,
          common.ErrorReason.ERROR_REASON_UNSPECIFIED,
          metadata: {'reason': 'full'},
        ),
      ),
      isNot(isA<StateConflictException>()),
    );
  });
}
