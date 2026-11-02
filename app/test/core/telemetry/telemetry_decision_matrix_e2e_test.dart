import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/analytics_event.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/telemetry_e2e_rig.dart';

/// TEL-9: the TEL-4 decision matrix and TEL-8's forget/reset, end to end over
/// the real controller, hooks, consent and database stores, and the real
/// Crashlytics payload code. Only the SDK edges are fakes. 0 RPCs.
const _both = {kFeatureCrashReporting, kFeatureAnalytics};
const _post = PostCreated(
  kind: PostKind.post,
  media: PostMedia.none,
  poll: false,
  scheduled: false,
);

ConsentChoice _choice(bool on) => on ? ConsentChoice.on : ConsentChoice.off;

void main() {
  late AppDatabase database;
  setUp(() {
    TelemetryE2eRig.restoreHooksAfterTest();
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => database.close());

  test('64 cells (platform, signed in, 2 flags, 2 consents): each kind '
      'collects in exactly one cell, observed at the SDK edge', () async {
    var crashOn = 0;
    var usageOn = 0;
    for (final supported in [false, true]) {
      for (final signedIn in [false, true]) {
        for (final flagCrash in [false, true]) {
          for (final flagUsage in [false, true]) {
            for (final consentCrash in [false, true]) {
              for (final consentUsage in [false, true]) {
                final db = AppDatabase.forTesting(NativeDatabase.memory());
                final rig = TelemetryE2eRig(db, supported: supported);
                // Answers given earlier on this device, for account "a".
                await rig.consent.setAll('a', {
                  TelemetryKind.crash: _choice(consentCrash),
                  TelemetryKind.usage: _choice(consentUsage),
                });
                await rig.launch(restoredUid: signedIn ? 'a' : null);
                if (signedIn) {
                  await rig.getMe({
                    if (flagCrash) kFeatureCrashReporting,
                    if (flagUsage) kFeatureAnalytics,
                  });
                }
                reportUnexpectedError(StateError('x'), StackTrace.current);
                await rig.controller.logEvent(_post);
                await pumpEventQueue();

                final cell =
                    'supported=$supported signedIn=$signedIn '
                    'flags=$flagCrash/$flagUsage consent=$consentCrash/'
                    '$consentUsage';
                final wantCrash =
                    supported && signedIn && flagCrash && consentCrash;
                final wantUsage =
                    supported && signedIn && flagUsage && consentUsage;
                expect(rig.recordErrors, wantCrash ? 1 : 0, reason: cell);
                expect(rig.usageLogs, wantUsage ? 1 : 0, reason: cell);
                if (supported) {
                  // The SDKs were told the decision, and the last word is it.
                  expect(rig.crashSdkOn, wantCrash, reason: cell);
                  expect(rig.usageSdkOn, wantUsage, reason: cell);
                  if (!wantCrash) {
                    expect(rig.port.calls, contains('deleteUnsent'));
                  }
                } else {
                  // Unsupported platform: Noop adapters, no SDK call at all.
                  expect(rig.port.calls, isEmpty, reason: cell);
                  expect(rig.calls.calls, isEmpty, reason: cell);
                }
                if (wantCrash) crashOn++;
                if (wantUsage) usageOn++;
                await rig.dispose();
                await db.close();
              }
            }
          }
        }
      }
    }
    // The other kind's flag and consent are free in a kind's own cell.
    expect(crashOn, 4);
    expect(usageOn, 4);
  });

  test('crash only: crash on, usage consent never given', () async {
    final rig = TelemetryE2eRig(database);
    await rig.consent.set('a', TelemetryKind.crash, ConsentChoice.on);
    await rig.launch(restoredUid: 'a');
    await rig.getMe(_both);
    reportUnexpectedError(StateError('x'), StackTrace.current);
    await rig.controller.logEvent(_post);
    await rig.controller.logScreen('home');
    await pumpEventQueue();
    expect(rig.recordErrors, 1);
    expect(rig.usageLogs, 0);
    expect(rig.calls.calls, isNot(contains('usage.screen(home)')));
    expect(rig.usageSdkOn, isFalse);
    await rig.dispose();
  });

  test('flag off in a GetMe: SDK off and unsent reports dropped before the '
      'next report, which is not recorded', () async {
    final rig = TelemetryE2eRig(database);
    await rig.consent.setAll('a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });
    await rig.launch(restoredUid: 'a');
    await rig.getMe(_both);
    reportUnexpectedError(StateError('one'), StackTrace.current);
    await pumpEventQueue();
    expect(rig.recordErrors, 1);

    rig.port.calls.clear();
    await rig.getMe({});
    reportUnexpectedError(StateError('two'), StackTrace.current);
    await rig.controller.logEvent(_post);
    await pumpEventQueue();
    expect(rig.port.calls, ['setCollectionEnabled(false)', 'deleteUnsent']);
    expect(rig.usageLogs, 0);
    expect(rig.usageSdkOn, isFalse);
    // The stored choice is kept: the switch comes back with the flag.
    expect(await database.readSetting('telemetry_consent:crash:a'), 'on');
    await rig.getMe(_both);
    reportUnexpectedError(StateError('three'), StackTrace.current);
    await pumpEventQueue();
    expect(
      rig.recordErrors,
      1,
    ); // port calls were cleared above: one new record
    await rig.dispose();
  });

  test('a Settings switch turned off stops collection at once and persists '
      'across a relaunch', () async {
    final rig = TelemetryE2eRig(database);
    await rig.consent.setAll('a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });
    await rig.launch(restoredUid: 'a');
    await rig.getMe(_both);
    await rig.consent.set('a', TelemetryKind.crash, ConsentChoice.off);
    reportUnexpectedError(StateError('x'), StackTrace.current);
    await pumpEventQueue();
    expect(rig.recordErrors, 0);
    expect(rig.port.calls, contains('deleteUnsent'));
    await rig.dispose();

    // Relaunch: the stored flags say "on", the stored consent says "off".
    final again = TelemetryE2eRig(database);
    await again.launch(restoredUid: 'a');
    expect(again.crashSdkOn, isFalse);
    expect(again.usageSdkOn, isTrue);
    reportUnexpectedError(StateError('x'), StackTrace.current);
    await pumpEventQueue();
    expect(again.recordErrors, 0);
    await again.dispose();
  });

  test('relaunch re-applies the stored decision before any GetMe, and '
      'always reaches the SDK (its native state persists)', () async {
    final first = TelemetryE2eRig(database);
    await first.consent.setAll('a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });
    await first.launch(restoredUid: 'a');
    await first.getMe(_both);
    await first.dispose();

    final second = TelemetryE2eRig(database);
    await second.launch(restoredUid: 'a');
    expect(second.crashSdkOn, isTrue);
    expect(second.usageSdkOn, isTrue);

    // Nobody signed in at launch: still told "off", though nothing changed.
    final third = TelemetryE2eRig(database);
    await third.launch();
    expect(third.crashSdkOn, isFalse);
    expect(third.usageSdkOn, isFalse);
    expect(third.port.calls, contains('deleteUnsent'));
    await second.dispose();
    await third.dispose();
  });

  test('sign-out means off and deletes unsent reports', () async {
    final rig = TelemetryE2eRig(database);
    await rig.consent.set('a', TelemetryKind.crash, ConsentChoice.on);
    await rig.launch(restoredUid: 'a');
    await rig.getMe(_both);
    rig.port.calls.clear();
    await rig.signOut();
    reportUnexpectedError(StateError('x'), StackTrace.current);
    await pumpEventQueue();
    expect(rig.port.calls, ['setCollectionEnabled(false)', 'deleteUnsent']);
    await rig.dispose();
  });

  group('account switch (TEL-8, F11)', () {
    test('A (opted in) to B (not): nothing of B is reported; B gets a '
        'fresh analytics ID first', () async {
      final rig = TelemetryE2eRig(database);
      await database.writeSetting(
        'telemetry_last_uid',
        'a',
      ); // not a first sign-in
      await rig.consent.setAll('a', {
        TelemetryKind.crash: ConsentChoice.on,
        TelemetryKind.usage: ConsentChoice.on,
      });
      await rig.launch(restoredUid: 'a');
      await rig.getMe(_both);
      reportUnexpectedError(StateError('a'), StackTrace.current);
      await pumpEventQueue();
      expect(rig.recordErrors, 1);
      expect(rig.resets, 0);

      await rig.signIn('b'); // direct switch, no sign-out in between
      await rig.getMe(_both); // B's own GetMe: flags on, B never opted in
      reportUnexpectedError(StateError('b'), StackTrace.current);
      await rig.controller.logEvent(_post);
      await pumpEventQueue();
      expect(rig.recordErrors, 1, reason: 'B opted in to nothing');
      expect(rig.usageLogs, 0);
      expect(rig.resets, 1);
      expect(rig.crashSdkOn, isFalse);
      expect(await database.readSetting('telemetry_last_uid'), 'b');
      await rig.dispose();
    });

    test(
      'B opted in too: the reset runs before the first event of B',
      () async {
        final rig = TelemetryE2eRig(database);
        await database.writeSetting(
          'telemetry_last_uid',
          'a',
        ); // not a first sign-in
        for (final uid in ['a', 'b']) {
          await rig.consent.set(uid, TelemetryKind.usage, ConsentChoice.on);
        }
        await rig.launch(restoredUid: 'a');
        await rig.getMe(_both);
        await rig.signIn('b');
        await rig.getMe(_both);
        await rig.controller.logEvent(_post);
        await pumpEventQueue();
        final calls = rig.calls.calls;
        expect(rig.resets, 1);
        expect(
          calls.indexOf('usage.reset'),
          lessThan(calls.lastIndexOf('usage.log')),
        );
        await rig.dispose();
      },
    );

    test('A signs in again after A: no reset', () async {
      final rig = TelemetryE2eRig(database);
      await database.writeSetting('telemetry_last_uid', 'a'); // A is recorded
      await rig.consent.set('a', TelemetryKind.usage, ConsentChoice.on);
      await rig.launch(restoredUid: 'a');
      await rig.signOut();
      await rig.signIn('a');
      await rig.getMe(_both);
      expect(rig.resets, 0);
      await rig.dispose();
    });

    test('a relaunch restoring B after A resets before usage is switched on, '
        'with the record kept on disk', () async {
      final first = TelemetryE2eRig(database);
      await first.consent.set('a', TelemetryKind.usage, ConsentChoice.on);
      await first.consent.set('b', TelemetryKind.usage, ConsentChoice.on);
      await first.launch(restoredUid: 'a');
      await first.getMe(_both);
      await first.dispose();

      // The stored flags of B (a previous session) would switch usage on.
      await database.writeSetting('telemetry_flags:b', 'analytics');
      final second = TelemetryE2eRig(database);
      await second.launch(restoredUid: 'b');
      final calls = second.calls.calls;
      expect(second.resets, 1);
      expect(
        calls.indexOf('usage.reset'),
        lessThan(calls.indexOf('usage.setCollecting(true)')),
      );
      expect(await database.readSetting('telemetry_last_uid'), 'b');
      await second.dispose();
    });
  });

  group('in-app account deletion (TEL-8)', () {
    test('forgets the consent keys, the flags and the last-uid record, drops '
        'unsent reports, resets the analytics ID', () async {
      final rig = TelemetryE2eRig(database);
      await rig.consent.setAll('a', {
        TelemetryKind.crash: ConsentChoice.on,
        TelemetryKind.usage: ConsentChoice.on,
      });
      await rig.launch(restoredUid: 'a');
      await rig.getMe(_both);
      final before = await rig.storedKeys('a');
      expect(before.values, everyElement(isNotNull), reason: '$before');

      rig.port.calls.clear();
      rig.calls.clear();
      await rig.deleteAccount('a');

      final after = await rig.storedKeys('a');
      expect(after.values, everyElement(isNull), reason: '$after');
      expect(rig.port.calls, contains('deleteUnsent'));
      expect(rig.resets, 1);
      await rig.dispose();
    });

    test('deleting while collection is off still resets, and the next '
        'account finds no record and resets (F12)', () async {
      final rig = TelemetryE2eRig(database);
      await database.writeSetting('telemetry_last_uid', 'a');
      await rig.launch(restoredUid: 'a'); // never opted in, flags off
      await rig.deleteAccount('a');
      expect(rig.resets, 1);

      await rig.consent.set('b', TelemetryKind.usage, ConsentChoice.on);
      rig.calls.clear();
      await rig.signIn('b');
      await rig.getMe(_both);
      await rig.controller.logEvent(_post);
      await pumpEventQueue();
      expect(rig.resets, 1);
      expect(rig.usageLogs, 1);
      await rig.dispose();
    });

    test('another account has its keys kept through the deletion', () async {
      final rig = TelemetryE2eRig(database);
      for (final uid in ['a', 'b']) {
        await rig.consent.set(uid, TelemetryKind.crash, ConsentChoice.on);
      }
      await rig.launch(restoredUid: 'a');
      await rig.deleteAccount('a');
      expect(await database.readSetting('telemetry_consent:crash:b'), 'on');
      await rig.dispose();
    });
  });
}
