import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart'
    show kInitResendMargin;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13, fix round 1: the pipeline's remembered hints. I2: a
// remembered delete is applied as soon as the vault is ready, whatever the
// device state, survives a failure and never breaks the start. I3: hints
// arriving while the start applies the remembered notes run after it. I5:
// a hint is the account's that made it; another account's are dropped.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

Future<void> _storeMessage(
  SecureVault v,
  String id, {
  String messageId = 'm-1',
  int createdAtMicros = 1,
}) => v.transaction(
  (tx) => tx.putMessage(
    StoredMessage(
      conversationId: id,
      messageId: messageId,
      createdAtMicros: createdAtMicros,
      mine: false,
      state: StoredMessageState.visible,
      generation: 1,
      epoch: 1,
      content: Uint8List.fromList([7]),
    ),
  ),
);

void main() {
  late PipelineHarness h;
  late RigPeer bob;

  setUp(() async {
    h = await PipelineHarness.create();
    bob = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  });

  tearDown(() => h.dispose());

  group('I2: remembered deletes', () {
    test('a delete noted before the vault was ready is made at ready even '
        'while the device keys failed', () async {
      final v = h.rig.device.vault;
      await _storeMessage(v, _c1);
      h.deviceKeys.phase = const DeviceKeysStatus.failed(retryable: true);
      h.pipeline.noteDeleted(_c1);

      await h.ready();

      expect(h.pipeline.started, isFalse);
      expect(await v.messages(_c1), isEmpty);
      expect((await v.conversation(_c1))!.sync.clearedAtMicros, isNotNull);
      expect(h.pipeline.notedCount, 0);
    });

    test('a delete that throws is reported, kept, and retried; the start '
        'still runs', () async {
      final v = h.rig.device.vault;
      await _storeMessage(v, _c1);
      var failures = 1;
      h.rig.device.onOutbox = () async {
        if (failures > 0) {
          failures--;
          throw const FormatException('rig: an unreadable outbox');
        }
      };
      h.pipeline.noteDeleted(_c1);

      await h.ready();

      expect(h.pipeline.coordinator!.running, isTrue);
      expect(h.pipeline.started, isTrue);
      expect(await v.messages(_c1), hasLength(1));
      expect(h.pipeline.notedCount, 1, reason: 'kept for a retry');
      expect(h.reported.whereType<Object>().map((e) => '$e'), [
        'E2eePipelineError(pipeline.delete)',
      ]);
      h.reported.clear();

      h.pipeline.onAppResumed();
      await h.settle();
      await _until(() async => (await v.messages(_c1)).isEmpty);
      expect(h.pipeline.notedCount, 0);
    });

    test('SA L3: a delete retried later removes only the messages stored '
        'when the user deleted; one that arrived since stays', () async {
      final v = h.rig.device.vault;
      await _storeMessage(v, _c1);
      await h.ready();
      var failures = 1;
      h.rig.device.onOutbox = () async {
        if (failures > 0) {
          failures--;
          throw const FormatException('rig: an unreadable outbox');
        }
      };
      h.pipeline.noteDeleted(_c1);
      await _until(() async => h.reported.isNotEmpty);
      await h.settle();
      expect(h.pipeline.notedCount, 1, reason: 'kept for a retry');
      h.reported.clear();
      // A message arrives after the user's delete.
      await _storeMessage(v, _c1, messageId: 'm-2', createdAtMicros: 5);

      h.pipeline.onAppResumed();
      await _until(() async => h.pipeline.notedCount == 0);
      await h.settle();

      expect((await v.messages(_c1)).map((m) => m.messageId), ['m-2']);
    });

    test('forgetting the hints (sign-out of the same account) keeps its '
        'deletes', () async {
      final v = h.rig.device.vault;
      await _storeMessage(v, _c1);
      h.pipeline
        ..noteDeleted(_c1)
        ..noteEncrypted(_c2)
        ..forgetNotes();
      expect(h.pipeline.notedCount, 1);

      await h.ready();

      expect(await v.messages(_c1), isEmpty);
      expect(h.pipeline.known.contains(_c2), isFalse);
    });
  });

  /// The pipeline started, then this device's first message to bob (whose
  /// 1:1 conversation is _c1) got no answer to either attempt: the group is
  /// provisional with its init row, and the server stored nothing.
  /// [margin]: the resend margin has passed (a discard may decide).
  /// [peer] / [ref] / [conversation]: another peer's conversation (the
  /// vault is then already ready: [ready] false).
  Future<void> unansweredInit({
    bool margin = true,
    RigPeer? peer,
    String ref = 'ref-bob',
    String conversation = _c1,
    String localId = 'local-1',
    bool ready = true,
  }) async {
    final v = h.rig.device.vault;
    final p = peer ?? bob;
    h.rig.keys.peers[ref] = [rigKeyDevice(p.idString, p.key)];
    h.rig.keys.claims[ref] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: conversation,
      keyPackages: [
        kpb.ClaimedKeyPackage(
          deviceId: p.idString,
          signaturePublicKey: p.key,
          keyPackage: await p.keyPackage(),
          hasKeyPackage_4: true,
        ),
      ],
    );
    h.rig.server.recipients[ref] = conversation;
    h.rig.server.rows[conversation] = pb.Conversation(
      id: conversation,
      peer: common.AuthorSnapshot(userId: ref),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );
    if (ready) await h.ready();
    // Two attempts with no answer: the group stays provisional with its
    // init row; the server stored nothing.
    const unknown = (error: NetworkException('timed out'), stored: false);
    h.rig.server.sendScript.addAll([unknown, unknown]);
    await h.pipeline.starter.startOrRoute(
      localId: localId,
      peerUserId: ref,
      text: 'hello',
    );
    await h.pipeline.starter.settled(conversation);
    await h.pipeline.sender.settled(conversation);
    expect((await v.group(conversation, 1))!.provisional, isTrue);
    expect(
      (await v.outbox()).items.where((r) => r.localId == localId).single.init,
      isNotNull,
    );
    if (margin) h.rig.clock.advance(kInitResendMargin);
  }

  test('m4: a delete of a conversation whose first message is still a '
      'pending init goes through the starter\'s discard, never deletes the '
      'init row under it', () async {
    final v = h.rig.device.vault;
    await unansweredInit();

    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await _until(() async => (await v.outbox()).items.isEmpty);

    expect(await v.group(_c1, 1), isNull, reason: 'discarded by the starter');
    expect(await h.pipeline.starter.pendingInit(conversationId: _c1), isNull);
  });

  test('r1-I1: while removed elsewhere a delete is made locally with no MLS '
      'call; the owed init discard runs once after the fact clears', () async {
    final v = h.rig.device.vault;
    await unansweredInit();
    await _storeMessage(v, _c1);
    h.deviceKeys.markRemoved();
    expect(h.pipeline.started, isFalse);
    final before = h.rig.server.calls.length;

    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();

    expect(await v.messages(_c1), isEmpty, reason: 'the local delete');
    final calls = h.rig.server.calls.skip(before).toList();
    expect(calls, isNot(contains('listConversationCommits')));
    expect(calls, isNot(contains('listWelcomes')));
    expect(await v.group(_c1, 1), isNotNull, reason: 'the discard is owed');
    expect((await v.outbox()).items.single.init, isNotNull);
    expect(h.pipeline.notedCount, 1, reason: 'one owed discard');

    final sends = h.rig.server.sends.length;
    h.deviceKeys.clearRemoved();
    await _until(() async => h.pipeline.started);
    await h.settle();

    // Discarded before the start's resumeProvisional could resend it.
    expect(await v.group(_c1, 1), isNull, reason: 'the owed discard ran');
    expect((await v.outbox()).items, isEmpty);
    expect(h.rig.server.sends, hasLength(sends), reason: 'never resent');
    expect(h.pipeline.notedCount, 0, reason: 'nothing owed any more');
  });

  test('SA M1: a delete-for-me whose owed discard was lost at a restart '
      'never lets the next run resend the deleted init', () async {
    final v = h.rig.device.vault;
    await unansweredInit();
    h.deviceKeys.markRemoved();
    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();
    expect(h.pipeline.notedCount, 1, reason: 'owed, in memory only');
    final sends = h.rig.server.sends.length;

    // The app ends: the owed set is gone. The next run's pipeline (a fresh
    // starter) opens the same vault with the device usable.
    h.pipeline.dispose();
    final next = h.build();
    addTearDown(next.dispose);
    h.deviceKeys.clearRemoved();
    await next.onVaultReady(v);
    await _until(() async => next.started);
    await next.coordinator!.idle();
    await next.starter.settled(_c1);

    expect(h.rig.server.sends, hasLength(sends), reason: 'never resent');
    // A fresh run holds an init it did not send for the resend margin;
    // after it, the next resume discards it.
    h.rig.clock.advance(kInitResendMargin);
    await next.starter.resumeProvisional();
    await next.starter.settled(_c1);
    await _until(() async => await v.group(_c1, 1) == null);
    await _until(() async => (await v.outbox()).items.isEmpty);
    expect(h.rig.server.sends, hasLength(sends), reason: 'never resent');
  });

  test('r2-m1: a delete arriving inside the start window never lets the '
      'start\'s resumeProvisional resend that conversation\'s init', () async {
    final v = h.rig.device.vault;
    await unansweredInit();
    h.deviceKeys.markRemoved();
    // The wake's start window: the user deletes the conversation in it.
    h.pipeline.onStartWindowForTest = () async {
      h.pipeline.onStartWindowForTest = null;
      h.pipeline.noteDeleted(_c1);
    };
    final sends = h.rig.server.sends.length;

    h.deviceKeys.clearRemoved();
    await _until(() async => h.pipeline.started);
    await h.settle();

    expect(h.rig.server.sends, hasLength(sends), reason: 'never resent');
    expect(await v.group(_c1, 1), isNull, reason: 'discarded');
    expect(h.pipeline.notedCount, 0);
  });

  test('CR M2: a delete made during the start window\'s last owed pass is '
      'discarded before the window closes, not left owed', () async {
    final v = h.rig.device.vault;
    final carol = await RigPeer.create('carol');
    await unansweredInit(margin: false);
    await unansweredInit(
      peer: carol,
      ref: 'ref-carol',
      conversation: _c2,
      localId: 'local-2',
      ready: false,
    );
    h.rig.clock.advance(kInitResendMargin);
    h.deviceKeys.markRemoved();
    // _c1's discard is owed, and its first try in the window cannot decide.
    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();
    var commitsCalls = 0;
    h.rig.server.onCall = (call) async {
      if (call != 'listConversationCommits') return;
      commitsCalls++;
      if (commitsCalls == 1) throw const NetworkException('rig: no network');
      // The window's last look at the owed set: the user deletes _c2.
      if (commitsCalls == 2) h.pipeline.noteDeleted(_c2);
    };

    h.deviceKeys.clearRemoved();
    await _until(() async => h.pipeline.started);
    await h.settle();
    await _until(() async => await v.group(_c2, 1) == null);

    expect(h.pipeline.notedCount, 0, reason: 'nothing left owed');
    expect(await v.group(_c1, 1), isNull);
  });

  test('CR M3: the resume\'s owed discard runs before the coordinator\'s '
      'resume', () async {
    final v = h.rig.device.vault;
    await unansweredInit();
    var fail = true;
    h.rig.server.onCall = (call) async {
      if (call == 'listConversationCommits' && fail) {
        fail = false;
        throw const NetworkException('rig: no network');
      }
    };
    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();
    expect(h.pipeline.notedCount, 1, reason: 'owed');
    final before = h.rig.server.calls.length;

    h.pipeline.onAppResumed();
    await _until(() async => await v.group(_c1, 1) == null);
    await h.settle();

    final calls = h.rig.server.calls.skip(before).toList();
    final discard = calls.indexOf('listConversationCommits');
    final welcomes = calls.indexOf('listWelcomes');
    expect(discard, greaterThanOrEqualTo(0));
    expect(welcomes, greaterThan(discard), reason: 'the resume waited');
  });

  test(
    'r2-m1: an owed discard that could not decide is retried at resume',
    () async {
      final v = h.rig.device.vault;
      await unansweredInit();
      // The stored-commits read fails once: the discard cannot decide.
      var fail = true;
      h.rig.server.onCall = (call) async {
        if (call == 'listConversationCommits' && fail) {
          fail = false;
          throw const NetworkException('rig: no network');
        }
      };
      final done = h.pipeline.changes.firstWhere((id) => id == _c1);
      h.pipeline.noteDeleted(_c1);
      await done;
      await h.settle();
      expect(await v.group(_c1, 1), isNotNull);
      expect(h.pipeline.notedCount, 1, reason: 'owed');

      h.pipeline.onAppResumed();
      await _until(() async => await v.group(_c1, 1) == null);
      await h.settle();
      expect(h.pipeline.notedCount, 0);
    },
  );

  test('r1-m2: a delete whose init discard answers held keeps the init row '
      'and the provisional group; the local copies go', () async {
    final v = h.rig.device.vault;
    // Attempts from an earlier run (a reset starts a new run of the
    // starter), inside the resend margin of this one: held.
    await unansweredInit(margin: false);
    h.pipeline.starter.reset();
    await _storeMessage(v, _c1);

    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await h.settle();

    expect(await v.messages(_c1), isEmpty);
    expect((await v.group(_c1, 1))!.provisional, isTrue);
    expect((await v.outbox()).items.single.init, isNotNull);
    expect(h.pipeline.notedCount, 0, reason: 'decided: nothing owed');
  });

  test('I3: a push and an open during the start window run after the '
      'start, never dropped', () async {
    await h.offer(_c1, bob);
    final window = Completer<void>();
    var entered = false;
    h.pipeline.onStartWindowForTest = () {
      entered = true;
      return window.future;
    };
    final ready = h.pipeline.onVaultReady(h.rig.device.vault);
    await _until(() async => entered);

    h.pipeline.onPush(_c1);
    final opened = h.pipeline.opened(_c1);
    expect(h.pipeline.notedCount, 1, reason: 'the push is remembered');
    window.complete();
    await ready;
    await opened;
    await h.settle();

    expect(h.pipeline.coordinator!.isWatched(_c1), isTrue);
    // The start's poll and the replayed push's (joined or after it): a
    // dropped push would leave the start's poll alone.
    expect(h.welcomePolls, 2);
    expect(h.pipeline.notedCount, 0);
  });

  test('I5, r1-I2: another account\'s remembered hints (by authenticated '
      'uid) are dropped, never applied to this vault', () async {
    final v = h.rig.device.vault;
    await h.offer(_c1, bob, accepted: false);
    await _storeMessage(v, _c1);
    // Account X (signed in with no vault) makes the hints; its own user
    // reference happens to read like this vault's.
    h.uid = 'user-x';
    h.pipeline
      ..noteDeleted(_c1)
      ..noteAccepted(_c1)
      ..noteEncrypted(_c2)
      ..onPush(_c1);
    // X signed out; the vault that opens is user-a's.
    h.uid = 'user-a';

    await h.ready();

    expect(await v.messages(_c1), hasLength(1), reason: 'A\'s delete');
    expect((await v.conversation(_c1))?.sync.clearedAtMicros, isNull);
    expect(
      (await v.conversation(_c1))?.sync.requestAccepted ?? false,
      isFalse,
      reason: 'A\'s accept',
    );
    expect(h.pipeline.known.contains(_c2), isFalse, reason: 'A\'s hint');
    expect(h.pipeline.notedCount, 0);
  });

  test('SA L2: a delete of the open vault that fails during a direct switch '
      'to another account is never remembered for the new account', () async {
    final v = h.rig.device.vault;
    await _storeMessage(v, _c1);
    await h.ready();
    // A direct A→B switch: the auth state is B while A's parts are live.
    h.uid = 'user-x';
    var failures = 1;
    h.rig.device.onOutbox = () async {
      if (failures > 0) {
        failures--;
        throw const FormatException('rig: an unreadable outbox');
      }
    };
    h.pipeline.noteDeleted(_c1);
    await _until(() async => h.reported.isNotEmpty);
    await h.settle();

    expect(h.pipeline.notedCount, 0, reason: 'A\'s delete is not B\'s note');
    h.reported.clear();
  });

  test('r1-I2: a delete made while the user reference is not known yet '
      '(null early in a run) is still remembered and made', () async {
    final v = h.rig.device.vault;
    await _storeMessage(v, _c1);
    h.ownUser = null;
    h.pipeline.noteDeleted(_c1);
    expect(h.pipeline.notedCount, 1);

    await h.ready();

    expect(await v.messages(_c1), isEmpty);
  });

  test('r1-I2: the user reference changing form (uid to public id) for the '
      'same account keeps its remembered notes', () async {
    final v = h.rig.device.vault;
    await _storeMessage(v, _c1);
    h.pipeline.noteDeleted(_c1);
    h.ownUser = 'pub-a-public-id';
    h.pipeline.noteEncrypted(_c2);
    expect(h.pipeline.notedCount, 2);

    await h.ready();

    expect(await v.messages(_c1), isEmpty, reason: 'the same account');
    expect(h.pipeline.known.contains(_c2), isTrue);
  });
}

/// Waits (real time, bounded) until [done] holds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('the condition never held');
}
