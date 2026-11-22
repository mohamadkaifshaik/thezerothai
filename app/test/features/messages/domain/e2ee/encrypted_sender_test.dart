import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_locks.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_sender.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

final RegExp _keyShape = RegExp(r'^[0-9a-f]{32}$');

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Conversation locks that refuse a second acquisition by code that already
/// holds the lock (the real ones would deadlock there).
class _ProbeLocks extends ConversationLocks {
  int acquired = 0;
  int reentered = 0;

  @override
  Future<T> run<T>(String conversationId, Future<T> Function() body) {
    if (isHeld(conversationId)) {
      reentered++;
      throw StateError('the conversation lock was taken twice');
    }
    acquired++;
    return super.run(conversationId, body);
  }
}

/// Records the length of every `randomBytes` call and its 16-byte answers.
class _RandomEngine extends RigEngine {
  final List<int> lengths = [];
  final List<Uint8List> sixteens = [];

  @override
  Future<Uint8List> randomBytes(int length) async {
    final bytes = await super.randomBytes(length);
    lengths.add(length);
    if (length == 16) sixteens.add(bytes);
    return bytes;
  }
}

/// Cuts `randomBytes` answers: [cut] answers how many bytes of a
/// [length]-byte answer are kept (null: all of them).
class _CutRandomEngine extends RigEngine {
  int? Function(int length)? cut;

  @override
  Future<Uint8List> randomBytes(int length) async {
    final bytes = await super.randomBytes(length);
    final keep = cut?.call(length);
    return keep == null ? bytes : bytes.sublist(0, keep);
  }
}

/// A sync budget that records the priority of every unit asked for.
class _SpyBudget extends SyncBudget {
  _SpyBudget(RigClock clock)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: clock.now);

  final List<BudgetPriority> taken = [];

  /// Runs at every `take` (it may throw: a call that fails unexpectedly).
  void Function()? onTake;

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    taken.add(priority);
    onTake?.call();
    return super.take(priority, lane: lane);
  }
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    final unexpected = [...rig.unexpected];
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  pb.Conversation headerRow({
    Folder? folder = Folder.FOLDER_INBOX,
    bool canReply = true,
  }) => pb.Conversation(
    id: _c1,
    peer: common.AuthorSnapshot(userId: 'ref-bob'),
    folder: folder,
    canReply: canReply,
  );

  /// This device joins [_c1] from bob's welcome. [accepted]: the stored sync
  /// record says so; [folder]: what the server's header row says (null: no
  /// folder, so the direction stays unknown); [attributed]: bob's device is
  /// in his key list.
  Future<void> setUpJoined({
    bool accepted = true,
    Folder? folder = Folder.FOLDER_INBOX,
    bool attributed = true,
    ConversationLocks? locks,
    RigEngine? engine,
    SyncBudget Function(RigClock clock)? syncBudget,
  }) async {
    rig = await RigCrypto.create(
      locks: locks,
      engine: engine,
      syncBudget: syncBudget,
    );
    bob = await RigPeer.create('bob');
    if (attributed) {
      rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    }
    if (accepted) await rig.accept(_c1);
    rig.server.rows[_c1] = headerRow(folder: folder);
    offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    // Call counts in a test start after the join.
    rig.device.engine.calls.clear();
    rig.server.calls.clear();
  }

  Future<List<OutboxItem>> outbox([String c = _c1]) async =>
      (await rig.device.vault.outbox(conversationId: c)).items;

  int encrypts() => rig.device.engine.calls.where((c) => c == 'encrypt').length;

  // Enqueue draws the report key and the plain row key. Entering _encrypt
  // draws a third key even when its in-transaction check blocks encryption.
  void expectBlockedBeforeEncrypt() => expect(
    rig.device.engine.calls.where((c) => c == 'randomBytes'),
    hasLength(2),
  );

  /// Enqueues and waits for the drain `enqueue` started (no second trigger).
  Future<void> send(String localId, [String text = 'hello']) async {
    await rig.sender.enqueue(localId: localId, conversationId: _c1, text: text);
    await rig.sender.settled(_c1);
  }

  /// One more trigger, at user priority, as these tests were written (the
  /// user's own send or retry). `drain`'s default is background since Task
  /// 9 review m2; a test of an automatic trigger passes it.
  Future<void> drain() => rig.sender.drain(_c1, priority: BudgetPriority.user);

  Future<ConversationSync> sync() async =>
      (await rig.device.vault.conversation(_c1))?.sync ??
      const ConversationSync();

  Future<void> updateSync(
    ConversationSync Function(ConversationSync s) change,
  ) async {
    final next = change(await sync());
    await rig.device.vault.transaction(
      (tx) => tx.putConversationSync(_c1, next),
    );
  }

  /// What Task 9's acceptance steps leave behind (the part the sender's
  /// gates read).
  Future<void> acceptanceSteps(String id) async {
    await updateSync((s) => s.copyWith(requestAccepted: true));
    rig.contexts.of(id).incomingRequest = false;
  }

  /// Bob commits a self-update on the server's current pair.
  Future<void> bobSelfUpdate() async {
    final g = offer.add.group;
    final at = rig.server.current(_c1);
    final c = await bob.engine.selfUpdate(bob.state, g.state);
    g.state = await bob.engine.confirmCommit(bob.state, c.groupState);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
  }

  Future<int> sentLog() async =>
      (await rig.device.db
              .customSelect('SELECT COUNT(*) AS n FROM vault_sent')
              .getSingle())
          .read<int>('n');

  Future<List<StoredMessage>> stored() async => [
    for (final m in await rig.device.vault.messages(_c1, limit: 500))
      if (m.kind == StoredMessageKind.message) m,
  ];

  String textOf(Uint8List content) => decodeMessageContentLenient(content).text;

  void offline() =>
      rig.server.onCall = (_) async => throw const NetworkException('offline');

  const lost = (error: NetworkException('timed out'), stored: false);

  group('review round one', () {
    test('discard uses a listing started after the last send', () async {
      await setUpJoined();
      rig.server.sendScript.addAll([lost, lost]);
      await send('l1');
      final listed = Completer<void>();
      final release = Completer<void>();
      rig.server.rewriteLive = (snapshot) async {
        rig.server.rewriteLive = null;
        listed.complete();
        await release.future;
        return snapshot;
      };
      rig.server.calls.clear();
      final older = rig.receiver.pullLive(_c1);
      await listed.future;
      rig.server.sendScript.add((error: lost.error, stored: true));
      await drain();
      final discarding = rig.sender.discard('l1');
      // Queue behind discard's outbox read before releasing the old snapshot.
      await outbox();
      // The older pass is still running: discard waits for it, then starts
      // a pull of its own (a second listing), which is its proof.
      expect(rig.contexts.of(_c1).running, isNotNull);
      release.complete();
      await older;
      await discarding;
      expect(
        rig.server.calls.where((call) => call == 'listMlsMessages'),
        hasLength(2),
      );
      expect((await stored()).single.content, isNotNull);
      expect(await outbox(), isEmpty);
    });

    test('the local message id survives a conflicting response id', () async {
      await setUpJoined();
      await send('first');
      final first = (await stored()).single;
      rig.server.sendResponseId = first.messageId;
      await send('second');
      await send('third');
      final reports = rig.unexpected.toList();
      rig.unexpected.clear();
      expect(
        (await stored()).map((m) => m.messageId),
        unorderedEquals([
          for (final s in rig.server.sends) expectedMessageId('user-a', s.key),
        ]),
      );
      expect(reports, hasLength(1));
      expect((reports.single as E2eePipelineError).step, 'send.responseId');
    });

    test(
      'an interrupted catch-up waits after a successful live pull',
      () async {
        await setUpJoined();
        await rig.receiver.pullLive(_c1);
        await bobSelfUpdate();
        rig.contexts.of(_c1).syncedSinceStart = false;
        rig.server.calls.clear();
        rig.server.onCall = (call) async {
          if (call == 'listConversationCommits') throw lost.error;
        };
        await send('l1');
        expect(
          rig.server.calls.where((call) => call == 'listMlsMessages'),
          hasLength(1),
        );
        expect(encrypts(), 0);
        expect(rig.server.sends, isEmpty);
        rig.server.onCall = null;
        await drain();
        expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      },
    );

    test('a stale send joins the second-page welcome and sends on the new generation', () async {
      await setUpJoined(locks: _ProbeLocks());
      rig.server.beforeSend = (_) async {
        rig.server.beforeSend = null;
        for (var i = 0; i < 10; i++) {
          rig.server.addWelcome(
            rig.device.deviceIdString,
            i.toRadixString(16).padLeft(32, '0'),
            const MlsPair(1, kMaxPairComponent),
            Uint8List(0),
          );
        }
        await rig.offer(_c1, bob, generation: 2);
      };
      await send('l1');
      expect(rig.server.sends.map((s) => s.pair), [
        const MlsPair(1, 1),
        const MlsPair(2, 1),
      ]);
      expect(rig.server.sends.last.key, isNot(rig.server.sends.first.key));
      expect((await stored()).single.generation, 2);
      expect((rig.locks as _ProbeLocks).reentered, 0);
    });

    test('a row with no group waits for a welcome', () async {
      rig = await RigCrypto.create();
      await rig.accept(_c1);
      await send('l1');
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.waitingForWelcome,
      );
      expect((await outbox()).single.stage, OutboxStage.plain);
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
    });

    test(
      'acceptance that changes the pair syncs again before the first reply',
      () async {
        await setUpJoined(accepted: false, folder: Folder.FOLDER_REQUESTS);
        rig.onAcceptForReply = (id) async {
          await acceptanceSteps(id);
          await bobSelfUpdate();
          rig.contexts.of(id).syncedSinceStart = false;
        };
        await send('l1');
        expect(rig.acceptCalls, [_c1]);
        expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      },
    );

    test(
      'a refusal write failure leaves only one resend per trigger',
      () async {
        await setUpJoined();
        rig.server.beforeSend = (_) async {
          rig.device.cipher.failSeal = (label) =>
              label.contains('vault_outbox');
        };
        rig.server.sendScript.add((
          error: const ValidationException('invalid'),
          stored: false,
        ));
        await send('l1');
        expect((await outbox()).single.lastError, isNull);
        rig.device.cipher.failSeal = null;
        rig.server.beforeSend = null;
        rig.server.sendScript.addAll([lost, lost]);
        await drain();
        expect(rig.server.sends, hasLength(2));
      },
    );

    test(
      'enqueue rejects a malformed conversation id before generating keys',
      () async {
        rig = await RigCrypto.create();
        rig.device.engine.calls.clear();
        await expectLater(
          rig.sender.enqueue(localId: 'x', conversationId: 'bad', text: 'a'),
          throwsArgumentError,
        );
        expect(rig.device.engine.calls, isEmpty);
      },
    );
  });

  group('enqueue', () {
    test('enqueue stores a sealed plain row and makes no engine or network '
        'call', () async {
      await setUpJoined();
      // The drain enqueue starts waits for the lock: what enqueue itself
      // did is all there is to see.
      final release = Completer<void>();
      final held = rig.locks.run(_c1, () => release.future);
      await rig.sender.enqueue(
        localId: 'local-1',
        conversationId: _c1,
        text: 'hello sealed text',
        sharedPostId: 'post-9',
      );
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.localId, 'local-1');
      expect(row.conversationId, _c1);
      expect(row.recipientUserId, isNull);
      expect((row.generation, row.epoch), (0, 0));
      expect(row.ciphertext, isEmpty);
      expect(row.reportCommitment, isEmpty);
      expect(row.init, isNull);
      expect(row.attempts, 0);
      expect(row.lastError, isNull);
      final content = decodeMessageContentLenient(row.content);
      expect(content.text, 'hello sealed text');
      expect(content.sharedPostId, 'post-9');
      expect(content.reportKey, hasLength(kReportKeyBytes));
      // Sealed: the stored bytes hold none of the text.
      final raw = await rig.device.db
          .customSelect('SELECT content FROM vault_outbox')
          .getSingle();
      expect(
        latin1.decode(raw.read<Uint8List>('content')),
        isNot(contains('hello sealed')),
      );
      // The CSPRNG only: no state call of the engine, no network call.
      expect(rig.device.engine.calls.toSet(), {'randomBytes'});
      expect(rig.server.calls, isEmpty);
      expect(rig.server.sends, isEmpty);
      // An unsent row already has that local id.
      await expectLater(
        rig.sender.enqueue(
          localId: 'local-1',
          conversationId: _c1,
          text: 'again',
        ),
        throwsArgumentError,
      );
      expect(await outbox(), hasLength(1));
      release.complete();
      await held;
      await rig.sender.settled(_c1);
    });

    test('the idempotency key is 32 hex characters from 16 random '
        'bytes', () async {
      final engine = _RandomEngine();
      await setUpJoined(engine: engine);
      engine.lengths.clear();
      engine.sixteens.clear();
      rig.device.onConfirmStored = (_, _) async => false;
      await send('l1');
      // The report key (32) and the row's key (16) at enqueue; the key the
      // ciphertext goes out under (16) at encrypt.
      expect(engine.lengths, [32, 16, 16]);
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.idempotencyKey, matches(_keyShape));
      expect(row.idempotencyKey, _hex(engine.sixteens[1]));
      expect(_hex(engine.sixteens[0]), matches(_keyShape));
      expect(engine.sixteens[0], isNot(engine.sixteens[1]));
      rig.device.onConfirmStored = null;
      await drain();
      expect(rig.server.sends.single.key, row.idempotencyKey);
    });

    test('the expected id equals expectedMessageId(uid, key)', () async {
      await setUpJoined();
      final release = Completer<void>();
      final held = rig.locks.run(_c1, () => release.future);
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'a');
      final plain = (await outbox()).single;
      expect(
        plain.expectedMessageId,
        expectedMessageId('user-a', plain.idempotencyKey),
      );
      rig.device.onConfirmStored = (_, _) async => false;
      release.complete();
      await held;
      await rig.sender.settled(_c1);
      final encrypted = (await outbox()).single;
      expect(encrypted.stage, OutboxStage.encrypted);
      expect(
        encrypted.expectedMessageId,
        expectedMessageId('user-a', encrypted.idempotencyKey),
      );
      rig.device.onConfirmStored = null;
      await drain();
      expect((await stored()).single.messageId, encrypted.expectedMessageId);
    });

    test('content over 4096 bytes is refused before anything is '
        'stored', () async {
      await setUpJoined();
      await expectLater(
        rig.sender.enqueue(
          localId: 'l1',
          conversationId: _c1,
          text: 'x' * (kMaxMessageContentBytes + 1),
        ),
        throwsArgumentError,
      );
      await rig.sender.settled(_c1);
      expect(await outbox(), isEmpty);
      expect(rig.server.calls, isEmpty);
      expect(encrypts(), 0);
    });
  });

  group('sync before encrypt', () {
    test('nothing is encrypted before catch-up reached the server pair and '
        'attribution finished', () async {
      await setUpJoined();
      // The server moved on; this device's state is stale and it is offline.
      await bobSelfUpdate();
      offline();
      await send('l1');
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect((await outbox()).single.stage, OutboxStage.plain);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
      // Online: the commit is applied first, then the message is encrypted
      // on the server's pair, never on the stale one.
      rig.server.onCall = null;
      await drain();
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(await outbox(), isEmpty);
    });

    test('nothing is encrypted before one live pull completed, even with '
        'commits current', () async {
      await setUpJoined();
      rig.server.onCall = (call) async {
        if (call == 'listMlsMessages') throw const NetworkException('offline');
      };
      await send('l1');
      final context = rig.contexts.of(_c1);
      // Commits are current and attribution is done...
      expect(context.serverPair, const MlsPair(1, 1));
      expect(context.attributionPending, isFalse);
      // ...and still nothing is encrypted (M10).
      expect(context.syncedSinceStart, isFalse);
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
      rig.server.onCall = null;
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
    });

    test('no encrypt while a member is unattributed', () async {
      await setUpJoined(attributed: false);
      await send('l1');
      expectBlockedBeforeEncrypt();
      expect(
        (await rig.device.vault.members(_c1)).map((m) => m.side),
        contains(MemberSide.unattributed),
      );
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
    });

    test('no encrypt while epoch must advance, and the row goes out after '
        'any commit', () async {
      await setUpJoined();
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await send('l1');
      expectBlockedBeforeEncrypt();
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.epochMustAdvance,
      );
      // Another trigger changes nothing while the epoch stands.
      await drain();
      expect(encrypts(), 0);
      // Any commit (here the peer's) moves the epoch on.
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), isNotNull);
      expect((await sync()).epochMustAdvance, isFalse);
      await drain();
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(await outbox(), isEmpty);
    });

    test('no encrypt on a provisional group', () async {
      rig = await RigCrypto.create();
      bob = await RigPeer.create('bob');
      await rig.seedProvisional(_c2, [bob]);
      rig.device.engine.calls.clear();
      await rig.sender.enqueue(localId: 'l1', conversationId: _c2, text: 'x');
      await rig.sender.settled(_c2);
      expectBlockedBeforeEncrypt();
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      // Task 8 settles a provisional group: the sender starts no catch-up.
      expect(rig.server.calls, isEmpty);
      expect((await outbox(_c2)).single.stage, OutboxStage.plain);
      expect(
        (await rig.sender.outgoing(_c2)).single.waitingOn,
        SendBlock.provisional,
      );
    });

    test('no encrypt while this device\'s commit is pending, and the row '
        'goes out once it is settled', () async {
      await setUpJoined();
      final v = rig.device.vault;
      final group = (await v.group(_c1, 1))!;
      final commit = await rig.device.engine.inner.selfUpdate(
        (await v.deviceState())!,
        group.state,
      );
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: group.epoch,
            state: commit.groupState,
            pending: PendingCommit(
              kind: PendingKind.selfUpdate,
              builtOn: MlsPair(1, group.epoch),
              commit: commit.commit,
            ),
          ),
        ),
      );
      await send('l1');
      // The gate holds the row: the engine is not even asked.
      expectBlockedBeforeEncrypt();
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
      // The server stored the commit: catch-up settles it.
      rig.server.addCommit(
        _c1,
        MlsPair(1, group.epoch),
        commit.commit,
        fromUser: 'user-a',
      );
      await rig.crypto.catchUp(_c1);
      expect((await v.group(_c1, 1))!.hasPending, isFalse);
      await drain();
      expect(rig.server.sends.single.pair, MlsPair(1, group.epoch + 1));
      expect(await outbox(), isEmpty);
    });

    test('removed elsewhere: nothing is encrypted and nothing is '
        'sent', () async {
      await setUpJoined();
      rig.removedElsewhere = true;
      await send('l1');
      expect(encrypts(), 0);
      expect(rig.server.calls, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.unavailable,
      );
      rig.removedElsewhere = false;
      await drain();
      expect(rig.server.sends, hasLength(1));
    });
  });

  group('encrypt and send', () {
    test('encrypt, the outbox row and the sent digest are one '
        'transaction', () async {
      await setUpJoined();
      final groupBefore = (await rig.device.vault.group(_c1, 1))!.state;
      var fail = false;
      rig.device.cipher.failSeal = (label) =>
          fail &&
          label.contains('vault_outbox') &&
          label.contains('ciphertext');
      final release = Completer<void>();
      final held = rig.locks.run(_c1, () => release.future);
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'a');
      final plain = (await outbox()).single;
      // From here the encrypted row's write fails part-way through the
      // transaction.
      fail = true;
      release.complete();
      await held;
      await rig.sender.settled(_c1);
      expect(encrypts(), 1, reason: 'the engine was asked');
      expect((await rig.device.vault.group(_c1, 1))!.state, groupBefore);
      final after = (await outbox()).single;
      expect(after.stage, OutboxStage.plain);
      expect(after.idempotencyKey, plain.idempotencyKey);
      expect(await sentLog(), 0);
      expect(rig.server.sends, isEmpty);
      // With the write working, all three are stored together.
      fail = false;
      rig.device.onConfirmStored = (_, _) async => false;
      await drain();
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect((row.generation, row.epoch), (1, 1));
      expect(row.localId, 'l1');
      expect(row.reportCommitment, reportCommitment(row.content));
      expect(row.content, plain.content);
      expect((await rig.device.vault.group(_c1, 1))!.state, isNot(groupBefore));
      expect(
        await rig.device.vault.hasSent(
          _c1,
          const MlsPair(1, 1),
          sentDigest(row.ciphertext),
        ),
        isTrue,
      );
      expect(await sentLog(), 1);
      rig.device.onConfirmStored = null;
      await drain();
      expect(await outbox(), isEmpty);
    });

    test('the network call waits for confirmStored and is not made when it '
        'is false', () async {
      await setUpJoined();
      final events = <String>[];
      final reached = Completer<void>();
      final answer = Completer<bool>();
      rig.device.onConfirmStored = (key, real) async {
        events.add('confirm');
        if (!reached.isCompleted) reached.complete();
        return answer.future;
      };
      rig.server.beforeSend = (_) async => events.add('send');
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'a');
      await reached.future;
      // The row is saved and confirmStored has not answered: no call yet.
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(rig.device.confirmStoredCalls, [row.idempotencyKey]);
      expect(rig.server.sends, isEmpty);
      answer.complete(true);
      await rig.sender.settled(_c1);
      expect(events, ['confirm', 'send']);
      expect(rig.server.sends.single.key, row.idempotencyKey);

      // False: no network call; the row stays encrypted and is not
      // encrypted again for it.
      rig.device.onConfirmStored = (_, _) async => false;
      await send('l2');
      final kept = (await outbox()).single;
      expect(kept.stage, OutboxStage.encrypted);
      expect(rig.server.sends, hasLength(1));
      expect(encrypts(), 2);
      // An error is no confirmation either.
      rig.device.onConfirmStored = (_, _) async =>
          throw StateError('the read failed');
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(encrypts(), 2);
      expect((await outbox()).single.ciphertext, kept.ciphertext);
      // Confirmed at the next drain: the same bytes go out.
      rig.device.onConfirmStored = null;
      await drain();
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[1].key, kept.idempotencyKey);
      expect(rig.server.sends[1].ciphertext, kept.ciphertext);
      expect(encrypts(), 2);
      expect(await outbox(), isEmpty);
    });

    test('success stores the message under the expected id and removes the '
        'row', () async {
      await setUpJoined();
      // The answer's conversation row says "cannot reply". Task 9 audit L6:
      // a send answer is noted peer-only, so its can_reply is not taken
      // (only a header or an inbox row of this run, or a CANNOT_MESSAGE
      // answer, sets it).
      rig.server.beforeSend = (_) async =>
          rig.server.rows[_c1] = headerRow(canReply: false);
      rig.clock.advance(const Duration(seconds: 3));
      await send('l1', 'the text');
      expect(await outbox(), isEmpty);
      final sent = rig.server.sends.single;
      expect(sent.conversationId, _c1);
      expect(sent.pair, const MlsPair(1, 1));
      final m = (await stored()).single;
      expect(m.messageId, expectedMessageId('user-a', sent.key));
      expect(m.state, StoredMessageState.visible);
      expect(m.mine, isTrue);
      expect(m.check, StoredMessageCheck.ok);
      expect(textOf(m.content!), 'the text');
      expect(sent.commitment, reportCommitment(m.content!));
      expect(m.senderDeviceId, rig.device.deviceId);
      expect((m.generation, m.epoch), (1, 1));
      expect(m.createdAtMicros, rig.clock.now().microsecondsSinceEpoch);
      expect(rig.contexts.of(_c1).canReply, isTrue);
      expect(rig.changed, contains(_c1));
    });

    test('a timeout resends the identical bytes once and then waits at '
        'stage encrypted', () async {
      await setUpJoined();
      rig.server.sendScript.addAll([lost, lost]);
      await send('l1');
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[0].same(rig.server.sends[1]), isTrue);
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.idempotencyKey, rig.server.sends[0].key);
      expect(row.ciphertext, rig.server.sends[0].ciphertext);
      expect(row.lastError, isNull);
      expect(
        (await rig.sender.outgoing(_c1)).single.status,
        OutgoingStatus5a.sending,
      );
      // The next trigger: one more attempt, byte for byte.
      rig.server.sendScript.add(lost);
      await drain();
      expect(rig.server.sends, hasLength(3));
      expect(rig.server.sends[2].same(rig.server.sends[0]), isTrue);
      expect((await outbox()).single.stage, OutboxStage.encrypted);
      await drain();
      expect(rig.server.sends, hasLength(4));
      expect(rig.server.sends[3].same(rig.server.sends[0]), isTrue);
      expect(await outbox(), isEmpty);
      expect(encrypts(), 1);
      expect((await stored()).single.mine, isTrue);
    });

    test('an unknown outcome with a retry time is resent once, not before '
        'that time, capped at 24 hours', () async {
      await setUpJoined();
      rig.server.sendScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(hours: 48),
        ),
        stored: false,
      ));
      await send('l1');
      expect(rig.server.sends, hasLength(1));
      expect(rig.scheduled.single.delay, kMaxServerRetryWait);
      // A trigger before the server's time makes no call.
      await drain();
      expect(rig.server.sends, hasLength(1));
      rig.clock.advance(kMaxServerRetryWait);
      rig.scheduled.single.run();
      await rig.sender.settled(_c1);
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[1].same(rig.server.sends[0]), isTrue);
      expect(await outbox(), isEmpty);
      expect(encrypts(), 1);
      expect(rig.scheduled, hasLength(1));
    });

    test('after a restart a stage-encrypted row is resent byte for byte '
        'with the same key', () async {
      await setUpJoined();
      rig.server.sendScript.addAll([lost, lost]);
      await send('l1', 'first');
      // A second message is still plain behind it.
      rig.server.sendScript.add(lost);
      await send('l2', 'second');
      expect((await outbox()).map((r) => r.stage), [
        OutboxStage.encrypted,
        OutboxStage.plain,
      ]);
      final before = rig.server.sends.length;
      await rig.restart();
      final encryptsAtSend = <int>[];
      rig.server.beforeSend = (_) async => encryptsAtSend.add(encrypts());
      await drain();
      final resent = rig.server.sends[before];
      expect(resent.same(rig.server.sends[0]), isTrue);
      // Resent before anything was encrypted in this run.
      expect(encryptsAtSend.first, 1);
      expect(rig.server.sends.last.key, isNot(resent.key));
      expect(await outbox(), isEmpty);
      expect(encrypts(), 2);
      expect(
        {for (final m in await stored()) textOf(m.content!)},
        {'first', 'second'},
      );
    });

    test('rows are sent in order and stop at a failed head row', () async {
      await setUpJoined();
      final release = Completer<void>();
      final held = rig.locks.run(_c1, () => release.future);
      for (final (id, text) in [
        ('l1', 'one'),
        ('l2', 'two'),
        ('l3', 'three'),
      ]) {
        await rig.sender.enqueue(localId: id, conversationId: _c1, text: text);
      }
      // The second message is refused. (Each send a second later, so the
      // stored messages sort by time.)
      rig.server.beforeSend = (_) async {
        rig.clock.advance(const Duration(seconds: 1));
        if (rig.server.sends.length == 2) {
          rig.server.sendScript.add((
            error: const ValidationException('no'),
            stored: false,
          ));
        }
      };
      release.complete();
      await held;
      await rig.sender.settled(_c1);
      expect(rig.server.sends, hasLength(2));
      expect([for (final m in await stored()) textOf(m.content!)], ['one']);
      final left = await outbox();
      expect(left.map((r) => r.localId), ['l2', 'l3']);
      expect(left.map((r) => r.stage), [
        OutboxStage.encrypted,
        OutboxStage.plain,
      ]);
      // Nothing goes past the failed head row, whatever the trigger.
      await drain();
      expect(rig.server.sends, hasLength(2));
      expect(encrypts(), 2);
      await rig.sender.retry('l2');
      await rig.sender.settled(_c1);
      expect(rig.server.sends, hasLength(4));
      expect(await outbox(), isEmpty);
      final messages = await stored();
      messages.sort((a, b) => a.sortKey.compareTo(b.sortKey));
      expect(
        [for (final m in messages) textOf(m.content!)],
        ['one', 'two', 'three'],
      );
    });
  });

  group('STALE_EPOCH (M1)', () {
    test('STALE_EPOCH after which catch-up advanced the pair returns the row '
        'to plain and re-encrypts under a new key and a new expected '
        'id', () async {
      await setUpJoined();
      // A commit lands while the first send is in flight; the re-encrypt
      // that follows fails once, so the row can be seen back at plain.
      rig.server.beforeSend = (_) async {
        if (rig.server.sends.length != 1) return;
        await bobSelfUpdate();
        rig.device.engine.failNext['encrypt'] = const MlsException(
          MlsErrorCode.internal,
          'rig',
        );
      };
      await send('l1', 'again');
      final first = rig.server.sends.single;
      expect(first.pair, const MlsPair(1, 1));
      final plain = (await outbox()).single;
      expect(plain.stage, OutboxStage.plain);
      expect(plain.localId, 'l1');
      expect((plain.generation, plain.epoch), (0, 0));
      expect(plain.ciphertext, isEmpty);
      expect(plain.reportCommitment, isEmpty);
      expect(textOf(plain.content), 'again');
      expect(plain.idempotencyKey, isNot(first.key));
      expect(plain.idempotencyKey, matches(_keyShape));
      expect(
        plain.expectedMessageId,
        expectedMessageId('user-a', plain.idempotencyKey),
      );
      expect(
        plain.expectedMessageId,
        isNot(expectedMessageId('user-a', first.key)),
      );
      await drain();
      expect(rig.server.sends, hasLength(2));
      final second = rig.server.sends[1];
      expect(second.pair, const MlsPair(1, 2));
      expect(second.key, isNot(first.key));
      expect(second.ciphertext, isNot(first.ciphertext));
      expect(await outbox(), isEmpty);
      final m = (await stored()).single;
      expect(m.messageId, expectedMessageId('user-a', second.key));
      expect(textOf(m.content!), 'again');
      expect((m.generation, m.epoch), (1, 2));
    });

    test('STALE_EPOCH with an unchanged pair keeps the bytes and never '
        're-encrypts', () async {
      await setUpJoined();
      rig.server.sendScript.add((
        error: const StaleEpochException('stale', generation: 1, epoch: 1),
        stored: false,
      ));
      await send('l1');
      expect(rig.server.sends, hasLength(1));
      // Catch-up and the live pull ran first.
      expect(rig.server.calls.last, isNot('sendEncrypted'));
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.idempotencyKey, rig.server.sends[0].key);
      expect(row.ciphertext, rig.server.sends[0].ciphertext);
      expect(row.lastError, isNull);
      expect(encrypts(), 1);
      expect(
        (await rig.sender.outgoing(_c1)).single.status,
        OutgoingStatus5a.sending,
      );
      await drain();
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[1].same(rig.server.sends[0]), isTrue);
      expect(await outbox(), isEmpty);
      expect(encrypts(), 1);
    });

    test('STALE_EPOCH whose echo is found by the live pull completes the row '
        'without re-encrypting', () async {
      await setUpJoined();
      // The server stored the message and answered STALE_EPOCH for it.
      rig.server.sendScript.add((
        error: const StaleEpochException('stale', generation: 1, epoch: 1),
        stored: true,
      ));
      await send('l1', 'kept once');
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
      expect(encrypts(), 1);
      final m = (await stored()).single;
      expect(m.messageId, expectedMessageId('user-a', rig.server.sends[0].key));
      expect(m.mine, isTrue);
      expect(textOf(m.content!), 'kept once');
      await drain();
      expect(rig.server.sends, hasLength(1));
    });

    test('at most kStaleEpochRoundsPerDrain rounds in one drain', () async {
      await setUpJoined();
      expect(kStaleEpochRoundsPerDrain, 3);
      // Every send meets a commit that landed just before it.
      rig.server.beforeSend = (_) => bobSelfUpdate();
      await send('l1');
      expect(rig.server.sends, hasLength(kStaleEpochRoundsPerDrain));
      expect(encrypts(), kStaleEpochRoundsPerDrain);
      expect((await outbox()).single.stage, OutboxStage.plain);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
      rig.server.beforeSend = null;
      await drain();
      expect(await outbox(), isEmpty);
    });

    test('only STALE_EPOCH re-encrypts: a refusal keeps the bytes', () async {
      await setUpJoined();
      final refusals = <(AppException, String)>[
        (
          const RateLimitedException('slow', retryAfter: Duration(seconds: 2)),
          'RateLimitedException',
        ),
        (const ValidationException('bad'), 'ValidationException'),
        (const FeatureDisabledException('off'), 'FeatureDisabledException'),
        (const LimitReachedException('cap'), 'LimitReachedException'),
        (const EmailNotVerifiedException('mail'), 'EmailNotVerifiedException'),
        (const DegradedModeException('down'), 'DegradedModeException'),
      ];
      rig.server.sendScript.add((error: refusals[0].$1, stored: false));
      await send('l1');
      for (var i = 0; i < refusals.length; i++) {
        final (error, name) = refusals[i];
        expect(rig.server.sends, hasLength(i + 1));
        final row = (await outbox()).single;
        expect(row.stage, OutboxStage.encrypted);
        expect(row.idempotencyKey, rig.server.sends[0].key);
        expect(row.ciphertext, rig.server.sends[0].ciphertext);
        expect(row.attempts, i + 1);
        expect(row.lastError, name);
        final out = (await rig.sender.outgoing(_c1)).single;
        expect(out.status, OutgoingStatus5a.failed);
        expect(out.error, same(error));
        // A trigger does not resend a failed row; retry does, same bytes.
        await drain();
        expect(rig.server.sends, hasLength(i + 1));
        if (i + 1 < refusals.length) {
          rig.server.sendScript.add((error: refusals[i + 1].$1, stored: false));
        }
        await rig.sender.retry('l1');
        await rig.sender.settled(_c1);
        expect(rig.server.sends[i + 1].same(rig.server.sends[0]), isTrue);
      }
      expect(await outbox(), isEmpty);
      expect(encrypts(), 1);
    });

    test('CANNOT_MESSAGE fails the row with the typed error and marks the '
        'thread read-only', () async {
      await setUpJoined();
      rig.server.sendScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await send('l1');
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.attempts, 1);
      expect(row.lastError, 'CannotMessageException');
      final out = (await rig.sender.outgoing(_c1)).single;
      expect(out.status, OutgoingStatus5a.failed);
      expect(out.error, isA<CannotMessageException>());
      expect(out.retryable, isFalse);
      expect(rig.contexts.of(_c1).canReply, isFalse);
      // Read-only: a retry makes no call while the thread cannot be
      // answered.
      await rig.sender.retry('l1');
      await rig.sender.settled(_c1);
      expect(rig.server.sends, hasLength(1));
      expect(encrypts(), 1);
    });
  });

  group('an unaccepted incoming request (M3)', () {
    test('no accept call while another gate holds the row', () async {
      await setUpJoined(accepted: false, folder: Folder.FOLDER_REQUESTS);
      rig.onAcceptForReply = acceptanceSteps;
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await send('l1');
      expect(rig.contexts.of(_c1).incomingRequest, isTrue);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
      expect(rig.acceptCalls, isEmpty);
      expect(encrypts(), 0);
      // The thread cannot be answered: no accept either.
      await updateSync((s) => s.copyWith(epochMustAdvance: false));
      rig.contexts.note(
        headerRow(folder: Folder.FOLDER_REQUESTS, canReply: false),
      );
      await drain();
      expect(rig.acceptCalls, isEmpty);
      expect(encrypts(), 0);
      // With every other gate open the reply accepts and goes out.
      rig.contexts.note(headerRow(folder: Folder.FOLDER_REQUESTS));
      await drain();
      expect(rig.acceptCalls, [_c1]);
      expect(rig.server.sends, hasLength(1));
    });

    test('no accept call while the direction is unknown', () async {
      await setUpJoined(accepted: false, folder: null);
      rig.onAcceptForReply = acceptanceSteps;
      await send('l1');
      expect(rig.contexts.of(_c1).incomingRequest, isNull);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
      expect(rig.acceptCalls, isEmpty);
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect((await outbox()).single.stage, OutboxStage.plain);
    });

    test('a failed accept leaves requestAccepted false', () async {
      await setUpJoined(accepted: false, folder: Folder.FOLDER_REQUESTS);
      for (final Object failure in [
        const NotFoundException('gone'),
        const NetworkException('offline'),
        const CannotMessageException(),
      ]) {
        rig.acceptCalls.clear();
        rig.onAcceptForReply = (_) async => throw failure;
        if ((await outbox()).isEmpty) {
          await send('l1');
        } else {
          await drain();
        }
        // One call per drain, and nothing changed.
        expect(rig.acceptCalls, [_c1]);
        expect((await sync()).requestAccepted, isFalse);
        expect(rig.contexts.of(_c1).incomingRequest, isTrue);
        expect(encrypts(), 0);
        expect(rig.server.sends, isEmpty);
        expect((await outbox()).single.stage, OutboxStage.plain);
      }
    });

    test('an incoming unaccepted request whose reply can otherwise go out '
        'accepts as the last gate, then runs the acceptance steps before the '
        'first reply is encrypted', () async {
      await setUpJoined(accepted: false, folder: Folder.FOLDER_REQUESTS);
      final events = <String>[];
      rig.onAcceptForReply = (id) async {
        // Synced first: catch-up and the live pull came before the accept.
        events.add(
          'accept synced=${rig.contexts.of(id).syncedSinceStart} '
          'encrypts=${encrypts()}',
        );
        await acceptanceSteps(id);
        events.add('steps done encrypts=${encrypts()}');
      };
      rig.server.beforeSend = (_) async =>
          events.add('send encrypts=${encrypts()}');
      await send('l1');
      expect(events, [
        'accept synced=true encrypts=0',
        'steps done encrypts=0',
        'send encrypts=1',
      ]);
      expect(rig.acceptCalls, [_c1]);
      expect(await outbox(), isEmpty);
      // An accept that reports success without accepting sends nothing.
      await updateSync((s) => s.copyWith(requestAccepted: false));
      rig.contexts.of(_c1).incomingRequest = true;
      rig.onAcceptForReply = (_) async {};
      await send('l2');
      expect(rig.acceptCalls, [_c1, _c1]);
      expect(rig.server.sends, hasLength(1));
      expect(encrypts(), 1);
    });

    test('drain that needs catch-up and acceptance completes without taking '
        'the conversation lock twice', () async {
      final locks = _ProbeLocks();
      await setUpJoined(
        accepted: false,
        folder: Folder.FOLDER_REQUESTS,
        locks: locks,
      );
      // The server moved on: the drain needs a real catch-up.
      await bobSelfUpdate();
      var lockedCatchUps = 0;
      rig.onAcceptForReply = (id) async {
        // Task 9's steps run under the drain's lock and use the locked
        // entries (reconcile, catch-up).
        expect(locks.isHeld(id), isTrue);
        await acceptanceSteps(id);
        await rig.crypto.catchUpLocked(id, priority: BudgetPriority.user);
        lockedCatchUps++;
      };
      locks.acquired = 0;
      await send('l1');
      expect(locks.reentered, 0);
      expect(locks.acquired, greaterThan(1));
      expect(lockedCatchUps, 1);
      expect(rig.acceptCalls, [_c1]);
      expect(rig.server.calls, contains('listConversationCommits'));
      expect(rig.server.calls, contains('listMlsMessages'));
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(await outbox(), isEmpty);
    });
  });

  group('discard and outgoing', () {
    test('discard removes an unsent row and refuses one the server '
        'accepted', () async {
      await setUpJoined();
      // A plain row was never sent: it goes at once, with no network call.
      offline();
      await send('l1');
      rig.server.calls.clear();
      await rig.sender.discard('l1');
      expect(await outbox(), isEmpty);
      expect(rig.server.calls, isEmpty);
      rig.server.onCall = null;

      // An unknown outcome the server did store: the live pull finds the
      // echo, the message is kept and nothing is discarded.
      const kept = (error: NetworkException('timed out'), stored: true);
      rig.server.sendScript.addAll([kept, kept]);
      await send('l2', 'accepted');
      expect((await outbox()).single.stage, OutboxStage.encrypted);
      await rig.sender.discard('l2');
      expect(await outbox(), isEmpty);
      expect(
        [for (final m in await stored()) textOf(m.content!)],
        ['accepted'],
      );

      // An unknown outcome the server did not store: one live pull found no
      // echo, the row goes.
      rig.server.sendScript.addAll([lost, lost]);
      await send('l3', 'never arrived');
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      // While the pull cannot complete the row stays.
      offline();
      await rig.sender.discard('l3');
      expect((await outbox()).single.idempotencyKey, row.idempotencyKey);
      rig.server.onCall = null;
      await rig.sender.discard('l3');
      expect(await outbox(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isFalse,
      );
      expect(await stored(), hasLength(1));
      // An unknown local id is a no-op.
      await rig.sender.discard('nope');
      await rig.sender.retry('nope');
    });

    test('discard keeps a row whose send was in flight during its live '
        'pull', () async {
      await setUpJoined();
      rig.server.sendScript.addAll([lost, lost]);
      await send('l1', 'in flight');
      // The next send is in flight (the lock is held) while discard pulls;
      // the server stores the message and the answer is lost.
      final inFlight = Completer<void>();
      final go = Completer<void>();
      rig.server.beforeSend = (_) async {
        inFlight.complete();
        await go.future;
      };
      rig.server.sendScript.add((
        error: const NetworkException('timed out'),
        stored: true,
      ));
      final draining = drain();
      await inFlight.future;
      rig.server.beforeSend = null;
      // The pull's listing is answered first; only then is the send stored.
      rig.server.rewriteLive = (real) {
        if (!go.isCompleted) go.complete();
        return real;
      };
      final discarding = rig.sender.discard('l1');
      await draining;
      await discarding;
      // Not discarded: the pull began before that send ended.
      expect((await outbox()).single.stage, OutboxStage.encrypted);
      // Asked again, the pull finds the echo and the message is kept.
      await rig.sender.discard('l1');
      expect(await outbox(), isEmpty);
      expect(
        [for (final m in await stored()) textOf(m.content!)],
        ['in flight'],
      );
    });

    test('outgoing reports waiting with its reason, sending and '
        'failed', () async {
      await setUpJoined();
      expect(await rig.sender.outgoing(_c1), isEmpty);
      offline();
      await send('l1', 'shown');
      var out = (await rig.sender.outgoing(_c1)).single;
      expect(out.localId, 'l1');
      expect(out.conversationId, _c1);
      expect(textOf(out.content), 'shown');
      expect(out.createdAt, rig.clock.now());
      expect(out.status, OutgoingStatus5a.waiting);
      expect(out.waitingOn, SendBlock.notSynced);
      expect(out.error, isNull);
      expect(out.retryable, isFalse);
      expect(out.tryTomorrow, isFalse);

      rig.server.onCall = null;
      rig.server.sendScript.addAll([lost, lost]);
      await drain();
      out = (await rig.sender.outgoing(_c1)).single;
      expect(out.status, OutgoingStatus5a.sending);
      expect(out.waitingOn, SendBlock.none);
      expect(out.error, isNull);

      rig.server.sendScript.add((
        error: const RateLimitedException(
          'cap',
          limitName: 'messaging_send_daily',
        ),
        stored: false,
      ));
      await drain();
      out = (await rig.sender.outgoing(_c1)).single;
      expect(out.status, OutgoingStatus5a.failed);
      expect(out.error, isA<RateLimitedException>());
      expect(out.retryable, isTrue);
      expect(out.tryTomorrow, isTrue);
      // After a restart the row is still failed; the typed error was in
      // memory only.
      await rig.restart();
      out = (await rig.sender.outgoing(_c1)).single;
      expect(out.status, OutgoingStatus5a.failed);
      expect(out.error, isNull);
      expect(out.retryable, isTrue);
      await drain();
      expect(rig.server.calls.where((c) => c == 'sendEncrypted'), hasLength(3));
    });
  });

  group('a fresh server pair before encrypt (audit M1)', () {
    void failCommitListing() => rig.server.onCall = (call) async {
      if (call == 'listConversationCommits') throw lost.error;
    };

    test('an interrupted drain, then a completed receive pass: the next '
        'drain does not encrypt on the stale pair', () async {
      await setUpJoined();
      final context = rig.contexts.of(_c1);
      // The server moves to (1, 2); this device read (1, 1) at the join.
      await bobSelfUpdate();
      failCommitListing();
      await send('l1');
      expect(encrypts(), 0);
      expect(context.serverPair, const MlsPair(1, 1));
      // A push: a receive pass that completes at the device's pair.
      final pull = await rig.receiver.pullLive(_c1);
      expect(pull.kind, ReceiveOutcomeKind.complete);
      expect(context.livePulledAt, const MlsPair(1, 1));
      // The second drain's commit listing still fails.
      await drain();
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect((await outbox()).single.stage, OutboxStage.plain);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.notSynced,
      );
      expect(context.syncedSinceStart, isFalse);
      // A catch-up that ends current: the row goes out on the server's pair.
      rig.server.onCall = null;
      await drain();
      expect(context.syncedSinceStart, isTrue);
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(await outbox(), isEmpty);
    });

    test('an interrupted receiver-side catch-up, then a completed receive '
        'pass: a drain does not encrypt on the stale pair', () async {
      await setUpJoined();
      final context = rig.contexts.of(_c1);
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );
      expect(context.syncedSinceStart, isTrue);
      await bobSelfUpdate();
      failCommitListing();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(context.syncedSinceStart, isFalse);
      expect(context.serverPair, const MlsPair(1, 1));
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );
      // The stale pair never sets the flag again.
      expect(context.syncedSinceStart, isFalse, reason: 'a stale server pair');
      await send('l1');
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect((await outbox()).single.stage, OutboxStage.plain);
      rig.server.onCall = null;
      await drain();
      expect(context.syncedSinceStart, isTrue);
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(await outbox(), isEmpty);
    });
  });

  group('an encrypted row while a member is not attributable (audit M2)', () {
    /// Bob's pin is stored with [side] (what attribution, or a verdict that
    /// takes it back, leaves in the vault).
    Future<void> pinBob(String side) async {
      final v = rig.device.vault;
      final m = (await v.members(_c1))
          .singleWhere((m) => rigEq(m.deviceId, bob.id));
      await v.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: m.deviceId,
            signatureKey: m.signatureKey,
            side: side,
            since: m.since,
          ),
        ),
      );
    }

    /// 'l1' is encrypted and was never sent (the barrier answered false).
    Future<OutboxItem> encryptedNeverSent() async {
      rig.device.onConfirmStored = (_, _) async => false;
      await send('l1', 'first');
      rig.device.onConfirmStored = null;
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(rig.server.sends, isEmpty);
      return row;
    }

    test('it is not sent while a member is unattributed, nothing is sent '
        'past it, and it goes out byte for byte once attribution '
        'returns', () async {
      await setUpJoined();
      final row = await encryptedNeverSent();
      // This device no longer knows whose bob's device is.
      await pinBob(MemberSide.unattributed);
      await send('l2', 'second');
      await drain();
      await rig.sender.retry('l1');
      await rig.sender.settled(_c1);
      expect(rig.server.sends, isEmpty);
      expect(encrypts(), 1, reason: 'nothing is encrypted past it');
      var out = await rig.sender.outgoing(_c1);
      expect(out.map((r) => r.localId), ['l1', 'l2']);
      expect(out.map((r) => r.status), [
        OutgoingStatus5a.waiting,
        OutgoingStatus5a.waiting,
      ]);
      // The reason the plain row's gate gives.
      expect(out.map((r) => r.waitingOn), [
        SendBlock.notSynced,
        SendBlock.notSynced,
      ]);
      // Never encrypted again for this: the bytes and the key stay.
      final kept = (await outbox()).first;
      expect(kept.stage, OutboxStage.encrypted);
      expect(kept.idempotencyKey, row.idempotencyKey);
      expect(kept.ciphertext, row.ciphertext);

      await pinBob(MemberSide.theirs);
      out = await rig.sender.outgoing(_c1);
      expect(out.first.status, OutgoingStatus5a.sending);
      await drain();
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[0].key, row.idempotencyKey);
      expect(rig.server.sends[0].ciphertext, row.ciphertext);
      expect(rig.server.sends[0].pair, const MlsPair(1, 1));
      expect(rig.server.sends[1].key, isNot(row.idempotencyKey));
      expect(encrypts(), 2);
      expect(await outbox(), isEmpty);
      expect(
        {for (final m in await stored()) textOf(m.content!)},
        {'first', 'second'},
      );
    });

    test('it is not sent while attribution is pending, and the drain\'s own '
        'catch-up lets it go', () async {
      await setUpJoined();
      final row = await encryptedNeverSent();
      // A new member is not attributed yet, and the catch-up that would
      // conclude it cannot run.
      rig.contexts.of(_c1).attributionPending = true;
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') throw lost.error;
      };
      await drain();
      expect(rig.server.sends, isEmpty);
      final out = (await rig.sender.outgoing(_c1)).single;
      expect(out.status, OutgoingStatus5a.waiting);
      expect(out.waitingOn, SendBlock.notSynced);
      rig.server.onCall = null;
      await drain();
      expect(rig.contexts.of(_c1).attributionPending, isFalse);
      expect(rig.server.sends.single.key, row.idempotencyKey);
      expect(rig.server.sends.single.ciphertext, row.ciphertext);
      expect(encrypts(), 1);
      expect(await outbox(), isEmpty);
    });

    test('epoch must advance does not hold a resend', () async {
      await setUpJoined();
      final row = await encryptedNeverSent();
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await drain();
      expect(rig.server.sends.single.key, row.idempotencyKey);
      expect(await outbox(), isEmpty);
    });
  });

  group('random output of another length (audit L6)', () {
    late _CutRandomEngine engine;

    /// The reports so far, as step names; the list is emptied.
    List<String> takeReports() {
      final steps = [
        for (final e in rig.unexpected) (e as E2eePipelineError).step,
      ];
      rig.unexpected.clear();
      return steps;
    }

    test('enqueue stores nothing and throws StateError', () async {
      engine = _CutRandomEngine();
      await setUpJoined(engine: engine);
      for (final length in [kReportKeyBytes, 16]) {
        for (final keep in [length - 1, 0]) {
          engine.cut = (n) => n == length ? keep : null;
          await expectLater(
            rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'a'),
            throwsStateError,
            reason: '$keep of $length bytes',
          );
          await rig.sender.settled(_c1);
          expect(await outbox(), isEmpty);
        }
      }
      expect(rig.server.calls, isEmpty);
      expect(encrypts(), 0);
      engine.cut = null;
      await send('l1');
      expect(rig.server.sends, hasLength(1));
    });

    test('the encrypt stops the row as unavailable, stores nothing and '
        'reports once', () async {
      engine = _CutRandomEngine();
      await setUpJoined(engine: engine);
      rig.removedElsewhere = true;
      await send('l1');
      rig.removedElsewhere = false;
      final plain = (await outbox()).single;
      final groupBefore = (await rig.device.vault.group(_c1, 1))!.state;
      for (final keep in [15, 0]) {
        engine.cut = (n) => n == 16 ? keep : null;
        await drain();
        expect(encrypts(), 0, reason: '$keep bytes');
        expect(rig.server.sends, isEmpty);
        final row = (await outbox()).single;
        expect(row.stage, OutboxStage.plain);
        expect(row.idempotencyKey, plain.idempotencyKey);
        expect((await rig.device.vault.group(_c1, 1))!.state, groupBefore);
        expect(
          (await rig.sender.outgoing(_c1)).single.waitingOn,
          SendBlock.unavailable,
        );
      }
      expect(takeReports(), ['send.encrypt.random']);
      engine.cut = null;
      await drain();
      expect(rig.server.sends.single.key, matches(_keyShape));
      expect(await outbox(), isEmpty);
    });

    test('the return to plain after STALE_EPOCH keeps the encrypted row and '
        'reports once', () async {
      engine = _CutRandomEngine();
      await setUpJoined(engine: engine);
      rig.server.beforeSend = (_) async {
        if (rig.server.sends.length != 1) return;
        await bobSelfUpdate();
        engine.cut = (n) => n == 16 ? 15 : null;
      };
      await send('l1');
      final first = rig.server.sends.single;
      var row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.idempotencyKey, first.key);
      expect(row.ciphertext, first.ciphertext);
      engine.cut = (n) => n == 16 ? 0 : null;
      await drain();
      row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.idempotencyKey, first.key);
      expect(encrypts(), 1);
      expect(takeReports(), ['send.stale.random']);
      engine.cut = null;
      await drain();
      expect(rig.server.sends.last.pair, const MlsPair(1, 2));
      expect(rig.server.sends.last.key, isNot(first.key));
      expect(rig.server.sends.last.key, matches(_keyShape));
      expect(await outbox(), isEmpty);
    });
  });

  group('a joined drain (code review I1)', () {
    test('a user call that joins a background drain makes the rerun a user '
        'drain', () async {
      late _SpyBudget budget;
      await setUpJoined(syncBudget: (clock) => budget = _SpyBudget(clock));
      // A waiting plain row, with no drain running.
      rig.removedElsewhere = true;
      await send('l1');
      rig.removedElsewhere = false;
      // The priority of the unit each commit listing was made with. The
      // first listing waits, then fails: that drain's row stays.
      final atListing = <BudgetPriority>[];
      final listing = Completer<void>();
      final release = Completer<void>();
      rig.server.onCall = (call) async {
        if (call != 'listConversationCommits') return;
        atListing.add(budget.taken.last);
        if (atListing.length > 1) return;
        listing.complete();
        await release.future;
        throw lost.error;
      };
      final background = rig.sender.drain(
        _c1,
        priority: BudgetPriority.background,
      );
      await listing.future;
      // The user's send joins the running drain.
      final user = rig.sender.drain(_c1, priority: BudgetPriority.user);
      release.complete();
      await Future.wait([background, user]);
      expect(atListing, [BudgetPriority.background, BudgetPriority.user]);
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
    });

    test('a background call that joins a user drain reruns in the '
        'background', () async {
      late _SpyBudget budget;
      await setUpJoined(syncBudget: (clock) => budget = _SpyBudget(clock));
      rig.removedElsewhere = true;
      await send('l1');
      rig.removedElsewhere = false;
      final atListing = <BudgetPriority>[];
      final listing = Completer<void>();
      final release = Completer<void>();
      rig.server.onCall = (call) async {
        if (call != 'listConversationCommits') return;
        atListing.add(budget.taken.last);
        if (atListing.length > 1) return;
        listing.complete();
        await release.future;
        throw lost.error;
      };
      final user = rig.sender.drain(_c1, priority: BudgetPriority.user);
      await listing.future;
      // Two joiners: the strongest of them is what the rerun uses.
      final joined = [
        rig.sender.drain(_c1, priority: BudgetPriority.background),
        rig.sender.drain(_c1, priority: BudgetPriority.live),
        rig.sender.drain(_c1, priority: BudgetPriority.background),
      ];
      release.complete();
      await Future.wait([user, ...joined]);
      expect(atListing, [BudgetPriority.user, BudgetPriority.live]);
      expect(rig.server.sends, hasLength(1));
    });
  });

  group('the scheduled resend\'s priority (Task 9 review m1)', () {
    const busy = ScreeningUnavailableException(
      'busy',
      retryAfter: Duration(minutes: 1),
    );

    /// Runs the one scheduled resend, whose send answers STALE_EPOCH, and
    /// answers the priority of the unit its catch-up listed commits with.
    Future<BudgetPriority> resendPriority(_SpyBudget budget) async {
      expect(rig.scheduled, hasLength(1));
      final atListing = <BudgetPriority>[];
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') atListing.add(budget.taken.last);
      };
      rig.server.sendScript.add((
        error: const StaleEpochException('stale', generation: 1, epoch: 1),
        stored: false,
      ));
      rig.clock.advance(busy.retryAfter!);
      rig.scheduled.single.run();
      await rig.sender.settled(_c1);
      expect(rig.server.sends, hasLength(2));
      expect(atListing, isNotEmpty);
      return atListing.first;
    }

    test('a user drain\'s resend drains at live: never user (it does not '
        'accept), never behind the background sweep', () async {
      late _SpyBudget budget;
      await setUpJoined(syncBudget: (clock) => budget = _SpyBudget(clock));
      rig.server.sendScript.add((error: busy, stored: false));
      await send('l1');
      expect(rig.server.sends, hasLength(1));

      expect(await resendPriority(budget), BudgetPriority.live);
    });

    test('a background drain\'s resend stays at background', () async {
      late _SpyBudget budget;
      await setUpJoined(syncBudget: (clock) => budget = _SpyBudget(clock));
      rig.removedElsewhere = true;
      await send('l1');
      rig.removedElsewhere = false;
      rig.server.sendScript.add((error: busy, stored: false));
      await rig.sender.drain(_c1, priority: BudgetPriority.background);
      expect(rig.server.sends, hasLength(1));

      expect(await resendPriority(budget), BudgetPriority.background);
    });
  });

  group('a failed outbox read (code review I3)', () {
    /// 'l1' waits at stage plain with no drain running and every gate of
    /// an encrypt open (so `outgoing` shows what the last drain left).
    Future<void> waitingRow() async {
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
      final release = Completer<void>();
      final held = rig.locks.run(_c1, () => release.future);
      await rig.sender.enqueue(
        localId: 'l1',
        conversationId: _c1,
        text: 'kept',
      );
      rig.removedElsewhere = true;
      release.complete();
      await held;
      await rig.sender.settled(_c1);
      rig.removedElsewhere = false;
      expect((await outbox()).single.stage, OutboxStage.plain);
    }

    test('outgoing throws the vault\'s key exception during a keystore '
        'outage, and the rows are reported and sent once after it', () async {
      await setUpJoined();
      await waitingRow();
      rig.device.cipher.unavailable = true;
      await expectLater(
        rig.sender.outgoing(_c1),
        throwsA(isA<VaultKeyException>()),
      );
      await drain();
      expect(rig.server.sends, isEmpty);
      rig.device.cipher.unavailable = false;
      final out = (await rig.sender.outgoing(_c1)).single;
      expect(out.localId, 'l1');
      expect(textOf(out.content), 'kept');
      expect(out.status, OutgoingStatus5a.waiting);
      expect(out.waitingOn, SendBlock.unavailable);
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
      expect([for (final m in await stored()) textOf(m.content!)], ['kept']);
      expect(await rig.sender.outgoing(_c1), isEmpty);
    });

    test('a drain that dies on a failed read leaves unavailable as the '
        'reason', () async {
      await setUpJoined();
      await waitingRow();
      // A trigger with every gate open would clear the earlier reason.
      var reads = 0;
      rig.device.onOutbox = () async {
        reads++;
        throw const VaultKeyException(VaultKeyFailure.unavailable);
      };
      await expectLater(
        rig.sender.outgoing(_c1),
        throwsA(isA<VaultKeyException>()),
      );
      reads = 0;
      await drain();
      expect(reads, 1, reason: 'the drain read the outbox and died');
      rig.device.onOutbox = null;
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.unavailable,
      );
      expect(encrypts(), 0);
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
    });

    test('outgoing throws StateError while the vault is not open', () async {
      await setUpJoined();
      await waitingRow();
      rig.device.owner!.steal();
      await expectLater(rig.sender.outgoing(_c1), throwsStateError);
    });
  });

  group('the welcome poll between two holds', () {
    /// A send that meets a new generation whose welcome is on the second
    /// page: the drain's catch-up answers "waiting for a welcome".
    void secondPageWelcomeAtSend() => rig.server.beforeSend = (_) async {
      rig.server.beforeSend = null;
      for (var i = 0; i < 10; i++) {
        rig.server.addWelcome(
          rig.device.deviceIdString,
          i.toRadixString(16).padLeft(32, '0'),
          const MlsPair(1, kMaxPairComponent),
          Uint8List(0),
        );
      }
      await rig.offer(_c1, bob, generation: 2);
    };

    test('a welcome poll that throws is reported once and the drain goes '
        'on to the pull', () async {
      late _SpyBudget budget;
      await setUpJoined(syncBudget: (clock) => budget = _SpyBudget(clock));
      secondPageWelcomeAtSend();
      // The drain's unheld poll: its first unit outside the lock throws.
      var thrown = 0;
      budget.onTake = () {
        if (rig.server.sends.isEmpty || rig.locks.isHeld(_c1)) return;
        budget.onTake = null;
        thrown = rig.server.calls.length;
        throw UnsupportedError('rig: the poll failed');
      };
      await send('l1');
      final reports = [
        for (final e in rig.unexpected) (e as E2eePipelineError).step,
      ];
      rig.unexpected.clear();
      expect(reports, ['send.welcomes']);
      expect(thrown, greaterThan(0));
      // The live pull still ran after the failed poll.
      expect(rig.server.calls.skip(thrown), contains('listMlsMessages'));
      expect((await outbox()).single.stage, OutboxStage.encrypted);
      // The welcome is still unread. Once a later poll (a push, a resume)
      // has joined, the next trigger sends on the new generation.
      expect(await rig.crypto.processWelcomes(), [_c1]);
      await drain();
      expect(rig.server.sends.last.pair, const MlsPair(2, 1));
      expect(await outbox(), isEmpty);
    });

    test('a join made by a poll running beside the drain\'s own is not '
        'missed', () async {
      await setUpJoined();
      secondPageWelcomeAtSend();
      // While the drain's unheld poll lists, another poll (a push) joins
      // and acknowledges the welcome: the drain's own poll joins nothing.
      var beside = <String>[];
      rig.server.onCall = (call) async {
        if (call != 'listWelcomes' || rig.locks.isHeld(_c1)) return;
        rig.server.onCall = null;
        beside = await rig.crypto.processWelcomes();
      };
      await send('l1');
      expect(beside, [_c1]);
      expect(rig.server.sends.map((s) => s.pair), [
        const MlsPair(1, 1),
        const MlsPair(2, 1),
      ]);
      expect(await outbox(), isEmpty);
      expect((await stored()).single.generation, 2);
    });
  });

  group('this run\'s memory of a row', () {
    test('a row its STALE_EPOCH echo completed is forgotten', () async {
      await setUpJoined();
      rig.server.sendScript.add((
        error: const StaleEpochException('stale', generation: 1, epoch: 1),
        stored: true,
      ));
      await send('l1');
      expect(await outbox(), isEmpty);
      expect((await stored()).single.mine, isTrue);
      expect(rig.sender.memoryEntries, 0);
    });

    test('a row a receive pass completed is forgotten at the end of the '
        'next drain, and a waiting row is not', () async {
      await setUpJoined();
      const kept = (error: NetworkException('timed out'), stored: true);
      rig.server.sendScript.addAll([kept, kept]);
      await send('l1');
      expect((await outbox()).single.stage, OutboxStage.encrypted);
      // Still waiting: its unknown outcome and its send calls are kept.
      expect(rig.sender.memoryEntries, 2);
      await rig.receiver.pullLive(_c1);
      expect(await outbox(), isEmpty, reason: 'the echo completed the row');
      await drain();
      expect(rig.sender.memoryEntries, 0);
      expect(rig.server.sends, hasLength(2));
    });

    test('a refusal met after the vault was lost changes nothing in '
        'memory', () async {
      await setUpJoined();
      rig.server.beforeSend = (_) async {
        rig.device.owner!.steal();
        // The session has taken the loss in before the server answers.
        while (rig.device.session.vault != null) {
          await Future<void>.delayed(Duration.zero);
        }
      };
      rig.server.sendScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await send('l1');
      expect(rig.server.sends, hasLength(1));
      expect(rig.contexts.of(_c1).canReply, isTrue);
      await rig.restart();
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.lastError, isNull);
      expect(row.attempts, 0);
    });
  });

  group('rows with an init are left to Task 8', () {
    /// An outbox row with an init, as the first message of a provisional
    /// group is stored: stage encrypted, with bytes this class never made.
    Future<OutboxItem> seedInitRow(
      String c, {
      String? lastError,
      Duration after = Duration.zero,
    }) async {
      final content = encodeMessageContent(
        text: 'the first message',
        reportKey: Uint8List(kReportKeyBytes),
      );
      final key = 'ab' * 16;
      final item = OutboxItem(
        idempotencyKey: key,
        localId: 'init-1',
        expectedMessageId: expectedMessageId('user-a', key),
        conversationId: c,
        generation: 1,
        epoch: 1,
        ciphertext: Uint8List.fromList(List.filled(40, 7)),
        reportCommitment: reportCommitment(content),
        content: content,
        createdAtMicros: rig.clock.now().add(after).microsecondsSinceEpoch,
        init: Uint8List.fromList([1, 2, 3, 4]),
        attempts: lastError == null ? 0 : 1,
        lastError: lastError,
      );
      await rig.device.vault.transaction((tx) => tx.putOutbox(item));
      return item;
    }

    Future<void> setUpProvisional() async {
      rig = await RigCrypto.create();
      bob = await RigPeer.create('bob');
      await rig.seedProvisional(_c2, [bob]);
      rig.device.engine.calls.clear();
    }

    test('an init row at the head: nothing is sent or encrypted, and the '
        'row behind it waits as provisional', () async {
      await setUpProvisional();
      await seedInitRow(_c2);
      rig.clock.advance(const Duration(seconds: 1));
      await rig.sender.enqueue(localId: 'l2', conversationId: _c2, text: 'x');
      await rig.sender.settled(_c2);
      await rig.sender.drain(_c2);
      expect(rig.server.sends, isEmpty);
      expect(encrypts(), 0);
      expect(rig.server.calls, isEmpty);
      final out = await rig.sender.outgoing(_c2);
      expect(out.map((r) => r.localId), ['init-1', 'l2']);
      expect(out.last.status, OutgoingStatus5a.waiting);
      expect(out.last.waitingOn, SendBlock.provisional);
    });

    test('retry and discard of an init row leave it byte-identical', () async {
      await setUpProvisional();
      await seedInitRow(_c2, lastError: 'ValidationException');
      final before = await rig.dump();
      rig.changed.clear();
      await rig.sender.retry('init-1');
      await rig.sender.settled(_c2);
      expect(await rig.dump(), before, reason: 'retry');
      await rig.sender.discard('init-1');
      expect(await rig.dump(), before, reason: 'discard');
      // Neither made a call (a discard's live pull) or announced a change.
      expect(rig.server.calls, isEmpty);
      expect(rig.changed, isEmpty);
    });

    test('an init row behind a waiting plain row is not sent past '
        'it', () async {
      await setUpProvisional();
      await rig.sender.enqueue(localId: 'l1', conversationId: _c2, text: 'x');
      await rig.sender.settled(_c2);
      await seedInitRow(_c2, after: const Duration(seconds: 1));
      expect((await outbox(_c2)).map((r) => r.localId), ['l1', 'init-1']);
      final before = await rig.dump();
      await rig.sender.drain(_c2);
      expect(rig.server.sends, isEmpty);
      expect(encrypts(), 0);
      expect(await rig.dump(), before);
    });

    test('an init row behind an encrypted row: only the first is '
        'sent', () async {
      await setUpJoined();
      rig.device.onConfirmStored = (_, _) async => false;
      await send('l1');
      rig.device.onConfirmStored = null;
      final first = (await outbox()).single;
      expect(first.stage, OutboxStage.encrypted);
      final init = await seedInitRow(_c1, after: const Duration(seconds: 1));
      await drain();
      await drain();
      expect(rig.server.sends.single.key, first.idempotencyKey);
      final left = (await outbox()).single;
      expect(left.idempotencyKey, init.idempotencyKey);
      expect(left.init, init.init);
      expect(left.ciphertext, init.ciphertext);
      expect(encrypts(), 1);
    });

    test('a row that became an init row during discard\'s live pull is '
        'kept', () async {
      await setUpJoined();
      rig.device.onConfirmStored = (_, _) async => false;
      await send('l1');
      rig.device.onConfirmStored = null;
      final row = (await outbox()).single;
      // While the pull lists, the row is replaced by one with an init.
      rig.server.rewriteLive = (real) async {
        rig.server.rewriteLive = null;
        await rig.device.vault.transaction(
          (tx) => tx.putOutbox(
            OutboxItem(
              idempotencyKey: row.idempotencyKey,
              localId: row.localId,
              expectedMessageId: row.expectedMessageId,
              conversationId: _c1,
              generation: row.generation,
              epoch: row.epoch,
              ciphertext: row.ciphertext,
              reportCommitment: row.reportCommitment,
              content: row.content,
              createdAtMicros: row.createdAtMicros,
              init: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ),
        );
        return real;
      };
      await rig.sender.discard('l1');
      expect((await outbox()).single.init, isNotNull);
    });
  });

  group('contracts later tasks build on', () {
    test('this conversation\'s engine hold stops an encrypt', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      final context = rig.contexts.of(_c1);
      expect(context.syncedSinceStart, isTrue);
      context.engineHoldUntil = rig.clock.now().add(const Duration(minutes: 1));
      await send('l1');
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.unavailable,
      );
      rig.clock.advance(const Duration(minutes: 1));
      await drain();
      expect(rig.server.sends, hasLength(1));
    });

    test('the receiver-wide engine hold stops an encrypt', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      final context = rig.contexts.of(_c1);
      // A device-level engine answer met by a receive pass.
      final content = encodeMessageContent(
        text: 'from bob',
        reportKey: Uint8List(kReportKeyBytes),
      );
      final g = offer.add.group;
      final r = await bob.engine.encrypt(bob.state, g.state, content);
      g.state = r.groupState;
      rig.server.addMessage(
        pb.Message(
          id: 'c' * 32,
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(rig.clock.now()),
          ciphertext: r.ciphertext,
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(r.epoch),
          reportCommitment: reportCommitment(content),
        ),
      );
      rig.device.engine.failAlways['process'] = const MlsException(
        MlsErrorCode.unavailable,
        'rig',
      );
      await rig.receiver.pullLive(_c1);
      rig.device.engine.failAlways.clear();
      expect(rig.receiver.engineHeldUntil, isNotNull);
      expect(context.engineHoldUntil, isNull);
      expect(context.syncedSinceStart, isTrue);
      rig.device.engine.calls.clear();
      await send('l1');
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      expect(
        (await rig.sender.outgoing(_c1)).single.waitingOn,
        SendBlock.unavailable,
      );
      rig.clock.advance(const Duration(hours: 2));
      expect(rig.receiver.engineHeldUntil, isNull);
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
    });

    test('a message at or before cleared_at is not stored, and its row '
        'still goes', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      final cleared = rig.clock.now().microsecondsSinceEpoch;
      await updateSync((s) => s.copyWith(clearedAtMicros: cleared));
      await send('l1', 'cleared');
      expect(rig.server.sends, hasLength(1));
      expect(await outbox(), isEmpty);
      expect(await stored(), isEmpty);
      // One made after it is stored as ever.
      rig.clock.advance(const Duration(seconds: 1));
      await send('l2', 'after');
      expect(await outbox(), isEmpty);
      expect([for (final m in await stored()) textOf(m.content!)], ['after']);
    });

    test('a vault lost while a send is in flight: the drain stops and '
        'nothing is written to the vault opened next', () async {
      await setUpJoined();
      final old = rig.sender;
      var before = '';
      rig.server.beforeSend = (_) async {
        rig.server.beforeSend = null;
        before = await rig.dump();
        rig.device.owner!.steal();
        // The session has taken the loss in before the server answers.
        while (rig.device.session.vault != null) {
          await Future<void>.delayed(Duration.zero);
        }
      };
      // The server stores the message and answers; the answer meets a
      // session whose vault is gone.
      await send('l1', 'kept');
      await old.settled(_c1);
      expect(rig.server.sends, hasLength(1));
      await rig.restart();
      expect(await rig.dump(), before);
      final row = (await outbox()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect(await stored(), isEmpty);
      // The same request again is answered alike, and the row completes.
      await drain();
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[1].same(rig.server.sends[0]), isTrue);
      expect(await outbox(), isEmpty);
      expect([for (final m in await stored()) textOf(m.content!)], ['kept']);
    });

    test('reset forgets every memory of the run', () async {
      await setUpJoined(accepted: false, folder: Folder.FOLDER_REQUESTS);
      Future<OutgoingRow> row() async =>
          (await rig.sender.outgoing(_c1)).single;
      // Why the last drain stopped (a failed accept; no gate explains it).
      rig.onAcceptForReply = (_) async =>
          throw const NetworkException('offline');
      await send('l1');
      expect((await row()).waitingOn, SendBlock.notSynced);
      rig.sender.reset();
      expect((await row()).waitingOn, SendBlock.none);

      // A retry time, an unknown outcome and the send count.
      rig.onAcceptForReply = acceptanceSteps;
      rig.server.sendScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(hours: 1),
        ),
        stored: false,
      ));
      await drain();
      expect(rig.server.sends, hasLength(1));
      expect(rig.sender.memoryEntries, 3);
      await drain();
      expect(rig.server.sends, hasLength(1), reason: 'the retry time');
      rig.sender.reset();
      expect(rig.sender.memoryEntries, 0);
      // No retry time any more, and two attempts again, not one.
      rig.server.sendScript.addAll([lost, lost]);
      await drain();
      expect(rig.server.sends, hasLength(3));

      // The typed error of a refusal.
      rig.server.sendScript.add((
        error: const ValidationException('bad'),
        stored: false,
      ));
      await drain();
      expect(rig.server.sends, hasLength(4));
      expect((await row()).error, isA<ValidationException>());
      rig.sender.reset();
      expect(rig.sender.memoryEntries, 0);
      final failed = await row();
      expect(failed.status, OutgoingStatus5a.failed);
      expect(failed.error, isNull);
      // The row itself is the vault's: still failed, nothing is sent.
      await drain();
      expect(rig.server.sends, hasLength(4));
    });

    test('reset drops the rerun a joined call asked for', () async {
      await setUpJoined();
      final sending = Completer<void>();
      final release = Completer<void>();
      rig.server.beforeSend = (_) async {
        rig.server.beforeSend = null;
        sending.complete();
        await release.future;
      };
      rig.server.sendScript.addAll([lost, lost]);
      final first = rig.sender.enqueue(
        localId: 'l1',
        conversationId: _c1,
        text: 'a',
      );
      await sending.future;
      await first;
      // A call joins the running drain; then the session ends.
      final joined = drain();
      rig.sender.reset();
      release.complete();
      await joined;
      await rig.sender.settled(_c1);
      // The running drain made its two attempts; no rerun made a third.
      expect(rig.server.sends, hasLength(2));
    });
  });

  group('an unreadable outbox row', () {
    test('stops the drain as unavailable, is reported once, and nothing is '
        'sent past it', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      rig.removedElsewhere = true;
      await send('l1');
      rig.removedElsewhere = false;
      // The first row's sealed content no longer opens.
      await rig.device.db.customStatement(
        "UPDATE vault_outbox SET content = x'0102030405'",
      );
      expect((await rig.device.vault.outbox()).unreadableKeys, hasLength(1));
      await send('l2', 'behind');
      await drain();
      expect(encrypts(), 0);
      expect(rig.server.sends, isEmpty);
      final out = (await rig.sender.outgoing(_c1)).single;
      expect(out.localId, 'l2');
      expect(out.waitingOn, SendBlock.unavailable);
      final reports = [
        for (final e in rig.unexpected) (e as E2eePipelineError).step,
      ];
      rig.unexpected.clear();
      expect(reports, ['send.outbox.unreadable']);
    });
  });
}
