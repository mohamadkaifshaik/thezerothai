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

Future<void> _storeMessage(SecureVault v, String id) => v.transaction(
  (tx) => tx.putMessage(
    StoredMessage(
      conversationId: id,
      messageId: 'm-1',
      createdAtMicros: 1,
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

  test('m4: a delete of a conversation whose first message is still a '
      'pending init goes through the starter\'s discard, never deletes the '
      'init row under it', () async {
    final v = h.rig.device.vault;
    // Bob's 1:1 conversation is _c1; one claimable package.
    h.rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: _c1,
      keyPackages: [
        kpb.ClaimedKeyPackage(
          deviceId: bob.idString,
          signaturePublicKey: bob.key,
          keyPackage: await bob.keyPackage(),
          hasKeyPackage_4: true,
        ),
      ],
    );
    h.rig.server.recipients['ref-bob'] = _c1;
    h.rig.server.rows[_c1] = pb.Conversation(
      id: _c1,
      peer: common.AuthorSnapshot(userId: 'ref-bob'),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );
    await h.ready();
    // Two attempts with no answer: the group stays provisional with its
    // init row; the server stored nothing.
    const unknown = (error: NetworkException('timed out'), stored: false);
    h.rig.server.sendScript.addAll([unknown, unknown]);
    await h.pipeline.starter.startOrRoute(
      localId: 'local-1',
      peerUserId: 'ref-bob',
      text: 'hello',
    );
    await h.pipeline.starter.settled(_c1);
    await h.pipeline.sender.settled(_c1);
    expect((await v.group(_c1, 1))!.provisional, isTrue);
    expect((await v.outbox()).items.single.init, isNotNull);
    h.rig.clock.advance(kInitResendMargin);

    final done = h.pipeline.changes.firstWhere((id) => id == _c1);
    h.pipeline.noteDeleted(_c1);
    await done;
    await _until(() async => (await v.outbox()).items.isEmpty);

    expect(await v.group(_c1, 1), isNull, reason: 'discarded by the starter');
    expect(await h.pipeline.starter.pendingInit(conversationId: _c1), isNull);
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

  test('I5: another account\'s remembered hints are dropped, never applied '
      'to this vault', () async {
    final v = h.rig.device.vault;
    await h.offer(_c1, bob, accepted: false);
    await _storeMessage(v, _c1);
    h.pipeline
      ..noteDeleted(_c1)
      ..noteAccepted(_c1)
      ..noteEncrypted(_c2)
      ..onPush(_c1);
    // Account A signed out with no vault; account B signs in with one.
    h.ownUser = 'user-b';

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
}

/// Waits (real time, bounded) until [done] holds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('the condition never held');
}
