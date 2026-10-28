import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

void main() {
  late MessagingFeatureGate gate;
  var flagOn = true;
  var asked = 0;
  var calls = 0;
  final reported = <Object>[];

  Future<int> ok() async => ++calls;
  Future<int> disabled() async {
    calls++;
    throw withDetail(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'messaging'},
    );
  }

  setUp(() {
    flagOn = true;
    asked = 0;
    calls = 0;
    reported.clear();
    gate = MessagingFeatureGate(
      isMessagingEnabled: () => flagOn,
      onDisabledByServer: () => asked++,
      onUnexpectedError: (e, _) => reported.add(e),
    );
  });

  test('flag on for the caller: sends and reads both run', () async {
    expect(gate.canSend, isTrue);
    expect(gate.canRead, isTrue);
    await gate.run(ok);
    await gate.runRead(ok);
    expect(calls, 2);
  });

  test(
    'flag off for the caller: sends do not call the API, reads still do',
    () async {
      flagOn = false;
      expect(gate.canSend, isFalse);
      expect(gate.canRead, isTrue);
      await expectLater(gate.run(ok), throwsA(isA<FeatureDisabledException>()));
      expect(calls, 0);
      await gate.runRead(ok);
      expect(calls, 1);
    },
  );

  test(
    'a FEATURE_DISABLED answer to a send is per caller: reads keep working',
    () async {
      await expectLater(
        gate.run(disabled),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.canSend, isFalse);
      expect(gate.canRead, isTrue);
      expect(asked, 1);
      await gate.runRead(ok);
      expect(calls, 2);
    },
  );

  test(
    'a FEATURE_DISABLED answer to a read is global: reads and sends stop',
    () async {
      await expectLater(
        gate.runRead(disabled),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.canRead, isFalse);
      expect(gate.canSend, isFalse);
      expect(asked, 1);
      await expectLater(
        gate.runRead(ok),
        throwsA(isA<FeatureDisabledException>()),
      );
      await expectLater(gate.run(ok), throwsA(isA<FeatureDisabledException>()));
      expect(calls, 1);
    },
  );

  test('reset after a fresh GetMe forgets both answers', () async {
    await expectLater(
      gate.runRead(disabled),
      throwsA(isA<FeatureDisabledException>()),
    );
    gate.reset();
    expect(gate.canRead, isTrue);
    expect(gate.canSend, isTrue);
    await gate.runRead(ok);
    await gate.run(ok);
    expect(calls, 3);
  });

  test('listeners hear the global switch-off and its reset', () async {
    var notified = 0;
    gate.addListener(() => notified++);
    await expectLater(
      gate.runRead(disabled),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(notified, greaterThan(0));
    final before = notified;
    gate.reset();
    expect(notified, greaterThan(before));
  });

  test('typed errors pass through; an unknown one is reported once', () async {
    await expectLater(
      gate.runRead(
        () async => throw withDetail(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_CANNOT_MESSAGE,
        ),
      ),
      throwsA(isA<CannotMessageException>()),
    );
    expect(reported, isEmpty);
    await expectLater(
      gate.runRead(
        () async =>
            throw connect.ConnectException(connect.Code.internal, 'boom'),
      ),
      throwsA(isA<UnknownApiException>()),
    );
    expect(reported, hasLength(1));
  });
}
