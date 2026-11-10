import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:dzeroth/core/telemetry/telemetry_adapters.dart';
import 'package:dzeroth/core/telemetry/telemetry_bootstrap.dart';
import 'package:dzeroth/core/telemetry/telemetry_controller.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:dzeroth/core/telemetry/telemetry_interfaces.dart';
import 'package:dzeroth/core/telemetry/telemetry_platforms.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_telemetry.dart';

class _Rig {
  _Rig({bool supported = true, TelemetryFlagMemory? memory}) {
    crash = FakeCrashReporter(log);
    usage = FakeUsageAnalytics(log);
    controller = TelemetryController(
      adapters: TelemetryAdapters(crash: crash, analytics: usage),
      platformSupported: supported,
      consent: consent,
      memory: memory,
      debugLog: logged.add,
    );
  }

  final log = CallLog();
  final consent = FakeConsent();
  final logged = <String>[];
  late final FakeCrashReporter crash;
  late final FakeUsageAnalytics usage;
  late final TelemetryController controller;
}

Future<void> settle() => pumpEventQueue();

/// A flag memory whose storage cannot be read (a broken cache database).
class _UnreadableFlagMemory extends InMemoryTelemetryFlagMemory {
  @override
  Future<TelemetryFlags?> read(String uid) async =>
      throw StateError('storage unavailable');
}

void main() {
  const both = {kFeatureCrashReporting, kFeatureAnalytics};

  test('2x2x2x2 matrix: collecting is on in exactly one cell', () async {
    var onCells = 0;
    for (final flag in [false, true]) {
      for (final consent in [false, true]) {
        for (final platform in [false, true]) {
          for (final signedIn in [false, true]) {
            final rig = _Rig(supported: platform);
            if (consent) {
              rig.consent.crash.add('a');
              rig.consent.usage.add('a');
            }
            await rig.controller.applyAtBootstrap(signedIn ? 'a' : null);
            rig.controller.onEnabledFeatures(flag ? both : {});
            await settle();
            final on = flag && consent && platform && signedIn;
            final cell = '$flag $consent $platform $signedIn';
            expect(rig.controller.crashCollecting, on, reason: 'crash $cell');
            expect(rig.controller.usageCollecting, on, reason: 'usage $cell');
            if (on) onCells++;
          }
        }
      }
    }
    expect(onCells, 1);
  });

  test('each kind needs its own flag and its own consent', () async {
    final rig = _Rig();
    rig.consent.crash.add('a');
    rig.consent.usage.add('a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures({kFeatureCrashReporting});
    expect(rig.controller.crashCollecting, isTrue);
    expect(rig.controller.usageCollecting, isFalse);
    rig.consent.crash.clear();
    rig.consent.notify();
    expect(rig.controller.crashCollecting, isFalse);
  });

  test('flag off in a GetMe: setCollecting(false) and deleteUnsentReports '
      'run before the next record', () async {
    final rig = _Rig();
    rig.consent.crash.add('a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures(both);
    await settle();
    rig.log.clear();

    rig.controller.onEnabledFeatures({});
    await rig.controller.recordError(StateError('x'), StackTrace.empty);
    await settle();

    expect(rig.crash.recorded, isEmpty);
    expect(
      rig.log.calls,
      containsAllInOrder(['crash.setCollecting(false)', 'crash.deleteUnsent']),
    );
  });

  test('a record decided before the flag went off is delivered before the '
      'off calls', () async {
    final rig = _Rig();
    rig.consent.crash.add('a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures(both);
    await settle();
    rig.log.clear();

    final pending = rig.controller.recordError(
      StateError('x'),
      StackTrace.empty,
    );
    rig.controller.onEnabledFeatures({});
    await pending;
    await settle();

    expect(rig.log.calls, [
      'crash.record(nonfatal)',
      'crash.setCollecting(false)',
      'crash.deleteUnsent',
    ]);
  });

  test('A (opted in) to B (not): off before any report of B', () async {
    final rig = _Rig();
    rig.consent.crash.add('a');
    rig.consent.usage.add('a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures(both);
    await settle();
    expect(rig.controller.crashCollecting, isTrue);
    rig.log.clear();

    rig.controller.onAuthChanged('b');
    expect(rig.controller.crashCollecting, isFalse);
    expect(rig.controller.usageCollecting, isFalse);
    await rig.controller.recordError(StateError('of b'), StackTrace.empty);
    // B's own GetMe cannot turn it on: B has not consented.
    rig.controller.onEnabledFeatures(both);
    await rig.controller.recordError(StateError('of b'), StackTrace.empty);
    await settle();

    expect(rig.crash.recorded, isEmpty);
    expect(rig.log.calls.first, 'crash.setCollecting(false)');
    expect(rig.log.calls, contains('crash.deleteUnsent'));
  });

  test('A to B, both opted in: off until B has its own GetMe', () async {
    final rig = _Rig();
    rig.consent.crash
      ..add('a')
      ..add('b');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures(both);
    rig.controller.onAuthChanged('b');
    expect(rig.controller.crashCollecting, isFalse);
    rig.controller.onEnabledFeatures(both);
    expect(rig.controller.crashCollecting, isTrue);
  });

  test('sign-out means off and deletes unsent reports', () async {
    final rig = _Rig();
    rig.consent.crash.add('a');
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures(both);
    await settle();
    rig.log.clear();
    rig.controller.onAuthChanged(null);
    await settle();
    expect(rig.controller.crashCollecting, isFalse);
    expect(
      rig.log.calls,
      containsAllInOrder(['crash.setCollecting(false)', 'crash.deleteUnsent']),
    );
  });

  test(
    'a consent change applies at once; unsent reports go before "on" (L-1)',
    () async {
      final rig = _Rig();
      await rig.controller.applyAtBootstrap('a');
      rig.controller.onEnabledFeatures(both);
      await settle();
      rig.log.clear();
      rig.consent.crash.add('a');
      rig.consent.notify();
      await settle();
      expect(rig.log.calls, [
        'crash.deleteUnsent',
        'crash.setCollecting(true)',
      ]);
      rig.consent.crash.clear();
      rig.consent.notify();
      await settle();
      expect(rig.log.calls.skip(2), [
        'crash.setCollecting(false)',
        'crash.deleteUnsent',
      ]);
    },
  );

  test('bootstrap applies the stored decision of the restored uid and always '
      'reaches the SDKs', () async {
    final memory = InMemoryTelemetryFlagMemory();
    await memory.write('a', const TelemetryFlags(crash: true));
    final rig = _Rig(memory: memory);
    rig.consent.crash.add('a');
    await rig.controller.applyAtBootstrap('a');
    expect(rig.controller.crashCollecting, isTrue);
    expect(rig.log.calls, [
      'usage.reset', // F12: no record counts as a different account
      'crash.deleteUnsent', // L-1: before "on"
      'crash.setCollecting(true)',
      'usage.setCollecting(false)',
    ]);

    final cold = _Rig();
    await cold.controller.applyAtBootstrap(null);
    expect(cold.log.calls, [
      'crash.setCollecting(false)',
      'crash.deleteUnsent',
      'usage.setCollecting(false)',
    ]);
  });

  test('an unreadable flag memory at bootstrap fails closed: start-up goes '
      'on with both kinds off until GetMe', () async {
    final rig = _Rig(memory: _UnreadableFlagMemory());
    rig.consent.crash.add('a');
    rig.consent.usage.add('a');
    await rig.controller.applyAtBootstrap('a');
    expect(rig.controller.crashCollecting, isFalse);
    expect(rig.controller.usageCollecting, isFalse);
    expect(
      rig.log.calls,
      containsAll(['crash.setCollecting(false)', 'usage.setCollecting(false)']),
    );

    rig.controller.onEnabledFeatures(both);
    expect(rig.controller.crashCollecting, isTrue);
  });

  test('GetMe flags are remembered for the next bootstrap', () async {
    final memory = InMemoryTelemetryFlagMemory();
    final rig = _Rig(memory: memory);
    await rig.controller.applyAtBootstrap('a');
    rig.controller.onEnabledFeatures({kFeatureAnalytics});
    await settle();
    expect(await memory.read('a'), const TelemetryFlags(analytics: true));
  });

  test('web and iOS use Noop and no SDK method is called', () {
    expect(
      TelemetryPlatforms.isSupported(TargetPlatform.android, isWeb: true),
      isFalse,
    );
    expect(
      TelemetryPlatforms.isSupported(TargetPlatform.iOS, isWeb: false),
      isFalse,
    );
    expect(
      TelemetryPlatforms.isSupported(TargetPlatform.android, isWeb: false),
      isTrue,
    );
    // The unsupported path must not touch FirebaseCrashlytics.instance or
    // FirebaseAnalytics.instance: with no Firebase app in a unit test they
    // would throw.
    final adapters = createTelemetryAdapters(supported: false);
    expect(adapters.crash, isA<NoopCrashReporter>());
    expect(adapters.analytics, isA<NoopUsageAnalytics>());
  });

  test('debug log reports decision changes and never a uid', () async {
    final rig = _Rig();
    rig.consent.crash.add('secret-uid');
    await rig.controller.applyAtBootstrap('secret-uid');
    rig.controller.onEnabledFeatures(both);
    expect(rig.logged, isNotEmpty);
    expect(rig.logged.join(), isNot(contains('secret-uid')));
  });

  group('error hooks', () {
    late FlutterExceptionHandler? savedFlutter;
    late ErrorCallback? savedDispatcher;
    setUp(() {
      savedFlutter = FlutterError.onError;
      savedDispatcher = PlatformDispatcher.instance.onError;
    });
    tearDown(() {
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedDispatcher;
    });

    Future<_Rig> collectingRig() async {
      final rig = _Rig();
      rig.consent.crash.add('a');
      await rig.controller.applyAtBootstrap('a');
      rig.controller.onEnabledFeatures(both);
      await settle();
      return rig;
    }

    test('FlutterError.reportError (what reportUnexpectedError calls) reaches '
        'the adapter exactly once and does not re-enter onError', () async {
      final rig = await collectingRig();
      installTelemetryErrorHooks(rig.controller, debug: false);
      final sink = FlutterError.onError!;
      var entered = 0;
      FlutterError.onError = (details) {
        entered++;
        sink(details);
      };
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('boom'),
          stack: StackTrace.current,
          library: 'dzeroth',
        ),
      );
      await settle();
      expect(entered, 1);
      expect(rig.crash.recorded, hasLength(1));
      expect(rig.log.calls.where((c) => c.startsWith('crash.record')), [
        'crash.record(nonfatal)',
      ]);
    });

    test('debug prints through presentError, then records', () async {
      final rig = await collectingRig();
      final order = <String>[];
      installTelemetryErrorHooks(
        rig.controller,
        debug: true,
        presentError: (_) => order.add('present'),
      );
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('x')));
      await settle();
      expect(order, ['present']);
      expect(rig.crash.recorded, hasLength(1));
    });

    test('PlatformDispatcher.onError records directly as fatal', () async {
      final rig = await collectingRig();
      installTelemetryErrorHooks(rig.controller, debug: false);
      final handled = PlatformDispatcher.instance.onError!(
        StateError('async'),
        StackTrace.current,
      );
      await settle();
      expect(handled, isTrue);
      expect(rig.log.calls, contains('crash.record(fatal)'));
    });

    test('nothing is recorded while off', () async {
      final rig = _Rig();
      await rig.controller.applyAtBootstrap('a');
      installTelemetryErrorHooks(rig.controller, debug: false);
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('x')));
      PlatformDispatcher.instance.onError!(StateError('y'), StackTrace.empty);
      await settle();
      expect(rig.crash.recorded, isEmpty);
    });
  });

  test('startTelemetry order: Firebase init, adapters, then the bootstrap '
      'decision', () async {
    final steps = <String>[];
    final log = CallLog();

    final controller = await startTelemetry(
      initializeFirebase: () async {
        steps.add('firebase');
        await Future<void>.delayed(Duration.zero);
        steps.add('firebase-done');
      },
      restoredUid: () async {
        steps.add('restoredUid');
        return null;
      },
      supported: true,
      adaptersFor: (supported) {
        steps.add('adapters');
        return TelemetryAdapters(
          crash: FakeCrashReporter(log),
          analytics: FakeUsageAnalytics(log),
        );
      },
      debugLog: (_) {},
      installHooks: false,
    );

    expect(steps, ['firebase', 'firebase-done', 'adapters', 'restoredUid']);
    // The decision reached the SDKs before startTelemetry returned, so before
    // runApp and before any report could be recorded.
    expect(log.calls, [
      'crash.setCollecting(false)',
      'crash.deleteUnsent',
      'usage.setCollecting(false)',
    ]);
    expect(controller.crashCollecting, isFalse);
  });
}
