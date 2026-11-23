import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/fake_vault_world.dart';

// Plan 5a Task 13 (step 13-i): the real E2eePipeline over the rig. The
// plan's Step 1 tests for e2ee_pipeline_test.dart, the pinned inertness
// test, and the gate items of task-13-gates.md that need the real parts
// (named in each test). The port (EncryptedMessagingImpl) is Task 13b: the
// inertness test covers the pipeline's own entries now and grows in 13b.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

/// The MLS-related `MessagingRepository` methods (gate item 31: eight, the
/// tombstone listing included).
const Set<String> _mlsMethods = {
  'listMlsMessages',
  'listEpochMessages',
  'listMessageTombstones',
  'listConversationCommits',
  'listWelcomes',
  'ackWelcomes',
  'sendEncrypted',
  'commitConversation',
};

/// Records every member touched; only `conversationsChanged` answers.
class _RecordingMessaging implements MessagingRepository {
  final List<String> touched = [];
  final StreamController<void> changed = StreamController.broadcast();

  @override
  Stream<void> get conversationsChanged {
    touched.add('conversationsChanged');
    return changed.stream;
  }

  @override
  Object? noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    touched.add(name.substring(8, name.length - 2));
    throw UnimplementedError(name);
  }
}

class _RecordingKeys implements KeysRepository {
  final List<String> touched = [];

  @override
  Object? noSuchMethod(Invocation invocation) {
    touched.add('${invocation.memberName}');
    throw UnimplementedError('${invocation.memberName}');
  }
}

void main() {
  test('no vault on this device, flag off or unknown: no MLS call', () async {
    for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
      final world = FakeVaultWorld();
      final session = world.launch();
      await session.start(restoredUid: 'user-a', restoreDefinitive: true);
      final messaging = _RecordingMessaging();
      final keys = _RecordingKeys();
      var engineAsked = 0;
      GuardedCryptoEngine engine() {
        engineAsked++;
        throw StateError('no engine may be built');
      }

      final deviceKeys = DeviceKeysService(
        session: session,
        repository: keys,
        engine: engine,
        currentUid: () => 'user-a',
        periodicTimer: (_, _) => throw StateError('no timer'),
        isForeground: () => true,
      );
      final reported = <Object>[];
      final pipeline = E2eePipeline(
        session: session,
        deviceKeys: deviceKeys,
        engine: engine,
        messaging: messaging,
        keys: keys,
        ownUserId: () => 'user-a',
        onUnexpectedError: (e, _) => reported.add(e),
      );
      session
        ..addVaultReadyHook(deviceKeys.onVaultReady)
        ..addVaultReadyHook(pipeline.onVaultReady);
      await session.onSignedIn('user-a', flag: flag);
      expect(session.vaultKnown, isFalse);

      // Every entry of the pipeline.
      await pipeline.start();
      pipeline
        ..onAppResumed()
        ..onAppPaused()
        ..onAppResumed()
        ..onPush(_c1)
        ..onPush(null)
        ..noteEncrypted(_c1)
        ..noteAccepted(_c1)
        ..noteDeleted(_c1)
        ..closed(_c1);
      await pipeline.opened(_c1);
      messaging.changed.add(null);
      await expectLater(pipeline.setUpAgain(), throwsStateError);
      await session.onFlagChanged(
        flag == E2eeFlag.off ? E2eeFlag.unknown : E2eeFlag.off,
        uid: 'user-a',
      );
      await pipeline.start();
      await Future<void>.delayed(Duration.zero);

      expect(engineAsked, 0, reason: '$flag: the engine factory');
      expect(world.calls, isEmpty, reason: '$flag: the vault openers');
      expect(world.ciphers, isEmpty);
      expect(keys.touched, isEmpty, reason: '$flag: KeysRepository');
      expect(
        messaging.touched.toSet().intersection(_mlsMethods),
        isEmpty,
        reason: '$flag: the MLS methods',
      );
      expect(messaging.touched.toSet(), {'conversationsChanged'});
      expect(pipeline.started, isFalse);
      expect(pipeline.hasParts, isFalse);
      expect(pipeline.coordinator, isNull);
      expect(reported, isEmpty);
      pipeline.dispose();
      deviceKeys.dispose();
    }
  });

  group('the real pipeline', () {
    late PipelineHarness h;
    late RigPeer bob;

    setUp(() async {
      h = await PipelineHarness.create();
      bob = await RigPeer.create('bob');
      h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    });

    tearDown(() => h.dispose());

    test(
      'an accept made through the repository runs the acceptance steps',
      () async {
        await h.offer(_c1, bob, accepted: false);
        // Remembered before the vault is ready, applied at start (item 42).
        h.pipeline.noteAccepted(_c1);
        await h.ready();
        expect(h.pipeline.started, isTrue);
        final sync = (await h.rig.device.vault.conversation(_c1))!.sync;
        expect(sync.requestAccepted, isTrue);
        // A later accept of another conversation: the same steps at once.
        await h.offer(_c2, bob, accepted: false);
        // A message push that names no conversation: an unfloored poll.
        h.pipeline.onPush(null);
        await h.settle();
        expect(await h.rig.device.vault.groups(_c2), isNotEmpty);
        h.pipeline.noteAccepted(_c2);
        await h.settle();
        await _until(
          () async =>
              (await h.rig.device.vault.conversation(_c2))!
                  .sync
                  .requestAccepted,
        );
      },
    );

    test('a delete made through the repository removes local copies and '
        'unsent rows and keeps the group (item 47: the deferred items go in '
        'the same transaction)', () async {
      await h.offer(_c1, bob);
      await h.ready();
      final v = h.rig.device.vault;
      expect(await v.groups(_c1), isNotEmpty);
      await v.transaction((tx) async {
        await tx.putMessage(
          StoredMessage(
            conversationId: _c1,
            messageId: 'm-1',
            createdAtMicros: 1,
            mine: false,
            state: StoredMessageState.visible,
            generation: 1,
            epoch: 1,
            content: Uint8List.fromList([7]),
          ),
        );
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: 'key-1',
            localId: 'local-1',
            expectedMessageId: 'e' * 32,
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            ciphertext: Uint8List.fromList([1]),
            reportCommitment: Uint8List(32),
            content: Uint8List.fromList([2]),
            createdAtMicros: 1,
          ),
        );
        await DeferredRecords().putIn(
          tx,
          _c1,
          DeferredRecord([
            DeferredItem(
              id: 'a' * 32,
              pair: const MlsPair(1, 1),
              at: 1,
              da: 1,
              ct: Uint8List.fromList([9]),
              rc: Uint8List(32),
              fs: false,
              k: 1,
              la: 1,
              ru: 'ab' * 8,
            ),
          ]),
        );
      });
      final done = h.pipeline.changes.firstWhere((id) => id == _c1);

      h.pipeline.noteDeleted(_c1);
      await done;

      expect(await v.messages(_c1), isEmpty);
      expect((await v.outbox(conversationId: _c1)).items, isEmpty);
      expect(await v.groups(_c1), isNotEmpty, reason: 'the group stays');
      final sync = (await v.conversation(_c1))!.sync;
      expect(sync.requestAccepted, isTrue, reason: 'the sync record stays');
      expect(sync.clearedAtMicros, h.rig.clock.now().microsecondsSinceEpoch);
      final deferred = await DeferredRecords().read(v, _c1);
      expect(deferred.record.items, isEmpty);
      expect(h.pipeline.known.contains(_c1), isTrue);
    });

    test('a row with can_reply false parks the peer and a later true '
        'un-parks it (items 45, 67)', () async {
      await h.offer(_c1, bob);
      await h.ready();
      // CANNOT_MESSAGE parks the peer's lookups.
      h.rig.keys.peerError = const CannotMessageException();
      await h.pipeline.directory.peer('ref-bob', fresh: true);
      h.rig.keys.peerError = null;
      expect(h.pipeline.directory.isParked('ref-bob'), isTrue);

      // A ListMessages header (the receiver notes it after its RPC).
      h.pipeline.contexts.note(_header(_c1, canReply: false));
      await h.settle();
      expect(h.pipeline.contexts.of(_c1).canReply, isFalse);
      expect(h.pipeline.directory.isParked('ref-bob'), isTrue);

      h.pipeline.contexts.note(_header(_c1));
      await h.settle();
      expect(h.pipeline.contexts.of(_c1).canReply, isTrue);
      expect(h.pipeline.directory.isParked('ref-bob'), isFalse);
    });

    test('a cached row after a list change is no sight: its can_reply false '
        'parks nothing; true un-parks the lookups', () async {
      await h.offer(_c1, bob);
      await h.ready();
      h.rig.keys.peerError = const CannotMessageException();
      await h.pipeline.directory.peer('ref-bob', fresh: true);
      h.rig.keys.peerError = null;
      h.messaging.inbox = [_header(_c1, canReply: false)];
      h.messaging.changed.add(null);
      await h.settle();
      expect(h.pipeline.contexts.of(_c1).canReply, isTrue);
      expect(h.pipeline.directory.isParked('ref-bob'), isTrue);
      h.messaging.inbox = [_header(_c1)];
      h.messaging.changed.add(null);
      await _until(() async => !h.pipeline.directory.isParked('ref-bob'));
    });

    test('noteEncrypted for a conversation without a group polls welcomes '
        '(item 24: and joins the known set)', () async {
      await h.ready();
      final polls = h.welcomePolls;
      h.pipeline.noteEncrypted(_c2);
      await _until(() async => h.welcomePolls == polls + 1);
      expect(h.pipeline.known.contains(_c2), isTrue);
      // The same hint again is an other reason: floored (60 s).
      h.pipeline.noteEncrypted(_c2);
      await h.settle();
      expect(h.welcomePolls, polls + 1);
    });

    test('ids noted before the vault was ready join the known set at start '
        '(items 24, 42: at most kPipelineNotesMax are kept)', () async {
      for (var i = 0; i <= kPipelineNotesMax; i++) {
        h.pipeline.noteEncrypted(conv(i));
      }
      await h.ready();
      expect(h.pipeline.known.contains(conv(0)), isFalse);
      expect(h.pipeline.known.contains(conv(1)), isTrue);
      expect(h.pipeline.known.contains(conv(kPipelineNotesMax)), isTrue);
    });

    test('item 12: the known ids are put into the ever-encrypted cache set '
        'when the vault becomes ready', () async {
      await h.rig.known.add(_c1);
      await h.rig.known.add(_c2);
      h.messaging.noted.clear();
      await h.ready();
      expect({for (final n in h.messaging.noted) n.id}, {_c1, _c2});
      expect(
        {for (final n in h.messaging.noted) n.session},
        {h.messaging.cacheSession},
      );
    });

    test('item 7: two own devices halve the calls per minute', () async {
      await h.ready();
      h.rig.clock.advance(const Duration(minutes: 2));
      int background(SyncBudget b) {
        var n = 0;
        while (b.tryTake(BudgetPriority.background)) {
          n++;
        }
        return n;
      }

      final one = await RigPeer.create('one');
      h.rig.keys.own
        ..clear()
        ..add(rigKeyDevice(one.idString, one.key));
      await h.pipeline.directory.own(fresh: true);
      h.rig.clock.advance(const Duration(minutes: 2));
      // One unit a minute stays for user priority. The harness scales every
      // budget by PipelineHarness.budgetScale (its clock stands still).
      const s = PipelineHarness.budgetScale;
      expect(background(h.pipeline.syncBudget), kSyncCallsPerMinute * s - 1);
      expect(background(h.pipeline.readBudget), kMlsReadCallsPerMinute * s - 1);

      final two = await RigPeer.create('two');
      h.rig.keys.own.add(rigKeyDevice(two.idString, two.key));
      await h.pipeline.directory.own(fresh: true);
      h.rig.clock.advance(const Duration(minutes: 2));
      expect(
        background(h.pipeline.syncBudget),
        kSyncCallsPerMinute * s ~/ 2 - 1,
      );
      expect(
        background(h.pipeline.readBudget),
        kMlsReadCallsPerMinute * s ~/ 2 - 1,
      );
    });

    test(
      'item 1: a second pipeline handed the same vault runs nothing',
      () async {
        await h.ready();
        final second = h.build();
        await second.onVaultReady(h.rig.device.vault);
        expect(second.hasParts, isFalse);
        expect(h.reported.whereType<Object>().map((e) => '$e'), [
          'E2eePipelineError(pipeline.owner)',
        ]);
        h.reported.clear();
        second.dispose();
      },
    );

    test('item 28: with a vault but no registered device no ListWelcomes and '
        'no claim is made, and the first poll follows the device becoming '
        'ready', () async {
      await h.dispose();
      h = await PipelineHarness.create(registered: false);
      h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
      await h.offer(_c1, bob);
      h.deviceKeys.phase = DeviceKeysStatus.idle;
      await h.ready();
      expect(h.pipeline.started, isFalse);
      h.pipeline
        ..onPush(_c1)
        ..onAppResumed();
      await h.pipeline.opened(_c1);
      await h.settle();
      expect(h.welcomePolls, 0);
      expect(h.rig.keys.claimCalls, isEmpty);
      expect(h.rig.server.calls, isEmpty);

      // Ready without the registered-once mark: still nothing.
      h.deviceKeys.phase = DeviceKeysStatus.ready;
      await h.settle();
      expect(h.welcomePolls, 0);

      await h.rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRegisteredOnce,
          Uint8List.fromList(const [1]),
        ),
      );
      h.deviceKeys
        ..phase = DeviceKeysStatus.idle
        ..phase = DeviceKeysStatus.ready;
      // The start's poll, then the remembered push's (both unfloored).
      await _until(() async => h.welcomePolls >= 1);
      await h.settle();
      expect(h.pipeline.started, isTrue);
      expect(await h.rig.device.vault.groups(_c1), isNotEmpty);
    });

    test('item 29: the flag turning on after the vault opened starts the '
        'gated work once, after device upkeep', () async {
      final session = h.rig.device.session;
      await session.onFlagChanged(E2eeFlag.unknown, uid: 'user-a');
      expect(session.mayStart, isFalse);
      h.deviceKeys.phase = DeviceKeysStatus.dormant;
      await h.ready();
      expect(h.pipeline.started, isTrue);
      expect(h.welcomePolls, 1, reason: 'reading and receiving run');

      await session.onFlagChanged(E2eeFlag.on, uid: 'user-a');
      await h.pipeline.start();
      await h.settle();
      expect(h.welcomePolls, 1, reason: 'not before the device upkeep');
      // The device's own upkeep (ensureReady) moves the status first.
      h.deviceKeys.phase = DeviceKeysStatus.ready;
      await _until(() async => h.welcomePolls == 2);
      await h.pipeline.start();
      h.deviceKeys
        ..phase = DeviceKeysStatus.idle
        ..phase = DeviceKeysStatus.ready;
      await h.settle();
      expect(h.welcomePolls, 2, reason: 'once');
    });

    test('items 32, 33: nothing runs while removed elsewhere, and the '
        'pipeline restarts when removedElsewhere clears', () async {
      await h.offer(_c1, bob);
      await h.ready();
      expect(h.pipeline.coordinator!.running, isTrue);
      h.deviceKeys.markRemoved();
      expect(h.pipeline.coordinator!.running, isFalse);
      final calls = h.rig.server.calls.length;
      h.pipeline
        ..onPush(_c1)
        ..onAppResumed()
        ..noteEncrypted(_c2);
      await h.pipeline.opened(_c1);
      h.messaging.changed.add(null);
      await h.settle();
      expect(h.rig.server.calls.length, calls);

      final polls = h.welcomePolls;
      h.deviceKeys.clearRemoved();
      // The start's poll (and the remembered _c2 hint's).
      await _until(() async => h.welcomePolls >= polls + 1);
      await h.settle();
      expect(h.pipeline.coordinator!.running, isTrue);
      expect(h.pipeline.known.contains(_c2), isTrue);
      expect(
        h.rig.server.calls.skip(calls),
        contains('listMlsMessages'),
        reason: 'the pass ran again',
      );
    });
  });
}

pb.Conversation _header(String id, {bool canReply = true}) => pb.Conversation(
  id: id,
  peer: common.AuthorSnapshot(userId: 'ref-bob'),
  folder: Folder.FOLDER_INBOX,
  state: ConversationState.CONVERSATION_STATE_ACCEPTED,
  canReply: canReply,
  encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
);

/// Waits (real time, bounded) until [done] holds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('the condition never held');
}
