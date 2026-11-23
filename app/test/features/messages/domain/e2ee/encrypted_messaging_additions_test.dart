import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart'
    show RemovedElsewhere;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart'
    show InitDiscard, kInitResendMargin;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// The port-additions PR (before 5b Task 14): the members the Task 13b PR
// recorded but could not build (task-13-gates.md items 14, 15, 18, 26 and
// lane D's removal members), over the real pipeline and the rig.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (await done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('the condition never held');
}

void main() {
  late PipelineHarness h;
  late RigPeer bob;
  late EncryptedMessagingImpl port;

  setUp(() async {
    h = await PipelineHarness.create();
    bob = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    port = EncryptedMessagingImpl(h.pipeline);
  });

  tearDown(() => h.dispose());

  Future<void> joined() async {
    await h.offer(_c1, bob);
    await h.ready();
  }

  /// A first message to 'ref-carol' whose init got no answer twice: the
  /// group of [_c2] stays provisional with its init row 'local-1'.
  /// [margin]: the resend margin has passed (a discard may decide).
  Future<void> unansweredInit({bool margin = true}) async {
    final carol = await RigPeer.create('carol');
    h.rig.keys.peers['ref-carol'] = [rigKeyDevice(carol.idString, carol.key)];
    h.rig.keys.claims['ref-carol'] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: _c2,
      keyPackages: [
        kpb.ClaimedKeyPackage(
          deviceId: carol.idString,
          signaturePublicKey: carol.key,
          keyPackage: await carol.keyPackage(),
          hasKeyPackage_4: true,
        ),
      ],
    );
    h.rig.server.recipients['ref-carol'] = _c2;
    h.rig.server.rows[_c2] = pb.Conversation(
      id: _c2,
      peer: common.AuthorSnapshot(userId: 'ref-carol'),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );
    await h.ready();
    const unknown = (error: NetworkException('timed out'), stored: false);
    h.rig.server.sendScript.addAll([unknown, unknown]);
    final out = await port.send(
      to: ThreadRef.recipientOf(common.AuthorSnapshot(userId: 'ref-carol')),
      localId: 'local-1',
      text: 'hello',
    );
    expect(out.kind, SendOutcomeKind.queued);
    await h.pipeline.starter.settled(_c2);
    await h.pipeline.sender.settled(_c2);
    final vault = h.rig.device.vault;
    expect((await vault.group(_c2, 1))!.provisional, isTrue);
    expect((await vault.outbox()).items.single.init, isNotNull);
    if (margin) h.rig.clock.advance(kInitResendMargin);
  }

  group('discardUnsent (gate items 14, 15)', () {
    test('a failed row is discarded, and the row that waited behind it '
        'starts (F1)', () async {
      await joined();
      h.rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'one',
      );
      await h.pipeline.sender.settled(_c1);
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-2',
        text: 'two',
      );
      await h.pipeline.sender.settled(_c1);
      expect(h.rig.server.sends, hasLength(1), reason: 'behind a failed head');

      expect(await port.discardUnsent('local-1'), UnsentDiscard.discarded);
      await h.pipeline.sender.settled(_c1);
      await h.settle();

      expect(h.rig.server.sends, hasLength(2), reason: 'local-2 went out');
      expect(
        await port.unsentEntries(const ThreadRef.conversation(_c1)),
        isEmpty,
      );
      expect((await h.rig.device.vault.outbox()).items, isEmpty);
    });

    test('a discard whose write fails answers notDecided, never held, and '
        'keeps the row (CR n1)', () async {
      await joined();
      h.rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'one',
      );
      await h.pipeline.sender.settled(_c1);
      // A stage-plain row behind the failed head: never sent.
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-2',
        text: 'two',
      );
      await h.pipeline.sender.settled(_c1);
      await h.settle();

      h.rig.device.failNextWriteAsked = true;
      expect(await port.discardUnsent('local-2'), UnsentDiscard.notDecided);
      expect(h.rig.device.writesRefused, 1);
      final rows = (await h.rig.device.vault.outbox()).items;
      expect(rows.map((r) => r.localId), contains('local-2'));
    });

    test('an unknown id, an empty id, and a row already gone answer '
        'none', () async {
      await joined();
      expect(await port.discardUnsent('nope'), UnsentDiscard.none);
      expect(await port.discardUnsent(''), UnsentDiscard.none);
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'one',
      );
      await h.pipeline.sender.settled(_c1);
      await h.settle();
      expect(await port.discardUnsent('local-1'), UnsentDiscard.none);
    });

    test(
      'a pending first message goes through discardInit: stopped when the '
      'server holds nothing, and then it is a failed row (item 15)',
      () async {
        await unansweredInit();

        expect(await port.discardUnsent('local-1'), UnsentDiscard.stopped);

        final vault = h.rig.device.vault;
        expect(await vault.group(_c2, 1), isNull);
        final row = (await port.unsentEntries(
          const ThreadRef.conversation(_c2),
        ))!.single;
        expect(row.id, 'local-1');
        expect(
          (row.progress, row.problem),
          (SendProgress.notSent, SendProblem.retryable),
        );
      },
    );

    test('a pending first message the server may still answer is held, and '
        'nothing changes (items 15, 23)', () async {
      await unansweredInit(margin: false);
      // A new run of the starter: an init an earlier run sent is held for
      // the resend margin.
      h.pipeline.starter.reset();

      expect(await port.discardUnsent('local-1'), UnsentDiscard.held);

      final vault = h.rig.device.vault;
      expect((await vault.group(_c2, 1))!.provisional, isTrue);
      expect((await vault.outbox()).items.single.init, isNotNull);
    });

    for (final state in [RemovedElsewhere.removed, RemovedElsewhere.unknown]) {
      test('a pending first message on a stopped device ($state) answers '
          'notDecided with no MLS call, through the port and through the '
          "starter's own discard (SA L1, flag-on gate G1)", () async {
        await unansweredInit();
        if (state == RemovedElsewhere.removed) {
          h.deviceKeys.markRemoved();
        } else {
          h.deviceKeys.state = state;
        }
        await h.settle();
        final calls = h.rig.server.calls.length;

        expect(await port.discardUnsent('local-1'), UnsentDiscard.notDecided);
        expect(
          await h.pipeline.starter.discardInit(_c2),
          InitDiscard.notDecided,
        );

        expect(h.rig.server.calls.sublist(calls), isEmpty, reason: 'no RPC');
        final vault = h.rig.device.vault;
        expect((await vault.group(_c2, 1))!.provisional, isTrue);
        expect((await vault.outbox()).items.single.init, isNotNull);
      });
    }

    test(
      'a pending first message while the pipeline is not started answers '
      'notDecided with no MLS call (SA L1: the rule of _discardOrOwe)',
      () async {
        await unansweredInit();
        // Removed, then the fact clears with no wake: the pipeline stays
        // stopped though nothing stops it now.
        h.deviceKeys.markRemoved();
        await h.settle();
        h.deviceKeys.state = RemovedElsewhere.notRemoved;
        expect(h.pipeline.started, isFalse);
        expect(h.pipeline.hasParts, isTrue);
        final calls = h.rig.server.calls.length;

        expect(await port.discardUnsent('local-1'), UnsentDiscard.notDecided);

        expect(h.rig.server.calls.sublist(calls), isEmpty, reason: 'no RPC');
        expect(
          (await h.rig.device.vault.outbox()).items.single.init,
          isNotNull,
        );
      },
    );
  });

  group('an unreadable outbox row (gate item 18, a flag-on gate)', () {
    test('the thread lists it by ref; deleteUnreadableUnsent deletes only '
        'that row of that conversation, with no network call; then the '
        'conversation sends again', () async {
      await joined();
      h.expectedErrors = ['send.outbox.unreadable'];
      final vault = h.rig.device.vault;
      h.rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'one',
      );
      await h.pipeline.sender.settled(_c1);
      final bad = (await vault.outbox()).items.single.idempotencyKey;
      await h.rig.device.db.customStatement(
        'UPDATE vault_outbox SET content = ciphertext, ciphertext = content '
        "WHERE idempotency_key = '$bad'",
      );
      expect((await vault.outbox()).unreadableKeys, [bad]);

      final seen = <EncryptedThread>[];
      final sub = port
          .watchThread(const ThreadRef.conversation(_c1))
          .listen(seen.add);
      await _until(() async => seen.isNotEmpty);
      // SA L2 (flag-on gate G3): a per-run handle, never the outbox key
      // (the key sent on the wire).
      final handle = seen.last.unreadableUnsent.single;
      expect(handle, isNot(bad));
      expect(handle, isNotEmpty);

      // A later row waits behind the unreadable one.
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-2',
        text: 'two',
      );
      await h.pipeline.sender.settled(_c1);
      await h.settle();
      expect(h.rig.server.sends, hasLength(1));
      final good = (await vault.outbox()).items.single.idempotencyKey;

      final serverCalls = h.rig.server.calls.length;
      final keyCalls = (
        h.rig.keys.listCalls,
        h.rig.keys.getCalls.length,
        h.rig.keys.claimCalls.length,
        h.rig.keys.removeCalls.length,
      );
      // The same row keeps its handle across emissions of this run.
      await _until(() async => seen.last.entries.any((e) => e.id == 'local-2'));
      expect(seen.last.unreadableUnsent, [handle]);
      expect(await port.deleteUnreadableUnsent(_c1, good), isFalse);
      // The raw keys are not handles: refused, also for the right row.
      expect(await port.deleteUnreadableUnsent(_c1, bad), isFalse);
      expect(await port.deleteUnreadableUnsent(_c2, handle), isFalse);
      expect(await port.deleteUnreadableUnsent(_c1, 'unknown'), isFalse);
      expect(await port.deleteUnreadableUnsent(_c1, ''), isFalse);
      expect((await vault.outbox()).unreadableKeys, [bad]);
      expect(await port.deleteUnreadableUnsent(_c1, handle), isTrue);
      // A stale handle (its row is gone).
      expect(await port.deleteUnreadableUnsent(_c1, handle), isFalse);
      await h.settle();
      expect(h.rig.server.calls, hasLength(serverCalls), reason: 'no network');
      expect((
        h.rig.keys.listCalls,
        h.rig.keys.getCalls.length,
        h.rig.keys.claimCalls.length,
        h.rig.keys.removeCalls.length,
      ), keyCalls);

      final left = await vault.outbox();
      expect(left.unreadableKeys, isEmpty);
      expect(left.items.single.localId, 'local-2');
      await _until(() async => seen.last.unreadableUnsent.isEmpty);

      // The user's retry of the waiting row now sends it.
      await port.retrySend('local-2');
      await h.pipeline.sender.settled(_c1);
      await h.settle();
      expect(h.rig.server.sends, hasLength(2));
      await sub.cancel();
    });
  });

  test('delete-for-me also deletes the conversation\'s unreadable unsent rows '
      '(CR m3)', () async {
    await joined();
    final vault = h.rig.device.vault;
    h.rig.server.sendScript.add((
      error: const FeatureDisabledException('off'),
      stored: false,
    ));
    await port.send(
      to: const ThreadRef.conversation(_c1),
      localId: 'local-1',
      text: 'one',
    );
    await h.pipeline.sender.settled(_c1);
    final bad = (await vault.outbox()).items.single.idempotencyKey;
    await h.rig.device.db.customStatement(
      'UPDATE vault_outbox SET content = ciphertext, ciphertext = content '
      "WHERE idempotency_key = '$bad'",
    );
    expect((await vault.outbox(conversationId: _c1)).unreadableKeys, [bad]);

    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();

    final left = await vault.outbox(conversationId: _c1);
    expect(left.unreadableKeys, isEmpty);
    expect(left.items, isEmpty);
  });

  group('device removal (lane D)', () {
    /// An own device the directory lists, read by the port's ownDevices.
    Future<RigPeer> ownOther(String name) async {
      final p = await RigPeer.create(name);
      h.rig.keys.own.add(rigKeyDevice(p.idString, p.key));
      await port.ownDevices();
      return p;
    }

    for (final ended in [true, false]) {
      test('removeDevice answers other_sessions_ended ($ended)', () async {
        await joined();
        final other = await ownOther('other');
        h.rig.keys.otherSessionsEnded = ended;
        final removal = await port.removeDevice(other.idString);
        expect(removal.otherSessionsEnded, ended);
        await h.settle();
      });
    }

    test('a REAUTH_REQUIRED removal is parked: needsReauth and the parked '
        'ref follow the runner; removeDevice of a parked ref is accepted with '
        'no own list read in this port; dropRemoval gives one up', () async {
      await joined();
      final other = await ownOther('other');
      h.rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        port.removeDevice(other.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(port.needsReauth.value, isTrue);
      expect(port.parkedRemovals.value, [other.idString]);

      // A port with no own list in memory (a new screen, after a restart).
      final fresh = EncryptedMessagingImpl(h.pipeline);
      await expectLater(fresh.removeDevice('f' * 32), throwsArgumentError);
      h.rig.keys
        ..removeError = null
        ..otherSessionsEnded = true;
      final removal = await fresh.removeDevice(other.idString);
      expect(removal.otherSessionsEnded, isTrue);
      expect(port.needsReauth.value, isFalse);
      expect(port.parkedRemovals.value, isEmpty);

      final third = await ownOther('third');
      h.rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        port.removeDevice(third.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(port.parkedRemovals.value, [third.idString]);
      await port.dropRemoval(third.idString);
      expect(port.needsReauth.value, isFalse);
      expect(port.parkedRemovals.value, isEmpty);
      await expectLater(port.dropRemoval(third.idString), throwsStateError);
      await expectLater(port.dropRemoval(''), throwsStateError);
      await h.settle();
    });

    test('a removal parked in an earlier run is asked for once the vault is '
        'ready, also while the pipeline does not start (CR n2)', () async {
      final other = await RigPeer.create('other');
      await h.rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRemovalRecord,
          RemovalRecord(
            intents: [
              RemovalMark(
                deviceId: other.idString,
                atMicros: h.rig.clock.now().microsecondsSinceEpoch,
                signatureKey: other.key,
                reauth: true,
              ),
            ],
          ).encode(),
        ),
      );
      h.deviceKeys.markRemoved();

      await h.ready();

      expect(h.pipeline.started, isFalse);
      expect(port.needsReauth.value, isTrue);
      expect(port.parkedRemovals.value, [other.idString]);
      expect(h.rig.keys.removeCalls, isEmpty);
    });

    test('a closed vault drops the ask and the parked refs', () async {
      await joined();
      final other = await ownOther('other');
      h.rig.keys.removeError = const ReauthRequiredException('rig: sign in');
      await expectLater(
        port.removeDevice(other.idString),
        throwsA(isA<ReauthRequiredException>()),
      );
      expect(port.needsReauth.value, isTrue);

      h.rig.device.owner!.steal();
      await _until(() async => !port.needsReauth.value);
      expect(port.parkedRemovals.value, isEmpty);
      await expectLater(port.dropRemoval(other.idString), throwsStateError);
    });
  });
}
