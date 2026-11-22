import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's fix-round tests (Task 11 review): the hooks under a
// held lock, the intent record, the own-list refresh, the durable
// "removed by the user" record, the pending record and a stored hold. The
// first file is removal_queue_runner_test.dart.

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

  group('the hooks (review I3)', () {
    test('noteConversation and onAccepted return at once inside a held '
        'conversation lock', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await removeAndSettle(sibling);
      expect((await stored())!.entries.single.parked, isTrue);
      rig.contexts.note(headerRow(_c1));

      await rig.locks.run(_c1, () async {
        await runner.noteConversation(_c1).timeout(const Duration(seconds: 5));
        await runner.onAccepted(_c1).timeout(const Duration(seconds: 5));
      });
      await runner.idle();

      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
    });
  });

  group('the own-device list (review M2)', () {
    test('a removal refreshes the cached own-device list', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      bool lists(DeviceList l) =>
          l.devices.any((d) => rigEq(d.deviceId, sibling.id));
      expect(lists(await rig.directory.own()), isTrue);

      await removeAndSettle(sibling);

      // Reused, not fetched again: the reused list no longer names it.
      final calls = rig.keys.listCalls;
      final after = await rig.directory.own();
      expect(rig.keys.listCalls, calls);
      expect(after.readable, isTrue);
      expect(lists(after), isFalse);
    });
  });

  group('the intent (review M1)', () {
    /// Restarts the app and lets the new runner start.
    Future<void> restartAndStart() async {
      await rig.restart();
      runner = build();
      await runner.onVaultReady();
      await runner.idle();
    }

    test('a crash between RemoveKeyDevice and the save, then a restart, '
        'queues the device', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      // The server removed it; the app stops before the queue is stored.
      rig.keys.onRemoved = () async {
        rig.keys.onRemoved = null;
        await rig.restart();
      };

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<StateError>()),
      );
      expect(await stored(), isNull, reason: 'nothing queued before it');

      runner = build();
      await runner.onVaultReady();
      await runner.idle();

      // The leftover intent ran RemoveKeyDevice again (a success for a
      // removed device), then queued it.
      expect(rig.keys.removeCalls, hasLength(2));
      expect(rig.keys.removeCalls.last.deviceId, sibling.idString);
      expect(queued(_c1, sibling), isTrue);
      expect((await stored())!.entries, hasLength(1));

      // The intent is gone: the next start sends nothing.
      await restartAndStart();
      expect(rig.keys.removeCalls, hasLength(2));
      expect(queued(_c1, sibling), isTrue);
    });

    test('a definite refusal removes the intent; a restart sends '
        'nothing', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      rig.keys.removeError = const ValidationException('rig');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ValidationException>()),
      );
      rig.keys.removeError = null;
      await restartAndStart();

      expect(rig.keys.removeCalls, hasLength(1));
      expect(runner.queuedFor(_c1), isEmpty);
      expect(await stored(), isNull);
    });

    test('an unknown outcome keeps the intent; the next start sends it '
        'again and queues', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      rig.keys.removeError = const NetworkException('rig: timed out');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      expect(runner.queuedFor(_c1), isEmpty);
      rig.keys.removeError = null;
      await restartAndStart();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(queued(_c1, sibling), isTrue);
    });

    test(
      'a record that cannot be read is unknown and changes nothing',
      () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await stateOnly(_c1, accepted: false, mine: [sibling]);
        await rig.device.vault.transaction(
          (tx) =>
              tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
        );
        final sealed = await rig.sealedSetting(kVaultSettingRemovalRecord);
        expectedErrors = ['removalQueue.read'];

        await runner.onVaultReady();
        await runner.idle();
        await expectLater(
          runner.removeDevice(sibling.idString),
          throwsA(isA<StateError>()),
        );

        expect(rig.keys.removeCalls, isEmpty);
        expect(runner.unreadable, isTrue);
        expect(await stored(), isNull);
        expect(await rig.sealedSetting(kVaultSettingRemovalRecord), sealed);
      },
    );
  });
}
