import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

/// A message id of the server's shape (32 lower-case hex).
String _mid(int n) => n.toRadixString(16).padLeft(32, '0');

final Uint8List _reportKey = Uint8List.fromList(List.filled(32, 7));

Uint8List _content(String text) =>
    encodeMessageContent(text: text, reportKey: _reportKey);

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;
  late DateTime t0;

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    final unexpected = [...rig.unexpected];
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    // A swallowed UnimplementedError (a MessagingStore call on the rig's
    // repository) would be reported here.
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  /// This device joins [_c1] from bob's welcome (generation 1, accepted),
  /// with [others] in the group; bob is pinned `theirs` by attribution.
  Future<void> setUpJoined({List<RigPeer> others = const []}) async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    for (final o in others) {
      rig.keys.own.add(rigKeyDevice(o.idString, o.key));
    }
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    offer = await rig.offer(
      _c1,
      bob,
      others: [for (final o in others) await o.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    t0 = rig.clock.now();
  }

  RigGroup bobGroup() => offer.add.group;

  /// [g]'s owner encrypts [bytes] (default: a MessageContent of [text]) and
  /// the server stores it as message [n], created [at] after t0.
  Future<pb.Message> say(
    RigGroup g,
    int n, {
    String text = 'hello',
    Duration at = Duration.zero,
    bool fromSelf = false,
    Uint8List? bytes,
    Uint8List? commitment,
  }) async {
    final content = bytes ?? _content(text);
    final r = await g.owner.engine.encrypt(g.owner.state, g.state, content);
    g.state = r.groupState;
    final m = pb.Message(
      id: _mid(n),
      conversationId: _c1,
      fromSelf: fromSelf,
      state: MessageState.MESSAGE_STATE_VISIBLE,
      createdAt: ts.Timestamp.fromDateTime(t0.add(at)),
      ciphertext: r.ciphertext,
      mlsGeneration: Int64(1),
      mlsEpoch: Int64(r.epoch),
      reportCommitment: commitment ?? reportCommitment(content),
    );
    rig.server.addMessage(m);
    return m;
  }

  /// This device encrypts [text] on its stored group without saving the
  /// result (a send whose local records are gone), stored by the server as
  /// message [n] with [fromSelf].
  Future<pb.Message> sayOwn(
    int n, {
    String text = 'mine',
    bool fromSelf = true,
    Duration at = Duration.zero,
  }) async {
    final v = rig.device.vault;
    final g = (await v.group(_c1, 1))!;
    final content = _content(text);
    final r = await rig.device.engine.inner.encrypt(
      (await v.deviceState())!,
      g.state,
      content,
    );
    final m = pb.Message(
      id: _mid(n),
      conversationId: _c1,
      fromSelf: fromSelf,
      state: MessageState.MESSAGE_STATE_VISIBLE,
      createdAt: ts.Timestamp.fromDateTime(t0.add(at)),
      ciphertext: r.ciphertext,
      mlsGeneration: Int64(1),
      mlsEpoch: Int64(r.epoch),
      reportCommitment: reportCommitment(content),
    );
    rig.server.addMessage(m);
    return m;
  }

  /// Bob commits a self-update on the server's current pair; returns it.
  Future<MlsPair> bobSelfUpdate() async {
    final g = bobGroup();
    final at = rig.server.current(_c1);
    final c = await bob.engine.selfUpdate(bob.state, g.state);
    g.state = await bob.engine.confirmCommit(bob.state, c.groupState);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
    return at;
  }

  Future<StoredMessage?> row(String id) => rig.device.vault.message(_c1, id);

  Future<ConversationSync> sync() async =>
      (await rig.device.vault.conversation(_c1))!.sync;

  Future<Uint8List> groupState() async =>
      (await rig.device.vault.group(_c1, 1))!.state;

  Future<void> putOutbox({
    required String expectedId,
    required Uint8List ciphertext,
    required Uint8List content,
    String key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  }) => rig.device.vault.transaction(
    (tx) => tx.putOutbox(
      OutboxItem(
        idempotencyKey: key,
        localId: key,
        expectedMessageId: expectedId,
        conversationId: _c1,
        generation: 1,
        epoch: 1,
        ciphertext: ciphertext,
        reportCommitment: reportCommitment(content),
        content: content,
        createdAtMicros: t0.microsecondsSinceEpoch,
      ),
    ),
  );

  int processedCount(List<int> wire) =>
      rig.device.engine.processed.where((w) => rigEq(w, wire)).length;

  group('one message', () {
    test('a peer message is stored visible with its exact bytes, check ok '
        'and mine false', () async {
      await setUpJoined();
      final bytes = _content('hi there');
      await say(bobGroup(), 1, bytes: bytes);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.visible);
      expect(m.content, bytes);
      expect(m.check, StoredMessageCheck.ok);
      expect(m.mine, isFalse);
      expect(m.kind, StoredMessageKind.message);
      expect(rigEq(m.senderDeviceId!, bob.id), isTrue);
      expect(m.createdAtMicros, t0.microsecondsSinceEpoch);
      expect((m.generation, m.epoch), (1, 1));
      expect(rig.changed, contains(_c1));
    });

    test('a message from my other device is mine although it is processed '
        'like any other', () async {
      final sib = await RigPeer.create('sib');
      await setUpJoined(others: [sib]);
      final joined = await sib.engine.joinFromWelcome(
        sib.state,
        offer.add.welcome,
      );
      sib.state = joined.deviceState;
      final sibGroup = RigGroup(
        sib,
        offer.add.group.groupId,
        joined.groupState,
      );
      final m = await say(sibGroup, 1, fromSelf: true);

      await rig.receiver.pullLive(_c1);

      final stored = (await row(_mid(1)))!;
      expect(stored.mine, isTrue);
      expect(stored.state, StoredMessageState.visible);
      expect(rigEq(stored.senderDeviceId!, sib.id), isTrue);
      expect(processedCount(m.ciphertext), 1);
    });

    test('direction ignores a wrong from_self from the server', () async {
      await setUpJoined();
      await say(bobGroup(), 1, fromSelf: true);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.mine, isFalse);
      expect(m.state, StoredMessageState.visible);
    });

    test(
      'a commitment mismatch is stored unverified with its content',
      () async {
        await setUpJoined();
        final bytes = _content('tampered');
        await say(
          bobGroup(),
          1,
          bytes: bytes,
          commitment: Uint8List.fromList(List.filled(32, 9)),
        );

        await rig.receiver.pullLive(_c1);

        final m = (await row(_mid(1)))!;
        expect(m.state, StoredMessageState.visible);
        expect(m.check, StoredMessageCheck.unverified);
        expect(m.content, bytes);
      },
    );

    test('a 31-byte report key is unverified', () async {
      await setUpJoined();
      final bytes = pb.MessageContent(
        text: 'short key',
        reportKey: List.filled(31, 7),
      ).writeToBuffer();
      await say(bobGroup(), 1, bytes: bytes);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.check, StoredMessageCheck.unverified);
      expect(m.content, bytes);
    });

    test('bytes that are not a MessageContent with a matching commitment are '
        'undecodable with content kept', () async {
      await setUpJoined();
      // A lone end-group tag: malformed at the top level.
      final bytes = Uint8List.fromList([0x0c]);
      await say(bobGroup(), 1, bytes: bytes);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.visible);
      expect(m.check, StoredMessageCheck.undecodable);
      expect(m.content, bytes);
    });

    test('a stored id is skipped without an engine call', () async {
      await setUpJoined();
      final m = await say(bobGroup(), 1);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m.ciphertext), 1);

      // The epoch's walk lists it again before bob's commit is applied.
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(processedCount(m.ciphertext), 1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
    });

    test('an echo with the expected id and equal bytes completes its outbox '
        'row', () async {
      await setUpJoined();
      final m = await sayOwn(1, text: 'sent by me');
      await putOutbox(
        expectedId: _mid(1),
        ciphertext: Uint8List.fromList(m.ciphertext),
        content: _content('sent by me'),
      );

      await rig.receiver.pullLive(_c1);

      final stored = (await row(_mid(1)))!;
      expect(stored.mine, isTrue);
      expect(stored.state, StoredMessageState.visible);
      expect(stored.content, _content('sent by me'));
      expect(stored.check, StoredMessageCheck.ok);
      expect(rigEq(stored.senderDeviceId!, rig.device.deviceId), isTrue);
      expect(stored.createdAtMicros, t0.microsecondsSinceEpoch);
      expect((await rig.device.vault.outbox()).items, isEmpty);
      expect(processedCount(m.ciphertext), 0);
    });

    test('the expected id with other bytes is not an echo', () async {
      await setUpJoined();
      await say(bobGroup(), 1, text: 'from bob');
      await putOutbox(
        expectedId: _mid(1),
        ciphertext: Uint8List.fromList([1, 2, 3]),
        content: _content('other'),
      );

      await rig.receiver.pullLive(_c1);

      final stored = (await row(_mid(1)))!;
      expect(stored.mine, isFalse);
      expect(stored.content, _content('from bob'));
      expect((await rig.device.vault.outbox()).items, hasLength(1));
    });
  });

  group('own leaf (C3, R7)', () {
    test('own leaf without from_self is skipped and counted, no row', () async {
      await setUpJoined();
      final m = await sayOwn(1, fromSelf: false);

      await rig.receiver.pullLive(_c1);

      expect(processedCount(m.ciphertext), 1);
      expect(await row(_mid(1)), isNull);
      expect(rig.receiver.forgeriesSkipped, 1);
      expect((await sync()).epochMustAdvance, isFalse);
    });

    test(
      'own leaf with from_self, no stored id, no outbox row and no sent '
      'digest is a lost send: undecryptable row and epoch must advance',
      () async {
        await setUpJoined();
        final before = await groupState();
        await sayOwn(1);

        await rig.receiver.pullLive(_c1);

        final m = (await row(_mid(1)))!;
        expect(m.state, StoredMessageState.undecryptable);
        expect(m.mine, isTrue);
        expect(m.content, isNull);
        expect((await sync()).epochMustAdvance, isTrue);
        expect(rig.receiver.forgeriesSkipped, 0);
        expect(await groupState(), before);
      },
    );

    test('own leaf with from_self whose digest is in the sent log is '
        'skipped', () async {
      await setUpJoined();
      final m = await sayOwn(1);
      await rig.device.vault.transaction(
        (tx) => tx.addSent(
          _c1,
          const MlsPair(1, 1),
          sentDigest(Uint8List.fromList(m.ciphertext)),
        ),
      );

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect((await sync()).epochMustAdvance, isFalse);
      expect(rig.receiver.forgeriesSkipped, 0);
    });

    test('own leaf not marked from_self is never a lost send', () async {
      await setUpJoined();
      await sayOwn(1, fromSelf: false);

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect((await sync()).epochMustAdvance, isFalse);
    });

    test(
      'own leaf with from_self whose id is already stored is skipped',
      () async {
        await setUpJoined();
        final m = await sayOwn(1);
        await rig.device.vault.transaction(
          (tx) => tx.putMessage(
            StoredMessage(
              conversationId: _c1,
              messageId: _mid(1),
              createdAtMicros: t0.microsecondsSinceEpoch,
              mine: true,
              state: StoredMessageState.visible,
              generation: 1,
              epoch: 1,
              content: _content('mine'),
            ),
          ),
        );

        await rig.receiver.pullLive(_c1);

        expect(processedCount(m.ciphertext), 0);
        expect((await row(_mid(1)))!.state, StoredMessageState.visible);
        expect((await sync()).epochMustAdvance, isFalse);
      },
    );

    test('own leaf with from_self whose id an outbox row expects with other '
        'bytes is skipped', () async {
      await setUpJoined();
      await sayOwn(1);
      await putOutbox(
        expectedId: _mid(1),
        ciphertext: Uint8List.fromList([1, 2, 3]),
        content: _content('other'),
      );

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect((await sync()).epochMustAdvance, isFalse);
      expect((await rig.device.vault.outbox()).items, hasLength(1));
    });

    test('a replayed peer message under a new id is an undecryptable row, '
        'not a lost send', () async {
      await setUpJoined();
      final m = await say(bobGroup(), 1);
      await rig.receiver.pullLive(_c1);
      rig.server.addMessage(
        m.deepCopy()
          ..id = _mid(2)
          ..fromSelf = true
          ..createdAt = ts.Timestamp.fromDateTime(t0.add(seconds(1))),
      );

      await rig.receiver.pullLive(_c1);

      final replay = (await row(_mid(2)))!;
      expect(replay.state, StoredMessageState.undecryptable);
      expect(replay.mine, isFalse);
      expect((await sync()).epochMustAdvance, isFalse);
    });
  });

  group('rows without an engine call', () {
    test('a swept message is an undecryptable row', () async {
      await setUpJoined();
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          fromSelf: true,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
          ciphertextRemoved: true,
        ),
      );

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.undecryptable);
      expect(m.mine, isFalse);
      expect(rig.device.engine.processed, isEmpty);
    });

    test('a message of an epoch before the join is skipped', () async {
      await setUpJoined();
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: [1, 2, 3, 4],
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(0),
        ),
      );

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect(rig.device.engine.processed, isEmpty);
    });

    test('a message of an earlier pair is undecryptable without an engine '
        'call, whatever from_self says', () async {
      await setUpJoined();
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.processed.clear();
      // Listed live only after the epoch was closed.
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          fromSelf: true,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: [1, 2, 3, 4],
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
        ),
      );

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.undecryptable);
      expect(m.mine, isFalse);
      expect(rig.device.engine.processed, isEmpty);
    });

    test('REMOVED and DELETED_ACCOUNT clear a stored copy and store nothing '
        'new', () async {
      for (final (state, name) in [
        (MessageState.MESSAGE_STATE_REMOVED, StoredMessageState.removed),
        (
          MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
          StoredMessageState.deletedAccount,
        ),
      ]) {
        await setUpJoined();
        await say(bobGroup(), 1);
        await rig.receiver.pullLive(_c1);
        expect((await row(_mid(1)))!.state, StoredMessageState.visible);
        final never = await say(bobGroup(), 2, at: seconds(1));
        rig.server
          ..tombstone(_c1, _mid(1), state)
          ..tombstone(_c1, _mid(2), state);

        await rig.receiver.pullLive(_c1);

        final m = (await row(_mid(1)))!;
        expect(m.state, name);
        expect(m.content, isNull);
        expect(await row(_mid(2)), isNull);
        expect(processedCount(never.ciphertext), 0);
        final refused = rig.server.refusedAcks.length;
        final unexpected = [...rig.unexpected];
        await rig.dispose();
        expect(refused, 0);
        expect(unexpected, isEmpty);
      }
      // The shared tearDown disposes the last rig again.
      await setUpJoined();
    });
  });

  group('engine answers', () {
    test('a sender that is not a pinned member is an undecryptable row and '
        'the group state is not changed', () async {
      await setUpJoined();
      await rig.device.vault.transaction((tx) => tx.deleteMember(_c1, bob.id));
      final before = await groupState();
      await say(bobGroup(), 1);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.undecryptable);
      expect(m.mine, isFalse);
      expect(await groupState(), before);
    });

    test('a commit listed as a message is an undecryptable row and changes '
        'no group state', () async {
      await setUpJoined();
      final g = bobGroup();
      final c = await bob.engine.selfUpdate(bob.state, g.state);
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: c.commit,
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
        ),
      );
      final before = await groupState();

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await groupState(), before);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
    });

    test('bad input is an undecryptable row and the group state is not '
        'changed', () async {
      await setUpJoined();
      final m = await say(bobGroup(), 1);
      final before = await groupState();
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.badInput,
        'x',
      );

      await rig.receiver.pullLive(_c1);

      expect(processedCount(m.ciphertext), 1);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await groupState(), before);
    });

    test('a deadline stops the batch and the same message is processed on the '
        'next pull', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.deadline,
        'x',
      );

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);
      expect((await sync()).sinceToken, '');

      await rig.receiver.pullLive(_c1);

      expect(processedCount(m1.ciphertext), 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, isNotEmpty);
    });

    test('the group state and the message row are written in one '
        'transaction', () async {
      await setUpJoined();
      await say(bobGroup(), 1);
      final before = await groupState();
      // The group state is written first in the transaction, then the row.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_messages.');

      await rig.receiver.pullLive(_c1);

      expect(await groupState(), before);
      rig.device.cipher.failSeal = null;
      expect(await row(_mid(1)), isNull);
      expect((await sync()).sinceToken, '');

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await groupState(), isNot(before));
    });
  });

  group('order and epochs', () {
    test("an epoch's messages are decrypted in created_at then id order "
        'whatever the page order', () async {
      await setUpJoined();
      final g = bobGroup();
      final a = await say(g, 3, at: seconds(0));
      final b = await say(g, 1, at: seconds(5));
      final c = await say(g, 2, at: seconds(5));
      // The epoch walk sees them in reverse id order.
      rig.server.rewriteEpoch = (real) =>
          real.deepCopy()..messages.sort((x, y) => y.id.compareTo(x.id));
      await bobSelfUpdate();
      rig.device.engine.processed.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final order = [
        for (final w in rig.device.engine.processed)
          for (final m in [a, b, c])
            if (rigEq(w, m.ciphertext)) m.id,
      ];
      expect(order, [_mid(3), _mid(1), _mid(2)]);
      for (final id in [_mid(1), _mid(2), _mid(3)]) {
        expect((await row(id))!.state, StoredMessageState.visible);
      }
    });

    test('a message of a later pair triggers catch-up first', () async {
      await setUpJoined();
      final before = await say(bobGroup(), 1);
      await bobSelfUpdate();
      final after = await say(bobGroup(), 2, at: seconds(1));
      rig.server.calls.clear();
      rig.device.engine.processed.clear();

      await rig.receiver.pullLive(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await row(_mid(2))), isNotNull);
      final commitAt = rig.server.calls.indexOf('listConversationCommits');
      expect(
        commitAt,
        greaterThan(rig.server.calls.indexOf('listMlsMessages')),
      );
      // The epoch-1 message once (by the walk), then the commit, then the
      // epoch-2 message.
      expect(processedCount(before.ciphertext), 1);
      expect(rigEq(rig.device.engine.processed.last, after.ciphertext), isTrue);
      expect(rig.contexts.of(_c1).livePulledAt, const MlsPair(1, 2));
    });

    test(
      'messages at or before cleared_at are processed and not stored',
      () async {
        await setUpJoined();
        final g = bobGroup();
        final m1 = await say(g, 1, at: seconds(0));
        final m2 = await say(g, 2, at: seconds(10));
        await say(g, 3, at: seconds(20));
        rig.server.clearedAt[_c1] = t0.add(seconds(10));
        // cleared_at is in the past now (a future value is ignored).
        rig.clock.advance(seconds(30));
        await bobSelfUpdate();

        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

        expect(processedCount(m1.ciphertext), 1);
        expect(processedCount(m2.ciphertext), 1);
        expect(await row(_mid(1)), isNull);
        expect(await row(_mid(2)), isNull);
        expect((await row(_mid(3)))!.state, StoredMessageState.visible);
        expect(
          (await sync()).clearedAtMicros,
          t0.add(seconds(10)).microsecondsSinceEpoch,
        );
      },
    );

    test('a refused epoch page token starts the listing again once', () async {
      await setUpJoined();
      final g = bobGroup();
      for (var i = 1; i <= 60; i++) {
        await say(g, i, at: seconds(i));
      }
      rig.server.refuseEpochPageTokens = 1;
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      for (var i = 1; i <= 60; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test(
      'a second refused page token stops the walk and the commit waits',
      () async {
        await setUpJoined();
        final g = bobGroup();
        for (var i = 1; i <= 60; i++) {
          await say(g, i, at: seconds(i));
        }
        rig.server.refuseEpochPageTokens = 2;
        await bobSelfUpdate();

        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);

        expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
        expect(await row(_mid(1)), isNull);
      },
    );

    test('completing an epoch twice stores the same rows and decrypts '
        'nothing again', () async {
      await setUpJoined();
      final g = bobGroup();
      await say(g, 1);
      await sayOwn(2, fromSelf: false, at: seconds(1));
      await say(g, 3, at: seconds(2));
      Future<void> complete() => rig.locks.run(
        _c1,
        () => rig.receiver.completeEpoch(
          _c1,
          const MlsPair(1, 1),
          priority: BudgetPriority.user,
        ),
      );

      await complete();
      final dump = await rig.dump();
      final processed = rig.device.engine.processed.length;
      await complete();

      expect(await rig.dump(), dump);
      // Stored ids are skipped, and the forgery met this run is not given
      // to the engine again (nor counted again).
      expect(rig.device.engine.processed.length, processed);
      expect(rig.receiver.forgeriesSkipped, 1);
    });

    test('an epoch marked undecryptable stores an undecryptable row for each '
        'message not stored, with no engine call', () async {
      await setUpJoined();
      final g = bobGroup();
      await say(g, 1);
      await rig.receiver.pullLive(_c1);
      await say(g, 2, at: seconds(1));
      rig.device.engine.processed.clear();

      await rig.locks.run(
        _c1,
        () => rig.receiver.markEpochUndecryptable(
          _c1,
          const MlsPair(1, 1),
          priority: BudgetPriority.user,
        ),
      );

      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      final m = (await row(_mid(2)))!;
      expect(m.state, StoredMessageState.undecryptable);
      expect(m.mine, isFalse);
      expect(rig.device.engine.processed, isEmpty);
    });
  });

  group('live pull', () {
    test('a since answer with nothing new and no since token keeps the '
        'stored token and completes', () async {
      await setUpJoined();
      await say(bobGroup(), 1);
      await rig.receiver.pullLive(_c1);
      final token = (await sync()).sinceToken;
      expect(token, isNotEmpty);
      rig.contexts.of(_c1).livePulledAt = null;
      // An all-default answer: no messages, no token, no gap.
      rig.server.rewriteLive = (_) => pb.ListMessagesResponse();
      rig.server.calls.clear();

      await rig.receiver.pullLive(_c1);

      expect((await sync()).sinceToken, token);
      // Not taken for a retired token: no walk from the first page.
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        hasLength(1),
      );
      expect(rig.contexts.of(_c1).livePulledAt, const MlsPair(1, 1));
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
    });

    test('a server time out of range is stored at time 0 and a cleared_at '
        'out of range is ignored, never an error', () async {
      await setUpJoined();
      await say(bobGroup(), 2);
      // The epoch walk lists it at a time beyond what the client holds, with
      // a cleared_at beyond it too.
      // Out of range, not a date: 2^53 microseconds is about 9.0e9 s.
      final far = ts.Timestamp()..seconds = Int64(10) * Int64(1000000000000);
      rig.server.rewriteEpoch = (real) {
        final out = real.deepCopy()..clearedAt = far;
        for (final m in out.messages) {
          m.createdAt = far;
        }
        return out;
      };
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final m = (await row(_mid(2)))!;
      expect(m.state, StoredMessageState.visible);
      expect(m.createdAtMicros, 0);
      expect((await sync()).clearedAtMicros, isNull);
    });

    test('a later generation with no welcome stops the batch, and an unheld '
        'welcome poll runs after the lock is released', () async {
      await setUpJoined();
      rig.server.addCommit(
        _c1,
        const MlsPair(2, 0),
        rigBytes('a commit of generation 2'),
        fromUser: 'user-b',
      );
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: [1, 2, 3, 4],
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(2),
          mlsEpoch: Int64(1),
        ),
      );
      rig.server.calls.clear();

      await rig.receiver.pullLive(_c1);

      // Catch-up's held poll, then the unheld one after the pull.
      expect(rig.server.calls.where((c) => c == 'listWelcomes'), hasLength(2));
      expect(rig.server.calls.last, 'listWelcomes');
      expect(await row(_mid(1)), isNull);
      expect((await sync()).sinceToken, '');
      expect(rig.contexts.of(_c1).livePulledAt, isNull);
      expect(rig.device.engine.processed, isEmpty);
    });

    test('a gap is followed until it closes', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      final g = bobGroup();
      for (var i = 1; i <= 5; i++) {
        await say(g, i, at: seconds(i));
      }
      rig.server.livePageSize = 2;

      await rig.receiver.pullLive(_c1);

      for (var i = 1; i <= 5; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('the since token is saved with the batch and nothing reaches '
        'MessagingStore', () async {
      await setUpJoined();
      rig.messaging.noted.clear();
      await say(bobGroup(), 1);

      await rig.receiver.pullLive(_c1);

      final token = (await sync()).sinceToken;
      expect(token, isNotEmpty);
      expect((await row(_mid(1))), isNotNull);
      // The rig's repository throws for every MessagingStore method; the
      // pull used only listMlsMessages (and nothing was noted).
      expect(rig.messaging.noted, isEmpty);
      expect(rig.server.calls.where((c) => c == 'listMlsMessages'), isNotEmpty);

      // The next pull sends the stored token: only the new message comes.
      await say(bobGroup(), 2, at: seconds(1));
      rig.device.engine.processed.clear();
      await rig.receiver.pullLive(_c1);
      expect(rig.device.engine.processed, hasLength(1));
      expect((await sync()).sinceToken, isNot(token));
    });

    test('a retired since token keeps every stored message and reconciles '
        'tombstones by id', () async {
      await setUpJoined();
      final g = bobGroup();
      await say(g, 1);
      await say(g, 2, at: seconds(1));
      await rig.receiver.pullLive(_c1);
      final token = (await sync()).sinceToken;
      // A row the server no longer lists.
      await rig.device.vault.transaction(
        (tx) => tx.putMessage(
          StoredMessage(
            conversationId: _c1,
            messageId: _mid(9),
            createdAtMicros: t0.microsecondsSinceEpoch,
            mine: true,
            state: StoredMessageState.visible,
            generation: 1,
            epoch: 1,
            content: _content('kept'),
          ),
        ),
      );
      rig.server
        ..tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED)
        ..retiredSince.add(token)
        ..livePageSize = 1;

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.removed);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await row(_mid(9)))!.state, StoredMessageState.visible);
      final next = (await sync()).sinceToken;
      expect(next, isNotEmpty);
      expect(next, isNot(token));
    });

    test('a completed live pull records its pair and an interrupted one does '
        'not', () async {
      await setUpJoined();
      final context = rig.contexts.of(_c1);
      expect(context.livePulledAt, isNull);
      expect(context.syncedSinceStart, isFalse);
      await say(bobGroup(), 1);
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.deadline,
        'x',
      );

      await rig.receiver.pullLive(_c1);

      expect(context.livePulledAt, isNull);
      expect(context.syncedSinceStart, isFalse);

      await rig.receiver.pullLive(_c1);

      expect(context.livePulledAt, const MlsPair(1, 1));
      expect(context.syncedSinceStart, isTrue);
    });
  });

  group('cleared_at (R8)', () {
    test('applyClearedAtOnce deletes local copies up to cleared_at, once per '
        'run, and ignores a future value', () async {
      await setUpJoined();
      final g = bobGroup();
      await say(g, 1, at: seconds(0));
      await say(g, 2, at: seconds(10));
      await rig.receiver.pullLive(_c1);
      rig.server.clearedAt[_c1] = t0;
      rig.server.calls.clear();

      await rig.receiver.applyClearedAtOnce(_c1);

      expect(await row(_mid(1)), isNull);
      expect((await row(_mid(2))), isNotNull);
      expect((await sync()).clearedAtMicros, t0.microsecondsSinceEpoch);
      expect(rig.server.calls, ['listEpochMessages']);

      // Once per run.
      rig.server.clearedAt[_c1] = t0.add(seconds(10));
      await rig.receiver.applyClearedAtOnce(_c1);
      expect((await row(_mid(2))), isNotNull);
      expect(rig.server.calls, ['listEpochMessages']);

      // A new run with a value in the future: nothing is deleted.
      rig.contexts.clear();
      rig.server.clearedAt[_c1] = rig.clock.now().add(const Duration(hours: 1));
      await rig.receiver.applyClearedAtOnce(_c1);
      expect((await row(_mid(2))), isNotNull);
      expect((await sync()).clearedAtMicros, t0.microsecondsSinceEpoch);
    });
  });
}

Duration seconds(int n) => Duration(seconds: n);
