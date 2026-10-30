import 'dart:async';

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

  // --- W7-26: access mode and the probe -------------------------------------
  group("access and probe", () {
    var cached = true;
    var refreshes = 0;
    Future<bool> hasCached() async => cached;
    Future<void> refresh() => gate.runRead(() async => refreshes++);
    Future<void> refreshDisabled() => gate.runRead(disabled);

    setUp(() {
      cached = true;
      refreshes = 0;
      flagOn = false;
    });

    test("the flag on is full, whatever the probe says", () async {
      flagOn = true;
      expect(gate.access, MessagingAccess.full);
      await gate.probe(hasCached: hasCached, refresh: refresh);
      expect(refreshes, 0, reason: "enabled: no probe request");
      expect(gate.access, MessagingAccess.full);
    });

    test(
      "a per-caller FEATURE_DISABLED to a send keeps full (flag decides)",
      () async {
        flagOn = true;
        await expectLater(
          gate.run(disabled),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(gate.access, MessagingAccess.full);
      },
    );

    test(
      "not enabled: hidden until the probe succeeds, then readOnly",
      () async {
        expect(gate.access, MessagingAccess.hidden);
        var notified = 0;
        gate.addListener(() => notified++);
        await gate.probe(hasCached: hasCached, refresh: refresh);
        expect(refreshes, 1);
        expect(gate.access, MessagingAccess.readOnly);
        expect(notified, 1);
      },
    );

    test("no cached conversation: no request, hidden", () async {
      cached = false;
      await gate.probe(hasCached: hasCached, refresh: refresh);
      expect(refreshes, 0);
      expect(gate.access, MessagingAccess.hidden);
    });

    test("FEATURE_DISABLED (globally off): hidden, and a fresh GetMe does not "
        "bring readOnly back", () async {
      await gate.probe(hasCached: hasCached, refresh: refreshDisabled);
      expect(gate.access, MessagingAccess.hidden);
      gate.reset();
      expect(gate.access, MessagingAccess.hidden);
      expect(gate.canRead, isTrue);
    });

    test("another failure at session start leaves hidden", () async {
      await gate.probe(
        hasCached: hasCached,
        refresh: () => gate.runRead(
          () async =>
              throw connect.ConnectException(connect.Code.unavailable, "x"),
        ),
      );
      expect(gate.access, MessagingAccess.hidden);
    });

    test("readOnly turns hidden at once on a FEATURE_DISABLED read", () async {
      await gate.probe(hasCached: hasCached, refresh: refresh);
      expect(gate.access, MessagingAccess.readOnly);
      await expectLater(
        gate.runRead(disabled),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.access, MessagingAccess.hidden);
    });

    test("a re-probe that fails keeps the earlier readOnly", () async {
      await gate.probe(hasCached: hasCached, refresh: refresh);
      await gate.probe(
        hasCached: hasCached,
        refresh: () => gate.runRead(
          () async =>
              throw connect.ConnectException(connect.Code.unavailable, "x"),
        ),
      );
      expect(gate.access, MessagingAccess.readOnly);
    });

    test("a probe that returns after sign-out or after the flag turned on is "
        "dropped", () async {
      final late = Completer<void>();
      final first = gate.probe(
        hasCached: hasCached,
        refresh: () => late.future,
      );
      await Future<void>.delayed(Duration.zero);
      gate.endSession();
      late.complete();
      await first;
      expect(gate.access, MessagingAccess.hidden, reason: "signed out");

      final late2 = Completer<void>();
      final second = gate.probe(
        hasCached: hasCached,
        refresh: () => late2.future,
      );
      await Future<void>.delayed(Duration.zero);
      flagOn = true;
      late2.complete();
      await second;
      flagOn = false;
      expect(gate.access, MessagingAccess.hidden, reason: "flag turned on");
    });

    test("endSession forgets readOnly", () async {
      await gate.probe(hasCached: hasCached, refresh: refresh);
      gate.endSession();
      expect(gate.access, MessagingAccess.hidden);
    });
  });
}
