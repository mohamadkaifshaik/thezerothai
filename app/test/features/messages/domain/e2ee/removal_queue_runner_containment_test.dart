import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
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

    test('the upkeep\'s reconcile keeps a pin whose key is not the key the '
        'own list showed (fix round 4, CR2 I-1)', () async {
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
      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);

      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
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

  group('the intent being sent (CR Minor 3)', () {
    test('a pass that starts while the intent is being stored leaves it to '
        'removeDevice', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await runner.onVaultReady();
      await runner.idle();
      // The intent's write is the first one asked for: a pass starts then.
      var hooked = false;
      rig.device.onWriteAsked = () {
        if (hooked) return;
        hooked = true;
        unawaited(runner.runPass());
      };

      await removeAndSettle(sibling);

      expect(hooked, isTrue);
      expect(rig.keys.removeCalls, hasLength(1), reason: 'sent once');
      expect(queued(_c1, sibling), isTrue);
    });
  });

  group('the record\'s caps (CR Minor 4, SA L1, SA L4)', () {
    RemovalMark mark(int i, DateTime at) => RemovalMark(
      deviceId: 'capped-device-${i.toString().padLeft(4, '0')}',
      atMicros: at.microsecondsSinceEpoch,
    );

    Future<void> putRecord(RemovalRecord record) =>
        rig.device.vault.transaction(
          (tx) => tx.putSetting(kVaultSettingRemovalRecord, record.encode()),
        );

    Future<RemovalRecord> storedRecord() async => RemovalRecord.decode(
      (await rig.device.vault.setting(kVaultSettingRemovalRecord))!,
    );

    test('at the intent cap a new removal is refused; nothing is sent and no '
        'intent is dropped', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      final now = rig.clock.now();
      await putRecord(
        RemovalRecord(
          intents: [for (var i = 0; i < kMaxRemovalIntents; i++) mark(i, now)],
        ),
      );
      expectedErrors = ['removalQueue.intentCap'];

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<StateError>()),
      );

      expect(rig.keys.removeCalls, isEmpty);
      final intents = (await storedRecord()).intents;
      expect(intents, hasLength(kMaxRemovalIntents));
      expect(intents.first.deviceId, mark(0, now).deviceId);
    });

    test('at the removed-mark cap a new removal is refused, after the expired '
        'marks are pruned', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      final then = rig.clock.now();
      await putRecord(
        RemovalRecord(
          removed: [for (var i = 0; i < kMaxRemovalIntents; i++) mark(i, then)],
        ),
      );
      expectedErrors = ['removalQueue.intentCap'];

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<StateError>()),
      );
      expect(rig.keys.removeCalls, isEmpty);
      expect(
        await runner.wasRemovedByUser(rigBytes(mark(0, then).deviceId)),
        isTrue,
      );

      // Once those marks expire they are pruned first, and it goes.
      rig.clock.advance(kRemovedByUserLimit + const Duration(minutes: 1));
      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls, hasLength(1));
      final removed = (await storedRecord()).removed;
      expect([for (final m in removed) m.deviceId], [sibling.idString]);
    });

    test('expired marks are pruned when the record is loaded', () async {
      await setUpRig();
      final now = rig.clock.now();
      await putRecord(
        RemovalRecord(
          removed: [
            mark(
              1,
              now.subtract(kRemovedByUserLimit + const Duration(hours: 1)),
            ),
            mark(2, now),
          ],
        ),
      );

      await runner.onVaultReady();
      await runner.idle();

      final removed = (await storedRecord()).removed;
      expect([for (final m in removed) m.deviceId], [mark(2, now).deviceId]);
    });
  });

  group('reset during an attempt (CR Minor 5)', () {
    test('a rate limit answered after reset() stores no hold and arms no '
        'timer', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'rig',
          retryAfter: Duration(hours: 5),
          limitName: kLimitCommitsPerConversationDaily,
        ),
        stored: false,
      ));
      // Sign-out while the commit is in flight.
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') runner.reset();
      };

      await removeAndSettle(sibling);

      expect(requests(_c1), hasLength(1));
      expect(runnerScheduled.where((s) => !s.cancelled), isEmpty);
      expect(runner.queuedFor(_c1), isEmpty);
      expect(runner.pending.value, 0);
    });
  });

  group('a parked entry (CR Minor 6)', () {
    test('a pass lets go of a parked entry whose device is no longer pinned, '
        'with no call', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await removeAndSettle(sibling);
      expect((await stored())!.entries.single.parked, isTrue);
      // Bob's commit removed it, and this device applied it.
      await bobRemoves(_c1, [sibling.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(sibling), isNull);
      final calls = rig.server.calls.length;

      await runner.runPass();

      expect(runner.queuedFor(_c1), isEmpty);
      expect(runner.pending.value, 0);
      expect((await stored())!.entries, isEmpty);
      expect(rig.server.calls, hasLength(calls), reason: 'no call');
    });
  });

  group('a prune on pins this device has not caught up (fix round 3, '
      'F1)', () {
    test('a peer commit that adds the device is not applied yet: the prune '
        'keeps the entry; after the catch-up the device leaves', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      // Bob adds the user's sibling; this device has not listed it.
      await bobAdds(_c1, [sibling]);
      // A new run (no catch-up yet), and the thread cannot be answered:
      // the pass parks the entry with a prune from the stored pins, which
      // do not name the sibling yet.
      // (Accepted long before this run, so attribution concludes, as in
      // bobAdds.)
      rig.contexts.clear();
      rig.contexts.of(_c1)
        ..canReply = false
        ..acceptedSeenAt = rig.clock.now().subtract(
          kConversationCopyStale + const Duration(minutes: 1),
        );
      rig.server.rows[_c1] = headerRow(_c1, canReply: false);

      await removeAndSettle(sibling);

      expect(await pin(sibling), isNull, reason: 'not applied yet');
      expect(queued(_c1, sibling), isTrue, reason: 'the entry stays');
      expect((await stored())!.entries.single.parked, isTrue);

      // The thread can be answered again: un-parked; the pass catches up
      // (bob's add pins the sibling unattributed) and takes it out (the
      // commit may wait for the next pass: fix round 3, F2).
      rig.server.rows[_c1] = headerRow(_c1);
      rig.contexts.of(_c1).canReply = true;
      await runner.noteConversation(_c1);
      await runner.idle();
      await runner.runPass();

      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      expect(runner.pending.value, 0);
    });

    test('a pass that cannot catch up keeps the entry while the listed '
        'server pair is ahead', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      // The group's pair is behind the pair the last listing answered.
      final context = rig.contexts.of(_c1);
      context
        ..serverPair = rig.server.current(_c1)
        ..serverPairFresh = true
        ..canReply = false;
      rig.server.rows[_c1] = headerRow(_c1, canReply: false);

      await removeAndSettle(sibling);

      expect(queued(_c1, sibling), isTrue);
      expect(rig.server.calls.where((c) => c == 'commitConversation'), isEmpty);
    });

    test('caught up, then parked, then a peer add lands: the prune drops the '
        'entry, a later pass queues the marked pin again, and the device '
        'leaves after the un-park', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      // The thread cannot be answered; bob's add lands after the last
      // listing, so the stored pins are at the last listed pair.
      rig.contexts.of(_c1).canReply = false;
      rig.server.rows[_c1] = headerRow(_c1, canReply: false);
      await bobAdds(_c1, [sibling]);

      await removeAndSettle(sibling);

      expect(queued(_c1, sibling), isFalse, reason: 'dropped by the prune');
      expect(requests(), isEmpty);

      // The thread can be answered again; a sync applies bob's add (the
      // sibling is pinned unattributed: the own list no longer names it).
      rig.server.rows[_c1] = headerRow(_c1);
      rig.contexts.of(_c1).canReply = true;
      await runner.noteConversation(_c1);
      await runner.idle();
      await synced();
      expect((await pin(sibling))!.side, MemberSide.unattributed);

      // Ruling 1 gap (option B): the pass queues the marked pin again.
      await runner.runPass();
      await runner.runPass();

      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      expect(runner.pending.value, 0);
    });

    test('an unattributed pin whose key is not its mark\'s is not queued again '
        'and is reported', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      // The own list names the sibling's id with another key.
      await setUpRig();
      rig.keys.own.add(rigKeyDevice(sibling.idString, other.key));
      await join(_c1);
      await synced();
      rig.contexts.of(_c1).canReply = false;
      rig.server.rows[_c1] = headerRow(_c1, canReply: false);
      await bobAdds(_c1, [sibling]);
      await removeAndSettle(sibling);
      expect(queued(_c1, sibling), isFalse);
      rig.server.rows[_c1] = headerRow(_c1);
      rig.contexts.of(_c1).canReply = true;
      await synced();
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expectedErrors = ['removalQueue.keyMismatch'];

      await runner.runPass();

      expect(queued(_c1, sibling), isFalse);
      expect(requests(), isEmpty);
    });
  });

  group('an own device removed on another own device (SA M2)', () {
    /// The user's other phone removed the sibling: the own list no longer
    /// names it, and this device never ran removeDevice.
    Future<RigPeer> removedElsewhereByUser() async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      expect((await pin(sibling))!.side, MemberSide.mine);
      rig.keys.own.removeWhere((d) => d.deviceId == sibling.idString);
      return sibling;
    }

    test('a pass queues a mine pin a fresh own list does not show, and '
        'removes it', () async {
      final sibling = await removedElsewhereByUser();

      await runner.onVaultReady();
      await runner.idle();

      expect(rig.keys.removeCalls, isEmpty);
      expect(requests(_c1), hasLength(1));
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
    });

    test('it is not user-queued: the M5 pause holds it', () async {
      final sibling = await removedElsewhereByUser();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }

      await runner.onVaultReady();
      await runner.idle();

      expect(requests(), isEmpty);
      expect(queued(_c1, sibling), isTrue);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('reconcile exempts a queued removal from the pause only when the '
        'user removed the device', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      // Queued; the own list reconcile reads still shows it (M3 says no).
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      rig.upkeep.removedByUser = (_) => false;

      await rig.upkeep.reconcile(_c1);
      expect(requests(), isEmpty, reason: 'held by the pause');

      rig.upkeep.removedByUser = (_) => true;
      await rig.upkeep.reconcile(_c1);
      expect(requests(_c1), hasLength(1));
      expect(await pin(sibling), isNull);
    });

    test('a mine pin the own list still shows is never queued', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();

      await runner.onVaultReady();
      await runner.idle();

      expect(runner.queuedFor(_c1), isEmpty);
      expect(requests(), isEmpty);
    });
  });
}
