import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart'
    show SignInProbe;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/settings/presentation/bloc/encryption_devices_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_encrypted_messaging.dart';

const _mine = OwnDevice(
  ref: 'ref-mine',
  thisDevice: true,
  inConversations: true,
);
const _other = OwnDevice(ref: 'ref-other', thisDevice: false);

Future<bool> _yes() async => true;

void main() {
  late FakeEncryptedMessaging port;
  late List<Object> reported;

  setUp(() {
    port = FakeEncryptedMessaging()
      ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]));
    reported = [];
  });

  EncryptionDevicesCubit make() => EncryptionDevicesCubit(
    messaging: port,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  blocTest<EncryptionDevicesCubit, EncryptionDevicesState>(
    'load emits loading then ready',
    build: make,
    act: (c) => c.load(),
    verify: (c) {
      expect(c.state.status, EncryptionDevicesStatus.ready);
      expect(c.state.list!.devices, hasLength(2));
      expect(port.calls, ['ownDevices']);
    },
    expect: () => [
      isA<EncryptionDevicesState>().having(
        (s) => s.status,
        'status',
        EncryptionDevicesStatus.loading,
      ),
      isA<EncryptionDevicesState>().having(
        (s) => s.status,
        'status',
        EncryptionDevicesStatus.ready,
      ),
    ],
  );

  test('a thrown error is failed with the typed error', () async {
    port.failNextOn('ownDevices', const NetworkException('x'));
    final c = make();
    addTearDown(c.close);
    await c.load();
    expect(c.state.status, EncryptionDevicesStatus.failed);
    expect(c.state.error, isA<NetworkException>());
    expect(reported, isEmpty);
  });

  test('an untyped error is failed, reported as a fixed StateError', () async {
    port.failNextOn('ownDevices', ArgumentError.value('ref-secret'));
    final c = make();
    addTearDown(c.close);
    await c.load();
    expect(c.state.status, EncryptionDevicesStatus.failed);
    expect(c.state.error, isNull);
    expect(reported.single, isA<StateError>());
    expect(reported.single.toString(), isNot(contains('ref-secret')));
  });

  test(
    'remove calls the port once with the ref, reloads, and returns true',
    () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      expect(
        await c.remove('ref-other', confirmItsYou: _yes),
        RemoveOutcome.removed,
      );
      expect(port.removedDevices, ['ref-other']);
      expect(port.calls, ['removeDevice', 'ownDevices']);
      expect(c.state.removing, isNull);
      expect(c.state.status, EncryptionDevicesStatus.ready);
    },
  );

  test('remove failure keeps the list and exposes the error', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    final before = c.state.list;
    port.failNextOn('removeDevice', const NetworkException('x'));
    expect(
      await c.remove('ref-other', confirmItsYou: _yes),
      RemoveOutcome.failed,
    );
    expect(c.state.list, same(before));
    expect(c.state.error, isA<NetworkException>());
    expect(c.state.removing, isNull);
    expect(port.calls, isNot(contains('retryDeviceSetup')));
  });

  test('a failed reload after a removal still answers true', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    port.failNextOn('ownDevices', const NetworkException('x'));
    expect(
      await c.remove('ref-other', confirmItsYou: _yes),
      RemoveOutcome.removed,
    );
    expect(c.state.status, EncryptionDevicesStatus.ready);
    expect(c.state.list, isNotNull);
    // An ordinary network error on the reload is not an unexpected error.
    expect(reported, isEmpty);
  });

  test('a reload failing with a non-typed error after a removal is reported '
      'as a fixed StateError', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    port.failNextOn('ownDevices', ArgumentError.value('ref-secret'));
    expect(
      await c.remove('ref-other', confirmItsYou: _yes),
      RemoveOutcome.removed,
    );
    expect(reported.single, isA<StateError>());
    expect(reported.single.toString(), isNot(contains('ref-secret')));
  });

  test('a removal off the device limit never calls retryDeviceSetup', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    await c.remove('ref-other', confirmItsYou: _yes);
    expect(port.retryDeviceSetupCalls, 0);
  });

  test('at the device limit the list is reloaded after the retry', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    port.calls.clear();
    expect(
      await c.remove('ref-other', retrySetup: true, confirmItsYou: _yes),
      RemoveOutcome.removed,
    );
    expect(port.calls, ['removeDevice', 'retryDeviceSetup', 'ownDevices']);
  });

  test(
    'a second remove during a removal calls nothing and is not attempted',
    () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.holdRemoveDevice = Completer<void>();
      final first = c.remove('ref-other', confirmItsYou: _yes);
      await Future<void>.delayed(Duration.zero);
      // Not cleared: the fake reads `calls.last` to find the method it serves.
      final callsBefore = port.calls.length;
      expect(
        await c.remove('ref-other', confirmItsYou: _yes),
        RemoveOutcome.notAttempted,
      );
      expect(port.calls, hasLength(callsBefore));
      port.holdRemoveDevice!.complete();
      expect(await first, RemoveOutcome.removed);
    },
  );

  test('a closed cubit does not attempt a removal', () async {
    final c = make();
    await c.close();
    expect(
      await c.remove('ref-other', confirmItsYou: _yes),
      RemoveOutcome.notAttempted,
    );
    expect(port.calls, isEmpty);
  });

  test('Try again during a removal keeps the removal guard', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    port.holdRemoveDevice = Completer<void>();
    final first = c.remove('ref-other', confirmItsYou: _yes);
    await Future<void>.delayed(Duration.zero);
    await c.load();
    expect(c.state.removing, 'ref-other');
    expect(
      await c.remove('ref-older', confirmItsYou: _yes),
      RemoveOutcome.notAttempted,
    );
    port.holdRemoveDevice!.complete();
    await first;
    expect(c.state.removing, isNull);
  });

  test('removalsPending follows the port\'s listenable', () async {
    port.removalsPending.value = 3;
    final c = make();
    addTearDown(c.close);
    expect(c.state.removalsPending, 3);
    port.removalsPending.value = 12;
    expect(c.state.removalsPending, 12);
    await c.load();
    expect(c.state.removalsPending, 12);
  });

  test('retryDeviceSetup is called after a successful removal', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    await c.remove('ref-other', retrySetup: true, confirmItsYou: _yes);
    expect(port.retryDeviceSetupCalls, 1);
  });

  test('closing the cubit stops listening', () async {
    final c = make();
    expect(port.removalsPending.listenerCount, 1);
    await c.close();
    expect(port.removalsPending.listenerCount, 0);
    port.removalsPending.value = 5;
    expect(c.state.removalsPending, 0);
  });

  // Ruling 3 (lane D PR 4; removal design §4 "Task 11 queue"): the
  // re-sign-in comes BEFORE the removal is sent and queued, so the first
  // REMOTE call goes out inside the server's recent-sign-in window.
  group('confirm it is you', () {
    Future<bool> Function() confirm(bool answer) => () async {
      port.calls.add('confirmItsYou');
      return answer;
    };

    test('the re-sign-in runs before the port is called', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      final outcome = await c.remove('ref-other', confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.removed);
      expect(port.calls.take(2), ['confirmItsYou', 'removeDevice']);
      expect(port.removedDevices, ['ref-other']);
    });

    test('a declined re-sign-in sends nothing and keeps the list', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      final before = c.state.list;
      port.calls.clear();
      final outcome = await c.remove(
        'ref-other',
        confirmItsYou: confirm(false),
      );
      expect(outcome, RemoveOutcome.cancelled);
      expect(port.calls, ['confirmItsYou']);
      expect(port.removedDevices, isEmpty);
      expect(c.state.removing, isNull);
      expect(c.state.error, isNull);
      expect(c.state.list, same(before));
    });

    test('no spinner while the re-sign-in is open, and a second removal '
        'is not attempted meanwhile', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      final open = Completer<bool>();
      final first = c.remove('ref-other', confirmItsYou: () => open.future);
      await pumpEventQueue();
      expect(c.state.removing, isNull);
      expect(c.state.confirming, isTrue);
      expect(
        await c.remove('ref-other', confirmItsYou: _yes),
        RemoveOutcome.notAttempted,
      );
      expect(port.removedDevices, isEmpty);
      open.complete(true);
      expect(await first, RemoveOutcome.removed);
      expect(c.state.confirming, isFalse);
      expect(port.removedDevices, ['ref-other']);
    });

    test('a re-sign-in that throws is a cancel, reported', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      final outcome = await c.remove(
        'ref-other',
        confirmItsYou: () async => throw StateError('plugin'),
      );
      expect(outcome, RemoveOutcome.cancelled);
      expect(port.removedDevices, isEmpty);
      expect(reported.single, isA<StateError>());
    });

    test('REAUTH_REQUIRED from the removal asks again: needsReauth, the '
        'list kept, no error shown', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.failNextOn(
        'removeDevice',
        const ReauthRequiredException('Please sign in again.'),
      );
      final outcome = await c.remove('ref-other', confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.needsReauth);
      expect(c.state.removing, isNull);
      expect(c.state.error, isNull);
      expect(c.state.list, isNotNull);
    });

    test(
      'the removal answer is kept: other_sessions_ended true, false, null',
      () async {
        for (final answer in [true, false, null]) {
          port.nextRemoval = DeviceRemoval(otherSessionsEnded: answer);
          final c = make();
          addTearDown(c.close);
          await c.load();
          await c.remove('ref-other', confirmItsYou: _yes);
          expect(c.otherSessionsEnded, answer);
          expect(c.sessionsEnded, answer == true);
        }
      },
    );

    test('a failed removal keeps no answer', () async {
      port.nextRemoval = const DeviceRemoval(otherSessionsEnded: true);
      final c = make();
      addTearDown(c.close);
      await c.load();
      await c.remove('ref-other', confirmItsYou: _yes);
      expect(c.sessionsEnded, isTrue);
      port.failNextOn('removeDevice', const NetworkException('x'));
      await c.remove('ref-other', confirmItsYou: _yes);
      expect(c.otherSessionsEnded, isNull);
      expect(c.sessionsEnded, isFalse);
    });

    // Item 1 of the last round: `confirmItsYou` is a required parameter, so a
    // removal without the re-sign-in no longer compiles (nothing to test at
    // run time); the order below is the rule it enforces.
    test('every removal asks for the re-sign-in first', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      await c.remove('ref-other', confirmItsYou: confirm(true));
      expect(port.calls.first, 'confirmItsYou');
    });
  });

  group('parked removals', () {
    Future<bool> Function() confirm(bool answer) => () async {
      port.calls.add('confirmItsYou');
      return answer;
    };

    test('the re-sign-in runs before removeDevice, once, then every parked '
        'ref is sent', () async {
      port.park(['ref-other', 'ref-third']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      final outcome = await c.resumeParked(confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.removed);
      expect(port.calls.take(3), [
        'confirmItsYou',
        'removeDevice',
        'removeDevice',
      ]);
      expect(port.calls.where((x) => x == 'confirmItsYou'), hasLength(1));
      expect(port.removedDevices, ['ref-other', 'ref-third']);
      expect(port.parkedRemovals.value, isEmpty);
      expect(port.needsReauth.value, isFalse);
    });

    test('a declined re-sign-in never calls removeDevice and keeps the '
        'removals parked', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      expect(
        await c.resumeParked(confirmItsYou: confirm(false)),
        RemoveOutcome.cancelled,
      );
      expect(port.calls, ['confirmItsYou']);
      expect(port.removedDevices, isEmpty);
      expect(port.parkedRemovals.value, ['ref-other']);
    });

    test('a re-sign-in that throws is a cancel, reported as a fixed step, '
        'and sends nothing', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      final outcome = await c.resumeParked(
        confirmItsYou: () async => throw StateError('ref-secret'),
      );
      expect(outcome, RemoveOutcome.cancelled);
      expect(port.removedDevices, isEmpty);
      expect(reported.single.toString(), isNot(contains('ref-secret')));
    });

    test('nothing parked is nothing attempted, and asks nothing', () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      expect(
        await c.resumeParked(confirmItsYou: confirm(true)),
        RemoveOutcome.notAttempted,
      );
      expect(port.calls, isEmpty);
    });

    test('REAUTH_REQUIRED again is needsReauth: the removal stays parked and '
        'no error shows', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.failNextOn(
        'removeDevice',
        const ReauthRequiredException('Please sign in again.'),
      );
      final outcome = await c.resumeParked(confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.needsReauth);
      expect(port.parkedRemovals.value, ['ref-other']);
      expect(c.state.error, isNull);
      expect(c.state.removing, isNull);
    });

    test('a ref that left the parked list during the re-sign-in is not '
        'sent', () async {
      port.park(['ref-other', 'ref-third']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      final outcome = await c.resumeParked(
        confirmItsYou: () async {
          await port.dropRemoval('ref-third');
          return true;
        },
      );
      expect(outcome, RemoveOutcome.removed);
      expect(port.removedDevices, ['ref-other']);
    });

    test('a ref parked during the re-sign-in is not sent either: only the '
        'intersection', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      await c.resumeParked(
        confirmItsYou: () async {
          port.park(['ref-new']);
          return true;
        },
      );
      expect(port.removedDevices, ['ref-other']);
      expect(port.parkedRemovals.value, ['ref-new']);
    });

    test('everything left the parked list during the re-sign-in: nothing is '
        'sent', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      final outcome = await c.resumeParked(
        confirmItsYou: () async {
          await port.dropRemoval('ref-other');
          return true;
        },
      );
      expect(outcome, RemoveOutcome.notAttempted);
      expect(port.removedDevices, isEmpty);
    });

    test('a later failure after an earlier success reloads the list before '
        'answering failed', () async {
      port.park(['ref-other', 'ref-third']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.failRemovalOf('ref-third', const NetworkException('x'));
      port.calls.clear();
      final outcome = await c.resumeParked(confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.failed);
      expect(c.state.error, isA<NetworkException>());
      expect(port.calls.last, 'ownDevices');
      expect(c.state.list, isNotNull);
    });

    test('a first failure with nothing removed does not reload', () async {
      port.park(['ref-other']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.failRemovalOf('ref-other', const NetworkException('x'));
      port.calls.clear();
      await c.resumeParked(confirmItsYou: confirm(true));
      expect(port.calls, isNot(contains('ownDevices')));
    });

    test('a failure stops the rest and exposes the typed error', () async {
      port.park(['ref-other', 'ref-third']);
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.failNextOn('removeDevice', const NetworkException('x'));
      final outcome = await c.resumeParked(confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.failed);
      expect(c.state.error, isA<NetworkException>());
      expect(port.removedDevices, ['ref-other']);
    });

    test('the answer is true only when every removal says true; any false is '
        'false; an unknown one is null', () async {
      for (final (first, second, want) in <(bool?, bool?, bool?)>[
        (true, true, true),
        (true, false, false),
        (false, null, false),
        (true, null, null),
      ]) {
        port = FakeEncryptedMessaging()
          ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]))
          ..park(['ref-other', 'ref-third']);
        port.queueRemovals([
          DeviceRemoval(otherSessionsEnded: first),
          DeviceRemoval(otherSessionsEnded: second),
        ]);
        final c = make();
        addTearDown(c.close);
        await c.load();
        await c.resumeParked(confirmItsYou: confirm(true));
        expect(c.otherSessionsEnded, want, reason: '$first $second');
        // Remover copy (ruling 2026-11-27): any true is a cut, which ended
        // every session (this device's too).
        expect(
          c.sessionsEnded,
          first == true || second == true,
          reason: '$first $second',
        );
      }
    });

    // Fix round 1, R2: a true answer is probed (one forced refresh) before
    // anything is shown; only a sign-in that is not alive has ended.
    group('the sign-in probe', () {
      EncryptionDevicesCubit probing(SignInProbe answer, List<String> log) =>
          EncryptionDevicesCubit(
            messaging: port,
            onUnexpectedError: (e, _) => reported.add(e),
            checkSignIn: () async {
              // Still busy: the row shows its spinner while it runs.
              log.add('probe');
              return answer;
            },
          );

      for (final (answer, ended) in [
        (SignInProbe.alive, false),
        (SignInProbe.dead, true),
        (SignInProbe.unknown, true),
      ]) {
        test('$answer: thisSignInEnded $ended', () async {
          port.nextRemoval = const DeviceRemoval(otherSessionsEnded: true);
          final log = <String>[];
          final c = probing(answer, log);
          addTearDown(c.close);
          await c.load();
          await c.remove('ref-other', confirmItsYou: _yes);
          expect(log, ['probe']);
          expect(c.sessionsEnded, isTrue);
          expect(c.thisSignInEnded, ended);
        });
      }

      test('no true answer: no probe, nothing ended', () async {
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: false);
        final log = <String>[];
        final c = probing(SignInProbe.dead, log);
        addTearDown(c.close);
        await c.load();
        await c.remove('ref-other', confirmItsYou: _yes);
        expect(log, isEmpty);
        expect(c.thisSignInEnded, isFalse);
      });

      test('the probe runs while the row is still busy', () async {
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: true);
        late EncryptionDevicesCubit c;
        String? removingDuringProbe;
        c = EncryptionDevicesCubit(
          messaging: port,
          checkSignIn: () async {
            removingDuringProbe = c.state.removing;
            return SignInProbe.dead;
          },
        );
        addTearDown(c.close);
        await c.load();
        await c.remove('ref-other', confirmItsYou: _yes);
        expect(removingDuringProbe, 'ref-other');
        expect(c.state.removing, isNull);
      });

      test('a throwing probe is unknown: ended', () async {
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: true);
        final c = EncryptionDevicesCubit(
          messaging: port,
          checkSignIn: () async => throw StateError('x'),
        );
        addTearDown(c.close);
        await c.load();
        await c.remove('ref-other', confirmItsYou: _yes);
        expect(c.thisSignInEnded, isTrue);
        expect(c.probed, SignInProbe.unknown);
      });

      // Fix round 2, F2 (re-review m1): a true answer is never treated as
      // alive unless a probe ran, and one user action keeps what it learned.
      test('resumeParked: a true answer, then REAUTH_REQUIRED, then the '
          'continued run is cancelled: ended, no probe, never alive', () async {
        port = FakeEncryptedMessaging()
          ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]))
          ..park(['ref-other', 'ref-third'])
          ..nextRemoval = const DeviceRemoval(otherSessionsEnded: true)
          ..failRemovalOf(
            'ref-third',
            const ReauthRequiredException('sign in'),
          );
        final log = <String>[];
        final c = probing(SignInProbe.alive, log);
        addTearDown(c.close);
        await c.load();
        expect(
          await c.resumeParked(confirmItsYou: confirm(true)),
          RemoveOutcome.needsReauth,
        );
        expect(c.sessionsEnded, isTrue);
        expect(c.probed, isNull);
        expect(c.thisSignInEnded, isTrue);
        // The second "Confirm it's you" of the same action is declined.
        expect(
          await c.resumeParked(confirmItsYou: confirm(false), continued: true),
          RemoveOutcome.cancelled,
        );
        expect(log, isEmpty);
        expect(c.sessionsEnded, isTrue);
        expect(c.thisSignInEnded, isTrue);
      });

      test('resumeParked: the continued run that finishes probes, and an '
          'alive answer then counts', () async {
        port = FakeEncryptedMessaging()
          ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]))
          ..park(['ref-other', 'ref-third'])
          ..nextRemoval = const DeviceRemoval(otherSessionsEnded: true)
          ..failRemovalOf(
            'ref-third',
            const ReauthRequiredException('sign in'),
          );
        final log = <String>[];
        final c = probing(SignInProbe.alive, log);
        addTearDown(c.close);
        await c.load();
        await c.resumeParked(confirmItsYou: confirm(true));
        // ref-third answers this time, with no sessions-ended bit of its own.
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: false);
        expect(
          await c.resumeParked(confirmItsYou: confirm(true), continued: true),
          RemoveOutcome.removed,
        );
        expect(c.sessionsEnded, isTrue);
        expect(log, ['probe']);
        expect(c.probed, SignInProbe.alive);
        expect(c.thisSignInEnded, isFalse);
      });

      test('a new user action starts clean', () async {
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: true);
        final log = <String>[];
        final c = probing(SignInProbe.dead, log);
        addTearDown(c.close);
        await c.load();
        await c.remove('ref-other', confirmItsYou: _yes);
        expect(c.thisSignInEnded, isTrue);
        port.nextRemoval = const DeviceRemoval(otherSessionsEnded: false);
        await c.remove('ref-other', confirmItsYou: _yes);
        expect(c.sessionsEnded, isFalse);
        expect(c.probed, isNull);
        expect(c.thisSignInEnded, isFalse);
      });
    });

    test('sessionsEnded holds a true answer even when a later removal of '
        'the run fails', () async {
      port = FakeEncryptedMessaging()
        ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]))
        ..park(['ref-other', 'ref-third'])
        ..nextRemoval = const DeviceRemoval(otherSessionsEnded: true)
        ..failRemovalOf('ref-third', const NetworkException('x'));
      final c = make();
      addTearDown(c.close);
      await c.load();
      final outcome = await c.resumeParked(confirmItsYou: confirm(true));
      expect(outcome, RemoveOutcome.failed);
      expect(c.sessionsEnded, isTrue);
    });

    test('dropParked drops every parked ref with no removal call', () async {
      port.park(['ref-other', 'ref-third']);
      final c = make();
      addTearDown(c.close);
      await c.dropParked();
      expect(port.droppedRemovals, ['ref-other', 'ref-third']);
      expect(port.removedDevices, isEmpty);
      expect(port.needsReauth.value, isFalse);
    });

    test('a failing drop is reported as a fixed step, never the ref', () async {
      port.park(['ref-secret']);
      port.failNextOn('dropRemoval', StateError('ref-secret'));
      final c = make();
      addTearDown(c.close);
      await c.dropParked();
      expect(reported.single, isA<StateError>());
      expect(reported.single.toString(), isNot(contains('ref-secret')));
    });
  });
}
