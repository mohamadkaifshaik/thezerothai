import 'dart:async';
import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart'
    show kCommitCallsPerConversationPerDay, kRequestInFlightMargin;
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/e2ee_reset_harness.dart';

const _c1 = '11111111111111111111111111111111';
const _bob = 'ref-bob';
const _me = 'user-a';

void main() {
  // The shared state and helpers (`e2ee_reset_harness.dart`, review m-7).
  registerResetHarness();

  group('who may reset, and when', () {
    test('reset throws FeatureDisabledException with the flag off or unknown '
        'and nothing is claimed', () async {
      await setUpJoined();
      await makeStuck();
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        await rig.device.session.onFlagChanged(flag, uid: _me);
        await expectLater(reset(), throwsA(isA<FeatureDisabledException>()));
      }
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.keys.getCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
      expect(await groupAt(2), isNull);
    });

    test('reset is refused in an unaccepted conversation', () async {
      await setUpJoined();
      await makeStuck();
      await rig.device.vault.transaction(
        (tx) async => tx.putConversationSync(
          _c1,
          (await sync()).copyWith(requestAccepted: false),
        ),
      );
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.notAccepted,
          ),
        ),
      );
      expect((await state()).canReset, isFalse);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
    });

    test('a waiting device may not reset at 23 h 59 min and may at 24 h, '
        'counted from the first sighting of that generation', () async {
      await setUpJoined();
      // Bob reset into generation 2 without this device.
      await bobResets(1, addMe: false);
      final first = rig.clock.now();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      rig.clock.advance(const Duration(hours: 1));
      // A later sighting does not move the first one.
      await rig.crypto.catchUp(_c1);
      expect(
        (await sync()).firstSawGenerationAtMicros,
        first.microsecondsSinceEpoch,
      );
      rig.clock.value = first.add(
        const Duration(hours: 23, minutes: 59, seconds: 59),
      );
      var s = await state();
      expect(s.phase, ConversationPhase.waitingForWelcome);
      expect(s.resetAllowedAt, first.add(kResetWaitWithoutWelcome));
      expect(s.canReset, isFalse);
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.unavailable,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);

      rig.clock.value = first.add(kResetWaitWithoutWelcome);
      s = await state();
      expect(s.canReset, isTrue);
      await reset();
      // The server is at generation 2: the reset names it and makes 3.
      final r = resets().single;
      expect(r.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
      expect(await groupAt(1), isNull);
      expect((await state()).phase, ConversationPhase.ready);
    });

    test('canReset is true exactly for stuck, waiting past 24 h and '
        'anti-flap pause, with the flag on and the conversation '
        'accepted', () async {
      await setUpJoined();
      var s = await state();
      expect(s.phase, ConversationPhase.ready);
      expect(s.canReset, isFalse);

      // M5's pause: the anti-flap offer (amendment 8).
      await rig.ledger.addUndone(_c1);
      expect((await state()).canReset, isFalse);
      await rig.ledger.addUndone(_c1);
      s = await state();
      expect(s.committingPausedToday, isTrue);
      expect(s.canReset, isTrue);
      rig.clock.advance(const Duration(days: 1));
      expect((await state()).canReset, isFalse);

      // Stuck.
      await makeStuck();
      expect((await state()).canReset, isTrue);
      // The flag off: stuck, and it says so.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isFalse);
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      expect((await state()).canReset, isTrue);
      // Not accepted.
      final accepted = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          accepted.copyWith(requestAccepted: false),
        ),
      );
      expect((await state()).canReset, isFalse);
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(_c1, accepted),
      );
      expect((await state()).canReset, isTrue);

      // A reset in progress: never a second one.
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isFalse);
    });

    test('unavailable and peerHasNoDevice are E2eeActionException with the '
        'kind named, the commit cap a RateLimitedException (amendment '
        '9)', () async {
      await setUpJoined();
      // Not offered: a healthy conversation.
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.unavailable,
          ),
        ),
      );
      await makeStuck();
      peers([]);
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.peerHasNoDevice,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);
      // The commit cap of the conversation: a RateLimitedException, before
      // any claim.
      peers([bob]);
      await rig.device.vault.transaction(
        (tx) async => tx.putConversationSync(
          _c1,
          (await sync()).copyWith(
            commitCallsDay: istDay(rig.clock.now()),
            commitCallsToday: kCommitCallsPerConversationPerDay,
          ),
        ),
      );
      await expectLater(
        reset(),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitCommitsPerConversationDaily,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
    });
  });

  group('the reset', () {
    test('the new group id is mlsGroupId(conversation, g + 1)', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      final g2 = (await groupAt(2))!;
      final described = await rig.device.engine.inner.describe(g2.state);
      expect(rigEq(described.groupId, mlsGroupId(_c1, 2)), isTrue);
    });

    test('a reset addresses every usable device and fails peerHasNoDevice '
        'with none of the peer\'s', () async {
      final bob2 = await RigPeer.create('bob2');
      final sib = await RigPeer.create('sib');
      await setUpJoined();
      peers([bob, bob2]);
      siblings([sib]);
      await makeStuck();

      // Only bob is listed and his claim has no package: nothing is built
      // or sent.
      final real = rig.keys.claims[_bob]!;
      peers([bob]);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [kpb.ClaimedKeyPackage(deviceId: bob.idString)],
      );
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.peerHasNoDevice,
          ),
        ),
      );
      expect(await groupAt(2), isNull);
      expect(rig.server.commitRequests, isEmpty);

      // Every usable device: both of bob's and this user's other one. (Bob's
      // empty claim of today is not tried again: a fresh device is used.)
      rig.keys.peers[_bob] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(bob2.idString, bob2.key),
      ];
      rig.keys.claims[_bob] = real;
      rig.clock.advance(const Duration(days: 1));
      await reset();
      final r = resets().single;
      expect(r.welcomeDeviceIds.toSet(), {
        bob.idString,
        bob2.idString,
        sib.idString,
      });
      expect((await pin(bob2.id))!.side, MemberSide.theirs);
      expect((await pin(sib.id))!.side, MemberSide.mine);
    });

    test('the provisional group of g + 1 leaves g\'s group, pins and marks '
        'untouched until the server accepts; the pending record and the '
        'call count are stored before the call (amendment 1)', () async {
      await setUpJoined();
      await makeStuck();
      final v = rig.device.vault;
      final g1 = (await groupAt(1))!;
      final pinsBefore = [
        for (final m in await v.members(_c1))
          (m.deviceId, m.signatureKey, m.side, m.since),
      ];
      final marks = await v.conversation(_c1);
      var seen = 0;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        seen++;
        final request = rig.server.commitRequests.single;
        expect(request.reset, isTrue);
        expect(request.builtOn, const MlsPair(1, 0));
        final g2 = (await groupAt(2))!;
        expect(g2.provisional, isTrue);
        expect(g2.epoch, 1);
        final pending = g2.pending!;
        expect(pending.kind, PendingKind.reset);
        expect(pending.builtOn, const MlsPair(2, 0));
        expect(rigEq(pending.commit, request.commit), isTrue);
        expect(rigEq(pending.welcome!, request.welcome!), isTrue);
        expect(pending.welcomeDeviceIds, [bob.idString]);
        // Counted before the call.
        final s = await sync();
        expect(s.commitCallsDay, istDay(rig.clock.now()));
        expect(s.commitCallsToday, 1);
        // g is untouched.
        final now1 = (await groupAt(1))!;
        expect(rigEq(now1.state, g1.state), isTrue);
        expect(now1.epoch, g1.epoch);
        expect([
          for (final m in await v.members(_c1))
            (m.deviceId, m.signatureKey, m.side, m.since),
        ], hasLength(pinsBefore.length));
        for (final m in await v.members(_c1)) {
          expect(m.since.generation, 1);
        }
        final marksNow = await v.conversation(_c1);
        expect(marksNow?.afterPair, marks?.afterPair);
        expect(marksNow?.joinHighWater, marks?.joinHighWater);
      };
      await reset();
      expect(seen, 1);
    });

    test('success clears provisional with after-pair (g + 1, 0), deletes g '
        'and writes one encryptionReset row', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      final v = rig.device.vault;
      expect(await groupAt(1), isNull);
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(g2.pending, isNull);
      expect(g2.epoch, 1);
      final record = (await v.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(2, 0));
      final s = record.sync;
      expect(s.completedEpochs, isEmpty);
      expect(s.firstSawGeneration, isNull);
      expect(s.firstSawGenerationAtMicros, isNull);
      expect(s.epochMustAdvance, isFalse);
      expect(s.lastSelfUpdateAtMicros, rig.clock.now().microsecondsSinceEpoch);
      final resetLines = [
        for (final l in await lines())
          if (l.line == SystemLine.encryptionReset) l,
      ];
      expect(resetLines, hasLength(1));
      // The pins are g + 1's members.
      final pins = await v.members(_c1);
      expect(pins, hasLength(2));
      for (final m in pins) {
        expect(m.since, const MlsPair(2, 1));
      }
      expect((await pin(rig.device.deviceId))!.side, MemberSide.mine);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      final st = await state();
      expect(st.phase, ConversationPhase.ready);
      expect(st.canReset, isFalse);
      // The key history keeps bob, never shrinks.
      expect(
        (await rig.keyHistoryIds(_c1))[vaultDeviceIdHex(bob.id)],
        base64Encode(bob.key),
      );
    });

    test('an unchanged peer key set gives the reset line only; a new peer '
        'key also gives a deviceAdded row', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      expect(
        [for (final l in await lines()) l.line],
        [SystemLine.encryptionReset],
      );

      // A second reset (stuck again) with a new device of bob's.
      final bob2 = await RigPeer.create('bob2');
      peers([bob, bob2]);
      final garbage2 = rigBytes('a second commit no engine can process');
      rig.device.engine.failWireAlways[RigEngine.key(garbage2)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage2,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
      await reset();
      final added = [
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ];
      expect(added, hasLength(1));
      expect(rigEq(added.single.deviceId!, bob2.id), isTrue);
      expect(added.single.side, MemberSide.theirs);
      expect(
        [for (final l in await lines()) l.line]
            .where((l) => l == SystemLine.encryptionReset),
        hasLength(2),
      );
    });

    test('a key claimed on both sides is added on neither, and a device '
        'reclaimed through an unattributed pin is new: own-side and '
        'peer-side deviceAdded rows (amendment 7)', () async {
      final carol = await RigPeer.create('carol');
      final sib = await RigPeer.create('sib');
      // Carol (bob's) and sib (this user's) are in the group, in no list:
      // pinned unattributed.
      await setUpJoined(others: [carol, sib]);
      expect((await pin(carol.id))!.side, MemberSide.unattributed);
      expect((await pin(sib.id))!.side, MemberSide.unattributed);
      // Now both are listed, and a device of bob's whose key is also
      // claimed for this user's side.
      final twin = await RigPeer.create('twin');
      // A package of this user's side that names twin's key under its own
      // id (what a server could hand out): its key is claimed on both sides.
      final mineTwin = await RigPeer.create('minetwin');
      final mineTwinPackage = await mineTwin.keyPackage();
      rig.device.engine.rewriteInspect = (kp, real) =>
          rigEq(kp, mineTwinPackage)
          ? KeyPackageInfo(deviceId: mineTwin.id, signaturePublicKey: twin.key)
          : null;
      peers([bob, carol, twin]);
      rig.keys.own
        ..add(rigKeyDevice(sib.idString, sib.key))
        ..add(rigKeyDevice(mineTwin.idString, twin.key));
      rig.keys.claims[_me] = () async => kpb.ClaimKeyPackagesResponse(
        keyPackages: [
          await packageOf(sib),
          kpb.ClaimedKeyPackage(
            deviceId: mineTwin.idString,
            signaturePublicKey: twin.key,
            keyPackage: mineTwinPackage,
            hasKeyPackage_4: true,
          ),
        ],
      );
      await makeStuck();
      await reset();
      final r = resets().single;
      expect(r.welcomeDeviceIds.toSet(), {
        bob.idString,
        carol.idString,
        sib.idString,
      });
      expect((await pin(carol.id))!.side, MemberSide.theirs);
      expect((await pin(sib.id))!.side, MemberSide.mine);
      final added = {
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded)
            (vaultDeviceIdHex(l.deviceId!), l.side),
      };
      expect(added, {
        (vaultDeviceIdHex(carol.id), MemberSide.theirs),
        (vaultDeviceIdHex(sib.id), MemberSide.mine),
      });
    });

    test('a member of g + 1 that is neither in the directory nor pinned at '
        'the end of g is unattributed and blocks sends', () async {
      final carol = await RigPeer.create('carol');
      await setUpJoined();
      peers([bob, carol]);
      await makeStuck();
      // The answers are lost and the record cannot be read in this run.
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);

      // A restart: carol is no longer listed.
      await rig.restart();
      build();
      listingsFail = false;
      peers([bob]);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect((await pin(carol.id))!.side, MemberSide.unattributed);
      final s = await state();
      expect(s.unattributedPresent, isTrue);
      expect(s.sendBlock, isNot(SendBlock.none));
      // No deviceAdded row for a member with no side.
      expect([
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
    });

    test('the pins of g + 1 are admitted to the key history before '
        'attribution: a refused member is unattributed with an unknownDevice '
        'row, and the history keeps closed and allow', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      peers([bob, bob2]);
      await makeStuck();
      // While the call is out, bob2's id is seen with another key here
      // (tainted), and the history is closed at a raised allowance. The
      // settle in this run has the reset's lists, which list bob2.
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        await rig.putKeyHistory(
          _c1,
          ids: [(bob.id, bob.key)],
          changed: [bob2.id],
          closed: true,
          allow: 512,
        );
      };
      await reset();
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect((await pin(bob2.id))!.side, MemberSide.unattributed);
      final unknownLines = [
        for (final l in await lines())
          if (l.line == SystemLine.unknownDevice) l,
      ];
      expect(unknownLines, hasLength(1));
      expect(rigEq(unknownLines.single.deviceId!, bob2.id), isTrue);
      expect((await state()).unknownDevicePresent, isTrue);
      final history = (await rig.keyHistory(_c1))!;
      expect(history['closed'], isTrue);
      expect(history['allow'], 512);
      expect(await rig.keyHistoryChanged(_c1), [vaultDeviceIdHex(bob2.id)]);
    });

    test('STALE_EPOCH: the provisional group is deleted and the winner\'s '
        'welcome is joined', () async {
      await setUpJoined();
      await makeStuck();
      RigAdd? winner;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' && winner == null) {
          winner = await bobResets(1);
        }
      };
      await reset();
      expect(resets(), hasLength(1));
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      final described = await rig.device.engine.inner.describe(g2.state);
      expect(
        described.members.map((m) => vaultDeviceIdHex(m.deviceId)).toSet(),
        {vaultDeviceIdHex(rig.device.deviceId), vaultDeviceIdHex(bob.id)},
      );
      expect(await groupAt(1), isNull);
      expect(rig.server.acks, isNotEmpty);
      // This device's own reset line is not written: the join writes one.
      expect(
        [for (final l in await lines()) l.line]
            .where((l) => l == SystemLine.encryptionReset),
        hasLength(1),
      );
    });

    test('a timeout resends the identical reset once; a restart finds its '
        'record at (g + 1, 0) and clears provisional', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 2) {
          listingsFail = true;
        }
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      final calls = resets();
      expect(calls, hasLength(2));
      expect(calls[0].sameBytes(calls[1]), isTrue);
      expect(calls[0].key, isNot(calls[1].key));
      expect((await sync()).commitCallsToday, 2);
      expect((await groupAt(2))!.provisional, isTrue);

      await rig.restart();
      build();
      listingsFail = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isFalse);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(2, 0),
      );
      expect(await groupAt(1), isNull);
    });

    test('the reset cap surfaces as RateLimitedException', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'slow down',
          limitName: kLimitResetsDaily,
        ),
        stored: false,
      ));
      await expectLater(
        reset(),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitResetsDaily,
          ),
        ),
      );
      expect(await groupAt(2), isNull);
      expect(await groupAt(1), isNotNull);
      expect((await state()).phase, ConversationPhase.stuck);
      expect((await state()).canReset, isTrue);
    });

    test('a stage-encrypted row of g is re-encrypted in g + 1 after its '
        'STALE_EPOCH', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.receiver.pullLive(_c1);
      // The send's outcome stays unknown: the row stays at stage
      // encrypted, at (1, 1).
      rig.server.sendScript.addAll([unknown, unknown]);
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'hi');
      await rig.sender.settled(_c1);
      final row = (await rig.device.vault.outbox(conversationId: _c1))
          .items
          .single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.generation, 1);

      final sentBefore = rig.server.sends.length;
      await makeStuck();
      await reset();
      await rig.sender.drain(_c1, priority: BudgetPriority.user);
      await rig.sender.settled(_c1);
      expect(rig.server.sends.last.pair.generation, 2);
      // Review m-6: the row of g went out once more at its own pair, under
      // its own key, and the server (at g + 1) answered STALE_EPOCH; only
      // then was it encrypted again in g + 1, under a new key.
      expect(rig.server.current(_c1).generation, 2);
      final after = rig.server.sends.sublist(sentBefore);
      expect(after, hasLength(2));
      expect(after.first.key, row.idempotencyKey);
      expect(after.first.pair, MlsPair(1, row.epoch));
      expect(after.first.pair, isNot(rig.server.current(_c1)));
      expect(after.last.pair.generation, 2);
      expect(after.last.key, isNot(row.idempotencyKey));
      expect(
        (await rig.device.vault.outbox(conversationId: _c1)).items,
        isEmpty,
      );
      final stored = [
        for (final m in await rig.device.vault.messages(_c1, limit: 50))
          if (m.kind == StoredMessageKind.message) m,
      ];
      expect(stored.single.generation, 2);
    });
  });

  group('the stuck member (R12, M9)', () {
    test('a stuck member with the flag on is repaired by one reset; with '
        'the flag off it stays stuck and says so', () async {
      await setUpJoined();
      await makeStuck();
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await starter.repairIfStuck(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      var s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.sendBlock, SendBlock.stuck);
      expect(s.canReset, isFalse);
      expect(await rig.ledger.autoResets(_c1), 0);

      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      s = await state();
      expect(s.phase, ConversationPhase.ready);
      expect(await rig.ledger.autoResets(_c1), 1);
    });

    test('a third stuck result in one day does not reset by itself', () async {
      await setUpJoined();
      await makeStuck();
      final real = rig.keys.claims[_bob]!;
      // Each automatic reset fails at its claim; the count was written
      // before it.
      final countsAtClaim = <int>[];
      rig.keys.claims[_bob] = () async {
        countsAtClaim.add(await rig.ledger.autoResets(_c1));
        throw const NetworkException('rig: no claim');
      };
      await starter.repairIfStuck(_c1);
      await starter.repairIfStuck(_c1);
      expect(countsAtClaim, [1, 2]);
      expect(await rig.ledger.autoResets(_c1), kAutoResetsPerDay);

      await starter.repairIfStuck(_c1);
      expect(countsAtClaim, [1, 2], reason: 'no claim the third time');
      var s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isTrue);

      // A manual reset is not counted.
      rig.keys.claims[_bob] = real;
      await reset();
      expect(resets(), hasLength(1));
      expect(await rig.ledger.autoResets(_c1), kAutoResetsPerDay);

      // Stuck again the same day: no reset by itself; the next IST day
      // allows two again.
      final garbage2 = rigBytes('another unprocessable commit');
      rig.device.engine.failWireAlways[RigEngine.key(garbage2)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage2,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      rig.clock.advance(const Duration(days: 1));
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(2));
      expect(await rig.ledger.autoResets(_c1), 1);
      s = await state();
      expect(s.phase, ConversationPhase.ready);
    });

    test('audit L1: five automatic resets of the user today, in other '
        'conversations, leave this stuck one to the manual offer', () async {
      await setUpJoined();
      await makeStuck();
      // Hostile peers in five other conversations used today's allowance.
      for (var i = 0; i < kAutoResetsPerUserPerDay; i++) {
        await rig.ledger.addAutoReset('${i}2222222222222222222222222222222');
      }
      await starter.repairIfStuck(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      expect(resets(), isEmpty);
      expect(await rig.ledger.autoResets(_c1), 0);
      final s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isTrue, reason: 'the manual reset stays offered');
      // The user's own reset is not held by that cap.
      await reset();
      expect(resets(), hasLength(1));
    });

    test('audit L4: an automatic reset adds no device this device removed '
        'here today; a manual reset still does', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      peers([bob, bob2]);
      await makeStuck();
      // This device removed bob2 from this conversation today (as its own
      // commit's transaction records it).
      await rig.device.session.runWrite((v) async {
        final current = await rig.ledger.readLocked(v);
        await v.transaction(
          (tx) => rig.ledger.writeIn(
            tx,
            current,
            (r) => r.withOwnChange(_c1, removed: [bob2.id]),
          ),
        );
      });
      await starter.repairIfStuck(_c1);
      expect(resets().single.welcomeDeviceIds, [bob.idString]);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(await pin(bob2.id), isNull);

      // The user's own reset is the user's choice (its deviceAdded rows
      // show): bob2 is added.
      await stuckAgain();
      await reset();
      expect(resets(), hasLength(2));
      expect(resets().last.welcomeDeviceIds.toSet(), {
        bob.idString,
        bob2.idString,
      });
      expect((await pin(bob2.id))!.side, MemberSide.theirs);
    });

    test('audit M2 / L5: removed elsewhere, or a failed engine: canReset is '
        'false and repairIfStuck counts nothing', () async {
      await setUpJoined();
      await makeStuck();
      expect((await state()).canReset, isTrue);

      // Task 12's seam set: this device was removed elsewhere.
      rig.removedElsewhere = true;
      expect((await state()).canReset, isFalse);
      await starter.repairIfStuck(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rig.ledger.autoResets(_c1), 0);
      rig.removedElsewhere = false;

      // The guarded engine failed twice: it answers `unavailable`.
      final down = GuardedCryptoEngine(
        create: () => throw StateError('rig: no engine'),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(down.randomBytes(1), throwsA(isA<MlsException>()));
      }
      expect(down.unavailable.value, isTrue);
      rig.engineOverride = down;
      expect((await state()).canReset, isFalse);
      await starter.repairIfStuck(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rig.ledger.autoResets(_c1), 0);
      rig.engineOverride = null;
      expect((await state()).canReset, isTrue);
      expect(resets(), isEmpty);
    });

    test(
      'an unreadable ledger makes no automatic reset (fails closed)',
      () async {
        await setUpJoined();
        await makeStuck();
        await rig.device.vault.transaction(
          (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
        );
        expectedErrors = ['daily.read'];
        await starter.repairIfStuck(_c1);
        expect(rig.keys.claimCalls, isEmpty);
        expect(resets(), isEmpty);
        expect((await state()).canReset, isTrue);
      },
    );

    test('an unprocessable commit never triggers more than one reset per '
        'catch-up', () async {
      await setUpJoined();
      await makeStuck();
      await Future.wait([
        starter.repairIfStuck(_c1),
        starter.repairIfStuck(_c1),
      ]);
      expect(resets(), hasLength(1));
      expect(rig.keys.claimCalls.where((c) => c.userId == _bob), hasLength(1));
      // The unprocessable commit is behind the reset: catch-up is current
      // and nothing asks for another.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      expect(await rig.ledger.autoResets(_c1), 1);
    });
  });

  group('a reset in progress (amendment 10)', () {
    test('blocks reconcile and the self-update check', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      rig.server.calls.clear();
      final lists = rig.keys.listCalls;
      final gets = rig.keys.getCalls.length;
      rig.clock.advance(const Duration(days: 31));
      await rig.upkeep.reconcile(_c1);
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(rig.server.calls, isNot(contains('commitConversation')));
      expect(rig.keys.listCalls, lists);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(resets(), hasLength(2));
    });
  });

  group('a lower generation not walked (audit L3)', () {
    test('audit L3: the reset settle waits while a lower generation that '
        'was not walked is stored (seeded)', () async {
      await setUpJoined();
      await makeStuck();
      // g's last epoch is marked walked: the settle walks nothing first.
      final g1 = (await groupAt(1))!;
      final s = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          s.copyWith(completedEpochs: [MlsPair(1, g1.epoch)]),
        ),
      );
      // Seeded (no path makes it today): once the call is answered, before
      // the settle's transaction reads the groups, generation 1 is stored
      // at an epoch that was never walked.
      var armed = false;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') armed = true;
      };
      rig.device.onOutbox = () async {
        if (!armed) return;
        armed = false;
        await rig.device.vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 1,
              epoch: g1.epoch + 1,
              state: g1.state,
            ),
          ),
        );
      };
      await reset();
      expect(resets(), hasLength(1));
      expect((await groupAt(1))!.epoch, g1.epoch + 1);
      expect(
        (await groupAt(2))!.provisional,
        isTrue,
        reason: 'never settled past a generation still to be walked',
      );
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        isNot(const MlsPair(2, 0)),
      );
      expect([
        for (final l in await lines()) l.line,
      ], isNot(contains(SystemLine.encryptionReset)));
    });
  });

  group('a removal of this device in g (review I-1)', () {
    test('review I-1: a removal stored at (g, e) before the reset is '
        'accepted: the reset settles into g + 1, with no deviceAdded row for '
        'bob, and the pins are the members of g + 1', () async {
      await setUpJoined();
      await pauseCommitting();
      await bobRemovesMe();
      // The server checks only the generation: it accepts the reset, and
      // the settle walks g first, which applies the removal.
      await reset();
      expect(resets(), hasLength(1));
      final g2 = await groupAt(2);
      expect(g2, isNotNull, reason: 'the server holds g + 1 with this leaf');
      expect(g2!.provisional, isFalse);
      expect(await groupAt(1), isNull);
      final pins = await rig.device.vault.members(_c1);
      expect(
        {for (final m in pins) vaultDeviceIdHex(m.deviceId)},
        {vaultDeviceIdHex(rig.device.deviceId), vaultDeviceIdHex(bob.id)},
      );
      for (final m in pins) {
        expect(m.since, const MlsPair(2, 1));
      }
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect([
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(2, 0),
      );
      expect((await state()).phase, ConversationPhase.ready);
    });

    test('review I-1: a catch-up removal while an abandoned reset call is '
        'out keeps g + 1 provisional', () async {
      await setUpJoined();
      await pauseCommitting();
      final ended = Completer<void>();
      rig.server.commitScript.addAll([unknown, unknown]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        }
      };
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);

      // A receiver catch-up applies bob's removal of this device in g.
      await bobRemovesMe();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      expect(await groupAt(1), isNull);
      final g2 = await groupAt(2);
      expect(g2, isNotNull, reason: 'a call of the reset may still land');
      expect(g2!.provisional, isTrue);
      expect(g2.pending?.kind, PendingKind.reset);
      expect(g2.pending?.keptAfterSelfRemoval, isTrue);

      // Review N-1: the removal is known now. No call of the kept reset is
      // ever made again; the server's record alone decides. Here it holds
      // nothing: the group goes once no call is out and the margin passed.
      ended.complete();
      await pumpEventQueue();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2), reason: 'never resent after removal');
      expect(await groupAt(2), isNull, reason: 'not stored: dropped');
      expect((await state()).phase, ConversationPhase.waitingForWelcome);
      // A later trigger, a send or a tap makes no call either.
      rig.clock.advance(const Duration(hours: 1));
      await starter.resumeProvisional();
      expect(resets(), hasLength(2));
    });

    test(
      'review N-1: after a restart the kept mark is read from the vault: '
      'no call, and the unstored reset is dropped after the margin',
      () async {
        await setUpJoined();
        await pauseCommitting();
        rig.server.commitScript.addAll([unknown, unknown]);
        await reset();
        expect(resets(), hasLength(2));
        await bobRemovesMe();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
        expect((await groupAt(2))!.provisional, isTrue);

        // A new run: this run's memory of the calls is gone.
        build();
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(resets(), hasLength(2), reason: 'no call in the new run');
        expect(await groupAt(2), isNotNull, reason: 'inside the margin');
        rig.clock.advance(kRequestInFlightMargin);
        await runScheduled();
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(resets(), hasLength(2), reason: 'never resent after removal');
        expect(await groupAt(2), isNull, reason: 'not stored: dropped');
      },
    );

    test('review N-1: a reset kept across the removal of this device is '
        'never sent again, and settles when the server holds it', () async {
      await setUpJoined();
      await pauseCommitting();
      final ended = Completer<void>();
      rig.server.commitScript.addAll([unknown, unknown]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      await bobRemovesMe();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      final kept = (await groupAt(2))!;
      expect(kept.provisional, isTrue);

      // Inside the wait: a resume makes no call.
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));

      // The abandoned call lands after all: the server holds the reset.
      rig.server.addCommit(
        _c1,
        const MlsPair(2, 0),
        kept.pending!.commit,
        fromUser: _me,
      );
      ended.complete();
      await pumpEventQueue();
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2), reason: 'never resent after removal');
      final g2 = await groupAt(2);
      expect(g2, isNotNull, reason: 'ours: settled');
      expect(g2!.provisional, isFalse);
      expect((await state()).phase, ConversationPhase.ready);
    });

    test('review T1: a removal of this device applied between the reset\'s '
        'create and its first call: the kept reset makes no call at all, '
        'and is dropped after the margin', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      // bob2 is listed but his claim hands out nothing: the create is
      // followed by a markEmptyClaim, after the lock is released and before
      // review m-2's first call takes it again.
      peers([bob, bob2]);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [await packageOf(bob)],
      );
      final ledger = HookedLedger();
      build(ledger: ledger);
      await pauseCommitting();
      var ran = false;
      ledger.beforeEmptyClaim = () async {
        if (ran || await groupAt(2) == null) return;
        ran = true;
        // Inside the window: a catch-up applies bob's removal of this
        // device in g, and the selfRemoved branch marks the reset kept.
        await bobRemovesMe();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
        final g2 = (await groupAt(2))!;
        expect(g2.provisional, isTrue);
        expect(g2.pending?.keptAfterSelfRemoval, isTrue);
        expect(resets(), isEmpty);
      };
      await reset();
      expect(ran, isTrue);
      // Review N-1: the send guard hands m-2's first call to the record.
      expect(resets(), isEmpty, reason: 'm-2 makes no call of a kept reset');
      expect((await groupAt(2))!.provisional, isTrue, reason: 'in the margin');

      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), isEmpty, reason: 'never sent after the removal');
      expect(await groupAt(2), isNull, reason: 'not stored: dropped');
      expect((await state()).phase, ConversationPhase.waitingForWelcome);
    });

    for (final stored in [false, true]) {
      test('review T2: a kept reset whose abandoned call is still out past '
          'its wait and the margin is neither listed nor dropped; after the '
          'call ends and the margin passes the record decides '
          '(${stored ? 'ours: settled' : 'not stored: dropped'})', () async {
        await setUpJoined();
        await pauseCommitting();
        final ended = Completer<void>();
        rig.server.commitScript.addAll([unknown, unknown]);
        rig.server.onCall = (call) async {
          if (call == 'commitConversation' &&
              rig.server.commitRequests.length == 1) {
            rig.server.abandon(
              rig.server.commitRequests.last.key,
              ended.future,
            );
          }
        };
        await reset();
        expect(resets(), hasLength(2));
        await bobRemovesMe();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
        final kept = (await groupAt(2))!;
        expect(kept.pending?.keptAfterSelfRemoval, isTrue);

        // The call is still out long after the wait and the margin.
        rig.clock.advance(kRequestInFlightMargin * 3);
        rig.server.calls.clear();
        await runScheduled();
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(resets(), hasLength(2), reason: 'never resent after removal');
        expect(
          await groupAt(2),
          isNotNull,
          reason: 'a call of the reset is out: not dropped',
        );
        expect(
          rig.server.calls.where(
            (c) => c.startsWith('listConversationCommits'),
          ),
          isEmpty,
          reason: 'nothing is listed while a call is out',
        );

        // The call ends (stored or not); its end schedules the resume that
        // decides once the margin from that end has passed.
        if (stored) {
          rig.server.addCommit(
            _c1,
            const MlsPair(2, 0),
            kept.pending!.commit,
            fromUser: _me,
          );
        }
        ended.complete();
        await pumpEventQueue();
        if (!stored) {
          // Inside the margin from the call's end: still kept.
          await starter.resumeProvisional();
          await starter.settled(_c1);
          expect(await groupAt(2), isNotNull, reason: 'inside the margin');
        }
        rig.clock.advance(kRequestInFlightMargin);
        await runScheduled();
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(resets(), hasLength(2), reason: 'never resent after removal');
        final g2 = await groupAt(2);
        if (stored) {
          expect(g2, isNotNull, reason: 'ours: settled');
          expect(g2!.provisional, isFalse);
          expect((await state()).phase, ConversationPhase.ready);
        } else {
          expect(g2, isNull, reason: 'not stored: dropped');
          expect((await state()).phase, ConversationPhase.waitingForWelcome);
        }
      });
    }
  });

  group('a reset ended elsewhere, and a reset made during a resume (review '
      'm-1, m-2)', () {
    test('review m-1: a reset the join path ended leaves no wait behind: a '
        'new reset made inside that wait is sent at once', () async {
      await setUpJoined();
      await makeStuck();
      // Reset A's outcome stays unknown: its resends wait one margin.
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      // Bob's reset into 2 adds this device; the join path (no starter)
      // discards reset A and joins his.
      await bobResets(1);
      await rig.crypto.processWelcomes();
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(g2.pending, isNull);

      // Stuck again inside A's wait: reset B is made and sent.
      await stuckAgain();
      await reset();
      expect(resets(), hasLength(3), reason: 'B is sent, not held by A');
      expect(resets().last.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
    });

    test('review N-2: a resume that sends the new reset right after its '
        'create keeps its call memory: the reset is not sent again as a '
        'first call', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      // bob2 is listed but his claim hands out nothing: the create is
      // followed by a markEmptyClaim, after the lock is released.
      peers([bob, bob2]);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [await packageOf(bob)],
      );
      final ledger = HookedLedger();
      build(ledger: ledger);
      await pauseCommitting();
      rig.server.commitScript.addAll([unknown, unknown, unknown]);
      var ran = false;
      ledger.beforeEmptyClaim = () async {
        if (ran || await groupAt(2) == null) return;
        ran = true;
        // A resume takes the lock the create just released, and sends the
        // reset: its outcome is unknown.
        await starter.resumeProvisional();
        expect(resets(), hasLength(1));
      };
      await reset();
      expect(ran, isTrue);
      expect(
        resets(),
        hasLength(1),
        reason: 'the resume made its call; no first call follows',
      );
      expect((await groupAt(2))!.provisional, isTrue);
    });

    test('review N-3: a resume that only saw the new reset (its listing '
        'failed inside the margin) made no call: the reset still makes its '
        'first call', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      peers([bob, bob2]);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [await packageOf(bob)],
      );
      final ledger = HookedLedger();
      build(ledger: ledger);
      await pauseCommitting();
      var ran = false;
      ledger.beforeEmptyClaim = () async {
        if (ran || await groupAt(2) == null) return;
        ran = true;
        // A resume meets the reset first; its listing fails, and the
        // margin it just opened holds its resend: no call.
        listingsFail = true;
        await starter.resumeProvisional();
        listingsFail = false;
        expect(resets(), isEmpty);
      };
      await reset();
      expect(ran, isTrue);
      expect(resets(), hasLength(1), reason: 'the first call is still made');
      expect((await groupAt(2))!.provisional, isFalse);
    });

    test('review m-2: a reset made while a resume of the same conversation '
        'runs its after-lock steps still makes its call', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      // Bob wins generation 2: the next resume drops reset A and joins his
      // welcome after the lock is released.
      await bobResets(1);
      Future<void>? second;
      var started = false;
      rig.server.onCall = (call) async {
        if (call != 'listWelcomes' || started) return;
        started = true;
        // The resume is in its after-lock join (it holds no lock): the
        // user resets again now, and B's group is created meanwhile.
        second = starter.resetConversation(_c1);
        for (var i = 0; i < 200 && await groupAt(3) == null; i++) {
          await pumpEventQueue();
        }
        expect((await groupAt(3))?.provisional, isTrue);
      };
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      expect(second, isNotNull);
      await second;
      await starter.settled(_c1);
      expect(resets(), hasLength(3), reason: 'B made its call');
      expect(resets().last.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
    });
  });
}
