import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// Plan 5a Task 12 with lane D PR 2 (removal design section 4, "Task 11
// queue"): the queue's RemoveKeyDevice is a removal of ANOTHER device, sent
// with REMOVE_REASON_REMOTE; a first call answered REAUTH_REQUIRED parks
// its intent and asks the UI for a re-sign-in (brief amendment 3).

const _c1 = '11111111111111111111111111111111';

/// The runner's stored record (opened); null when absent.
Future<RemovalRecord?> storedRecord() async {
  final raw = await rig.device.vault.setting(kVaultSettingRemovalRecord);
  return raw == null ? null : RemovalRecord.decode(raw);
}

void main() {
  tearDown(removalQueueTearDown);

  test('the queue sends REMOTE', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpRig(ownListed: [sibling]);
    await join(_c1, others: [sibling]);
    await synced();

    await removeAndSettle(sibling);

    final call = rig.keys.removeCalls.single;
    expect(call.deviceId, sibling.idString);
    expect(call.reason, kpb.RemoveReason.REMOVE_REASON_REMOTE);
    expect(await pin(sibling), isNull);
    expect(runner.needsReauth.value, isFalse);
  });

  test('removed elsewhere, a pass sends no RemoveKeyDevice and no commit; '
      'once the fact clears it does (fix round 1, M4)', () async {
    final sibling = await RigPeer.create('sibling');
    final other = await RigPeer.create('other');
    await setUpRig(ownListed: [sibling, other]);
    await join(_c1, others: [sibling, other]);
    await synced();
    final now = rig.clock.now().microsecondsSinceEpoch;
    // A queued removal of the sibling (with its mark) and a leftover
    // intent for the other device, whose outcome is unknown.
    await rig.device.vault.transaction((tx) async {
      await tx.putSetting(
        kVaultSettingRemovalQueue,
        RemovalQueue(
          entries: [
            RemovalQueueEntry(deviceId: sibling.id, conversationId: _c1),
          ],
        ).encode(),
      );
      await tx.putSetting(
        kVaultSettingRemovalRecord,
        RemovalRecord(
          intents: [
            RemovalMark(
              deviceId: other.idString,
              atMicros: now,
              signatureKey: other.key,
            ),
          ],
          removed: [
            RemovalMark(
              deviceId: sibling.idString,
              atMicros: now,
              signatureKey: sibling.key,
            ),
          ],
        ).encode(),
      );
    });
    rig.keys.own.removeWhere((d) => d.deviceId == sibling.idString);
    runner = build();
    rig.removedElsewhere = true;

    await runner.runPass();
    await runner.idle();

    expect(rig.keys.removeCalls, isEmpty);
    expect(requests(), isEmpty);
    expect((await pin(sibling))!.side, MemberSide.mine);

    rig.removedElsewhere = false;
    await runner.runPass();
    await runner.idle();

    expect(rig.keys.removeCalls.map((c) => c.deviceId), [other.idString]);
    expect(requests(_c1), isNotEmpty);
  });

  test('removed elsewhere, the user removal is refused before any read or '
      'call, and stores nothing (fix wave 2, SA M2)', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpRig(ownListed: [sibling]);
    await join(_c1, others: [sibling]);
    await synced();
    final lists = rig.keys.listCalls;
    final before = await rig.dump();
    rig.removedElsewhere = true;

    await expectLater(
      runner.removeDevice(sibling.idString),
      throwsA(isA<StateError>()),
    );
    await runner.idle();

    expect(rig.keys.removeCalls, isEmpty);
    expect(rig.keys.listCalls, lists);
    expect(await storedRecord(), isNull);
    expect(await rig.dump(), before);
    expect(await runner.wasRemovedByUser(sibling.id), isFalse);
  });

  test('an unknown fact (an unreadable marker) stops the pipeline but still '
      'lets the user remove a lost device (final round 5, SA L8)', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpRig(ownListed: [sibling]);
    await join(_c1, others: [sibling]);
    await synced();
    // stopsPipeline is true; the definite fact (a DEVICE_REMOVED answer)
    // is not.
    rig.removedElsewhere = true;
    rig.removedDefinitely = false;

    await runner.removeDevice(sibling.idString);
    await runner.idle();

    expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
    expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    // The queued commit still waits for the pipeline.
    expect(requests(), isEmpty);
  });

  group('REAUTH_REQUIRED (brief amendment 3)', () {
    test('a new removal answered REAUTH_REQUIRED parks its intent, never '
        'drops it, and asks for a re-sign-in; after it the same call '
        'finishes', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      await runner.idle();

      expect(runner.needsReauth.value, isTrue);
      // Parked, not dropped: the stored intent still answers.
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      expect((await storedRecord())!.intents.map((i) => i.deviceId), [
        sibling.idString,
      ]);
      expect(requests(), isEmpty);

      // A pass does not send it again while it waits for the sign-in.
      await runner.runPass();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(1));

      // The user signed in again and confirms: the call goes, and queues.
      rig.keys.removeError = null;
      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls, hasLength(2));
      expect(
        rig.keys.removeCalls.last.reason,
        kpb.RemoveReason.REMOVE_REASON_REMOTE,
      );
      expect(runner.needsReauth.value, isFalse);
      expect(await pin(sibling), isNull);
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test("a stored intent's retry answered REAUTH_REQUIRED keeps the "
        'intent and asks for a re-sign-in', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // The first call's outcome is unknown: an intent is left.
      rig.keys.removeError = const NetworkException('rig: offline');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();

      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await runner.runPass();
      await runner.idle();

      expect(rig.keys.removeCalls, hasLength(2));
      expect(runner.needsReauth.value, isTrue);
      expect((await storedRecord())!.intents.map((i) => i.deviceId), [
        sibling.idString,
      ]);
      // The own list still names it, but a REAUTH answer settles nothing.
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);

      await runner.runPass();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(2));

      // A reset (sign-out) forgets the ask; the intent stays stored.
      runner.reset();
      expect(runner.needsReauth.value, isFalse);
    });

    test('REAUTH_REQUIRED while the record cannot be read (the rebuild path, '
        'no intent stored) still asks for a re-sign-in (fix round 1, '
        'M3)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
      );
      expectedErrors = ['removalQueue.read', 'removalQueue.rebuilt'];
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(runner.needsReauth.value, isTrue);
      expect(runner.unreadable, isTrue);

      // The user signs in again and asks again: sent, rebuilt, cleared.
      rig.keys.removeError = null;
      await removeAndSettle(sibling);
      expect(runner.needsReauth.value, isFalse);
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test('dropRemoval refuses an intent that is not waiting for a re-sign-in, '
        'and one whose call is in flight (final round 4, CR Nit 6)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // An ordinary intent: its outcome is unknown, no re-sign-in asked.
      rig.keys.removeError = const NetworkException('rig: offline');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();
      await expectLater(
        runner.dropRemoval(sibling.idString),
        throwsA(isA<StateError>()),
      );
      expect((await storedRecord())!.intents, hasLength(1));

      // Parked now; the user signs in again and asks: while that call is
      // in flight the removal cannot be dropped.
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await runner.runPass();
      await runner.idle();
      expect(runner.needsReauth.value, isTrue);
      rig.keys.removeError = null;
      Object? inFlight;
      rig.keys.onRemoved = () async {
        try {
          await runner.dropRemoval(sibling.idString);
        } on Object catch (e) {
          inFlight = e;
        }
      };
      await removeAndSettle(sibling);
      rig.keys.onRemoved = null;

      expect(inFlight, isA<StateError>());
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test('a rebuild-path ask survives a later pass that loads a readable '
        'record (fix wave 10, CR Nit 3)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalRecord, rigBytes('not json')),
      );
      expectedErrors = ['removalQueue.read'];
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(runner.needsReauth.value, isTrue);

      // The record reads again (an empty one); a pass loads it.
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRemovalRecord,
          const RemovalRecord().encode(),
        ),
      );
      await runner.runPass();
      await runner.idle();

      expect(runner.needsReauth.value, isTrue);
    });

    test('a parked intent is never dropped for its age and keeps the ask, '
        'also after a restart (fix wave 9, SA L5)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      await runner.idle();
      expect((await storedRecord())!.intents.single.reauth, isTrue);

      // Past the intent limit, and a new run (the app restarted).
      rig.clock.advance(kRemovalIntentLimit + const Duration(days: 1));
      runner.reset();
      runner = build();
      await runner.runPass();
      await runner.idle();

      expect((await storedRecord())!.intents.map((i) => i.deviceId), [
        sibling.idString,
      ]);
      expect(runner.needsReauth.value, isTrue);
      // Parked from the stored record: not sent again before the sign-in.
      expect(rig.keys.removeCalls, hasLength(1));
    });

    test('the user drops a parked removal: the intent goes and the ask '
        'clears (fix wave 9, SA L5)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(runner.needsReauth.value, isTrue);

      await runner.dropRemoval(sibling.idString);

      expect(runner.needsReauth.value, isFalse);
      expect((await storedRecord())!.intents, isEmpty);
      await runner.runPass();
      await runner.idle();
      expect(rig.keys.removeCalls, hasLength(1));
    });

    test('parkedRefs lists every removal waiting for a re-sign-in, and is '
        'emptied by its call, by dropRemoval and by reset (port '
        'additions)', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      await setUpRig(ownListed: [sibling, other]);
      await join(_c1, others: [sibling, other]);
      await synced();
      expect(runner.parkedRefs.value, isEmpty);
      final seen = <List<String>>[];
      void note() => seen.add(runner.parkedRefs.value);
      runner.parkedRefs.addListener(note);
      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      for (final p in [sibling, other]) {
        await expectLater(
          runner.removeDevice(p.idString),
          throwsA(isA<ReauthRequiredException>()),
        );
      }
      expect(runner.parkedRefs.value.toSet(), {
        sibling.idString,
        other.idString,
      });
      // The second park changed the list, not needsReauth: it was heard.
      expect(seen.last.toSet(), {sibling.idString, other.idString});

      rig.keys.removeError = null;
      await removeAndSettle(sibling);
      expect(runner.parkedRefs.value, [other.idString]);
      expect(runner.needsReauth.value, isTrue);

      await runner.dropRemoval(other.idString);
      expect(runner.parkedRefs.value, isEmpty);
      expect(runner.needsReauth.value, isFalse);

      rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      final third = await RigPeer.create('third');
      rig.keys.own.add(rigKeyDevice(third.idString, third.key));
      await expectLater(
        runner.removeDevice(third.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(runner.parkedRefs.value, [third.idString]);
      runner.reset();
      expect(runner.parkedRefs.value, isEmpty);
      runner.parkedRefs.removeListener(note);
    });
  });

  group('other_sessions_ended (port additions, lane D)', () {
    for (final ended in [true, false]) {
      test('removeDevice answers the server\'s other_sessions_ended '
          '($ended), and a joined call answers the same', () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await join(_c1, others: [sibling]);
        await synced();
        rig.keys.otherSessionsEnded = ended;
        final answer = Completer<void>();
        rig.keys.onRemoved = () async {
          rig.keys.onRemoved = null;
          await answer.future;
        };

        final first = runner.removeDevice(sibling.idString);
        while (rig.keys.removeCalls.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        final second = runner.removeDevice(sibling.idString);
        answer.complete();
        expect(await first, ended);
        expect(await second, ended);
        await runner.idle();
        expect(rig.keys.removeCalls, hasLength(1));
      });
    }

    // Remover copy (controller ruling 2026-11-27, H1 option b): the outbox.
    // A stored removal sent again by a pass has no screen waiting for its
    // answer, so a true answer is reported for the vault's uid (production:
    // the auth bloc signs this device out at once).
    for (final ended in [true, false]) {
      test('a stored intent a pass sends again reports '
          'other_sessions_ended $ended '
          '${ended ? 'with the vault uid' : 'not at all'}', () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        final seen = <String>[];
        runner = build(onRemovalSignedOutAll: seen.add);
        await join(_c1, others: [sibling]);
        await synced();
        rig.keys.otherSessionsEnded = ended;
        // The first answer is lost: the intent stays stored.
        rig.keys.removeError = const NetworkException('rig: offline');
        await expectLater(
          runner.removeDevice(sibling.idString),
          throwsA(isA<NetworkException>()),
        );
        await runner.idle();
        expect(seen, isEmpty);
        rig.keys.removeError = null;

        await runner.runPass();
        await runner.idle();
        expect(rig.keys.removeCalls, hasLength(2));
        expect(seen, ended ? [rig.device.session.vault!.uid] : isEmpty);
        expect(await runner.wasRemovedByUser(sibling.id), isTrue);
      });
    }

    // Fix round 1, R2 (security M1): reported only once the removal is
    // stored, so a stored intent fires it at most once.
    test('the outbox report fires only after the save, and once', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      final seen = <String>[];
      runner = build(onRemovalSignedOutAll: seen.add);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.otherSessionsEnded = true;
      rig.keys.removeError = const NetworkException('rig: offline');
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();
      rig.keys.removeError = null;

      // The pass's save of the removal fails: no report yet.
      rig.device.failNextWriteAsked = true;
      try {
        await runner.runPass();
      } catch (_) {
        // The failed write may surface; the intent is what matters.
      }
      await runner.idle();
      expect(rig.device.writesRefused, 1);
      expect(seen, isEmpty);

      // The report stays owed; the next pass's successful save stores the
      // removal and reports once.
      await runner.runPass();
      await runner.idle();
      expect(seen, [rig.device.session.vault!.uid]);

      // Gone from storage: a later pass never reports it again.
      await runner.runPass();
      await runner.idle();
      expect(seen, hasLength(1));
    });

    test('a removeDevice answer is the caller\'s: it is never reported '
        '(the screen shows the result, then signs out)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      final seen = <String>[];
      runner = build(onRemovalSignedOutAll: seen.add);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.otherSessionsEnded = true;
      expect(await runner.removeDevice(sibling.idString), isTrue);
      await runner.idle();
      expect(seen, isEmpty);
    });

    test('a stored intent finished although its retry was refused answers '
        'null: no answer of the server says it', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.otherSessionsEnded = true;
      // The server removed it, but the answer was lost.
      rig.keys.onRemoved = () async {
        rig.keys.onRemoved = null;
        throw const NetworkException('rig: the answer was lost');
      };
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();
      rig.keys.removeError = const ValidationException('rig: refused');

      expect(await runner.removeDevice(sibling.idString), isNull);
      await runner.idle();
      expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    });
  });
}
