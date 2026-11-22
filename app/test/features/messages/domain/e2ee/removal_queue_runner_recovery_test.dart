import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
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

  group('removed by the user (amendment 6, review M3)', () {
    test('wasRemovedByUser still answers true once the entry left the '
        'queue', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();

      await removeAndSettle(sibling);

      // Committed and pruned: nothing names it in the queue any more.
      expect(await pin(sibling), isNull);
      expect(runner.queuedFor(_c1), isEmpty);
      expect((await stored())!.entries, isEmpty);
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test('the answer survives a restart after the entry left, and is '
        'forgotten after 30 days (concern 1)', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      await removeAndSettle(sibling);
      expect((await stored())!.entries, isEmpty);

      await rig.restart();
      runner = build();

      // Not loaded yet: the query loads it.
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(await runner.wasRemovedByUser(other.id), isFalse);

      rig.clock.advance(kRemovedByUserLimit + const Duration(minutes: 1));
      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
    });

    test('a record that cannot be read answers unknown (concern 1)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
      );
      expectedErrors = ['removalQueue.read'];

      await expectLater(
        runner.wasRemovedByUser(sibling.id),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('a pending record (review M4)', () {
    test('a pass resumes it, never builds a second commit, and the entry '
        'leaves once it is confirmed', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // No answer to the call or its one resend: the outcome is unknown
      // and the record stays.
      for (var i = 0; i < 2; i++) {
        rig.server.commitScript.add((
          error: const NetworkException('rig: no answer'),
          stored: false,
        ));
      }

      await removeAndSettle(sibling);

      final sent = requests(_c1);
      expect(sent, hasLength(2));
      expect(sent.last.sameBytes(sent.first), isTrue);
      expect((await rig.device.vault.groups(_c1)).last.hasPending, isTrue);
      expect(queued(_c1, sibling), isTrue);

      rig.clock.advance(kCommitRetryWaitMax + const Duration(minutes: 1));
      await runner.runPass();

      final made = requests(_c1);
      expect(made, hasLength(3), reason: 'one more call');
      expect(
        made.last.sameBytes(made.first),
        isTrue,
        reason: 'resumed, not rebuilt',
      );
      expect(await pin(sibling), isNull);
      // Fix round 3, ruling 1: the resend's answer is not a listing, so the
      // pins after it are not caught up and the entry stays; the next
      // pass's catch-up lets it go, with no commit call.
      expect(queued(_c1, sibling), isTrue);
      await runner.runPass();
      expect(requests(_c1), hasLength(3));
      expect(runner.queuedFor(_c1), isEmpty);
      expect(runner.pending.value, 0);
    });
  });

  group('a stored hold (review M5)', () {
    test('a restart with a stored hold respects it and arms the timer at '
        'its time', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'rig',
          retryAfter: Duration(minutes: 10),
        ),
        stored: false,
      ));
      await removeAndSettle(sibling);
      expect((await stored())!.notBeforeMicros, isNotNull);
      final sent = requests().length;

      rig.clock.advance(const Duration(minutes: 3));
      await rig.restart();
      runnerScheduled.clear();
      runner = build();
      await runner.onVaultReady();
      await runner.onAppResumed();
      await runner.idle();

      expect(requests(), hasLength(sent), reason: 'held after the restart');
      expect(queued(_c1, sibling), isTrue);
      expect(runnerScheduled.last.delay, const Duration(minutes: 7));

      rig.clock.advance(const Duration(minutes: 7));
      await runTimer();
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
    });
  });

  group('a reset in flight (fix round 4, CR2 M-5)', () {
    Future<kpb.ClaimedKeyPackage> packageOf(RigPeer p) async =>
        kpb.ClaimedKeyPackage(
          deviceId: p.idString,
          signaturePublicKey: p.key,
          keyPackage: await p.keyPackage(),
          hasKeyPackage_4: true,
        );

    test('a reset of g + 1 is in flight, then removeDevice, then the reset '
        'is accepted: the device leaves g + 1', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      final starter = GroupStarter(
        crypto: rig.crypto,
        sender: rig.sender,
        receiver: rig.receiver,
        session: rig.device.session,
        engine: rig.engineNow,
        messaging: rig.messaging,
        keys: rig.keys,
        directory: rig.directory,
        ledger: rig.ledger,
        known: rig.known,
        syncBudget: rig.syncBudget,
        locks: rig.locks,
        contexts: rig.contexts,
        now: rig.clock.now,
        onChanged: rig.changed.add,
        removedElsewhere: () => rig.removedElsewhere,
        ownUserId: () => 'user-a',
        publicIdsOff: () => false,
        schedule: (delay, run) => rig.scheduled.add((delay: delay, run: run)),
        onUnexpectedError: (e, _) => rig.unexpected.add(e),
      );
      rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [await packageOf(bob)],
      );
      rig.keys.claims['user-a'] = () async =>
          kpb.ClaimKeyPackagesResponse(keyPackages: [await packageOf(sibling)]);
      // Bob's next commit cannot be processed here: a reset is offered.
      final garbage = rigBytes('a commit no engine can process');
      rig.device.engine.failWireAlways[RigEngine.key(garbage)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
      // The user removes the sibling while the reset's commit is in flight.
      var removed = false;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || removed) return;
        removed = true;
        await runner.removeDevice(sibling.idString);
      };

      await starter.resetConversation(_c1);

      expect(removed, isTrue);
      final g2 = (await rig.device.vault.group(_c1, 2))!;
      expect(g2.provisional, isFalse, reason: 'the reset was accepted');
      final reset = rig.server.commitRequests.single;
      expect(reset.reset, isTrue);
      expect(reset.welcomeDeviceIds, contains(sibling.idString));
      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      await runner.idle();
      // At most one more trigger (fix round 3, F2).
      await runner.runPass();
      await runner.runPass();

      expect(await pin(sibling), isNull, reason: 'left g + 1');
      final removal = [
        for (final r in rig.server.commitRequests)
          if (!r.reset) r,
      ];
      expect(removal.single.builtOn.generation, 2);
      expect(runner.pending.value, 0);
      expect((await pin(bob))!.side, MemberSide.theirs);
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
      'a record that cannot be read is unknown and a pass changes nothing',
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
        await runner.runPass();

        expect(rig.keys.removeCalls, isEmpty);
        expect(runner.unreadable, isTrue);
        expect(await stored(), isNull);
        expect(await rig.sealedSetting(kVaultSettingRemovalRecord), sealed);
      },
    );

    test('a record that cannot be read does not block a removal; both '
        'values are rebuilt (CR Minor 8, SA M1)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
      );
      expectedErrors = ['removalQueue.read', 'removalQueue.rebuilt'];

      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(queued(_c1, sibling), isTrue);
      expect(runner.unreadable, isFalse);
      final record = RemovalRecord.decode(
        (await rig.device.vault.setting(kVaultSettingRemovalRecord))!,
      );
      expect(record.intents, isEmpty);
      expect([for (final m in record.removed) m.deviceId], [sibling.idString]);
      expect((await stored())!.entries, hasLength(1));
    });

    test('a failed removal with an unreadable record writes nothing', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
      );
      final sealed = await rig.sealedSetting(kVaultSettingRemovalRecord);
      expectedErrors = ['removalQueue.read'];
      rig.keys.removeError = const NetworkException('rig: offline');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );

      expect(rig.keys.removeCalls, hasLength(1));
      expect(runner.unreadable, isTrue);
      expect(await stored(), isNull);
      expect(await rig.sealedSetting(kVaultSettingRemovalRecord), sealed);
    });
  });
}
