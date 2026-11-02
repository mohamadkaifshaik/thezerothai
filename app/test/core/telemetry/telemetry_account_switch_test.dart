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

  test('A, sign out, B, sign out, A: each change resets', () async {
    final rig = _Rig();
    await rig.controller.applyAtBootstrap(null);
    rig.controller.onAuthChanged('a');
    rig.controller.onAuthChanged(null);
    rig.controller.onAuthChanged('b');
    rig.controller.onAuthChanged(null);
    rig.controller.onAuthChanged('a');
    await pumpEventQueue();

    // The first sign-in has no earlier account to differ from.
    expect(rig.resets, 2);
  });

  test('first sign-in on a device (no record) resets nothing and records the '
      'uid', () async {
    final rig = _Rig();
    await rig.controller.applyAtBootstrap(null);
    rig.controller.onAuthChanged('a');
    await pumpEventQueue();

    expect(rig.resets, 0);
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

  test('after A is deleted, B signing in is a first sign-in: no second '
      'reset', () async {
    final rig = _Rig(lastUid: 'a');
    await rig.controller.applyAtBootstrap('a');
    await rig.controller.forgetDevice('a');
    rig.controller.onAuthChanged(null);
    rig.log.clear();

    rig.controller.onAuthChanged('b');
    await pumpEventQueue();

    expect(rig.resets, 0);
  });

  test('forgetDevice keeps another account\'s record', () async {
    final rig = _Rig(lastUid: 'b');
    await rig.controller.applyAtBootstrap('b');
    await rig.controller.forgetDevice('a');

    expect(await rig.lastUid.read(), 'b');
  });

  test('a failing adapter never breaks sign-in or deletion', () async {
    final rig = _Rig(lastUid: 'a');
    final forget = TelemetryDeviceForget((uid) => throw StateError('boom'));
    await expectLater(forget('a'), completes);
    rig.controller.onAuthChanged('b');
    await pumpEventQueue();
    expect(await rig.lastUid.read(), 'b');
  });
}
