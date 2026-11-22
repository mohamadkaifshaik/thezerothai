import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's fix-round-2 tests (Task 11 whole-branch review CR and
// security audit SA): containment of a removed device in every case the
// earlier rounds left open. The other files are removal_queue_runner_test.dart,
// removal_queue_runner_recovery_test.dart and
// removal_queue_runner_lost_own_test.dart.

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

  group('the removed mark does not skip the key history (fix round 4, SA '
      'N2)', () {
    /// The sibling, added by bob while this device was behind, is pinned
    /// unattributed and queued with a mark carrying its key; then the
    /// conversation's key history answers `unrecorded` for it (held, not
    /// admitted). [tainted]: it answers `tainted` instead (the id was seen
    /// with another key; fix round 5, ruling 1).
    Future<RigPeer> markedButUnrecorded({bool tainted = false}) async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      await removeAndSettle(sibling);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
      expect(requests(), isEmpty);
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key)],
        held: tainted ? const [] : [(sibling.id, sibling.key)],
        changed: tainted ? [sibling.id] : const [],
        closed: !tainted,
      );
      return sibling;
    }

    test('a tainted pair: a pass keeps the entry and reports it (fix round '
        '5, m1)', () async {
      final sibling = await markedButUnrecorded(tainted: true);
      expectedErrors = ['removalQueue.keyHistory'];

      await runner.runPass();
      await runner.runPass();

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
    });

    test('a tainted pair a readable list shows: reconcile keeps it, as M2 '
        'would (fix round 5, m1)', () async {
      final sibling = await markedButUnrecorded(tainted: true);
      // Bob's list now shows the sibling's very (id, key) pair.
      rig.keys.peers['ref-bob']!.add(
        rigKeyDevice(sibling.idString, sibling.key),
      );
      await rig.directory.peer('ref-bob', fresh: true);
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);

      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
    });

    test('a pass keeps the entry and reports it', () async {
      final sibling = await markedButUnrecorded();
      expectedErrors = ['removalQueue.keyHistory'];

      await runner.runPass();
      await runner.runPass();

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
    });

    test('the upkeep\'s reconcile keeps it too', () async {
      final sibling = await markedButUnrecorded();
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

    test('a second removeDevice of the same id joins the one being sent '
        '(fix round 4, CR2 Nit)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      final answer = Completer<void>();
      rig.keys.onRemoved = () async {
        rig.keys.onRemoved = null;
        await answer.future;
      };

      final first = runner.removeDevice(sibling.idString);
      while (rig.keys.removeCalls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      // The user taps again while the first call is in flight.
      final second = runner.removeDevice(sibling.idString);
      answer.complete();
      await Future.wait([first, second]);
      await runner.idle();

      expect(rig.keys.removeCalls, hasLength(1), reason: 'sent once');
      expect(await pin(sibling), isNull);
      expect(requests(_c1), hasLength(1));
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

    test('the removed-mark cap never refuses a removal: 20 unexpired marks '
        'for devices pinned nowhere, and a 21st removal reaches the server '
        'and the groups; the oldest mark makes room (fix round 4, SA '
        'N1)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      final then = rig.clock.now();
      await putRecord(
        RemovalRecord(
          removed: [
            for (var i = 0; i < kMaxRemovalIntents; i++)
              mark(i, then.add(Duration(minutes: i))),
          ],
        ),
      );
      rig.clock.advance(const Duration(hours: 1));

      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      final removed = [
        for (final m in (await storedRecord()).removed) m.deviceId,
      ];
      expect(removed, hasLength(kMaxRemovalIntents));
      expect(removed, isNot(contains(mark(0, then).deviceId)));
      expect(removed, contains(mark(1, then).deviceId));
      expect(removed, contains(sibling.idString));
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test('when every mark is still needed, the removal still goes and is '
        'queued without a mark (fix round 4, SA N1)', () async {
      const c2 = '22222222222222222222222222222222';
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      final now = rig.clock.now();
      await putRecord(
        RemovalRecord(
          removed: [for (var i = 0; i < kMaxRemovalIntents; i++) mark(i, now)],
        ),
      );
      // Each marked device still has a queue entry (an unaccepted request).
      await stateOnly(c2, accepted: false);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRemovalQueue,
          RemovalQueue(
            entries: [
              for (var i = 0; i < kMaxRemovalIntents; i++)
                RemovalQueueEntry(
                  deviceId: rigBytes(mark(i, now).deviceId),
                  conversationId: c2,
                  parked: true,
                ),
            ],
          ).encode(),
        ),
      );
      expectedErrors = ['removalQueue.markCap'];

      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(await pin(sibling), isNull, reason: 'left the group');
      final removed = (await storedRecord()).removed;
      expect(removed, hasLength(kMaxRemovalIntents));
      expect([
        for (final m in removed) m.deviceId,
      ], isNot(contains(sibling.idString)));
      // The 20 parked entries, and the sibling's own (c2 has group state).
      expect(runner.queuedFor(c2), hasLength(kMaxRemovalIntents + 1));
      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
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

    test('a queue-wide rate limit answered after reset() and a reload '
        'stores no notBeforeMicros and arms no timer (fix round 4, CR2 '
        'M-3)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'rig',
          retryAfter: Duration(hours: 5),
        ),
        stored: false,
      ));
      // Sign-out while the commit is in flight, and the next run loads the
      // stored queue before the answer arrives.
      var hooked = false;
      bool? reloaded;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || hooked) return;
        hooked = true;
        runner.reset();
        reloaded = await runner.wasRemovedByUser(sibling.id);
      };

      await removeAndSettle(sibling);
      expect(reloaded, isTrue);
      expect((await stored())!.notBeforeMicros, isNull);
      expect(runnerScheduled.where((s) => !s.cancelled), isEmpty);

      // The next run starts: nothing holds it.
      await runner.onVaultReady();
      await runner.idle();

      expect((await stored())!.notBeforeMicros, isNull);
      expect(runnerScheduled.where((s) => !s.cancelled), isEmpty);
      expect(requests(_c1), hasLength(2));
      expect(await pin(sibling), isNull);
    });

    test('a pass that outlives reset() and a reload during its catch-up '
        'makes no commit (fix round 4, CR2 M-2)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // Sign-out, then the next run loads the stored queue again, while the
      // old pass's catch-up lists.
      var hooked = false;
      bool? reloaded;
      rig.server.onCall = (call) async {
        if (call != 'listConversationCommits' || hooked) return;
        hooked = true;
        runner.reset();
        reloaded = await runner.wasRemovedByUser(sibling.id);
      };

      await removeAndSettle(sibling);

      expect(hooked, isTrue);
      expect(reloaded, isTrue, reason: 'the next run loaded the queue');
      expect(requests(), isEmpty, reason: 'the old pass commits nothing');
      expect(queued(_c1, sibling), isTrue);
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
}
