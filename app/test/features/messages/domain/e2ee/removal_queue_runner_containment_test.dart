import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's fix-round-2 tests (Task 11 whole-branch review CR and
// security audit SA): containment of a removed device in every case the
// earlier rounds left open. The other files are removal_queue_runner_test.dart
// and removal_queue_runner_recovery_test.dart.

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

  /// Some minutes after the acceptance (so a peer fetch counts and
  /// attribution concludes), bob commits, on the server's current pair of
  /// [c], an add of [add] (this device has not applied it).
  Future<void> bobAdds(String c, List<RigPeer> add) async {
    rig.clock.advance(kConversationCopyStale + const Duration(minutes: 1));
    final at = rig.server.current(c);
    final commit = await rigCommit(
      offers[c]!.add.group,
      add: [for (final p in add) await p.keyPackage()],
    );
    rig.server.addCommit(c, at, commit.commit, fromUser: 'user-b');
  }

  group('a removed own device pinned unattributed (CR I-A, SA L3)', () {
    test('a peer-built commit adds an own device while this device is '
        'behind; removeDevice still takes it out of the group', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      // Bob adds the user's sibling; this device has not caught up, so it
      // never attributed the sibling while the own list still named it.
      await bobAdds(_c1, [sibling]);

      await removeAndSettle(sibling);
      // That pass's catch-up applied bob's add (the sibling is pinned
      // unattributed: the own list no longer names it); its commit waits
      // for a live pull at the new pair, which the next pass makes first.
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      await runner.runPass();

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      expect(runner.pending.value, 0);
      expect((await pin(bob))!.side, MemberSide.theirs);
    });

    test('the upkeep\'s reconcile takes it out too', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      // The runner's pass catches up (the sibling is pinned unattributed)
      // and cannot commit before a live pull at the new pair.
      await removeAndSettle(sibling);
      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);

      await rig.upkeep.reconcile(_c1);

      expect(await pin(sibling), isNull);
      expect(requests(_c1), hasLength(1));
    });

    test('a pin whose key is not the key the own list showed stays and is '
        'reported', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      // The own list names the sibling's id with another key.
      await setUpRig();
      rig.keys.own.add(rigKeyDevice(sibling.idString, other.key));
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      expectedErrors = ['removalQueue.keyMismatch'];

      await removeAndSettle(sibling);
      await runner.runPass();

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
    });
  });

  group('a retry of a removal whose outcome is unknown (CR Minor 1)', () {
    test('removeDevice finishes the intent although the own list no longer '
        'names the device', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // The server removed it, but the answer was lost.
      rig.keys.onRemoved = () async {
        rig.keys.onRemoved = null;
        throw const NetworkException('rig: the answer was lost');
      };
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      expect(rig.keys.own.any((d) => d.deviceId == sibling.idString), isFalse);
      expect(requests(), isEmpty);

      // The user tries again.
      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls, hasLength(2));
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });
  });

  group('a leftover intent in a pass (CR Minor 2)', () {
    /// An intent whose RemoveKeyDevice outcome is unknown.
    Future<RigPeer> unknownIntent() async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      rig.keys.removeError = const NetworkException('rig: timed out');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      return sibling;
    }

    test('a definite refusal drops the intent', () async {
      final sibling = await unknownIntent();
      rig.keys.removeError = const ValidationException('rig');

      await runner.runPass();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
      rig.keys.removeError = null;
      await runner.runPass();
      expect(rig.keys.removeCalls, hasLength(2), reason: 'not sent again');
      expect(runner.queuedFor(_c1), isEmpty);
    });

    test('RATE_LIMITED keeps the intent until the retry time, with one '
        'timer', () async {
      final sibling = await unknownIntent();
      rig.keys.removeError = const RateLimitedException(
        'rig',
        retryAfter: Duration(minutes: 10),
      );

      await runner.runPass();
      expect(rig.keys.removeCalls, hasLength(2));
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(runnerScheduled.where((s) => !s.cancelled), hasLength(1));
      expect(runnerScheduled.last.delay, const Duration(minutes: 10));

      // Not sooner, whoever asks.
      rig.keys.removeError = null;
      rig.clock.advance(const Duration(minutes: 5));
      await runner.runPass();
      await runner.onAppResumed();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(2));

      rig.clock.advance(const Duration(minutes: 5));
      await runTimer();
      expect(rig.keys.removeCalls, hasLength(3));
      expect(queued(_c1, sibling), isTrue);
    });

    test('wasRemovedByUser does not answer from a queue entry alone', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      // Queued, with no removal by the user behind it.
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRemovalQueue,
          RemovalQueue(
            entries: [
              RemovalQueueEntry(deviceId: sibling.id, conversationId: _c1),
            ],
          ).encode(),
        ),
      );

      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
      expect(queued(_c1, sibling), isTrue);
    });
  });
}
