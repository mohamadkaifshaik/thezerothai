import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

void main() {
  Object disabled() => serverError(
    connect.Code.failedPrecondition,
    common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
  );

  Future<void> hitDisabled(ServiceFeatureGate gate) async {
    try {
      await gate.run<void>(() async => throw disabled());
    } on FeatureDisabledException {
      // expected
    }
  }

  test(
    'flag off: no RPC is sent and FeatureDisabledException is thrown',
    () async {
      final gate = ServiceFeatureGate(isEnabled: () => false);
      var calls = 0;

      await expectLater(
        gate.run<void>(() async => calls++),
        throwsA(isA<FeatureDisabledException>()),
      );

      expect(calls, 0);
      expect(gate.enabled, isFalse);
    },
  );

  test('flag on: the call runs and its result is returned', () async {
    final gate = ServiceFeatureGate(isEnabled: () => true);

    expect(await gate.run(() async => 7), 7);
  });

  test('FEATURE_DISABLED is remembered until reset, which notifies', () async {
    final gate = ServiceFeatureGate(isEnabled: () => true);
    var notified = 0;
    gate.addListener(() => notified++);

    await hitDisabled(gate);
    expect(gate.enabled, isFalse);
    expect(notified, 1);

    gate.reset();
    expect(gate.enabled, isTrue);
    expect(notified, 2);

    gate.reset();
    expect(notified, 2, reason: 'nothing to forget');
  });

  test('refresh is requested once for concurrent disables and at most once '
      'per 60 s', () async {
    var now = DateTime(2026, 1, 1);
    var refreshes = 0;
    final gate = ServiceFeatureGate(
      isEnabled: () => true,
      onDisabledByServer: () => refreshes++,
      now: () => now,
    );

    await Future.wait([hitDisabled(gate), hitDisabled(gate)]);
    expect(refreshes, 1);

    gate.reset();
    now = now.add(const Duration(seconds: 30));
    await hitDisabled(gate);
    expect(refreshes, 1, reason: 'throttled inside the window');
    expect(gate.enabled, isFalse, reason: 'fail-closed meanwhile');

    gate.reset();
    now = now.add(kServiceGateRefreshInterval);
    await hitDisabled(gate);
    expect(refreshes, 2);
  });

  test('an unexpected error goes to the hook and is rethrown', () async {
    final seen = <Object>[];
    final gate = ServiceFeatureGate(
      isEnabled: () => true,
      onUnexpectedError: (e, _) => seen.add(e),
    );

    await expectLater(
      gate.run<void>(() async => throw const UnknownApiException('boom')),
      throwsA(isA<UnknownApiException>()),
    );

    expect(seen, hasLength(1));
    expect(gate.enabled, isTrue);
  });
}
