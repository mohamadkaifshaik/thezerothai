import 'package:dzeroth/core/telemetry/telemetry_adapters.dart';
import 'package:dzeroth/core/telemetry/telemetry_controller.dart';
import 'package:dzeroth/core/telemetry/telemetry_device_forget.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_telemetry.dart';

/// TEL-8 (ADR-0032 F11): a different account on the device resets the analytics
/// ID before its first event; the same account again does not; in-app deletion
/// forgets the device. Fake adapters, 0 RPCs.
class _Rig {
  _Rig({String? lastUid}) : lastUid = InMemoryTelemetryLastUidStore(lastUid) {
    controller = TelemetryController(
      adapters: TelemetryAdapters(
        crash: FakeCrashReporter(log),
        analytics: FakeUsageAnalytics(log),
      ),
      platformSupported: true,
      consent: consent,
      memory: memory,
      lastUid: this.lastUid,
      debugLog: (_) {},
    );
  }

  final log = CallLog();
  final consent = FakeConsent();
  final memory = InMemoryTelemetryFlagMemory();
  final InMemoryTelemetryLastUidStore lastUid;
  late final TelemetryController controller;

  int get resets => log.calls.where((c) => c == 'usage.reset').length;
}

const _both = {kFeatureCrashReporting, kFeatureAnalytics};

void main() {
  test('account B after A: the reset runs before B\'s first event', () async {
    final rig = _Rig(lastUid: 'a');
    rig.consent.usage.addAll(['a', 'b']);
    await rig.controller.applyAtBootstrap(null);
    rig.log.clear();

    rig.controller.onAuthChanged('b');
    rig.controller.onEnabledFeatures(_both);
    await rig.controller.logScreen('home');
    await pumpEventQueue();

    expect(rig.resets, 1);
    expect(
      rig.log.calls.indexOf('usage.reset'),
      lessThan(rig.log.calls.indexOf('usage.screen(home)')),
    );
    expect(await rig.lastUid.read(), 'b');
  });

  test('A signing in again after A: no reset', () async {
    final rig = _Rig(lastUid: 'a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onAuthChanged(null);
    rig.controller.onAuthChanged('a');
    await pumpEventQueue();

    expect(rig.resets, 0);
    expect(await rig.lastUid.read(), 'a');
  });

  test(
    'A, sign out, B, sign out, A: no record at first, then each change resets',
    () async {
      final rig = _Rig();
      await rig.controller.applyAtBootstrap(null);
      rig.controller.onAuthChanged('a');
      rig.controller.onAuthChanged(null);
      rig.controller.onAuthChanged('b');
      rig.controller.onAuthChanged(null);
      rig.controller.onAuthChanged('a');
      await pumpEventQueue();

      // F12: A finds no record (reset 1), then B (2), then A again (3).
      expect(rig.resets, 3);
    },
  );

  test('first sign-in on a device (no record) resets once and records the '
      'uid (F12)', () async {
    final rig = _Rig();
    await rig.controller.applyAtBootstrap(null);
    rig.controller.onAuthChanged('a');
    await pumpEventQueue();

    expect(rig.resets, 1);
    expect(await rig.lastUid.read(), 'a');
  });

  test('a restored uid that differs from the record resets once at launch, '
      'before usage switches on', () async {
    final rig = _Rig(lastUid: 'a');
    rig.consent.usage.add('b');
    await rig.memory.write('b', const TelemetryFlags(analytics: true));
    await rig.controller.applyAtBootstrap('b');
    await pumpEventQueue();

    expect(rig.resets, 1);
    expect(
      rig.log.calls.indexOf('usage.reset'),
      lessThan(rig.log.calls.indexOf('usage.setCollecting(true)')),
    );
    expect(await rig.lastUid.read(), 'b');
  });

  test('a sign-out alone keeps the record and resets nothing', () async {
    final rig = _Rig(lastUid: 'a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onAuthChanged(null);
    await pumpEventQueue();

    expect(rig.resets, 0);
    expect(await rig.lastUid.read(), 'a');
  });

  test(
    'forgetDevice drops unsent reports, resets the analytics ID and '
    'forgets the uid\'s flags and record, even while collecting is off',
    () async {
      final rig = _Rig(lastUid: 'a');
      await rig.controller.applyAtBootstrap('a');
      rig.controller.onEnabledFeatures(_both);
      await pumpEventQueue();
      expect(await rig.memory.read('a'), isNotNull);
      rig.log.clear();

      await rig.controller.forgetDevice('a');

      expect(rig.log.calls, containsAll(['crash.deleteUnsent', 'usage.reset']));
      expect(await rig.memory.read('a'), isNull);
      expect(await rig.lastUid.read(), isNull);
    },
  );

  test(
    'after A is deleted, B signing in finds no record and resets (F12)',
    () async {
      final rig = _Rig(lastUid: 'a');
      await rig.controller.applyAtBootstrap('a');
      await rig.controller.forgetDevice('a');
      rig.controller.onAuthChanged(null);
      rig.log.clear();

      rig.controller.onAuthChanged('b');
      await pumpEventQueue();

      expect(rig.resets, 1);
    },
  );

  test('forgetDevice keeps another account\'s record', () async {
    final rig = _Rig(lastUid: 'b');
    await rig.controller.applyAtBootstrap('b');
    await rig.controller.forgetDevice('a');

    expect(await rig.lastUid.read(), 'b');
  });

  _failClosedTests();

  test('a failing adapter never breaks sign-in or deletion', () async {
    final rig = _Rig(lastUid: 'a');
    final forget = TelemetryDeviceForget((uid) => throw StateError('boom'));
    await expectLater(forget('a'), completes);
    rig.controller.onAuthChanged('b');
    await pumpEventQueue();
    expect(await rig.lastUid.read(), 'b');
  });
}

class _ThrowingReadStore extends InMemoryTelemetryLastUidStore {
  _ThrowingReadStore({this.failWrite = false});
  final bool failWrite;

  @override
  Future<String?> read() async => throw StateError('unreadable');

  @override
  Future<void> write(String uid) async {
    if (failWrite) throw StateError('unwritable');
    await super.write(uid);
  }
}

class _ThrowingResetAnalytics extends FakeUsageAnalytics {
  _ThrowingResetAnalytics(super.calls);

  @override
  Future<void> resetDevice() async {
    calls.add('usage.reset');
    throw StateError('reset failed');
  }
}

TelemetryController _controller(
  CallLog log,
  TelemetryLastUidStore store, {
  bool resetFails = false,
}) => TelemetryController(
  adapters: TelemetryAdapters(
    crash: FakeCrashReporter(log),
    analytics: resetFails
        ? _ThrowingResetAnalytics(log)
        : FakeUsageAnalytics(log),
  ),
  platformSupported: true,
  lastUid: store,
  debugLog: (_) {},
);

void _failClosedTests() {
  test('F12 fail closed: an unreadable record resets before the uid\'s first '
      'event, then sign-in completes and the uid is recorded', () async {
    final log = CallLog();
    final store = _ThrowingReadStore();
    final c = _controller(log, store);
    await c.applyAtBootstrap(null);
    log.clear();

    c.onAuthChanged('a');
    await c.logScreen('home');
    await pumpEventQueue();

    expect(log.calls.where((e) => e == 'usage.reset').length, 1);
    expect(store.value, 'a');
  });

  test(
    'F12: a failing reset and a failing write never break sign-in',
    () async {
      final log = CallLog();
      final c = _controller(
        log,
        _ThrowingReadStore(failWrite: true),
        resetFails: true,
      );
      await c.applyAtBootstrap(null);
      c.onAuthChanged('a');
      await pumpEventQueue();
      expect(log.calls.where((e) => e == 'usage.reset').length, 1);
      expect(c.crashCollecting, isFalse); // still working
      c.onAuthChanged('b');
      await pumpEventQueue();
      expect(log.calls.where((e) => e == 'usage.reset').length, 2);
    },
  );

  test(
    'F12: A deleted with its reset failing, then B signing in resets',
    () async {
      final log = CallLog();
      final store = InMemoryTelemetryLastUidStore('a');
      final c = _controller(log, store, resetFails: true);
      await c.applyAtBootstrap('a');
      await c.forgetDevice('a'); // reset throws, swallowed; record cleared
      c.onAuthChanged(null);
      log.clear();

      c.onAuthChanged('b');
      await pumpEventQueue();

      expect(log.calls.where((e) => e == 'usage.reset').length, 1);
      expect(store.value, 'b');
    },
  );
}
