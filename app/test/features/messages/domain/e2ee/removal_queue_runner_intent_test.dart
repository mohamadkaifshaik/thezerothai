import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's intent tests (Task 11 review M1; whole-branch review
// CR Minor 1 and 2; fix round 4, ruling 2; fix round 5, ruling 4): a
// removal whose RemoveKeyDevice outcome is unknown, its retry, and a
// definite refusal of that retry. A pure move out of
// removal_queue_runner_containment_test.dart (fix round 5, file size).

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

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

  group('a definite refusal of a retried intent (fix round 4, CR2 I-2)', () {
    /// A stored intent for the sibling. [carriedOut]: the server removed it
    /// and the answer was lost; otherwise the call failed before it.
    Future<RigPeer> storedIntent({required bool carriedOut}) async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      if (carriedOut) {
        rig.keys.onRemoved = () async {
          rig.keys.onRemoved = null;
          throw const NetworkException('rig: the answer was lost');
        };
      } else {
        rig.keys.removeError = const NetworkException('rig: offline');
      }
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();
      expect(
        rig.keys.own.any((d) => d.deviceId == sibling.idString),
        !carriedOut,
      );
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      rig.keys.removeError = const ValidationException('rig: refused');
      return sibling;
    }

    test('removeDevice: the own list still names the device, so the intent '
        'goes', () async {
      final sibling = await storedIntent(carriedOut: false);

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ValidationException>()),
      );
      await runner.idle();

      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
      expect(runner.queuedFor(_c1), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('removeDevice: a readable own list no longer names it, so it is '
        'queued with the intent\'s key and leaves the group', () async {
      final sibling = await storedIntent(carriedOut: true);

      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls, hasLength(2));
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      expect(runner.pending.value, 0);
      final record = RemovalRecord.decode(
        (await rig.device.vault.setting(kVaultSettingRemovalRecord))!,
      );
      expect(record.intents, isEmpty);
      expect(rigEq(record.removed.single.signatureKey!, sibling.key), isTrue);
    });

    test('removeDevice: an own list that cannot be read keeps the '
        'intent', () async {
      final sibling = await storedIntent(carriedOut: true);
      rig.keys.ownFails = true;

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ValidationException>()),
      );
      await runner.idle();

      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(runner.queuedFor(_c1), isEmpty);
      final record = RemovalRecord.decode(
        (await rig.device.vault.setting(kVaultSettingRemovalRecord))!,
      );
      expect(record.intents.single.deviceId, sibling.idString);
    });

    test('a pass: a readable own list no longer names it, so it is '
        'queued', () async {
      final sibling = await storedIntent(carriedOut: true);

      await runner.runPass();
      await runner.runPass();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(runner.pending.value, 0);
    });

    test('a pass: an own list that cannot be read keeps the intent', () async {
      final sibling = await storedIntent(carriedOut: true);
      rig.keys.ownFails = true;

      await runner.runPass();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect(runner.queuedFor(_c1), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.mine);
      final record = RemovalRecord.decode(
        (await rig.device.vault.setting(kVaultSettingRemovalRecord))!,
      );
      expect(record.intents.single.deviceId, sibling.idString);
      expect(record.removed, isEmpty);
    });

    test('removeDevice: the queued branch reads the own list once (fix '
        'round 5, m4)', () async {
      final sibling = await storedIntent(carriedOut: true);
      final before = rig.keys.listCalls;

      await removeAndSettle(sibling);

      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(rig.keys.listCalls, before + 1, reason: 'one fresh own list');
    });

    test('a pass: refused intents share one fresh own list (fix round 5, '
        'm4)', () async {
      final one = await RigPeer.create('sibling-one');
      final two = await RigPeer.create('sibling-two');
      await setUpRig(ownListed: [one, two]);
      await join(_c1, others: [one, two]);
      await synced();
      // The server removed both, and both answers were lost.
      rig.keys.onRemoved = () async =>
          throw const NetworkException('rig: the answer was lost');
      for (final p in [one, two]) {
        await expectLater(
          runner.removeDevice(p.idString),
          throwsA(isA<NetworkException>()),
        );
      }
      rig.keys.onRemoved = null;
      rig.keys.removeError = const ValidationException('rig: refused');
      final before = rig.keys.listCalls;

      await runner.runPass();

      expect(rig.keys.removeCalls, hasLength(4));
      expect(rig.keys.listCalls, before + 1, reason: 'one fresh own list');
      expect(await runner.wasRemovedByUser(one.id), isTrue);
      expect(await runner.wasRemovedByUser(two.id), isTrue);
      expect(queued(_c1, one) || await pin(one) == null, isTrue);
      expect(queued(_c1, two) || await pin(two) == null, isTrue);
    });
  });

  group('the key-history read of an attempt (fix round 5, m4)', () {
    test('an unattributed pin that is not queued with a mark reads no key '
        'history', () async {
      final sibling = await RigPeer.create('sibling');
      final stranger = await RigPeer.create('stranger');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // A member no list attributes, not queued.
      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: stranger.id,
            signatureKey: stranger.key,
            side: MemberSide.unattributed,
            since: rig.server.current(_c1),
          ),
        ),
      );
      // The key history cannot be read: any read of it is reported.
      await rig.device.vault.transaction(
        (tx) => tx.putSetting('messages.e2ee.keys.$_c1', rigBytes('not json')),
      );
      expect(rig.keyHistoryErrors, isEmpty);
      // No commit is built (the daily call cap): only the attempt's own
      // read could report.
      await updateSync(
        (s) => s.copyWith(
          commitCallsDay: istDay(rig.clock.now()),
          commitCallsToday: kCommitCallsPerConversationPerDay,
        ),
      );

      await removeAndSettle(sibling);

      expect(rig.keyHistoryErrors, isEmpty, reason: 'no key-history read');
      expect(queued(_c1, sibling), isTrue);
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
