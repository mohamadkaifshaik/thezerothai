import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart'
    show kSelfUpdateEvery;
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/receive_record.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13 (step 13-i): the small seams the pipeline wiring needs in
// the parts of Tasks 5-12. Each test names its gate item of task-13-gates.md.

const _c1 = '11111111111111111111111111111111';

void main() {
  late RigCrypto rig;
  late RigPeer bob;

  setUp(() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  });

  tearDown(() async {
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    await rig.dispose();
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  Future<void> join() async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    await rig.receiver.pullLive(_c1);
  }

  pb.Conversation row({bool canReply = true}) => pb.Conversation(
    id: _c1,
    peer: common.AuthorSnapshot(userId: 'ref-bob'),
    folder: Folder.FOLDER_INBOX,
    state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    canReply: canReply,
  );

  group('item 45: ConversationContexts.onRowNoted', () {
    test('fires after a server row is noted, never for a peer-only row', () {
      final noted = <String>[];
      rig.contexts.onRowNoted = (r) {
        // The facts are taken before the hook runs.
        expect(rig.contexts.of(r.id).canReply, r.canReply);
        noted.add('${r.id}:${r.canReply}');
      };
      rig.contexts.note(row(canReply: false), peerOnly: true);
      expect(noted, isEmpty);
      rig.contexts.note(row(canReply: false));
      rig.contexts.note(row());
      expect(noted, ['$_c1:false', '$_c1:true']);
    });
  });

  group('item 51: reconcile(renewLeaf: false)', () {
    test(
      'a background reconcile makes no self-update; the default does',
      () async {
        await join();
        rig.clock.advance(kSelfUpdateEvery + const Duration(days: 1));
        rig.server.commitRequests.clear();

        await rig.upkeep.reconcile(_c1, renewLeaf: false);
        expect(rig.server.commitRequests, isEmpty);

        await rig.upkeep.reconcile(_c1);
        expect(rig.server.commitRequests, hasLength(1));
        expect(rig.server.commitRequests.single.welcome, isNull);
      },
    );
  });

  group('item 25: MessageReceiver.pendingWork', () {
    test('nothing is pending after a complete pass', () async {
      await join();
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
      final p = await rig.receiver.pendingWork(_c1);
      expect(p.any, isFalse);
    });

    test(
      'an armed reconcile entry and an unended open walk are pending',
      () async {
        await join();
        final before = await rig.receiver.pendingWork(_c1);
        expect(before.reconcile, isFalse);
        await rig.device.vault.transaction(
          (tx) => ReceiveRecords().putIn(
            tx,
            _c1,
            const ReceiveRecord(
              open: WalkEntry(pair: MlsPair(1, 1)),
              rec: ReconcileEntry(armed: true),
            ),
          ),
        );
        final p = await rig.receiver.pendingWork(_c1);
        expect(p.reconcile, isTrue);
        expect(p.openBacklog, isTrue);
        expect(p.walks, isFalse);
        expect(p.any, isTrue);
      },
    );

    test('nothing is read while removed elsewhere', () async {
      await rig.device.vault.transaction(
        (tx) => ReceiveRecords().putIn(
          tx,
          _c1,
          const ReceiveRecord(rec: ReconcileEntry(armed: true)),
        ),
      );
      expect((await rig.receiver.pendingWork(_c1)).reconcile, isTrue);
      rig.removedElsewhere = true;
      expect((await rig.receiver.pendingWork(_c1)).any, isFalse);
    });
  });

  group('item 13: the clock-skew map is capped', () {
    test('a new id drops the oldest counter once the map is full', () async {
      final seeded = {
        for (var i = 0; i < kWelcomeSkewEntriesMax; i++)
          'f${i.toRadixString(16).padLeft(31, '0')}': 1,
      };
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingWelcomeSkew,
          Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'n': seeded}))),
        ),
      );
      // Garbage bytes while the device clock is behind the welcome: the
      // engine answers bad_input, a transient skew.
      final skewed = rig.server.addWelcome(
        rig.device.deviceIdString,
        _c1,
        const MlsPair(1, 0),
        Uint8List(4),
        createdAt: rig.clock.now().add(const Duration(hours: 1)),
      );
      // A held poll never completes, so no counter is dropped at its end.
      await rig.locks.run(_c1, () => rig.crypto.processWelcomesHeld(_c1));

      final raw = await rig.device.vault.setting(kVaultSettingWelcomeSkew);
      final n =
          (jsonDecode(utf8.decode(raw!)) as Map<String, Object?>)['n']!
              as Map<String, Object?>;
      expect(n, hasLength(kWelcomeSkewEntriesMax));
      expect(n[skewed], 1);
      expect(n.containsKey(seeded.keys.first), isFalse);
      expect(n.containsKey(seeded.keys.last), isTrue);
    });
  });
}
