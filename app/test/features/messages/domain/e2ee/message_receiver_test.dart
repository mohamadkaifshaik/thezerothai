import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/receive_record.dart';
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
  Future<void> setUpJoined({
    List<RigPeer> others = const [],
    int pageSize = kEpochPageSize,
  }) async {
    rig = await RigCrypto.create(epochPageSize: pageSize);
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
    // Engine call counts in a test start after the join.
    rig.device.engine.calls.clear();
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
    int generation = 1,
    String conversation = _c1,
  }) async {
    final content = bytes ?? _content(text);
    final r = await g.owner.engine.encrypt(g.owner.state, g.state, content);
    g.state = r.groupState;
    final m = pb.Message(
      id: _mid(n),
      conversationId: conversation,
      fromSelf: fromSelf,
      state: MessageState.MESSAGE_STATE_VISIBLE,
      createdAt: ts.Timestamp.fromDateTime(t0.add(at)),
      ciphertext: r.ciphertext,
      mlsGeneration: Int64(generation),
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

  /// Bob's messages [from] .. [from] + [count] - 1 at (1, current epoch),
  /// one millisecond apart from [start] after t0.
  Future<List<pb.Message>> sayMany(
    int from,
    int count, {
    Duration start = Duration.zero,
  }) async => [
    for (var i = 0; i < count; i++)
      await say(bobGroup(), from + i, at: start + Duration(milliseconds: i)),
  ];

  /// A message of (1, [epoch]), a pair the server has no commit for, stored
  /// as message [n] created [at] after t0.
  void noCommitMessage(int n, int epoch, Duration at) => rig.server.addMessage(
    pb.Message(
      id: _mid(n),
      conversationId: _c1,
      state: MessageState.MESSAGE_STATE_VISIBLE,
      createdAt: ts.Timestamp.fromDateTime(t0.add(at)),
      ciphertext: [1, 2, 3],
      reportCommitment: List.filled(32, 1),
      mlsGeneration: Int64(1),
      mlsEpoch: Int64(epoch),
    ),
  );

  /// The stored receive record, as stored (not normalized).
  Future<ReceiveRecord> receiveRecord() =>
      ReceiveRecords().read(rig.device.vault, _c1);

  /// Stores [r] as the receive record (as a transaction would leave it).
  Future<void> putReceiveRecord(ReceiveRecord r) =>
      rig.device.vault.transaction((tx) => ReceiveRecords().putIn(tx, _c1, r));

  /// The reconcile walk of [conversation] has REALLY disarmed its entry
  /// (step 2b: the pass that saved the since token listed the tombstones
  /// to the end, and that last page's transaction cleared the entry). A
  /// deferred message is never given to the engine by a retry while the
  /// entry stands (step 2a fix round 2), so a test that needs an engine
  /// retry checks this first. It writes nothing: until step 2b this helper
  /// wrote `rec: null` itself.
  Future<void> reconciled([String conversation = _c1]) async {
    final v = rig.device.vault;
    final r = await ReceiveRecords().read(v, conversation);
    expect((await v.conversation(conversation))!.sync.sinceToken, isNotEmpty);
    expect(r.rec, isNull, reason: 'the reconcile walk did not disarm');
    expect(rig.server.calls, contains('listMessageTombstones'));
  }

  /// The ordered epoch requests for [pair] (page tokens, in order).
  List<String> orderedTokens(MlsPair pair) => [
    for (final r in rig.server.epochRequests)
      if (r.pair == pair &&
          r.order == EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT)
        r.token,
  ];

  int epochCalls() =>
      rig.server.calls.where((c) => c == 'listEpochMessages').length;

  /// A first pull with nothing to receive: the open walk ends and the since
  /// token is saved (later probes take the fast path).
  Future<String> prime() async {
    final out = await rig.receiver.pullLive(_c1);
    expect(out.kind, ReceiveOutcomeKind.complete);
    final token = (await sync()).sinceToken;
    expect(token, isNotEmpty);
    return token;
  }

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

    test('a 31-byte report key is stored as badReportKey', () async {
      await setUpJoined();
      final bytes = pb.MessageContent(
        text: 'short key',
        reportKey: List.filled(31, 7),
      ).writeToBuffer();
      await say(bobGroup(), 1, bytes: bytes);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.check, StoredMessageCheck.badReportKey);
      expect(m.content, bytes);
    });

    test('a message with a matching commitment and a bad report key is stored '
        'as badReportKey', () async {
      await setUpJoined();
      final bytes = pb.MessageContent(
        text: 'long key',
        reportKey: List.filled(33, 7),
      ).writeToBuffer();
      await say(bobGroup(), 1, bytes: bytes);

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.visible);
      expect(m.check, StoredMessageCheck.badReportKey);
      expect(m.content, bytes);
    });

    test(
      'a message whose commitment does not match is stored as unverified',
      () async {
        await setUpJoined();
        // A bad key length too: the mismatch wins, so it is not badReportKey.
        final bytes = pb.MessageContent(
          text: 'short key, wrong commitment',
          reportKey: List.filled(31, 7),
        ).writeToBuffer();
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
      // The fast path (a saved token, an ended open walk) processes probe
      // pages; walks list the current pair only.
      await prime();
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

    test('an unavailable engine stops the batch and the same message is '
        'processed on the next pull', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.unavailable,
        'x',
      );

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);
      expect((await sync()).sinceToken, '');

      rig.clock.advance(kEngineBackoff);
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
    test("an epoch's messages are decrypted in the ordered listing's "
        'created_at then id order', () async {
      await setUpJoined();
      final g = bobGroup();
      final a = await say(g, 3, at: seconds(0));
      final b = await say(g, 1, at: seconds(5));
      final c = await say(g, 2, at: seconds(5));
      // (A page out of that order is discarded: see the order check tests.)
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
      // The fast path needs a saved token and an ended open walk.
      await prime();
      final before = await say(bobGroup(), 1);
      await bobSelfUpdate();
      final after = await say(bobGroup(), 2, at: seconds(1));
      rig.server.calls.clear();
      rig.device.engine.processed.clear();

      await rig.receiver.pullLive(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      final commitAt = rig.server.calls.indexOf('listConversationCommits');
      expect(
        commitAt,
        greaterThan(rig.server.calls.indexOf('listMlsMessages')),
      );
      // The epoch-1 message once, then the commit, then the epoch-2 message
      // (by the new pair's open walk).
      expect(processedCount(before.ciphertext), 1);
      expect(rigEq(rig.device.engine.processed.last, after.ciphertext), isTrue);
      // The batch stopped without saving; the next fast path saves it.
      await rig.receiver.pullLive(_c1);
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

      // The sink lists 2 pages a hold: page 1, then the refused token; the
      // walk restarts from the start (its stored cursor) and the next pass
      // finishes it.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect((await receiveRecord()).close!.t, '');
      await rig.receiver.pullLive(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      for (var i = 1; i <= 60; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('a third refused page token in a run stops the walk and the commit '
        'waits', () async {
      await setUpJoined();
      final g = bobGroup();
      for (var i = 1; i <= 60; i++) {
        await say(g, i, at: seconds(i));
      }
      rig.server.refuseEpochPageTokens = 3;
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      final out = await rig.receiver.pullLive(_c1);
      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).walkRestarts, 3);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      expect(await rig.receiver.epochWalkDone(_c1, const MlsPair(1, 1)), false);
    });

    test('the restart count of a walk is reset once a listing reaches its '
        'end', () async {
      await setUpJoined();
      await sayMany(1, 120, start: const Duration(minutes: -10));
      rig.server.refuseEpochPageTokens = 2;

      await rig.receiver.pullLive(_c1, priority: BudgetPriority.user);

      expect((await row(_mid(120)))!.state, StoredMessageState.visible);
      expect(rig.contexts.of(_c1).walkRestarts, 0);

      // Later in the same (long) run: one more refused token restarts the
      // walk again instead of backing off.
      await sayMany(121, 2, start: seconds(1));
      rig.server.livePageSize = 1;
      rig.server.refuseEpochPageTokens = 1;
      final out = await rig.receiver.pullLive(
        _c1,
        priority: BudgetPriority.user,
      );

      expect(out.kind, isNot(ReceiveOutcomeKind.stopped));
      expect((await row(_mid(122)))!.state, StoredMessageState.visible);
    });

    test(
      'a server that refuses every continuation token still backs off',
      () async {
        await setUpJoined();
        await sayMany(1, 120, start: const Duration(minutes: -10));
        rig.server.refuseEpochPageTokens = 1000;

        final out = await rig.receiver.pullLive(
          _c1,
          priority: BudgetPriority.user,
        );

        // Page 1, then refused, twice restarted, then the backoff.
        expect(out.kind, ReceiveOutcomeKind.stopped);
        expect(epochCalls(), 6);
        expect(rig.contexts.of(_c1).walkRestarts, 3);
        rig.server.calls.clear();
        expect(
          (await rig.receiver.pullLive(_c1)).kind,
          ReceiveOutcomeKind.stopped,
        );
        expect(epochCalls(), 0);
      },
    );

    test(
      'past the restart cap the next attempt lists from the start',
      () async {
        await setUpJoined();
        await sayMany(1, 120, start: const Duration(minutes: -10));
        rig.server.refuseEpochPageTokens = 1000;

        final out = await rig.receiver.pullLive(
          _c1,
          priority: BudgetPriority.user,
        );

        expect(out.kind, ReceiveOutcomeKind.stopped);
        expect(rig.contexts.of(_c1).walkRestarts, 3);
        // The refused token is not kept past the cap.
        expect((await receiveRecord()).open!.t, '');

        // The server accepts tokens again: after the backoff the walk lists
        // from the start, never the refused token again.
        rig.server.refuseEpochPageTokens = 0;
        rig.server.epochRequests.clear();
        rig.clock.advance(const Duration(hours: 1));
        await rig.receiver.pullLive(_c1, priority: BudgetPriority.user);

        expect(orderedTokens(const MlsPair(1, 1)).first, '');
        for (var i = 1; i <= 120; i++) {
          expect((await row(_mid(i)))!.state, StoredMessageState.visible);
        }
      },
    );

    test('a page whose record went stale under its last message is discarded, '
        'not counted as applied', () async {
      await setUpJoined();
      await sayMany(1, 2, start: const Duration(minutes: -10));
      // While the page's first message is decrypted, another writer moves
      // the open walk's cursor: the last message's record update is stale.
      final engine = rig.device.engine;
      engine.onProcessCall[engine.processed.length + 1] = () async {
        final r = await receiveRecord();
        await putReceiveRecord(r.copyWith(open: r.open!.copyWith(t: 'moved')));
      };
      final serial = rig.contexts.of(_c1).serial;

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).discardedPages, 1);
      // The stale page was listed again from the moved cursor (refused, so
      // from the start), never treated as finished.
      expect(orderedTokens(const MlsPair(1, 1)), contains('moved'));
      expect(rig.contexts.of(_c1).serial, greaterThan(serial));
      for (var i = 1; i <= 2; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

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
      await prime();
      await say(bobGroup(), 2);
      // Out of range, not a date: 2^53 microseconds is about 9.0e9 s.
      final far = ts.Timestamp()..seconds = Int64(10) * Int64(1000000000000);
      // The live batch (it records no listing position) gets the message at
      // a time beyond what the client holds. An epoch page with such a time
      // is refused instead (the order check): see the order check group.
      rig.server.rewriteLive = (real) {
        final out = real.deepCopy();
        for (final m in out.messages) {
          m.createdAt = far;
        }
        return out;
      };
      // Every epoch page carries a cleared_at beyond it too.
      rig.server.rewriteEpoch = (real) => real.deepCopy()..clearedAt = far;

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(2)))!;
      expect(m.state, StoredMessageState.visible);
      expect(m.createdAtMicros, 0);

      await bobSelfUpdate();
      rig.server.epochRequests.clear();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // The catch-up's sink listed at least one page with that cleared_at.
      expect(rig.server.epochRequests, isNotEmpty);
      expect((await sync()).clearedAtMicros, isNull);
    });

    test('a later generation with no welcome stops the batch, and an unheld '
        'welcome poll runs after the lock is released', () async {
      await setUpJoined();
      // The fast path needs a saved token and an ended open walk.
      final token = await prime();
      rig.contexts.of(_c1).livePulledAt = null;
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
      expect((await sync()).sinceToken, token);
      expect(rig.contexts.of(_c1).livePulledAt, isNull);
      expect(rig.device.engine.processed, isEmpty);
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

    test('a completed live pull records its pair and an interrupted one does '
        'not', () async {
      await setUpJoined();
      final context = rig.contexts.of(_c1);
      expect(context.livePulledAt, isNull);
      expect(context.syncedSinceStart, isFalse);
      await say(bobGroup(), 1);
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.unavailable,
        'x',
      );

      await rig.receiver.pullLive(_c1);

      expect(context.livePulledAt, isNull);
      expect(context.syncedSinceStart, isFalse);

      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);

      expect(context.livePulledAt, const MlsPair(1, 1));
      expect(context.syncedSinceStart, isTrue);

      // A gapped probe page: recorded only once the open walk ended and its
      // token was saved (rule 2).
      context
        ..livePulledAt = null
        ..syncedSinceStart = false;
      await sayMany(2, 3, start: seconds(1));
      rig.server.livePageSize = 1;
      rig.device.engine.failProcessCall[rig.device.engine.processed.length +
          1] = const MlsException(
        MlsErrorCode.unavailable,
        'x',
      );
      await rig.receiver.pullLive(_c1);
      expect(context.livePulledAt, isNull);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect(context.livePulledAt, const MlsPair(1, 1));

      // The open walk for an older pair (a commit applied meanwhile, by
      // catch-up, which records nothing of the live pull): not recorded
      // until the new pair's walk ended.
      context
        ..livePulledAt = null
        ..syncedSinceStart = false;
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.livePulledAt, isNull);
      await say(bobGroup(), 9, at: seconds(9));
      rig.device.engine.failProcessCall[rig.device.engine.processed.length +
          1] = const MlsException(
        MlsErrorCode.unavailable,
        'x',
      );
      await rig.receiver.pullLive(_c1);
      expect(context.livePulledAt, isNull);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect(context.livePulledAt, const MlsPair(1, 2));
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

    test('applyClearedAtOnce lists without the lock', () async {
      await setUpJoined();
      final held = <bool>[];
      rig.server.onCall = (c) async {
        if (c == 'listEpochMessages') held.add(rig.locks.isHeld(_c1));
      };
      rig.server.clearedAt[_c1] = t0;

      await rig.receiver.applyClearedAtOnce(_c1);

      expect(held, [false]);
      expect((await sync()).clearedAtMicros, t0.microsecondsSinceEpoch);
    });
  });

  group('durable walks (C1)', () {
    test(
      'an epoch of 5000 messages completes across passes and across a '
      'restart, refetching at most one page, and its commit applies',
      () async {
        // Scaled tenfold (M7): 500 messages in pages of 5 are the 100 pages
        // of 5000 messages in pages of 50.
        const pageSize = 5;
        const count = 500;
        await setUpJoined(pageSize: pageSize);
        final sent = await sayMany(
          1,
          count,
          start: const Duration(minutes: -10),
        );
        await bobSelfUpdate();
        final listed = <String>[];
        rig.server.rewriteEpoch = (real) {
          listed.addAll(real.messages.map((m) => m.id));
          return real;
        };

        // The sink lists 2 pages under the lock, then leaves the walk pending.
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect(rig.contexts.of(_c1).catchUpDueAt, const MlsPair(1, 1));
        var passes = 0;
        var killed = false;
        // The pass that ends the close walk applies the commit (I2).
        while ((await rig.device.vault.group(_c1, 1))!.epoch == 1) {
          if (++passes == 4) {
            // The app is killed while the third message of a page is being
            // decrypted: that pass never returns; the app starts again.
            final inFlight = Completer<void>();
            rig.device.engine.onProcessCall[rig.device.engine.processed.length +
                3] = () {
              inFlight.complete();
              return Completer<void>().future;
            };
            unawaited(rig.receiver.pullLive(_c1));
            await inFlight.future;
            await rig.restart();
            killed = true;
            continue;
          }
          await rig.receiver.pullLive(_c1);
          expect(passes, lessThan(40));
        }
        expect(killed, isTrue);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

        expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
        // At most the page in flight was listed again, and only its message
        // in flight was given to the engine again.
        expect(
          listed.length - listed.toSet().length,
          lessThanOrEqualTo(pageSize),
        );
        expect(listed.toSet(), hasLength(count));
        final wires = {
          for (final m in sent) String.fromCharCodes(m.ciphertext),
        };
        final decrypts = rig.device.engine.processed
            .where((w) => wires.contains(String.fromCharCodes(w)))
            .length;
        expect(decrypts, inInclusiveRange(count, count + 1));
        final tokens = orderedTokens(const MlsPair(1, 1));
        expect(tokens.length, lessThanOrEqualTo(count ~/ pageSize + 2));
        final rows = await rig.device.vault.messages(_c1, limit: 600);
        expect(
          rows.where((m) => m.state == StoredMessageState.visible),
          hasLength(count),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('a walk resumes from the stored cursor after a restart in the middle '
        'of a page', () async {
      await setUpJoined();
      final sent = await sayMany(1, 80, start: const Duration(minutes: -10));
      // The app is killed while page 2's tenth message (the 60th process
      // call) is being decrypted: the pass never returns.
      final inFlight = Completer<void>();
      rig.device.engine.onProcessCall[60] = () {
        inFlight.complete();
        return Completer<void>().future;
      };
      unawaited(rig.receiver.pullLive(_c1));
      await inFlight.future;

      expect((await row(_mid(59)))!.state, StoredMessageState.visible);
      expect(await row(_mid(60)), isNull);
      final page2 = orderedTokens(const MlsPair(1, 1)).last;
      expect(page2, isNotEmpty);
      expect((await receiveRecord()).open!.t, page2);

      // The receiver is dropped; the same vault file is opened again.
      await rig.restart();
      rig.server.epochRequests.clear();
      await rig.receiver.pullLive(_c1);

      expect(orderedTokens(const MlsPair(1, 1)).first, page2);
      for (var i = 1; i <= 80; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
      // Only the message in flight was given to the engine twice.
      for (final m in sent) {
        expect(processedCount(m.ciphertext), m.id == _mid(60) ? 2 : 1);
      }
    });

    test('an oversized next or resume token is treated as refused', () async {
      await setUpJoined();
      await sayMany(1, 3, start: const Duration(minutes: -10));
      final long = 'x' * (kMaxTokenChars + 1);
      var n = 0;
      rig.server.rewriteEpoch = (real) => switch (++n) {
        1 => real.deepCopy()..nextPageToken = long,
        2 => real.deepCopy()..resumePageToken = long,
        _ => real,
      };
      // Before the second and third listings: nothing of the pages with an
      // oversized token was processed.
      final before = <StoredMessage?>[];
      rig.server.afterEpochAnswer = () async {
        if (n >= 1) before.add(await row(_mid(1)));
      };

      await rig.receiver.pullLive(_c1);

      expect(before, [null, null]);
      // Each was a refused token: the walk listed again from the start.
      expect(orderedTokens(const MlsPair(1, 1)), ['', '', '']);
      expect(rig.contexts.of(_c1).orderViolation, 0);
      for (var i = 1; i <= 3; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
      expect((await receiveRecord()).open!.end, isTrue);
    });

    test('a page whose next token holds control characters is refused and the '
        'record still decodes', () async {
      await setUpJoined();
      final sent = await sayMany(1, 60, start: const Duration(minutes: -10));
      final shape = RegExp(r'^[\x21\x23-\x5b\x5d-\x7e]*$');
      // Page 1 is full; its next and resume tokens are 1,024 × U+0001 (six
      // bytes each in JSON).
      final bad = '\u0001' * kMaxTokenChars;
      var n = 0;
      rig.server.rewriteEpoch = (real) => ++n == 1
          ? (real.deepCopy()
              ..nextPageToken = bad
              ..resumePageToken = bad)
          : real;
      // Before the second listing: nothing of page 1 was processed.
      final before = <StoredMessage?>[];
      rig.server.afterEpochAnswer = () async {
        if (n == 1 && before.isEmpty) before.add(await row(_mid(1)));
      };

      await rig.receiver.pullLive(_c1);

      expect(before, [null]);
      // The token was refused: the walk listed again from the start, and no
      // token outside the shape was ever sent or stored.
      final tokens = orderedTokens(const MlsPair(1, 1));
      expect(tokens.take(2), ['', '']);
      expect(tokens.where((t) => !shape.hasMatch(t)), isEmpty);
      expect(rig.contexts.of(_c1).orderViolation, 0);
      final bytes = await rig.device.vault.setting(ReceiveRecords.keyOf(_c1));
      final stored = ReceiveRecord.decode(bytes!);
      for (final t in [stored.open!.t, stored.open!.s, stored.anchor]) {
        expect(shape.hasMatch(t), isTrue);
      }
      expect(stored.open!.end, isTrue);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('a page goes stale when only the record serial changed', () async {
      await setUpJoined();
      final sent = await sayMany(1, 60, start: const Duration(minutes: -10));
      // While page 1 is in flight, a record write elsewhere bumps the serial;
      // the pair and the token of the entry are unchanged.
      rig.server.afterEpochAnswer = () async {
        rig.server.afterEpochAnswer = null;
        rig.contexts.of(_c1).serial++;
      };

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).discardedPages, 1);
      expect(orderedTokens(const MlsPair(1, 1)).take(2), ['', '']);
      for (final m in sent) {
        expect(processedCount(m.ciphertext), 1);
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('a page stops when its pass goes stale in the middle of it', () async {
      await setUpJoined();
      final sent = await sayMany(1, 10, start: const Duration(minutes: -10));
      // While the fourth message is decrypted, another tab takes the vault:
      // the session stops its writers at once.
      final engine = rig.device.engine;
      engine.onProcessCall[engine.processed.length + 4] = () async {
        rig.device.owner!.steal();
      };
      rig.changed.clear();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      // The message whose body was running commits; nothing after it is
      // given to the engine or written, and the cursor did not move.
      expect(engine.processed, hasLength(4));
      expect(rig.changed, contains(_c1));

      await rig.restart();
      expect((await receiveRecord()).open!.t, '');
      for (var i = 1; i <= 4; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
      expect(await row(_mid(5)), isNull);

      // The next run lists the page again; stored messages are skipped.
      await rig.receiver.pullLive(_c1);
      for (final m in sent) {
        expect(processedCount(m.ciphertext), 1);
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('an unreadable or older receive record only re-lists pages and '
        'stores every message once', () async {
      await setUpJoined();
      final sent = await sayMany(1, 120, start: const Duration(minutes: -10));
      rig.device.engine.failProcessCall[51] = const MlsException(
        MlsErrorCode.unavailable,
        'x',
      );
      await rig.receiver.pullLive(_c1);
      final key = ReceiveRecords.keyOf(_c1);
      final older = (await rig.sealedSetting(key))!;
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);
      final processed = rig.device.engine.processed.length;
      final dump = await rig.device.vault.messages(_c1, limit: 500);

      // A replayed older record: the walk re-lists from its old cursor.
      await rig.replaySealedSetting(key, older);
      rig.server.epochRequests.clear();
      await rig.receiver.pullLive(_c1);
      expect(orderedTokens(const MlsPair(1, 1)), isNotEmpty);
      // An unreadable one: it reads as empty and re-lists from the start.
      await rig.replaySealedSetting(key, Uint8List.fromList([1, 2, 3]));
      rig.server.epochRequests.clear();
      await rig.receiver.pullLive(_c1);
      expect(orderedTokens(const MlsPair(1, 1)).first, '');

      // Reads only: nothing was decrypted again and every row is as it was.
      expect(rig.device.engine.processed.length, processed);
      final after = await rig.device.vault.messages(_c1, limit: 500);
      expect(after, hasLength(sent.length));
      expect(
        [for (final m in after) (m.messageId, m.state)],
        [for (final m in dump) (m.messageId, m.state)],
      );
      expect(rig.unexpected.whereType<E2eePipelineError>().map((e) => e.step), [
        'receive.read',
      ]);
      rig.unexpected.clear();
    });

    test('a first sync of 3000 current-pair messages decrypts oldest first '
        'through the open walk and only then saves the since token', () async {
      // Scaled tenfold (M7): 300 messages in pages of 5 are the 60 pages of
      // 3000 messages in pages of 50.
      await setUpJoined(pageSize: 5);
      final sent = await sayMany(1, 300, start: const Duration(minutes: -10));
      final index = {
        for (var i = 0; i < sent.length; i++)
          String.fromCharCodes(sent[i].ciphertext): i,
      };
      var passes = 0;
      ReceiveOutcome out;
      do {
        out = await rig.receiver.pullLive(_c1, priority: BudgetPriority.user);
        if (out.kind != ReceiveOutcomeKind.complete) {
          expect((await sync()).sinceToken, '');
        }
        expect(++passes, lessThan(20));
      } while (out.kind != ReceiveOutcomeKind.complete);

      expect(passes, greaterThan(1));
      expect((await sync()).sinceToken, isNotEmpty);
      final order = [
        for (final w in rig.device.engine.processed)
          index[String.fromCharCodes(w)]!,
      ];
      expect(order, List.generate(300, (i) => i));
      // Only the probe's one ListMessages call per pass: no ListMessages
      // paging.
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        hasLength(passes),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the open walk resumes from its settle token and lists only messages '
        'stored since', () async {
      await setUpJoined();
      await sayMany(1, 5, start: const Duration(minutes: -10));
      await prime();
      final s = (await receiveRecord()).open!.s;
      expect(s, isNotEmpty);
      await sayMany(6, 2);
      // A gapped probe page: the open walk lists once from s.
      rig.server.livePageSize = 1;
      final listed = <String>[];
      rig.server.rewriteEpoch = (real) {
        listed.addAll(real.messages.map((m) => m.id));
        return real;
      };
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      expect(orderedTokens(const MlsPair(1, 1)).first, s);
      expect(listed, [_mid(6), _mid(7)]);
      expect((await row(_mid(7)))!.state, StoredMessageState.visible);
    });

    test(
      'a message committed late inside the trail is found by the next listing',
      () async {
        await setUpJoined();
        await say(bobGroup(), 1);
        final token = await prime();
        // Stamped before message 1 (inside the 60 s trail), stored after the
        // listing that passed its position.
        await say(bobGroup(), 2, at: seconds(-30));
        await say(bobGroup(), 3, at: seconds(1));
        rig.server.livePageSize = 1;

        await rig.receiver.pullLive(_c1);

        expect((await row(_mid(2)))!.state, StoredMessageState.visible);
        expect((await row(_mid(3)))!.state, StoredMessageState.visible);
        expect((await sync()).sinceToken, isNot(token));
      },
    );

    test('the settle token stops at the first unsettled page and the next '
        'listing starts there', () async {
      await setUpJoined();
      await sayMany(1, 100, start: const Duration(minutes: -10));
      await sayMany(101, 20);
      await prime();
      final open = (await receiveRecord()).open!;
      // Pages 1 and 2 were settled (their floor is message 100); page 3
      // trails, so s is its resume token, not the end.
      expect(open.f, isNotNull);
      expect(open.f!.id, _mid(100));
      // A time-only position (the trail), not the position after message
      // 120.
      expect(open.s, endsWith(':-'));
      expect(open.end, isTrue);
      // Two new messages and a page size of one: a gapped probe page.
      await sayMany(121, 2, start: seconds(1));
      rig.server.livePageSize = 1;
      final listed = <String>[];
      rig.server.rewriteEpoch = (real) {
        listed.addAll(real.messages.map((m) => m.id));
        return real;
      };
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      expect(orderedTokens(const MlsPair(1, 1)).first, open.s);
      expect(listed, [for (var i = 101; i <= 122; i++) _mid(i)]);
    });

    test(
      'the fast path runs one settle listing at most every ten minutes',
      () async {
        await setUpJoined();
        await prime();
        await say(bobGroup(), 1);
        rig.server.calls.clear();

        await rig.receiver.pullLive(_c1);
        expect(epochCalls(), 0);
        expect((await row(_mid(1)))!.state, StoredMessageState.visible);

        rig.clock.advance(const Duration(minutes: 10));
        await rig.receiver.pullLive(_c1);
        expect(epochCalls(), 1);
        await rig.receiver.pullLive(_c1);
        expect(epochCalls(), 1);
      },
    );
  });

  group('the since-token rule (§4)', () {
    test('a gapped since page is not processed and its token is saved only '
        'after the open walk reached its end', () async {
      await setUpJoined();
      final token = await prime();
      await sayMany(1, 7);
      rig.server.livePageSize = 2;
      final atListing = <String>[];
      rig.server.afterEpochAnswer = () async {
        atListing.add((await sync()).sinceToken);
        expect(await row(_mid(7)), isNull);
      };
      rig.server.calls.clear();

      await rig.receiver.pullLive(_c1);

      // One probe call (the gap is never followed), then the open walk.
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        hasLength(1),
      );
      expect(atListing, [token]);
      for (var i = 1; i <= 7; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
      expect((await sync()).sinceToken, isNot(token));
    });

    test('the fast path reads the open walk again under the lock', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      // While the probe is in flight, the open walk's entry stops being at
      // its end (no serial bump: a write the serial does not see).
      rig.server.onCall = (c) async {
        if (c != 'listMlsMessages') return;
        rig.server.onCall = null;
        final r = await receiveRecord();
        await putReceiveRecord(r.copyWith(open: r.open!.copyWith(end: false)));
      };
      final atListing = <StoredMessage?>[];
      rig.server.afterEpochAnswer = () async {
        atListing.add(await row(_mid(1)));
      };

      await rig.receiver.pullLive(_c1);

      // The probe page was not processed: message 1 came through the walk.
      expect(atListing, isNotEmpty);
      expect(atListing.first, isNull);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
    });

    test('the walked since token is not saved over a token that changed since '
        'the listing', () async {
      await setUpJoined();
      final token = await prime();
      await sayMany(1, 3);
      // A gapped probe page: its token waits for the open walk's end (§4
      // rule 2). While the walk's page is in flight, the stored token moves.
      rig.server.livePageSize = 1;
      // Neither the primed token nor the probe's (s:3).
      const other = 's:2';
      expect(other, isNot(token));
      rig.server.afterEpochAnswer = () async {
        rig.server.afterEpochAnswer = null;
        final s = await sync();
        await rig.device.vault.transaction(
          (tx) => tx.putConversationSync(_c1, s.copyWith(sinceToken: other)),
        );
      };

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, other);
    });

    test('the since token is never saved while the open walk is for an older '
        'pair', () async {
      await setUpJoined();
      final token = await prime();
      await sayMany(1, 2);
      rig.server.livePageSize = 1;
      // While the open walk's page of (1, 1) is in flight, catch-up
      // applies bob's commit; the page is then stale.
      rig.server.afterEpochAnswer = () async {
        rig.server.afterEpochAnswer = null;
        await bobSelfUpdate();
        await say(bobGroup(), 3, at: seconds(1));
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        rig.device.engine.failProcessCall[rig.device.engine.processed.length +
            1] = const MlsException(
          MlsErrorCode.unavailable,
          'x',
        );
      };

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).discardedPages, greaterThanOrEqualTo(1));
      expect((await sync()).sinceToken, token);
      expect(await row(_mid(3)), isNull);
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kEngineBackoff);
        await rig.receiver.pullLive(_c1);
      }
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, isNot(token));
    });

    test('a probe page without a gap is not processed after a join until the '
        "new pair's open walk ended", () async {
      await setUpJoined();
      final token = await prime();
      await say(bobGroup(), 1);
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // The open walk of the new pair (1, 2) starts from the beginning.
      expect((await receiveRecord()).open, isNull);
      await say(bobGroup(), 2, at: seconds(1));
      rig.server.afterEpochAnswer = () async {
        // The probe page (messages 1 and 2, no gap) was not processed.
        expect(await row(_mid(2)), isNull);
        expect((await sync()).sinceToken, token);
      };

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, isNot(token));
      expect((await receiveRecord()).open!.pair, const MlsPair(1, 2));
    });

    test(
      'a probe batch whose catch-up changes the pair stops without saving the '
      'token',
      () async {
        await setUpJoined();
        final token = await prime();
        await say(bobGroup(), 1);
        await bobSelfUpdate();
        await say(bobGroup(), 2, at: seconds(1));

        await rig.receiver.pullLive(_c1);

        expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
        expect((await sync()).sinceToken, token);
        expect((await row(_mid(2)))!.state, StoredMessageState.visible);
        // The next fast path saves it.
        await rig.receiver.pullLive(_c1);
        expect((await sync()).sinceToken, isNot(token));
      },
    );

    test(
      'rows written by another writer do not move the since token',
      () async {
        await setUpJoined();
        final token = await prime();
        await say(bobGroup(), 1);
        await bobSelfUpdate();

        // Catch-up's sink stores the epoch's rows; it never saves a token.
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

        expect((await row(_mid(1)))!.state, StoredMessageState.visible);
        expect((await sync()).sinceToken, token);
      },
    );

    test(
      'the probe draws on the read budget and never on the sync budget',
      () async {
        await setUpJoined();
        await prime();
        await say(bobGroup(), 1);
        rig.readBudget.pauseUntil(
          rig.clock.now().add(const Duration(hours: 1)),
        );
        rig.server.calls.clear();

        final held = await rig.receiver.pullLive(_c1);

        expect(held.kind, ReceiveOutcomeKind.held);
        expect(rig.server.calls, isEmpty);

        rig.readBudget.reset();
        rig.syncBudget.pauseUntil(
          rig.clock.now().add(const Duration(hours: 1)),
        );

        await rig.receiver.pullLive(_c1);

        expect(rig.server.calls, ['listMlsMessages']);
        expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      },
    );

    test('an own message whose digest is in the sent log is skipped before '
        'the engine', () async {
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

      expect(processedCount(m.ciphertext), 0);
      expect(await row(_mid(1)), isNull);
    });

    test('a second pullLive joins the running pass', () async {
      await setUpJoined();
      final gate = Completer<void>();
      rig.server.onCall = (c) async {
        if (c == 'listMlsMessages') await gate.future;
      };
      final a = rig.receiver.pullLive(_c1);
      final b = rig.receiver.pullLive(_c1);
      gate.complete();

      expect(await a, same(await b));
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        hasLength(1),
      );
    });

    test(
      'no ListMessages call is made while the conversation lock is held',
      () async {
        await setUpJoined();
        final held = <bool>[];
        rig.server.onCall = (c) async {
          if (c == 'listMlsMessages') held.add(rig.locks.isHeld(_c1));
        };
        await prime();
        await say(bobGroup(), 1);
        await bobSelfUpdate();
        await say(bobGroup(), 2, at: seconds(1));
        rig.server.livePageSize = 1;
        await rig.receiver.pullLive(_c1);
        await rig.receiver.pullLive(_c1);
        // The commit applies by catch-up (Task 13 runs it); the new pair's
        // open walk then lists message 2.
        await rig.crypto.catchUp(_c1);
        await rig.receiver.pullLive(_c1);

        expect(held, isNotEmpty);
        expect(held, everyElement(isFalse));
        expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      },
    );
  });

  group('ownership and the close walk (§5)', () {
    test("the close walk adopts the open walk's cursor for the same pair and "
        'ends after one listing from the settle token', () async {
      await setUpJoined();
      await sayMany(1, 5, start: const Duration(minutes: -10));
      await prime();
      final s = (await receiveRecord()).open!.s;
      await bobSelfUpdate();
      rig.server.epochRequests.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(orderedTokens(const MlsPair(1, 1)), [s]);
    });

    test('a close created while the open walk is mid-backlog lists the epoch '
        'once in total', () async {
      await setUpJoined();
      await sayMany(1, 590, start: const Duration(minutes: -10));
      final out = await rig.receiver.pullLive(_c1);
      expect(out.kind, ReceiveOutcomeKind.more);
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final tokens = orderedTokens(const MlsPair(1, 1));
      expect(tokens, hasLength(12));
      expect(tokens.toSet(), hasLength(12));
      for (var i = 1; i <= 590; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('the sink lists at most 2 epoch pages per lock hold and never waits '
        'for the budget', () async {
      await setUpJoined();
      await sayMany(1, 200, start: const Duration(minutes: -10));
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(orderedTokens(const MlsPair(1, 1)), hasLength(2));

      // No unit free: the sink makes no call and does not wait.
      rig.server.epochRequests.clear();
      rig.syncBudget.pauseUntil(rig.clock.now().add(const Duration(hours: 1)));
      Object? error;
      await rig.locks.run(_c1, () async {
        try {
          await rig.receiver.completeEpoch(
            _c1,
            const MlsPair(1, 1),
            priority: BudgetPriority.user,
          );
        } on Object catch (e) {
          error = e;
        }
      });
      expect(error, isA<Exception>());
      expect(rig.server.epochRequests, isEmpty);
    });

    test("another conversation's sink hold does not reset this hold's page "
        'count', () async {
      await setUpJoined();
      await sayMany(1, 200, start: const Duration(minutes: -10));
      await bobSelfUpdate();
      const c2 = '22222222222222222222222222222222';
      // While this hold's first page is in flight, the sink runs for c2
      // under c2's own lock (one empty page).
      rig.server.afterEpochAnswer = () async {
        rig.server.afterEpochAnswer = null;
        await rig.locks.run(
          c2,
          () => rig.receiver.completeEpoch(
            c2,
            const MlsPair(1, 1),
            priority: BudgetPriority.user,
          ),
        );
      };

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);

      // Two pages for _c1's hold and one for c2's.
      expect(orderedTokens(const MlsPair(1, 1)), hasLength(3));
    });

    test('a pending close walk is reported and the next pass completes it and '
        'the commit applies', () async {
      await setUpJoined();
      await sayMany(1, 200, start: const Duration(minutes: -10));
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(rig.contexts.of(_c1).catchUpDueAt, const MlsPair(1, 1));

      await rig.receiver.pullLive(_c1);

      // The pass ended the close walk and applied the commit itself (I2).
      expect(rig.contexts.of(_c1).catchUpDueAt, isNull);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      for (var i = 1; i <= 200; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('a pass whose close walk has ended applies the commit itself and does '
        'not spend another probe read', () async {
      await setUpJoined();
      await sayMany(1, 200, start: const Duration(minutes: -10));
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      rig.server.calls.clear();

      final out = await rig.receiver.pullLive(_c1);

      // The close walk ended in this pass, and the same pass applied the
      // commit: no further pass (and probe read) is needed for it.
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        hasLength(1),
      );
      expect(
        rig.server.calls.where((c) => c == 'listConversationCommits'),
        hasLength(1),
      );
      // The new pair's open walk is left (created at the next read).
      expect(out.kind, ReceiveOutcomeKind.more);
      for (var i = 1; i <= 200; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('a pass that saw a later pair on the probe runs one catch-up and '
        'continues on the next pair', () async {
      await setUpJoined();
      final token = await prime();
      await say(bobGroup(), 1);
      await bobSelfUpdate();
      await say(bobGroup(), 2, at: seconds(1));
      // A gapped probe page: not processed; the open walk of (1, 1) ends and
      // §4 rule 2 saves the probe's token, past message 2 of (1, 2).
      rig.server.livePageSize = 1;
      rig.server.calls.clear();

      final out = await rig.receiver.pullLive(_c1);

      expect((await sync()).sinceToken, isNot(token));
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect(
        rig.server.calls.where((c) => c == 'listConversationCommits'),
        hasLength(1),
      );
      expect(out.kind, ReceiveOutcomeKind.more);
      expect(await row(_mid(2)), isNull);

      rig.server.calls.clear();
      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
    });

    test('a pass whose catch-up leaves the close walk pending asks for '
        'more', () async {
      await setUpJoined();
      final token = await prime();
      // 150 messages inside the 60 s trail: the open walk ends but its
      // settle token stays before all of them.
      await sayMany(1, 150);
      await bobSelfUpdate();
      await say(bobGroup(), 151, at: seconds(1));
      rig.server.livePageSize = 1;

      final out = await rig.receiver.pullLive(_c1);

      // The catch-up's sink adopted the open walk at s and listed its 2
      // pages; the close walk is pending: work is left, not a wait.
      expect((await sync()).sinceToken, isNot(token));
      expect(out.kind, ReceiveOutcomeKind.more);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      expect((await receiveRecord()).close!.end, isFalse);

      await rig.receiver.pullLive(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
    });

    test('a later pair seen on the probe is caught up at the next pass when '
        'the catch-up failed', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      await bobSelfUpdate();
      await say(bobGroup(), 2, at: seconds(1));
      rig.server.livePageSize = 1;
      // The pass's one catch-up fails at its commit listing.
      var failed = false;
      rig.server.onCall = (c) async {
        if (c == 'listConversationCommits' && !failed) {
          failed = true;
          throw const NetworkException('rig');
        }
      };

      final first = await rig.receiver.pullLive(_c1);

      expect(failed, isTrue);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);

      // The token was saved past message 2, so this probe sees nothing new;
      // the pass still runs the catch-up the last one could not finish.
      rig.server.calls.clear();
      await rig.receiver.pullLive(_c1);

      expect(rig.server.calls, contains('listConversationCommits'));
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
    });

    test('a catch-up that applies nothing makes the pass wait, once', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      // A message of a pair the server has no commit for.
      rig.server.addMessage(
        pb.Message(
          id: _mid(2),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0.add(seconds(1))),
          ciphertext: [1, 2, 3],
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(5),
        ),
      );
      rig.server.livePageSize = 1;
      rig.server.calls.clear();

      final out = await rig.receiver.pullLive(_c1);

      expect(
        rig.server.calls.where((c) => c == 'listConversationCommits'),
        hasLength(1),
      );
      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kWalkBackoff));
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);

      rig.server.calls.clear();
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
    });

    test(
      'two fruitless catch-ups in a row wait longer the second time',
      () async {
        await setUpJoined();
        await prime();
        await say(bobGroup(), 1);
        await bobSelfUpdate();
        await say(bobGroup(), 2, at: seconds(1));
        rig.server.livePageSize = 1;
        // Every commit listing fails.
        rig.server.onCall = (c) async {
          if (c == 'listConversationCommits') {
            throw const NetworkException('rig');
          }
        };

        final first = await rig.receiver.pullLive(_c1);

        expect(first.kind, ReceiveOutcomeKind.stopped);
        expect(first.until, rig.clock.now().add(kWalkBackoff));

        rig.clock.advance(kWalkBackoff);
        rig.server.calls.clear();
        final second = await rig.receiver.pullLive(_c1);

        expect(
          rig.server.calls.where((c) => c == 'listConversationCommits'),
          hasLength(1),
        );
        expect(second.kind, ReceiveOutcomeKind.stopped);
        expect(second.until, rig.clock.now().add(kWalkBackoff * 2));
        expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      },
    );

    test('after the fast path applied the waiting commit, the next pass runs '
        'no catch-up and sets no walk backoff', () async {
      await setUpJoined();
      // This device is in generation 2 (generation 1's group is gone); the
      // open walk of the current pair has ended and the token is saved.
      final offer2 = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await prime();
      // An unfinished walk of an older pair holds the close slot: the sink
      // for the current pair is refused and the commit waits.
      await putReceiveRecord(
        (await receiveRecord()).copyWith(
          close: const WalkEntry(
            pair: MlsPair(1, 1),
            mode: WalkMode.undecryptable,
          ),
        ),
      );
      final epoch = (await rig.device.vault.group(_c1, 2))!.epoch;
      final at = rig.server.current(_c1);
      expect(at, MlsPair(2, epoch));
      final g2 = offer2.add.group;
      final c = await bob.engine.selfUpdate(bob.state, g2.state);
      g2.state = await bob.engine.confirmCommit(bob.state, c.groupState);
      rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      // The older walk no longer blocks (the slot is cleared by hand here; a
      // real end leaves it with `end`, which the sink also passes over); a
      // message of the next pair comes on an ungapped probe: the fast
      // path's batch applies the commit.
      await putReceiveRecord((await receiveRecord()).copyWith(close: null));
      await say(g2, 1, at: seconds(1), generation: 2);
      await rig.receiver.pullLive(_c1);
      expect((await rig.device.vault.group(_c1, 2))!.epoch, epoch + 1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      rig.server.calls.clear();

      final out = await rig.receiver.pullLive(_c1);

      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect(out.kind, isNot(ReceiveOutcomeKind.stopped));
      expect(rig.contexts.of(_c1).walkBackoffUntil, isNull);
    });

    test(
      'two fruitless catch-ups at different pairs do not escalate',
      () async {
        await setUpJoined();
        await prime();
        await say(bobGroup(), 1);
        noCommitMessage(2, 5, seconds(1));
        rig.server.livePageSize = 1;
        final first = await rig.receiver.pullLive(_c1);
        expect(first.until, rig.clock.now().add(kWalkBackoff));
        // Another catch-up (the scheduler's) moves the pair to (1, 2).
        await bobSelfUpdate();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
        rig.clock.advance(kWalkBackoff);
        await say(bobGroup(), 3, at: seconds(2));
        noCommitMessage(4, 9, seconds(3));
        rig.server.calls.clear();

        final second = await rig.receiver.pullLive(_c1);

        expect(
          rig.server.calls.where((c) => c == 'listConversationCommits'),
          hasLength(1),
        );
        // A first fruitless run at (1, 2): the flat wait, not the doubled.
        expect(second.kind, ReceiveOutcomeKind.stopped);
        expect(second.until, rig.clock.now().add(kWalkBackoff));
        expect(rig.contexts.of(_c1).walkBackoffUntil, isNull);
        expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      },
    );

    test('a fruitless catch-up never delays an honest walk', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      noCommitMessage(2, 5, seconds(1));
      rig.server.livePageSize = 1;
      final first = await rig.receiver.pullLive(_c1);
      expect(first.until, rig.clock.now().add(kWalkBackoff));
      rig.clock.advance(kWalkBackoff);
      await say(bobGroup(), 3, at: seconds(2));
      noCommitMessage(4, 6, seconds(3));
      final second = await rig.receiver.pullLive(_c1);
      // The second fruitless run at the same pair waits twice as long.
      expect(second.until, rig.clock.now().add(kWalkBackoff * 2));
      rig.clock.advance(kWalkBackoff);
      // New messages of the current pair: the open walk has pages to fetch.
      final sent = await sayMany(5, 60, start: seconds(4));

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).walkBackoffUntil, isNull);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('a due catch-up inside its own wait is not run and the pass says '
        'when', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      await bobSelfUpdate();
      await say(bobGroup(), 2, at: seconds(1));
      rig.server.livePageSize = 1;
      // Every commit listing fails: the reason (the later pair) stands.
      rig.server.onCall = (c) async {
        if (c == 'listConversationCommits') {
          throw const NetworkException('rig');
        }
      };
      await rig.receiver.pullLive(_c1);
      rig.clock.advance(kWalkBackoff);
      final second = await rig.receiver.pullLive(_c1);
      // The second fruitless run at the pair armed the catch-up's own wait.
      final notBefore = rig.clock.now().add(kWalkBackoff * 2);
      expect(second.until, notBefore);
      final context = rig.contexts.of(_c1);
      expect(context.catchUpNotBefore, notBefore);
      expect(context.laterPairSeen, const MlsPair(1, 2));
      // Inside the wait, and not at a time the flat wait would name.
      rig.clock.advance(const Duration(seconds: 45));
      rig.server.calls.clear();

      final third = await rig.receiver.pullLive(_c1);

      // The pass ran (its probe), the catch-up did not, and the pass names
      // the end of that wait.
      expect(rig.server.calls, contains('listMlsMessages'));
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect(third.kind, ReceiveOutcomeKind.stopped);
      expect(third.until, notBefore);
      expect(context.catchUpNotBefore, notBefore);
      expect(context.walkBackoffUntil, isNull);
      expect(context.laterPairSeen, const MlsPair(1, 2));
    });

    test('a later pair seen on the probe is not caught up again once the '
        'current pair has passed it', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      await bobSelfUpdate();
      await say(bobGroup(), 2, at: seconds(1));
      rig.server.livePageSize = 1;
      var failed = false;
      rig.server.onCall = (c) async {
        if (c == 'listConversationCommits' && !failed) {
          failed = true;
          throw const NetworkException('rig');
        }
      };
      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);

      // Another catch-up (the scheduler's) applies the commit: the pair
      // seen on the probe is the current pair now.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      rig.server.calls.clear();
      rig.clock.advance(kWalkBackoff);

      await rig.receiver.pullLive(_c1);

      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
    });

    test(
      'a provisional group at a close walk\'s generation reads as gone',
      () async {
        await setUpJoined();
        await sayMany(1, 60, start: const Duration(minutes: -10));
        // Generation 1 is being set up again: only a provisional group.
        final g1 = (await rig.device.vault.group(_c1, 1))!;
        await rig.device.vault.transaction((tx) async {
          await tx.deleteGroup(_c1, 1);
          await tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 1,
              epoch: 0,
              state: g1.state,
              provisional: true,
              provisionalCreatedAtMicros: t0.microsecondsSinceEpoch,
            ),
          );
        });
        await putReceiveRecord(
          const ReceiveRecord(
            close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
          ),
        );
        final processed = rig.device.engine.processed.length;

        await rig.receiver.pullLive(_c1);

        for (var i = 1; i <= 60; i++) {
          expect((await row(_mid(i)))!.state, StoredMessageState.undecryptable);
        }
        expect(rig.device.engine.processed, hasLength(processed));
        expect((await receiveRecord()).close!.end, isTrue);
        // The provisional group is kept.
        expect((await rig.device.vault.group(_c1, 1))!.provisional, isTrue);
      },
    );

    test('a pass with no final group that moves no walk waits instead of '
        'asking for more', () async {
      await setUpJoined();
      await sayMany(1, 60, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      // Every page goes stale while in flight.
      rig.server.afterEpochAnswer = () async {
        rig.contexts.of(_c1).serial++;
      };

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kWalkBackoff));
      expect(rig.contexts.of(_c1).discardedPages, kWalkPagesPerPass);
      expect(await row(_mid(1)), isNull);
    });

    test(
      'a pass never calls catch-up while its epoch walk is unfinished',
      () async {
        // Scaled tenfold (M7): 65 messages in pages of 5 are the 13 pages of
        // 650 messages in pages of 50.
        await setUpJoined(pageSize: 5);
        await sayMany(1, 65, start: const Duration(minutes: -10));
        await bobSelfUpdate();
        // A message of the next pair on the probe page too.
        await say(bobGroup(), 66, at: seconds(1));
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        rig.server.calls.clear();

        final out = await rig.receiver.pullLive(_c1);

        // 2 sink pages and 10 pass pages: the close walk has not ended.
        expect(out.kind, ReceiveOutcomeKind.more);
        expect((await receiveRecord()).close!.end, isFalse);
        expect(rig.server.calls, isNot(contains('listConversationCommits')));
        expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      },
    );

    test('an unfinished undecryptable walk is finished before a new close walk '
        'takes its slot', () async {
      await setUpJoined();
      await sayMany(1, 120, start: const Duration(minutes: -10));
      // Generation 1's group is gone (a reset) with its close walk of (1, 1)
      // unfinished in mode u; the device is now in generation 2.
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction((tx) async {
        await tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        );
        await tx.deleteGroup(_c1, 1);
      });
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      Future<Object?> sinkFor(MlsPair p) async {
        Object? error;
        await rig.locks.run(_c1, () async {
          try {
            await rig.receiver.completeEpoch(
              _c1,
              p,
              priority: BudgetPriority.user,
            );
          } on Object catch (e) {
            error = e;
          }
        });
        return error;
      }

      // The sink for (2, 1) does not take the slot: the walk is pending.
      expect(await sinkFor(const MlsPair(2, 1)), isA<Exception>());
      expect(rig.contexts.of(_c1).catchUpDueAt, const MlsPair(2, 1));
      final kept = (await receiveRecord()).close!;
      expect(kept.pair, const MlsPair(1, 1));
      expect(kept.mode, WalkMode.undecryptable);

      // The pass finishes (1, 1): every unlisted message gets its row.
      final processed = rig.device.engine.processed.length;
      await rig.receiver.pullLive(_c1);
      for (var i = 1; i <= 120; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.undecryptable);
      }
      expect(rig.device.engine.processed, hasLength(processed));

      // Now the slot is free for (2, 1).
      expect(await sinkFor(const MlsPair(2, 1)), isNull);
      expect((await receiveRecord()).close!.pair, const MlsPair(2, 1));
    });

    test('after an older undecryptable walk finishes, the next pass applies '
        'the waiting commit', () async {
      await setUpJoined();
      // This device joins generation 2 for real; generation 1's group is
      // then gone (a reset) with its close walk of (1, 1) unfinished in
      // mode u.
      final offer2 = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      await sayMany(1, 120, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      final epoch = (await rig.device.vault.group(_c1, 2))!.epoch;
      final at = rig.server.current(_c1);
      expect(at, MlsPair(2, epoch));
      // Bob commits on generation 2: the sink for (2, epoch) is refused
      // while (1, 1) is unfinished, so the commit waits.
      final g2 = offer2.add.group;
      final c = await bob.engine.selfUpdate(bob.state, g2.state);
      g2.state = await bob.engine.confirmCommit(bob.state, c.groupState);
      rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect((await receiveRecord()).close!.pair, const MlsPair(1, 1));

      // Passes only, no catch-up from outside: the pass that finishes
      // (1, 1) applies the waiting commit and continues on the new pair.
      final out = await rig.receiver.pullLive(
        _c1,
        priority: BudgetPriority.user,
      );

      for (var i = 1; i <= 120; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.undecryptable);
      }
      expect((await rig.device.vault.group(_c1, 2))!.epoch, epoch + 1);
      expect(out.kind, ReceiveOutcomeKind.more);
      expect(
        await rig.receiver.pullLive(_c1, priority: BudgetPriority.user),
        ReceiveOutcome.complete,
      );
    });

    test(
      "an unfinished orphan walk does not delay the current pair's commit",
      () async {
        await setUpJoined();
        final g1 = (await rig.device.vault.group(_c1, 1))!;
        // This device joins generation 3 for real. Two older generations
        // are kept (stored by hand): 1 at epoch 2 and 2 at epoch 1, neither
        // walked; the orphan slot takes them one after the other.
        final offer3 = await rig.offer(_c1, bob, generation: 3);
        expect(await rig.crypto.processWelcomes(), [_c1]);
        await rig.device.vault.transaction((tx) async {
          for (final (g, e) in const [(1, 2), (2, 1)]) {
            await tx.putGroup(
              GroupRecord(
                conversationId: _c1,
                generation: g,
                epoch: e,
                state: g1.state,
              ),
            );
          }
        });
        final epoch = (await rig.device.vault.group(_c1, 3))!.epoch;
        final at = rig.server.current(_c1);
        expect(at, MlsPair(3, epoch));
        // Bob commits on generation 3; the sink is held by a walk backoff,
        // so the commit waits.
        final g3 = offer3.add.group;
        final c = await bob.engine.selfUpdate(bob.state, g3.state);
        g3.state = await bob.engine.confirmCommit(bob.state, c.groupState);
        rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
        rig.contexts.of(_c1).walkBackoffUntil = rig.clock.now().add(
          const Duration(hours: 1),
        );
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect((await rig.device.vault.group(_c1, 3))!.epoch, epoch);
        rig.contexts.of(_c1).walkBackoffUntil = null;

        // The pass ends generation 1's orphan walk (its group is deleted);
        // generation 2's orphan walk takes the slot, unfinished. The commit
        // does not wait for it.
        final out = await rig.receiver.pullLive(
          _c1,
          priority: BudgetPriority.user,
        );

        expect(await rig.device.vault.group(_c1, 1), isNull);
        expect((await rig.device.vault.group(_c1, 3))!.epoch, epoch + 1);
        expect(out.kind, ReceiveOutcomeKind.more);
      },
    );

    test('the sink walks the close slot for a pair it holds instead of '
        'opening an orphan slot for the same pair', () async {
      await setUpJoined(pageSize: 5);
      await sayMany(1, 30, start: const Duration(minutes: -10));
      // The close walk of (1, 1) was started; then the device moved to
      // generation 2 and kept generation 1's group.
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await putReceiveRecord(
        const ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 1))),
      );

      Object? error;
      await rig.locks.run(_c1, () async {
        try {
          await rig.receiver.completeEpoch(
            _c1,
            const MlsPair(1, 1),
            priority: BudgetPriority.user,
          );
        } on Object catch (e) {
          error = e;
        }
      });

      // 2 of the 6 pages in this hold: the walk is pending, in the close
      // slot; no second slot lists the same pair.
      expect(error, isA<Exception>());
      final r = await receiveRecord();
      expect(r.orphan, isNull);
      expect(r.close!.pair, const MlsPair(1, 1));
      expect(r.close!.t, isNotEmpty);
      expect(orderedTokens(const MlsPair(1, 1)), hasLength(2));
      for (var i = 1; i <= 10; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test("a close walk of an older generation's last epoch deletes its kept "
        'group when it ends', () async {
      await setUpJoined(pageSize: 5);
      // 28 messages: the last page is short, so the walk's end rides the
      // transaction of its last message.
      final sent = await sayMany(1, 28, start: const Duration(minutes: -10));
      // The close walk of (1, 1) was started; then the device moved to
      // generation 2 and kept generation 1's group.
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await putReceiveRecord(
        const ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 1))),
      );
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1, priority: BudgetPriority.user);

      // Six pages, the last one short: no empty page ended the walk.
      expect(orderedTokens(const MlsPair(1, 1)), hasLength(6));

      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      // The transaction that recorded the end deleted the kept group and
      // freed the close slot; no orphan slot is made for the pair.
      expect(await rig.device.vault.group(_c1, 1), isNull);
      final r = await receiveRecord();
      expect(r.close, isNull);
      expect(r.orphan, isNull);
    });

    /// The sink for [pair], called as catch-up calls it (the lock held).
    Future<void> sinkComplete(MlsPair pair) => rig.locks.run(
      _c1,
      () =>
          rig.receiver.completeEpoch(_c1, pair, priority: BudgetPriority.user),
    );

    /// A final group of generation 2 at epoch 1 stored beside [g1] (the
    /// device moved on and kept generation 1's group).
    Future<void> keepBesideGeneration2(GroupRecord g1) =>
        rig.device.vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 2,
              epoch: 1,
              state: g1.state,
            ),
          ),
        );

    test('a close walk that ended before the generation moved still deletes '
        'its kept group', () async {
      await setUpJoined();
      final sent = await sayMany(1, 3, start: const Duration(minutes: -10));
      // The close walk of (1, 1) runs to its end while generation 1 is
      // current (a real walk, through the sink); its commit never applies.
      await sinkComplete(const MlsPair(1, 1));
      expect((await receiveRecord()).close!.end, isTrue);
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      // Then the device moved to generation 2 and kept generation 1's group.
      await keepBesideGeneration2((await rig.device.vault.group(_c1, 1))!);
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      // The pass took the final step for the walk that had already ended:
      // the group is gone and the slot is free, with nothing listed again.
      expect(await rig.device.vault.group(_c1, 1), isNull);
      final r = await receiveRecord();
      expect(r.close, isNull);
      expect(r.orphan, isNull);
      expect(orderedTokens(const MlsPair(1, 1)), isEmpty);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      expect(await rig.device.vault.group(_c1, 2), isNotNull);
    });

    test('a restart between a close walk\'s end and the delete of its kept '
        'group loses neither', () async {
      await setUpJoined();
      final sent = await sayMany(1, 3, start: const Duration(minutes: -10));
      await sinkComplete(const MlsPair(1, 1));
      await keepBesideGeneration2((await rig.device.vault.group(_c1, 1))!);
      // The app stops with the end recorded and the group still stored.
      await rig.restart();
      expect((await receiveRecord()).close!.end, isTrue);
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await receiveRecord()).close, isNull);
      expect(orderedTokens(const MlsPair(1, 1)), isEmpty);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('an ended close entry replaced by the current pair\'s close walk '
        'leaves its kept group to the orphan walk', () async {
      await setUpJoined();
      final sent = await sayMany(1, 3, start: const Duration(minutes: -10));
      await sinkComplete(const MlsPair(1, 1));
      await keepBesideGeneration2((await rig.device.vault.group(_c1, 1))!);
      // Before any pass, the sink takes the close slot for the current pair.
      await sinkComplete(const MlsPair(2, 1));
      expect((await receiveRecord()).close!.pair, const MlsPair(2, 1));
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      // The orphan check lists (1, 1) again from the start (stored ids are
      // skipped) and its final transaction deletes the group.
      expect(orderedTokens(const MlsPair(1, 1)), isNotEmpty);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await receiveRecord()).orphan, isNull);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test('an ended close walk of the current generation keeps its '
        'group', () async {
      await setUpJoined();
      await sayMany(1, 3, start: const Duration(minutes: -10));
      await sinkComplete(const MlsPair(1, 1));
      expect((await receiveRecord()).close!.end, isTrue);

      await rig.receiver.pullLive(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      expect((await receiveRecord()).close!.end, isTrue);
    });

    test('an ended close walk below the current generation never deletes a '
        'provisional group', () async {
      await setUpJoined();
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      // Generation 1 is being set up again (a provisional group only),
      // beside a final generation 2.
      await rig.device.vault.transaction((tx) async {
        await tx.deleteGroup(_c1, 1);
        await tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: g1.state,
            provisional: true,
            provisionalCreatedAtMicros: t0.microsecondsSinceEpoch,
          ),
        );
      });
      await keepBesideGeneration2(g1);
      await putReceiveRecord(
        const ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 1), end: true)),
      );

      await rig.receiver.pullLive(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.provisional, isTrue);
      expect((await receiveRecord()).close!.pair, const MlsPair(1, 1));
    });

    test('an ended close walk for another epoch than its group never deletes '
        'the group unwalked', () async {
      await setUpJoined();
      final sent = await sayMany(1, 3, start: const Duration(minutes: -10));
      // A stale slot (a replayed record): it names (1, 3), the kept group is
      // at (1, 1), never walked.
      await keepBesideGeneration2((await rig.device.vault.group(_c1, 1))!);
      await putReceiveRecord(
        const ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 3), end: true)),
      );
      var keptAtListing = false;
      rig.server.afterEpochAnswer = () async {
        if (rig.server.epochRequests.last.pair == const MlsPair(1, 1)) {
          keptAtListing = await rig.device.vault.group(_c1, 1) != null;
        }
      };

      await rig.receiver.pullLive(_c1);

      // The slot was no reason to delete: the group went only after the
      // orphan walk of its own last epoch decrypted with it.
      expect(keptAtListing, isTrue);
      for (final m in sent) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      expect(await rig.device.vault.group(_c1, 1), isNull);
    });

    test('an orphan entry stored at its end still lets go of its kept '
        'group', () async {
      await setUpJoined();
      await keepBesideGeneration2((await rig.device.vault.group(_c1, 1))!);
      // No writer leaves an orphan entry with `end` (its end clears the
      // slot); the decoder accepts one (an older or replayed record).
      await putReceiveRecord(
        const ReceiveRecord(orphan: WalkEntry(pair: MlsPair(1, 1), end: true)),
      );

      await rig.receiver.pullLive(_c1);

      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await receiveRecord()).orphan, isNull);
    });

    test('a generation switch whose lower generation\'s pair is in the close '
        'slot deletes that group, walks the last epoch, records both and '
        'joins', () async {
      await setUpJoined();
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      // This device joins generation 2 for real (that switch walks the then
      // empty (1, 1) and deletes generation 1).
      final offer2 = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      // Generation 1's group is kept after all, with messages of its last
      // epoch and its close walk started before the generation moved.
      final old = await sayMany(1, 3, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.putGroup(g1));
      await putReceiveRecord(
        const ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 1))),
      );
      final m2 = await say(
        offer2.add.group,
        10,
        at: seconds(-1),
        generation: 2,
      );
      final epoch2 = (await rig.device.vault.group(_c1, 2))!.epoch;
      // Bob starts generation 3: Task 5's switch. What is stored when the
      // switch reaches its welcome poll (before the join):
      await rig.offer(_c1, bob, generation: 3);
      GroupRecord? lowerAtPoll;
      WalkEntry? closeAtPoll;
      List<MlsPair>? doneAtPoll;
      var polls = 0;
      rig.server.onCall = (c) async {
        if (c != 'listWelcomes' || polls++ > 0) return;
        lowerAtPoll = await rig.device.vault.group(_c1, 1);
        closeAtPoll = (await receiveRecord()).close;
        doneAtPoll = (await sync()).completedEpochs;
      };

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // The sink ended (1, 1) in the close slot and deleted its group in
      // that transaction; then it walked (2, epoch2) in the freed slot.
      expect(polls, greaterThanOrEqualTo(1));
      expect(lowerAtPoll, isNull);
      expect(closeAtPoll!.pair, MlsPair(2, epoch2));
      expect(closeAtPoll!.end, isTrue);
      expect(
        doneAtPoll,
        containsAll([const MlsPair(1, 1), MlsPair(2, epoch2)]),
      );
      for (final m in old) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      expect((await row(m2.id))!.state, StoredMessageState.visible);
      // The join happened and took generation 2's group.
      expect(await rig.device.vault.group(_c1, 3), isNotNull);
      expect(await rig.device.vault.group(_c1, 2), isNull);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect(
        (await rig.device.vault.conversation(_c1))!.joinHighWater!.generation,
        3,
      );
    });

    test('a generation switch that meets an ended close walk of a lower '
        'generation deletes its group before the pair is recorded', () async {
      await setUpJoined();
      final old = await sayMany(1, 3, start: const Duration(minutes: -10));
      // The close walk of (1, 1) ends while generation 1 is current.
      await sinkComplete(const MlsPair(1, 1));
      final ended = (await receiveRecord()).close!;
      expect(ended.end, isTrue);
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      // This device joins generation 2 for real; generation 1's group is
      // kept after all, its ended close entry still stored.
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      await rig.device.vault.transaction((tx) => tx.putGroup(g1));
      await putReceiveRecord(ReceiveRecord(close: ended));
      await rig.offer(_c1, bob, generation: 3);
      GroupRecord? lowerAtPoll;
      var polls = 0;
      rig.server.onCall = (c) async {
        if (c != 'listWelcomes' || polls++ > 0) return;
        lowerAtPoll = await rig.device.vault.group(_c1, 1);
      };
      rig.server.epochRequests.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(polls, greaterThanOrEqualTo(1));
      expect(lowerAtPoll, isNull);
      expect(orderedTokens(const MlsPair(1, 1)), isEmpty);
      for (final m in old) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      expect(await rig.device.vault.group(_c1, 3), isNotNull);
      expect(await rig.device.vault.group(_c1, 2), isNull);
      expect(await rig.device.vault.group(_c1, 1), isNull);
    });

    test('a conversation with no final group still finishes its undecryptable '
        'walk', () async {
      await setUpJoined();
      await sayMany(1, 120, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      rig.server.calls.clear();
      final processed = rig.device.engine.processed.length;

      final out = await rig.receiver.pullLive(_c1);

      for (var i = 1; i <= 120; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.undecryptable);
      }
      expect(rig.device.engine.processed, hasLength(processed));
      expect((await receiveRecord()).close!.end, isTrue);
      expect(out.kind, ReceiveOutcomeKind.complete);
      // No probe without a final group; done once ended.
      expect(rig.server.calls, isNot(contains('listMlsMessages')));
      rig.server.calls.clear();
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);
      expect(epochCalls(), 0);
    });

    test('a page listed by a pass is discarded when the sink advanced the same '
        'walk meanwhile', () async {
      await setUpJoined();
      final sent = await sayMany(1, 250, start: const Duration(minutes: -10));
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      rig.server.afterEpochAnswer = () async {
        rig.server.afterEpochAnswer = null;
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      };

      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).discardedPages, 1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      for (final m in sent) {
        expect(processedCount(m.ciphertext), 1);
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
    });

    test(
      'a walk whose group was deleted while listing switches to undecryptable '
      'rows',
      () async {
        await setUpJoined();
        await sayMany(1, 120, start: const Duration(minutes: -10));
        await bobSelfUpdate();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        final processed = rig.device.engine.processed.length;
        rig.server.afterEpochAnswer = () async {
          rig.server.afterEpochAnswer = null;
          await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
        };

        await rig.receiver.pullLive(_c1);

        expect((await row(_mid(100)))!.state, StoredMessageState.visible);
        for (var i = 101; i <= 120; i++) {
          final m = (await row(_mid(i)))!;
          expect(m.state, StoredMessageState.undecryptable);
          expect(m.mine, isFalse);
        }
        expect(rig.device.engine.processed.length, processed);
        final close = (await receiveRecord()).close!;
        expect(close.mode, WalkMode.undecryptable);
        expect(close.end, isTrue);
      },
    );

    test(
      'a commit is never applied while its close walk has not ended',
      () async {
        await setUpJoined();
        await sayMany(1, 3);
        await bobSelfUpdate();
        // A sink that returns without walking.
        rig.crypto.sink = _NoWalkSink(rig.receiver);

        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);

        rig.crypto.sink = rig.receiver;
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      },
    );

    test('a close entry for a completed epoch reads as ended and writes no '
        'row', () async {
      await setUpJoined();
      await prime();
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // A late message of (1, 1) and a stale close entry for it in mode u.
      rig.server.addMessage(
        pb.Message(
          id: _mid(10),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: [1, 2, 3, 4],
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
        ),
      );
      final s = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          s.copyWith(completedEpochs: [const MlsPair(1, 1)]),
        ),
      );
      final r = await receiveRecord();
      await putReceiveRecord(
        r.copyWith(
          close: const WalkEntry(
            pair: MlsPair(1, 1),
            mode: WalkMode.undecryptable,
          ),
        ),
      );
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      expect(orderedTokens(const MlsPair(1, 1)), isEmpty);
      expect(await row(_mid(10)), isNull);
      expect((await receiveRecord()).close, isNull);
    });
  });

  group('the record and the orphan generation (§3.4, §6)', () {
    test('an empty since token with no reconcile entry creates an armed entry '
        'at read', () {
      final group = GroupRecord(
        conversationId: _c1,
        generation: 1,
        epoch: 1,
        state: Uint8List(1),
      );
      final r = ReceiveRecord.empty.normalized(
        sync: const ConversationSync(),
        groups: [group],
      );
      expect(r.rec, isNotNull);
      expect(r.rec!.armed, isTrue);
      expect(r.open!.pair, const MlsPair(1, 1));
      // A stored token: none is created.
      final kept = ReceiveRecord.empty.normalized(
        sync: const ConversationSync(sinceToken: 's:1'),
        groups: [group],
      );
      expect(kept.rec, isNull);
    });

    test('a retired since token clears the token and creates the reconcile '
        'entry in one transaction', () async {
      await setUpJoined();
      final token = await prime();
      // Step 2b: the first pass listed the tombstones and disarmed the
      // entry (until then this line expected it armed).
      expect((await receiveRecord()).rec, isNull);
      rig.server.retiredSince.add(token);
      // The record's seal fails: the token is not cleared either.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_settings');
      await rig.receiver.pullLive(_c1);
      expect((await sync()).sinceToken, token);
      rig.device.cipher.failSeal = null;

      await rig.receiver.pullLive(_c1);

      expect((await sync()).sinceToken, '');
      final rec = (await receiveRecord()).rec!;
      expect(rec.armed, isFalse);
      expect(rec.t, '');
      expect(rec.n, 0);
    });

    test('the reconcile entry is armed after one probe from the anchor even '
        'while the open walk is stalled', () async {
      await setUpJoined();
      await prime();
      final anchor = (await receiveRecord()).anchor;
      expect(anchor, isNotEmpty);
      // The since token moves on past the anchor; then it is retired.
      await say(bobGroup(), 1);
      await rig.receiver.pullLive(_c1);
      final token = (await sync()).sinceToken;
      expect(token, isNot(anchor));
      rig.server.retiredSince.add(token);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).rec!.armed, isFalse);
      await say(bobGroup(), 2, at: seconds(1));
      rig.server.epochOrderFallback = true;

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderMissing, 1);
      final record = await receiveRecord();
      expect(record.rec!.armed, isTrue);
      expect(record.anchor, isNot(anchor));
      expect(await row(_mid(2)), isNull);
    });

    test(
      'a since token outside the token shape is refused as an anchor',
      () async {
        await setUpJoined();
        // The first probe (no since token) answers a token with a control
        // character.
        var n = 0;
        rig.server.rewriteLive = (real) =>
            ++n == 1 ? (real.deepCopy()..sinceToken = 's:0\u0001') : real;

        await rig.receiver.pullLive(_c1);

        expect(n, greaterThanOrEqualTo(1));
        final bytes = await rig.device.vault.setting(ReceiveRecords.keyOf(_c1));
        final stored = ReceiveRecord.decode(bytes!);
        expect(stored.anchor, '');
        expect(stored.rec!.armed, isTrue);
      },
    );

    test('a since token outside the token shape is never saved', () async {
      await setUpJoined();
      const bad = 's:9\u0001';
      var forge = true;
      rig.server.rewriteLive = (real) =>
          forge ? (real.deepCopy()..sinceToken = bad) : real;

      // 1. The first probe (no since token): not the anchor, and not the
      // token §4 rule 2 saves when the open walk ends.
      await rig.receiver.pullLive(_c1);
      expect((await sync()).sinceToken, '');
      expect((await receiveRecord()).anchor, '');
      expect(rig.contexts.of(_c1).endToken, isNull);

      forge = false;
      final token = await prime();

      // 2. The fast path: the batch is processed, the stored token is kept.
      await say(bobGroup(), 1);
      forge = true;
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, token);

      // 3. A gapped page (rule 2): its messages come through the open walk
      // and its token is not kept for the walk's end.
      await sayMany(2, 3, start: seconds(1));
      rig.server.livePageSize = 1;
      await rig.receiver.pullLive(_c1);
      for (var i = 2; i <= 4; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
      expect((await sync()).sinceToken, token);
      expect(rig.contexts.of(_c1).endToken, isNull);
    });

    test('an orphan entry below its group\'s epoch reads as ended', () async {
      await setUpJoined();
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await putReceiveRecord(
        const ReceiveRecord(orphan: WalkEntry(pair: MlsPair(1, 1))),
      );
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      expect(orderedTokens(const MlsPair(1, 1)), isEmpty);
      // The orphan check found (1, 2), the kept group's last epoch.
      expect(orderedTokens(const MlsPair(1, 2)), isNotEmpty);
    });

    test('the last epoch of an orphan generation is decrypted with its kept '
        'group after a later join, then the group is deleted', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1, at: seconds(-1));
      // Bob starts generation 2; this device joins it and keeps generation
      // 1 (its last epoch was never walked).
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await rig.device.vault.group(_c1, 2), isNotNull);

      for (var i = 0; i < 3; i++) {
        await rig.receiver.pullLive(_c1);
      }

      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(processedCount(m1.ciphertext), 1);
      expect(await rig.device.vault.group(_c1, 1), isNull);
    });

    test('an orphan walk runs from the pass with no commit arriving', () async {
      await setUpJoined();
      await say(bobGroup(), 1, at: seconds(-1));
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      rig.server.calls.clear();

      await rig.receiver.pullLive(_c1);

      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect((await receiveRecord()).orphan, isNull);
    });
  });

  group('the order check (§3.3)', () {
    test('a page without the order echo is not processed and the walk '
        'stops', () async {
      await setUpJoined();
      await say(bobGroup(), 1);
      rig.server.epochOrderFallback = true;

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderMissing, 1);
      expect(await row(_mid(1)), isNull);
      expect((await receiveRecord()).open!.end, isFalse);
      expect((await sync()).sinceToken, '');
      // The fallback page looks like an end; the commit still waits.
      await bobSelfUpdate();
      rig.contexts.of(_c1).walkBackoffUntil = null;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      expect(await rig.receiver.epochWalkDone(_c1, const MlsPair(1, 1)), false);
    });

    test('a page that is not strictly ascending is discarded, backs off and '
        'counts an order violation', () async {
      await setUpJoined();
      await sayMany(1, 3);
      rig.server.rewriteEpoch = (real) =>
          real.deepCopy()..messages.sort((x, y) => y.id.compareTo(x.id));

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kWalkBackoff));
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect(await row(_mid(1)), isNull);
      // Backing off: no listing before the time.
      rig.server.calls.clear();
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.stopped,
      );
      expect(epochCalls(), 0);
      rig.server.rewriteEpoch = null;
      rig.clock.advance(kWalkBackoff);
      await rig.receiver.pullLive(_c1);
      for (var i = 1; i <= 3; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test('a continuation page that starts at or before the last processed '
        'message is discarded', () async {
      await setUpJoined();
      final sent = await sayMany(1, 60, start: const Duration(minutes: -10));
      rig.server.rewriteEpoch = (real) {
        if (rig.server.epochRequests.last.token.isEmpty) return real;
        return real.deepCopy()..messages.insert(0, sent[49].deepCopy());
      };

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect((await row(_mid(50)))!.state, StoredMessageState.visible);
      expect(await row(_mid(51)), isNull);
    });

    test('a listing-start page that starts at or before the settle floor is '
        'discarded', () async {
      await setUpJoined();
      final sent = await sayMany(1, 5, start: const Duration(minutes: -10));
      await prime();
      expect((await receiveRecord()).open!.f!.id, _mid(5));
      await sayMany(6, 2);
      rig.server.livePageSize = 1;
      rig.server.rewriteEpoch = (real) =>
          real.deepCopy()..messages.insert(0, sent[4].deepCopy());

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect(await row(_mid(6)), isNull);
    });

    test('a page with a malformed message id is refused as an order violation '
        'and never reaches the record', () async {
      await setUpJoined();
      final sent = await sayMany(1, 60, start: const Duration(minutes: -10));
      // Page 2 ends with an entry whose id is not 32 lower-case hex, after
      // every honest message (the order of the page is otherwise right).
      rig.server.rewriteEpoch = (real) {
        if (rig.server.epochRequests.last.token.isEmpty) return real;
        return real.deepCopy()
          ..messages.add(
            sent.last.deepCopy()
              ..id = 'A' * 32
              ..createdAt = ts.Timestamp.fromDateTime(t0),
          );
      };

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      // Nothing of page 2 was processed or recorded.
      expect((await row(_mid(50)))!.state, StoredMessageState.visible);
      expect(await row(_mid(51)), isNull);
      final page2 = orderedTokens(const MlsPair(1, 1)).last;
      expect(page2, isNotEmpty);
      final bytes = await rig.device.vault.setting(ReceiveRecords.keyOf(_c1));
      final stored = ReceiveRecord.decode(bytes!);
      expect(stored.open!.t, page2);
      expect(stored.open!.l!.id, _mid(50));

      // The next pass resumes from the old position.
      rig.server.rewriteEpoch = null;
      rig.server.epochRequests.clear();
      rig.clock.advance(kWalkBackoff);
      await rig.receiver.pullLive(_c1);
      expect(orderedTokens(const MlsPair(1, 1)).first, page2);
      for (var i = 51; i <= 60; i++) {
        expect((await row(_mid(i)))!.state, StoredMessageState.visible);
      }
    });

    test("a page whose last message has a time past the record's range is "
        'refused and the stored record still decodes', () async {
      await setUpJoined();
      await sayMany(1, 60, start: const Duration(minutes: -10));
      // Page 2's last message has the largest time a timestamp can carry
      // within _micros' seconds bound: 9,007,199,254,999,999 µs, above 2^53.
      rig.server.rewriteEpoch = (real) {
        if (rig.server.epochRequests.last.token.isEmpty) return real;
        final out = real.deepCopy();
        out.messages.last.createdAt = ts.Timestamp()
          ..seconds = Int64(9007199254)
          ..nanos = 999999999;
        return out;
      };

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      // Nothing of page 2 was processed or recorded.
      expect((await row(_mid(50)))!.state, StoredMessageState.visible);
      expect(await row(_mid(51)), isNull);
      final bytes = await rig.device.vault.setting(ReceiveRecords.keyOf(_c1));
      final stored = ReceiveRecord.decode(bytes!);
      expect(stored.open!.l!.id, _mid(50));
    });

    test('an empty page that carries a next token is refused', () async {
      await setUpJoined();
      await sayMany(1, 3);
      // Endless empty pages: each one names a next page.
      var n = 0;
      rig.server.rewriteEpoch = (real) => real.deepCopy()
        ..messages.clear()
        ..nextPageToken = 't:$_c1:1:1:${++n}:${_mid(n)}';

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect(orderedTokens(const MlsPair(1, 1)), hasLength(1));
      expect((await receiveRecord()).open!.t, '');

      // A short page with a next token is refused the same way.
      rig.server.rewriteEpoch = (real) =>
          real.deepCopy()..nextPageToken = 't:$_c1:1:1:1:${_mid(1)}';
      rig.clock.advance(const Duration(hours: 1));
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.stopped,
      );
      expect(rig.contexts.of(_c1).orderViolation, 2);
      expect(await row(_mid(1)), isNull);
    });

    test('a page with more than 50 messages is refused', () async {
      await setUpJoined();
      final m = await say(bobGroup(), 1);
      rig.server.rewriteEpoch = (real) => real.deepCopy()
        ..messages.addAll([
          for (var i = 0; i < 50; i++)
            m.deepCopy()
              ..id = _mid(100 + i)
              ..createdAt = ts.Timestamp.fromDateTime(t0.add(seconds(i + 1))),
        ]);

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect(await row(_mid(1)), isNull);
      expect(rig.device.engine.processed, isEmpty);
    });

    test('a ciphertext over 8192 bytes is not held and is an undecryptable '
        'row without an engine call', () async {
      await setUpJoined();
      rig.server.addMessage(
        pb.Message(
          id: _mid(1),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(t0),
          ciphertext: List.filled(kMaxCiphertextBytes + 1, 1),
          reportCommitment: List.filled(32, 1),
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
        ),
      );
      await say(bobGroup(), 2, at: seconds(1));

      await rig.receiver.pullLive(_c1);

      final m = (await row(_mid(1)))!;
      expect(m.state, StoredMessageState.undecryptable);
      expect(m.mine, isFalse);
      expect(rig.device.engine.processed, hasLength(1));
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
    });

    test('junk 8 KiB entries under fake ids in an epoch leave every honest '
        'message decryptable', () async {
      await setUpJoined();
      final honest = <pb.Message>[];
      for (var i = 0; i < 20; i++) {
        honest.add(await say(bobGroup(), 2 * i + 1, at: seconds(2 * i)));
        rig.server.addMessage(
          pb.Message(
            id: _mid(2 * i + 2),
            conversationId: _c1,
            state: MessageState.MESSAGE_STATE_VISIBLE,
            createdAt: ts.Timestamp.fromDateTime(t0.add(seconds(2 * i + 1))),
            ciphertext: List.filled(kMaxCiphertextBytes, i),
            reportCommitment: List.filled(32, 1),
            mlsGeneration: Int64(1),
            mlsEpoch: Int64(1),
          ),
        );
      }

      await rig.receiver.pullLive(_c1);

      for (final m in honest) {
        expect((await row(m.id))!.state, StoredMessageState.visible);
      }
      for (var i = 0; i < 20; i++) {
        expect(
          (await row(_mid(2 * i + 2)))!.state,
          StoredMessageState.undecryptable,
        );
      }
    });
  });

  // ---------------------------------------------------------------------
  // Step 2a: the failure rule (§7), the deferred record, the placeholder.

  const internal = MlsException(MlsErrorCode.internal, 'x');
  const deadline = MlsException(MlsErrorCode.deadline, 'x');
  const unavailable = MlsException(MlsErrorCode.unavailable, 'x');

  RigEngine engine() => rig.device.engine;

  /// The stored deferred record.
  Future<DeferredRecord> deferred() async =>
      (await DeferredRecords().read(rig.device.vault, _c1)).record;

  Future<List<String>> deferredIds() async => [
    for (final i in (await deferred()).items) i.id,
  ];

  /// Stores [r] as the deferred record (as a transaction would leave it).
  Future<void> putDeferred(DeferredRecord r) =>
      rig.device.vault.transaction((tx) => DeferredRecords().putIn(tx, _c1, r));

  /// Every `process` call with [m]'s bytes fails with [e].
  void failAlways(pb.Message m, MlsException e) =>
      engine().failWireAlways[RigEngine.key(m.ciphertext)] = e;

  /// The next `process` calls with [m]'s bytes fail with [errors], in order.
  void failNext(pb.Message m, List<MlsException> errors) =>
      engine().failWire[RigEngine.key(m.ciphertext)] = [...errors];

  int count(String name) => engine().calls.where((c) => c == name).length;

  /// A new app run in the same process: the engine and the receiver resume.
  void resume() {
    engine().onAppResumed();
    rig.receiver.onAppResumed();
  }

  group('the failure rule on a fresh message (§7.2)', () {
    test('internal whose describe probe succeeds defers the message with a '
        'strike and the walk goes on', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      final before = await groupState();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect(await row(_mid(1)), isNull);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      final item = (await deferred()).items.single;
      expect(item.id, _mid(1));
      expect(item.pair, const MlsPair(1, 1));
      expect(item.at, t0.microsecondsSinceEpoch);
      expect(item.da, rig.clock.now().microsecondsSinceEpoch);
      expect(item.la, item.da);
      expect(item.ct, m1.ciphertext);
      expect(item.rc, m1.reportCommitment);
      expect(item.fs, isFalse);
      expect((item.k, item.cc, item.cu), (1, 0, 0));
      expect(item.ru, matches(RegExp(r'^[0-9a-f]{16}$')));
      // The probe ran on the group state the failure left untouched.
      expect(count('describe'), 1);
      expect(count('randomBytes'), 0);
      expect(await groupState(), isNot(before));
      expect((await sync()).sinceToken, isNotEmpty);
      expect(rig.changed, contains(_c1));
      expect(rig.receiver.deferredCount, 1);

      // A walk never gives a deferred id to the engine again.
      await say(bobGroup(), 3, at: seconds(2));
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 1);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
    });

    test('two adjacent internal failures with succeeding probes are both '
        'deferred and the walk goes on', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      await say(bobGroup(), 3, at: seconds(2));
      failAlways(m1, internal);
      failAlways(m2, internal);

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect(count('describe'), 2);
      expect(rig.contexts.of(_c1).walkBackoffUntil, isNull);
    });

    test('internal whose describe and device probes fail stops the pass with '
        'no strike, no deferral and no row', () async {
      await setUpJoined();
      // The walks' own records are written first, so that the dump shows
      // only what the failure writes.
      await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      await say(bobGroup(), 2, at: seconds(2));
      failAlways(m1, internal);
      engine().failAlways['describe'] = internal;
      engine().failAlways['randomBytes'] = internal;
      final before = await rig.dump();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kEngineBackoff));
      expect(await rig.dump(), before);
      expect(rig.receiver.breakerOpened, 1);
      // Not before the backoff; then the backoff doubles.
      final again = await rig.receiver.pullLive(_c1);
      expect(again.kind, ReceiveOutcomeKind.stopped);
      expect(processedCount(m1.ciphertext), 1);
      rig.clock.advance(kEngineBackoff);
      final third = await rig.receiver.pullLive(_c1);
      expect(third.until, rig.clock.now().add(kEngineBackoff * 2));
      expect(processedCount(m1.ciphertext), 2);
      expect(await rig.dump(), before);

      // Once the engine works again everything decrypts: nothing was lost.
      engine().failAlways.clear();
      engine().failWireAlways.clear();
      rig.clock.advance(kEngineBackoff * 2);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });

    test('unavailable stops the pass and counts no attempt', () async {
      await setUpJoined();
      await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      await say(bobGroup(), 2, at: seconds(2));
      failNext(m1, [unavailable]);
      final before = await rig.dump();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kEngineBackoff));
      expect(await rig.dump(), before);
      // No probe either: the device is down.
      expect(count('describe'), 0);
      expect(count('randomBytes'), 0);

      // An unavailable answer from the describe probe is device-down too.
      failNext(m1, [internal]);
      engine().failNext['describe'] = unavailable;
      rig.clock.advance(kEngineBackoff);
      final second = await rig.receiver.pullLive(_c1);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      // The second device-level result in a row: the hold doubles.
      expect(second.until, rig.clock.now().add(kEngineBackoff * 2));
      expect(await rig.dump(), before);
      expect(count('randomBytes'), 0);

      rig.clock.advance(kEngineBackoff * 2);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });

    test('a deadline whose describe probe fails is deferred unwitnessed and '
        'stops the pass, and the next pass goes on past it', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [deadline]);
      engine().failNext['describe'] = internal;
      engine().failNext['randomBytes'] = internal;

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, rig.clock.now().add(kEngineBackoff));
      final item = (await deferred()).items.single;
      expect((item.id, item.k, item.cc, item.cu), (_mid(1), 0, 0, 1));
      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);
      expect((await sync()).sinceToken, '');
      expect(rig.changed, contains(_c1));
      // The cursor passed nothing: the next pass lists the page again,
      // skips the deferred id and goes on.
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 1);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
    });

    test('three group failures with a working engine make the message a row '
        'and the group is rowed for the run', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      final m3 = await say(bobGroup(), 3, at: seconds(2));
      final state = await groupState();
      // The engine works (the device probe answers), this group state does
      // not.
      engine().failState[RigEngine.key(state)] = internal;

      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(first.until, rig.clock.now().add(kEngineBackoff));
      expect((await receiveRecord()).gf!.n, 1);
      expect((await receiveRecord()).gf!.pair, const MlsPair(1, 1));
      expect(await row(_mid(1)), isNull);
      expect(await deferredIds(), isEmpty);
      expect(count('randomBytes'), 1);

      rig.clock.advance(kEngineBackoff);
      final second = await rig.receiver.pullLive(_c1);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      // The wait doubles with the count (1 min, then 2).
      expect(second.until, rig.clock.now().add(kEngineBackoff * 2));
      expect((await receiveRecord()).gf!.n, 2);
      expect(await row(_mid(1)), isNull);
      // Inside the wait a pass makes no engine call.
      rig.clock.advance(kEngineBackoff);
      final inside = await rig.receiver.pullLive(_c1);
      expect(inside.until, second.until);
      expect(processedCount(m1.ciphertext), 2);

      rig.clock.advance(kEngineBackoff);
      final probes = count('describe');
      final third = await rig.receiver.pullLive(_c1);
      expect(third.kind, ReceiveOutcomeKind.complete);
      expect((await receiveRecord()).gf!.n, kGroupFailuresMax);
      for (final n in [1, 2, 3]) {
        final r = (await row(_mid(n)))!;
        expect(r.state, StoredMessageState.undecryptable);
        expect(r.mine, isFalse);
      }
      // Rowed for the run: the later failures of the group got no probe.
      expect(count('describe'), probes + 1);
      expect(processedCount(m1.ciphertext), 3);
      expect(processedCount(m2.ciphertext), 1);
      expect(processedCount(m3.ciphertext), 1);
      expect(await deferredIds(), isEmpty);
      expect(await groupState(), state);
    });

    test('a group failure count survives a restart', () async {
      await setUpJoined();
      await say(bobGroup(), 1);
      final state = await groupState();
      engine().failState[RigEngine.key(state)] = internal;
      await rig.receiver.pullLive(_c1);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);

      await rig.restart();
      // A strike counts only a minute or more after the last counted one,
      // whatever the app run (fix round 2): at once it is not counted.
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);
      expect(await row(_mid(1)), isNull);

      await rig.restart();
      rig.clock.advance(kEngineBackoff);
      expect((await rig.receiver.pullLive(_c1)).kind, isNotNull);
      expect((await receiveRecord()).gf!.n, kGroupFailuresMax);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
    });

    test('three group failures within the same minute across three app '
        'resumes count once', () async {
      await setUpJoined();
      // The walks' own records are written first, so that the dump shows
      // only what a failure writes.
      await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      final state = await groupState();
      engine().failState[RigEngine.key(state)] = internal;
      final t1 = rig.clock.now();

      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect((await receiveRecord()).gf!.n, 1);

      // Each resume clears the conversation's hold, so the engine is tried
      // again at once; the strike is not counted and nothing is written.
      for (var i = 0; i < 2; i++) {
        resume();
        rig.clock.advance(seconds(20));
        final before = await rig.dump();
        final out = await rig.receiver.pullLive(_c1);
        expect(out.kind, ReceiveOutcomeKind.stopped);
        expect(out.until, rig.clock.now().add(kEngineBackoff));
        expect(await rig.dump(), before);
      }
      expect(processedCount(m1.ciphertext), 3);
      final gf = (await receiveRecord()).gf!;
      expect((gf.n, gf.at), (1, t1.microsecondsSinceEpoch));
      expect(await row(_mid(1)), isNull);
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);

      // A minute after the counted strike the next one counts.
      resume();
      rig.clock.advance(seconds(20));
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);
      expect(
        (await receiveRecord()).gf!.at,
        t1.add(kEngineBackoff).microsecondsSinceEpoch,
      );
      expect(await row(_mid(1)), isNull);
    });

    test('a group whose describe fails is still broken at the third '
        'strike', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      final state = await groupState();
      // `describe` itself fails for this group state while the device
      // probe answers: the design's group-level rule (§7.2), unchanged.
      engine().failState[RigEngine.key(state)] = internal;

      await rig.receiver.pullLive(_c1);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);

      rig.clock.advance(kEngineBackoff * 2);
      final probes = count('describe');
      final third = await rig.receiver.pullLive(_c1);

      expect(third.kind, ReceiveOutcomeKind.complete);
      expect((await receiveRecord()).gf!.n, kGroupFailuresMax);
      expect(rig.contexts.of(_c1).groupBroken, hasLength(1));
      // The group is rowed for the run: the next failing message is a row
      // at once, with no probe.
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(count('describe'), probes + 1);
      expect(processedCount(m1.ciphertext), 3);
      expect(processedCount(m2.ciphertext), 1);
    });

    test('a process success in the group clears its failure count', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final state = await groupState();
      engine().failState[RigEngine.key(state)] = internal;
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 1);
      engine().failState.clear();

      rig.clock.advance(kEngineBackoff);
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );

      expect((await receiveRecord()).gf, isNull);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(processedCount(m1.ciphertext), 2);
    });

    test('a failing message on the fast path is deferred and the since token '
        'is saved past it', () async {
      await setUpJoined();
      final token = await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      await say(bobGroup(), 2, at: seconds(2));
      failNext(m1, [internal]);
      final calls = epochCalls();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect(epochCalls(), calls);
      expect(await deferredIds(), [_mid(1)]);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await sync()).sinceToken, isNot(token));
    });

    test('a report commitment longer than the record holds is deferred as '
        'empty, so the record stays readable', () async {
      await setUpJoined();
      final m1 = await say(
        bobGroup(),
        1,
        commitment: Uint8List(kMaxDeferredCommitmentBytes + 1),
      );
      failNext(m1, [internal]);

      await rig.receiver.pullLive(_c1);

      expect((await deferred()).items.single.rc, isEmpty);
      expect(rig.unexpected, isEmpty);
    });
  });

  /// An item as another run left it: not attempted in this run; its last
  /// attempt [ago] before now.
  DeferredItem heldItem(
    int n, {
    List<int> ct = const [9, 9, 9],
    MlsPair pair = const MlsPair(1, 1),
    int k = 1,
    int cc = 0,
    int cu = 0,
    Duration ago = Duration.zero,
    int? at,
    int? da,
  }) {
    final now = rig.clock.now().microsecondsSinceEpoch;
    return DeferredItem(
      id: _mid(n),
      pair: pair,
      at: at ?? now,
      da: da ?? now,
      ct: Uint8List.fromList(ct),
      rc: Uint8List.fromList(List.filled(32, 1)),
      fs: false,
      k: k,
      cc: cc,
      cu: cu,
      la: now - ago.inMicroseconds,
      ru: 'bbbbbbbbbbbbbbbb',
    );
  }

  /// A later run, past the retry spacing.
  void nextRun() {
    resume();
    rig.clock.advance(kDeferredRetrySpacing);
  }

  group('deferred retries (§7.4-§7.6)', () {
    test('a deferred message is decrypted on a later run from the sealed '
        'record', () async {
      await setUpJoined();
      final bytes = _content('kept for later');
      final m1 = await say(bobGroup(), 1, bytes: bytes);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1)]);
      await reconciled();
      final before = await groupState();
      rig.changed.clear();

      await rig.restart();
      rig.clock.advance(kDeferredRetrySpacing);
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, bytes);
      expect(r.check, StoredMessageCheck.ok);
      expect(r.mine, isFalse);
      expect(rigEq(r.senderDeviceId!, bob.id), isTrue);
      expect(r.createdAtMicros, t0.microsecondsSinceEpoch);
      expect((r.generation, r.epoch), (1, 1));
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 2);
      expect(await groupState(), isNot(before));
      expect(rig.changed, contains(_c1));
    });

    test('a deferred item is attempted at most once per run and not before '
        'the retry spacing', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failAlways(m1, internal);
      await rig.receiver.pullLive(_c1);
      await reconciled();
      // The run that deferred it never retries it.
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 1);
      // A new run, but the spacing is counted from the last attempt.
      await putDeferred(DeferredRecord([heldItem(1, ct: m1.ciphertext)]));
      resume();
      rig.clock.advance(kDeferredRetrySpacing - seconds(1));
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 1);
      rig.clock.advance(seconds(1));
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 2);
      // Not again in the same run.
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 2);
      final item = (await deferred()).items.single;
      expect(item.k, 2);
      expect(item.ru, isNot('bbbbbbbbbbbbbbbb'));
    });

    test('a deferred item becomes a row after three witnessed '
        'strikes', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failAlways(m1, internal);
      await rig.receiver.pullLive(_c1);
      expect((await deferred()).items.single.k, 1);
      await reconciled();

      nextRun();
      await rig.receiver.pullLive(_c1);
      expect((await deferred()).items.single.k, 2);
      expect(await row(_mid(1)), isNull);

      nextRun();
      rig.changed.clear();
      await rig.receiver.pullLive(_c1);

      expect(await deferredIds(), isEmpty);
      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.undecryptable);
      expect(r.mine, isFalse);
      expect(r.createdAtMicros, t0.microsecondsSinceEpoch);
      expect(processedCount(m1.ciphertext), kDeferredStrikes);
      expect(rig.changed, contains(_c1));
    });

    test('a deferred retry that answers bad_input becomes an undecryptable '
        'row', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [
        internal,
        const MlsException(MlsErrorCode.badInput, 'too late'),
      ]);
      await rig.receiver.pullLive(_c1);
      await reconciled();
      final state = await groupState();

      nextRun();
      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
      expect(await groupState(), state);
    });

    test('a deadline whose describe probe succeeds is a witnessed crash and '
        'the second crash makes a row', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      failAlways(m1, deadline);

      final out = await rig.receiver.pullLive(_c1);

      // Witnessed: the walk went on.
      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      final item = (await deferred()).items.single;
      expect((item.k, item.cc, item.cu), (1, 1, 0));
      expect(count('describe'), 1);
      await reconciled();

      nextRun();
      await rig.receiver.pullLive(_c1);

      expect(processedCount(m1.ciphertext), kDeferredCrashStrikes);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
    });

    test('a deadline whose describe probe fails is deferred unwitnessed, is '
        'promoted after a later success in the run, and is never rowed while '
        'nothing succeeds', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      await say(bobGroup(), 3, at: seconds(2));
      // A hung engine: nothing answers.
      engine().failAlways['process'] = deadline;
      engine().failAlways['describe'] = deadline;
      engine().failAlways['randomBytes'] = deadline;

      for (var i = 0; i < 3; i++) {
        final out = await rig.receiver.pullLive(_c1);
        expect(out.kind, ReceiveOutcomeKind.stopped);
        // The receiver-wide hold doubles while nothing succeeds.
        expect(out.until, rig.clock.now().add(kEngineBackoff * (1 << i)));
        rig.clock.value = out.until!;
      }

      // One new unwitnessed deferral per pass; no row, ever.
      expect(await deferredIds(), [_mid(1), _mid(2), _mid(3)]);
      for (final i in (await deferred()).items) {
        expect((i.k, i.cc, i.cu), (0, 0, 1));
      }
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
      expect(processedCount(m2.ciphertext), 1);

      // The engine works again: a later success in the same run promotes
      // them (in one transaction at the end of the pass).
      engine().failAlways.clear();
      await say(bobGroup(), 4, at: seconds(3));
      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(4)))!.state, StoredMessageState.visible);
      for (final i in (await deferred()).items) {
        expect((i.k, i.cc, i.cu), (1, 1, 0));
      }
      // Still no row: a promoted item waits for its one retry.
      expect(await row(_mid(1)), isNull);
    });

    test('a deadline whose describe probe fails while the device probe '
        'answers is promoted at the end of the same pass', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [deadline]);
      engine().failNext['describe'] = internal;

      final out = await rig.receiver.pullLive(_c1);

      // The pass stops at the crash (unwitnessed when it was written), but
      // the device probe that answered after it is a later engine success:
      // the item is witnessed by the end of the pass, so its strikes run.
      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(count('randomBytes'), 1);
      final item = (await deferred()).items.single;
      expect((item.k, item.cc, item.cu), (1, 1, 0));
      expect(await row(_mid(2)), isNull);
    });

    test('a seventeenth unwitnessed failure is neither deferred nor evicts '
        'and stops the pass', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, k: 0, cu: 1),
        ]),
      );
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [deadline]);
      engine().failNext['describe'] = internal;
      engine().failNext['randomBytes'] = internal;
      final held = await deferredIds();

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(await deferredIds(), held);
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);
      expect(rig.receiver.evictedCount, 0);
      // The cursor is at the message: it is tried again.
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
    });

    test('with no successful decrypt in the group this run, a seventeenth '
        'failure evicts nothing', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++) heldItem(n),
        ]),
      );
      final held = (await deferred()).encode();
      // Every `process` of the group fails while `describe` answers.
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failAlways(m1, internal);
      failAlways(m2, internal);

      // A group-level result: nothing evicted, the message not deferred,
      // the group failure count up, and the pass stops for the conversation.
      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(first.until, rig.clock.now().add(kEngineBackoff));
      expect((await deferred()).encode(), held);
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);
      expect(rig.receiver.evictedCount, 0);
      expect((await receiveRecord()).gf!.pair, const MlsPair(1, 1));
      expect((await receiveRecord()).gf!.n, 1);
      expect(processedCount(m2.ciphertext), 0);
      expect(rig.receiver.engineHeldUntil, isNull);

      rig.clock.advance(kEngineBackoff);
      final second = await rig.receiver.pullLive(_c1);
      expect(second.until, rig.clock.now().add(kEngineBackoff * 2));
      expect((await receiveRecord()).gf!.n, 2);
      expect((await deferred()).encode(), held);
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);

      // The third spaced failure makes that ONE message a row and clears
      // the count in the same transaction. The group is NOT rowed for the
      // run (`describe` answers: it is not the group that is broken): the
      // next message is not a row in this pass, it is the first strike of a
      // new count, with its own probe, and the pass stops again. The
      // sixteen held messages are still held, none of them evicted.
      rig.clock.advance(kEngineBackoff * 2);
      final probes = count('describe');
      final third = await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await row(_mid(2)), isNull);
      expect(third.kind, ReceiveOutcomeKind.stopped);
      expect(third.until, rig.clock.now().add(kEngineBackoff));
      expect(processedCount(m2.ciphertext), 1);
      expect(count('describe'), probes + 2);
      expect((await receiveRecord()).gf!.n, 1);
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);
      expect((await deferred()).encode(), held);
      expect(rig.receiver.evictedCount, 0);
      for (var n = 101; n <= 100 + kDeferredMax; n++) {
        expect(await row(_mid(n)), isNull);
      }
      expect(await rig.device.vault.messages(_c1, limit: 20), hasLength(1));
    });

    test('with a full deferred record and no witness, the third spaced '
        'failure rows only that message and the group is not '
        'broken', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++) heldItem(n),
        ]),
      );
      final held = (await deferred()).encode();
      // The first message always fails, the second fails once, the third
      // decrypts; `describe` answers throughout.
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      await say(bobGroup(), 3, at: seconds(2));
      failAlways(m1, internal);
      failNext(m2, [internal]);

      // Two spaced strikes: counted durably with their time, nothing rowed.
      final t1 = rig.clock.now();
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 1);
      expect((await receiveRecord()).gf!.at, t1.microsecondsSinceEpoch);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);

      // The third: that message alone is a row, and the count is cleared
      // with it; the next failure of the group starts a new count.
      rig.clock.advance(kEngineBackoff * 2);
      final t3 = rig.clock.now();
      final third = await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(third.kind, ReceiveOutcomeKind.stopped);
      expect(await row(_mid(2)), isNull);
      expect(await row(_mid(3)), isNull);
      final gf = (await receiveRecord()).gf!;
      expect(
        (gf.pair, gf.n, gf.at),
        (const MlsPair(1, 1), 1, t3.microsecondsSinceEpoch),
      );
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);
      expect((await deferred()).encode(), held);
      expect(rig.receiver.evictedCount, 0);

      // The group was never rowed for the run: its next messages reach the
      // engine and decrypt, and that success clears the count.
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect((await receiveRecord()).gf, isNull);
      expect((await deferred()).encode(), held);
      expect(processedCount(m1.ciphertext), 3);
      expect(processedCount(m2.ciphertext), 2);
    });

    test('two full-record strikes then one describe failure do not break the '
        'group', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++) heldItem(n),
        ]),
      );
      final held = (await deferred()).encode();
      // The record is full with no witness: every `process` of the first
      // message fails while `describe` answers.
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failAlways(m1, internal);
      await rig.receiver.pullLive(_c1);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).gf!.n, 2);

      // Now `describe` itself fails for the group (the device probe
      // answers): a strike of the OTHER kind. It is the first of a new
      // count, not the third of the old one: nothing is a row and the group
      // is not rowed for the run.
      final state = await groupState();
      engine().failState[RigEngine.key(state)] = internal;
      rig.clock.advance(kEngineBackoff * 2);
      final t3 = rig.clock.now();
      final third = await rig.receiver.pullLive(_c1);
      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);
      expect(processedCount(m2.ciphertext), 0);
      expect(third.kind, ReceiveOutcomeKind.stopped);
      expect(third.until, t3.add(kEngineBackoff));
      var gf = (await receiveRecord()).gf!;
      expect(
        (gf.n, gf.kind, gf.at),
        (1, GroupFailureKind.describeFailed, t3.microsecondsSinceEpoch),
      );
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);
      expect((await deferred()).encode(), held);

      // Less than a minute after it a strike is not counted, whatever its
      // kind (here the full-record kind again): the count, its kind and its
      // time stay, and nothing is a row.
      engine().failState.clear();
      resume();
      rig.clock.advance(seconds(20));
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 4);
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);
      gf = (await receiveRecord()).gf!;
      expect(
        (gf.n, gf.kind, gf.at),
        (1, GroupFailureKind.describeFailed, t3.microsecondsSinceEpoch),
      );

      // Two more spaced describe failures: the third IN A ROW breaks the
      // group, and the next message is a row with no probe.
      engine().failState[RigEngine.key(state)] = internal;
      resume();
      rig.clock.advance(seconds(40));
      await rig.receiver.pullLive(_c1);
      gf = (await receiveRecord()).gf!;
      expect((gf.n, gf.kind), (2, GroupFailureKind.describeFailed));
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);

      resume();
      rig.clock.advance(kEngineBackoff);
      final probes = count('describe');
      await rig.receiver.pullLive(_c1);
      gf = (await receiveRecord()).gf!;
      expect(
        (gf.n, gf.kind),
        (kGroupFailuresMax, GroupFailureKind.describeFailed),
      );
      expect(rig.contexts.of(_c1).groupBroken, hasLength(1));
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(count('describe'), probes + 1);
      expect(processedCount(m2.ciphertext), 1);
      expect((await deferred()).encode(), held);
    });

    test('two describe failures then a full-record strike restart the count '
        'and row nothing', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++) heldItem(n),
        ]),
      );
      final held = (await deferred()).encode();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      // `describe` fails for the group while the device probe answers.
      engine().failState[RigEngine.key(await groupState())] = internal;
      await rig.receiver.pullLive(_c1);
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      var gf = (await receiveRecord()).gf!;
      expect((gf.n, gf.kind), (2, GroupFailureKind.describeFailed));

      // Now `describe` answers and only the message fails, with the record
      // full and no witness: a strike of the OTHER kind. It is the first of
      // a new count: this message is not a row (it would have been at the
      // third strike of one shared count) and the pass stops.
      engine().failState.clear();
      failAlways(m1, internal);
      rig.clock.advance(kEngineBackoff * 2);
      final t3 = rig.clock.now();
      final third = await rig.receiver.pullLive(_c1);
      expect(await row(_mid(1)), isNull);
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);
      expect(processedCount(m2.ciphertext), 0);
      expect(third.kind, ReceiveOutcomeKind.stopped);
      expect(third.until, t3.add(kEngineBackoff));
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);
      gf = (await receiveRecord()).gf!;
      expect(
        (gf.n, gf.kind, gf.at),
        (1, GroupFailureKind.fullRecord, t3.microsecondsSinceEpoch),
      );
      expect((await deferred()).encode(), held);
      expect(rig.receiver.evictedCount, 0);
    });

    test('with a successful decrypt in the group this run, a seventeenth '
        'witnessed failure evicts as before', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, k: n == 107 ? 2 : 1),
        ]),
      );
      // The group works: its first message decrypts, the second fails.
      await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      await say(bobGroup(), 3, at: seconds(2));
      failAlways(m2, internal);

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect((await row(_mid(107)))!.state, StoredMessageState.undecryptable);
      final ids = await deferredIds();
      expect(ids, hasLength(kDeferredMax));
      expect(ids, contains(_mid(2)));
      expect(ids, isNot(contains(_mid(107))));
      expect(rig.receiver.evictedCount, 1);
      expect((await receiveRecord()).gf, isNull);
    });

    test('a seventeenth witnessed failure evicts the witnessed item with the '
        'most strikes to a row and the walk goes on', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, k: n == 107 ? 2 : (n == 103 ? 1 : 0), cu: 1),
        ]),
      );
      // A decrypt in the group this run: the witness an eviction needs.
      await say(bobGroup(), 9, at: seconds(-1));
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      final m3 = await say(bobGroup(), 3, at: seconds(2));
      for (final m in [m1, m2, m3]) {
        failAlways(m, internal);
      }
      await say(bobGroup(), 4, at: seconds(3));

      final out = await rig.receiver.pullLive(_c1);

      // Never stops the walk while the engine works.
      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await row(_mid(4)))!.state, StoredMessageState.visible);
      final ids = await deferredIds();
      expect(ids, hasLength(kDeferredMax));
      // Most strikes first (107, then 103); the third eviction takes the
      // oldest of the two fresh one-strike items.
      for (final n in [107, 103, 1]) {
        expect(ids, isNot(contains(_mid(n))));
        final r = (await row(_mid(n)))!;
        expect(r.state, StoredMessageState.undecryptable);
        expect(r.mine, isFalse);
      }
      expect(ids, containsAll([_mid(2), _mid(3)]));
      expect(await row(_mid(2)), isNull);
      expect(rig.receiver.evictedCount, 3);
    });

    test('a seventeenth witnessed failure with no witnessed item held '
        'becomes a row itself and evicts nothing', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, k: 0, cu: 1),
        ]),
      );
      final held = await deferredIds();
      // A decrypt in the group this run: without it the failure would be a
      // group-level result, not a row.
      await say(bobGroup(), 9, at: seconds(-1));
      final m1 = await say(bobGroup(), 1);
      failAlways(m1, internal);

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), held);
      expect(rig.receiver.evictedCount, 0);
    });

    test('a crash-class item is retried at most once per run, never in the '
        "run it crashed, and after the pass's fresh work", () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [deadline]);
      failNext(m2, [deadline]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      await reconciled();

      // Never in the run it crashed.
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 1);

      // A new run: fresh work first, then ONE crash-class retry.
      nextRun();
      final m3 = await say(bobGroup(), 3, at: seconds(2));
      await rig.receiver.pullLive(_c1);
      final order = [
        for (final w in engine().processed)
          if (rigEq(w, m3.ciphertext))
            3
          else if (rigEq(w, m1.ciphertext))
            1
          else if (rigEq(w, m2.ciphertext))
            2,
      ];
      expect(order, [1, 2, 3, 1]);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), [_mid(2)]);

      // Not a second one in the same run.
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m2.ciphertext), 1);

      nextRun();
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });

    test('no crash-class retry runs after a deadline answer in the same '
        'run', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [deadline]);
      await rig.receiver.pullLive(_c1);
      expect((await deferred()).items.single.cc, 1);
      await reconciled();

      nextRun();
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failNext(m2, [deadline]);
      await rig.receiver.pullLive(_c1);

      // The fresh message crashed in this run: the held one is not tried.
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      // An item that never crashed is still retried in such a run.
      await putDeferred(
        (await deferred()).put(
          heldItem(9, ct: [1, 2, 3], ago: kDeferredRetrySpacing),
        ),
      );
      await rig.receiver.pullLive(_c1);
      expect(processedCount([1, 2, 3]), 1);
    });

    test('an unavailable answer stops every retry of the pass and counts no '
        'attempt', () async {
      await setUpJoined();
      // A stored since token and no armed reconcile: the retries may reach
      // the engine.
      await prime();
      await reconciled();
      await putDeferred(
        DeferredRecord([
          heldItem(1, ct: [1, 1, 1], ago: kDeferredRetrySpacing),
          heldItem(2, ct: [2, 2, 2], ago: kDeferredRetrySpacing),
        ]),
      );
      final before = (await deferred()).encode();
      engine().failAlways['process'] = unavailable;

      await rig.receiver.pullLive(_c1);

      expect(engine().processed, hasLength(1));
      expect((await deferred()).encode(), before);
      expect(rig.receiver.engineHeldUntil, rig.clock.now().add(kEngineBackoff));
    });

    test('a retry whose probes both fail writes nothing, and one that hangs '
        'with a failing describe probe only counts an unwitnessed '
        'crash', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failAlways(m1, internal);
      await rig.receiver.pullLive(_c1);
      await reconciled();
      final held = (await deferred()).encode();

      // The breaker: no strike, nothing durable, the pass's retries stop.
      nextRun();
      engine().failAlways['describe'] = internal;
      engine().failAlways['randomBytes'] = internal;
      await rig.receiver.pullLive(_c1);
      expect((await deferred()).encode(), held);
      expect(rig.receiver.breakerOpened, 1);
      expect(rig.receiver.engineHeldUntil, rig.clock.now().add(kEngineBackoff));
      expect(await row(_mid(1)), isNull);

      // A hang with a failing describe probe: an unwitnessed crash, counted
      // durably, never a strike and never a row.
      rig.clock.advance(kEngineBackoff);
      failAlways(m1, deadline);
      await rig.receiver.pullLive(_c1);
      final item = (await deferred()).items.single;
      expect((item.k, item.cc, item.cu), (1, 0, 1));
      expect(await row(_mid(1)), isNull);
      expect(processedCount(m1.ciphertext), 3);
    });

    test('a group-level failure at a retry counts against the group, not the '
        'message', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      await reconciled();
      final held = (await deferred()).encode();
      engine().failState[RigEngine.key(await groupState())] = internal;

      nextRun();
      await rig.receiver.pullLive(_c1);

      expect((await receiveRecord()).gf!.n, 1);
      expect((await deferred()).encode(), held);
      expect(await row(_mid(1)), isNull);
    });

    test('a third spaced describe failure at a retry breaks the group and '
        'the next item is rowed without a probe', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      failNext(m2, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      await reconciled();
      // From now `describe` fails for the group while the device probe
      // answers.
      engine().failState[RigEngine.key(await groupState())] = internal;

      // Two spaced strikes at the retry of the oldest item: counted, the
      // pass's retries stop, nothing is a row.
      nextRun();
      await rig.receiver.pullLive(_c1);
      var gf = (await receiveRecord()).gf!;
      expect((gf.n, gf.kind), (1, GroupFailureKind.describeFailed));
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);
      gf = (await receiveRecord()).gf!;
      expect((gf.n, gf.kind), (2, GroupFailureKind.describeFailed));
      expect(processedCount(m1.ciphertext), 3);
      expect(processedCount(m2.ciphertext), 1);
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);

      // The third: its item is a row and the group is rowed for the run,
      // so the next item's failure is a row at once, with no probe.
      rig.clock.advance(kEngineBackoff * 2);
      final probes = count('describe');
      await rig.receiver.pullLive(_c1);

      expect(rig.contexts.of(_c1).groupBroken, hasLength(1));
      gf = (await receiveRecord()).gf!;
      expect(
        (gf.n, gf.kind),
        (kGroupFailuresMax, GroupFailureKind.describeFailed),
      );
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(count('describe'), probes + 1);
      expect(processedCount(m1.ciphertext), 4);
      expect(processedCount(m2.ciphertext), 2);
      expect(await deferredIds(), isEmpty);
    });

    test('on the web a second crashing message in a run is held as an '
        'unwitnessed crash and reaches the engine twice', () async {
      await setUpJoined();
      // The since token is stored and no reconcile is armed before the
      // messages arrive (a retry reaches the engine only then), so the
      // first pass below takes the fast path.
      await prime();
      await reconciled();
      engine().webLike = true;
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      await say(bobGroup(), 3, at: seconds(2));
      failAlways(m1, deadline);
      failAlways(m2, deadline);

      // The first crash is witnessed on the replacement worker. The second
      // makes the engine unavailable, and its describe probe says so: an
      // unwitnessed crash, counted durably.
      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(
        [for (final i in (await deferred()).items) (i.id, i.k, i.cc, i.cu)],
        [(_mid(1), 1, 1, 0), (_mid(2), 0, 0, 1)],
      );
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);

      // The next resume: the walk passes both, the third message decrypts
      // (an engine success after the crash: the second is promoted), and
      // the run's one crash-class retry rows the first at its second crash.
      resume();
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      final held = (await deferred()).items.single;
      expect((held.id, held.k, held.cc, held.cu), (_mid(2), 1, 1, 0));
      // `cu` alone never made it a row, and it was not tried again.
      expect(await row(_mid(2)), isNull);
      expect(processedCount(m2.ciphertext), 1);

      // The resume after: its one retry is its second crash, and a row.
      resume();
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
      // Each crashing message replaced the worker at most twice, ever.
      expect(processedCount(m1.ciphertext), kDeferredCrashStrikes);
      expect(processedCount(m2.ciphertext), kDeferredCrashStrikes);
    });

    test('a deferred item past 30 days from the earlier of its server time '
        'and its local time becomes a row', () async {
      await setUpJoined();
      final now = rig.clock.now().microsecondsSinceEpoch;
      final d = kCiphertextRetention.inMicroseconds;
      await putDeferred(
        DeferredRecord([
          // The server's time is the earlier one.
          heldItem(1, ct: [1, 1, 1], at: now - d, da: now),
          // The local deferred-at time is the earlier one.
          heldItem(2, ct: [2, 2, 2], at: now, da: now - d),
          // One second short on both.
          heldItem(3, ct: [3, 3, 3], at: now - d + 1000000, da: now),
        ]),
      );

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(1)))!.createdAtMicros, now - d);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(await row(_mid(3)), isNull);
      expect(await deferredIds(), [_mid(3)]);
      expect(engine().processed, isEmpty);
    });

    test('the deferred items of a generation whose group is gone become rows '
        'with no engine call', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          heldItem(1),
          // Its group moved past its epoch: its keys are gone too.
          heldItem(2, pair: const MlsPair(1, 0)),
        ]),
      );
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), [_mid(1)]);

      // A reset: the generation's group is gone.
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.undecryptable);
      expect((r.generation, r.epoch), (1, 1));
      expect(await deferredIds(), isEmpty);
      expect(processedCount([9, 9, 9]), 0);
    });

    // Renamed in fix round 1 to what it proves: whether the stored-row check
    // runs before the tombstone check cannot be observed (an item whose id
    // is stored never gets a row from either), only that neither replaces
    // a stored row and that both come before the engine.
    test('a retry never replaces a stored row with a tombstone seen this '
        'run, ends a tombstoned item as its tombstone row, and only then '
        'calls the engine', () async {
      await setUpJoined();
      final m3 = await say(bobGroup(), 3);
      failNext(m3, [internal]);
      await rig.receiver.pullLive(_c1);
      await reconciled();
      final v = rig.device.vault;
      // Item 1 has a stored row AND a tombstone seen this run; item 2 has a
      // tombstone only; item 3 has neither.
      await v.transaction(
        (tx) => tx.putMessage(
          StoredMessage(
            conversationId: _c1,
            messageId: _mid(1),
            createdAtMicros: t0.microsecondsSinceEpoch,
            mine: false,
            state: StoredMessageState.undecryptable,
            generation: 1,
            epoch: 1,
            content: null,
          ),
        ),
      );
      await putDeferred(
        (await deferred())
            .put(heldItem(1, ct: [1, 1, 1], ago: kDeferredRetrySpacing))
            .put(heldItem(2, ct: [2, 2, 2], ago: kDeferredRetrySpacing)),
      );
      nextRun();
      rig.contexts.of(_c1).tombstoned
        ..[_mid(1)] = StoredMessageState.removed
        ..[_mid(2)] = StoredMessageState.deletedAccount;
      engine().processed.clear();

      await rig.receiver.pullLive(_c1);

      // 1: the stored row wins (it is not replaced by the tombstone row).
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      // 2: the tombstone, before any engine call.
      final r2 = (await row(_mid(2)))!;
      expect(r2.state, StoredMessageState.deletedAccount);
      expect(r2.content, isNull);
      // 3: the engine.
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
      expect(engine().processed, hasLength(1));
      expect(rigEq(engine().processed.single, m3.ciphertext), isTrue);
      expect(await deferredIds(), isEmpty);
    });

    test('a deferred echo of an own outbox row completes it with no engine '
        'call, and one whose digest is in the sent log is dropped', () async {
      await setUpJoined();
      final own = await sayOwn(1, text: 'sent by me');
      await putOutbox(
        expectedId: _mid(1),
        ciphertext: Uint8List.fromList(own.ciphertext),
        content: _content('sent by me'),
      );
      await rig.device.vault.transaction(
        (tx) => tx.addSent(
          _c1,
          const MlsPair(1, 1),
          sentDigest(Uint8List.fromList([7, 7, 7])),
        ),
      );
      await putDeferred(
        DeferredRecord([
          heldItem(1, ct: own.ciphertext),
          heldItem(2, ct: [7, 7, 7]),
        ]),
      );
      rig.server.rewriteLive = (r) => r..messages.clear();
      rig.server.rewriteEpoch = (r) => r..messages.clear();

      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(1)))!;
      expect(r.mine, isTrue);
      expect(r.state, StoredMessageState.visible);
      expect(r.content, _content('sent by me'));
      expect((await rig.device.vault.outbox()).items, isEmpty);
      expect(await row(_mid(2)), isNull);
      expect(await deferredIds(), isEmpty);
      expect(engine().processed, isEmpty);
    });
  });

  group('final attempts and the group-delete hold (§7.6 end 1)', () {
    /// A final group of generation 2 at epoch 1 stored beside generation
    /// 1's (the device moved on and kept generation 1's group).
    Future<void> keepBesideGeneration2() async {
      final g1 = (await rig.device.vault.group(_c1, 1))!;
      await rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
    }

    Future<int?> epochOf(int generation) async =>
        (await rig.device.vault.group(_c1, generation))?.epoch;

    test('a deferred message gets one final attempt at its close walk and '
        'the commit applies', () async {
      await setUpJoined();
      final bytes = _content('decrypted at the close');
      final m1 = await say(bobGroup(), 1, bytes: bytes);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1)]);
      await bobSelfUpdate();

      // The same run, no spacing: the final attempt is owed regardless.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, bytes);
      expect(r.check, StoredMessageCheck.ok);
      expect(processedCount(m1.ciphertext), 2);
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
      // The next epoch decrypts: the final attempt's group state was kept
      // under the commit.
      await say(bobGroup(), 3, at: seconds(2));
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(3)))!.state, StoredMessageState.visible);
    });

    test('a final attempt that fails with the engine working is a row and '
        'the commit applies', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failAlways(m1, internal);
      await rig.receiver.pullLive(_c1);
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(processedCount(m1.ciphertext), 2);
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
    });

    test("a crash-class item is rowed at the close walk's final attempt "
        'without an engine call', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [deadline]);
      await rig.receiver.pullLive(_c1);
      expect((await deferred()).items.single.cc, 1);
      await bobSelfUpdate();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
    });

    test('a seventeenth deferral evicts the item with the most strikes to a '
        'row and the close walk still ends', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, ct: [n, n, n], k: n == 105 ? 2 : 1),
        ]),
      );
      // A decrypt in the group this run: the witness an eviction needs.
      await say(bobGroup(), 9, at: seconds(-1));
      final m1 = await say(bobGroup(), 1);
      await say(bobGroup(), 2, at: seconds(1));
      failAlways(m1, internal);

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.complete);
      expect((await row(_mid(105)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
      final ids = await deferredIds();
      expect(ids, hasLength(kDeferredMax));
      expect(ids, contains(_mid(1)));
      expect(ids, isNot(contains(_mid(105))));

      // The close's final attempts handle every item of the pair, whatever
      // the record holds: the walk ends and the commit applies.
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
      for (var n = 101; n <= 100 + kDeferredMax; n++) {
        expect((await row(_mid(n)))!.state, StoredMessageState.undecryptable);
      }
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
    });

    test('the close waits while the describe probe fails at a final attempt, '
        'at most three group failures long, and the commit then '
        'applies', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      await bobSelfUpdate();
      // From now the engine works but this group state does not.
      engine().failState[RigEngine.key(await groupState())] = internal;

      for (var n = 1; n < kGroupFailuresMax; n++) {
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect((await receiveRecord()).gf!.n, n);
        expect((await receiveRecord()).close!.end, isFalse);
        expect(await epochOf(1), 1);
        expect(await deferredIds(), [_mid(1)]);
        expect(await row(_mid(1)), isNull);
        // The conversation's own wait doubles with the count: 1 min, 2.
        rig.clock.advance(kEngineBackoff * n - seconds(1));
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect((await receiveRecord()).gf!.n, n);
        rig.clock.advance(seconds(1));
      }
      // The commit is applied by another engine call on the same state:
      // the group works again for it.
      engine().failState.clear();
      failAlways(m1, internal);
      engine().failNext['describe'] = internal;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
    });

    test('a third spaced describe failure at a final attempt breaks the '
        'group and the next item is rowed without a probe', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      failNext(m2, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      await bobSelfUpdate();
      // From now the engine works but this group state does not.
      engine().failState[RigEngine.key(await groupState())] = internal;
      for (var n = 1; n < kGroupFailuresMax; n++) {
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        final gf = (await receiveRecord()).gf!;
        expect((gf.n, gf.kind), (n, GroupFailureKind.describeFailed));
        rig.clock.advance(kEngineBackoff * n);
      }
      expect(rig.contexts.of(_c1).groupBroken, isEmpty);
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);

      // The third strike: `describe` fails once more for the oldest item's
      // attempt, then would answer. The group is rowed for the run at that
      // strike, so the next item's failure asks no probe. (The commit is
      // applied by another engine call on the same state, which works.)
      engine().failState.clear();
      failAlways(m1, internal);
      failAlways(m2, internal);
      engine().failNext['describe'] = internal;
      final from = engine().calls.length;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(rig.contexts.of(_c1).groupBroken, hasLength(1));
      // The two final attempts, and one probe pair between them only.
      final calls = engine().calls.skip(from).toList();
      final second = calls.indexOf('process', calls.indexOf('process') + 1);
      expect(calls.sublist(0, second + 1), [
        'process',
        'describe',
        'randomBytes',
        'process',
      ]);
      // What follows is the commit's own application (pinned as observed:
      // a probe of the second item would be one more `describe` here).
      expect(calls.sublist(second + 1), ['describe', 'process', 'describe']);
      expect(processedCount(m1.ciphertext), 4);
      expect(processedCount(m2.ciphertext), 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect((await row(_mid(2)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
    });

    test('an unavailable engine at a final attempt writes nothing and the '
        'close ends once it answers', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [internal, unavailable]);
      await rig.receiver.pullLive(_c1);
      await bobSelfUpdate();
      final held = (await deferred()).encode();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);

      expect((await deferred()).encode(), held);
      expect(await row(_mid(1)), isNull);
      expect((await receiveRecord()).close!.end, isFalse);
      expect(await epochOf(1), 1);

      rig.clock.advance(kEngineBackoff);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await epochOf(1), 2);
    });

    test('final attempts stop at the first deadline and the walk ends on a '
        'later pass', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      failNext(m2, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      await bobSelfUpdate();
      // From now both hang; the describe probe answers.
      failAlways(m1, deadline);
      failAlways(m2, deadline);

      // The first hangs: its crash is counted (durably, so it never reaches
      // the engine again), nothing is written for the second, which is not
      // tried in this body, and the walk has not ended.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 2);
      expect(processedCount(m2.ciphertext), 1);
      var items = (await deferred()).items;
      expect(
        [for (final i in items) (i.id, i.k, i.cc, i.cu)],
        [(_mid(1), 2, 1, 0), (_mid(2), 1, 0, 0)],
      );
      expect((await receiveRecord()).close!.end, isFalse);
      expect(await epochOf(1), 1);
      expect(await row(_mid(1)), isNull);
      expect(await row(_mid(2)), isNull);

      // The next one: the first is a row with no engine call (in the end's
      // transaction, so not yet), the second hangs once.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(processedCount(m1.ciphertext), 2);
      expect(processedCount(m2.ciphertext), 2);
      items = (await deferred()).items;
      expect([for (final i in items) i.cc], [1, 1]);
      expect(await epochOf(1), 1);

      // Then the walk ends with no engine call and the commit applies.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(processedCount(m1.ciphertext), 2);
      expect(processedCount(m2.ciphertext), 2);
      for (final n in [1, 2]) {
        expect((await row(_mid(n)))!.state, StoredMessageState.undecryptable);
      }
      expect(await deferredIds(), isEmpty);
      expect(await epochOf(1), 2);
    });

    test('sixteen final attempts on a hanging engine make one engine attempt '
        'in a lock hold', () async {
      await setUpJoined();
      await putDeferred(
        DeferredRecord([
          for (var n = 101; n <= 100 + kDeferredMax; n++)
            heldItem(n, ct: [n, n, n]),
        ]),
      );
      engine().failAlways['process'] = deadline;

      Future<Object?> close() async {
        Object? refused;
        await rig.locks.run(_c1, () async {
          try {
            await rig.receiver.completeEpoch(
              _c1,
              const MlsPair(1, 1),
              priority: BudgetPriority.user,
            );
          } on Object catch (e) {
            refused = e;
          }
        });
        return refused;
      }

      expect(await close(), isA<Exception>());
      // One attempt and its describe probe, not sixteen of each.
      expect(engine().processed, hasLength(1));
      expect(count('describe'), 1);
      expect((await receiveRecord()).close!.end, isFalse);
      expect(await deferredIds(), hasLength(kDeferredMax));
      expect(await rig.device.vault.messages(_c1, limit: 20), isEmpty);

      expect(await close(), isA<Exception>());
      expect(engine().processed, hasLength(2));
    });

    test('an undecryptable close walk rows its deferred items with no engine '
        'call', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);

      await rig.locks.run(
        _c1,
        () => rig.receiver.markEpochUndecryptable(
          _c1,
          const MlsPair(1, 1),
          priority: BudgetPriority.user,
        ),
      );

      expect((await receiveRecord()).close!.end, isTrue);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(processedCount(m1.ciphertext), 1);
      expect(await deferredIds(), isEmpty);
    });

    test("an orphan generation's group is deleted only with its deferred "
        "message's final attempt, in one transaction", () async {
      await setUpJoined();
      final bytes = _content('from the kept generation');
      final m1 = await say(bobGroup(), 1, at: seconds(-1), bytes: bytes);
      failNext(m1, [internal, unavailable]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1)]);
      await keepBesideGeneration2();

      // The orphan walk reaches its end while the engine is down: the final
      // attempt is owed, so the group stays and the slot is not cleared.
      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(await epochOf(1), 1);
      expect(await deferredIds(), [_mid(1)]);
      expect(await row(_mid(1)), isNull);

      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, bytes);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect(await deferredIds(), isEmpty);
      expect((await receiveRecord()).orphan, isNull);
    });

    test('a close walk that ended before the generation moved makes its '
        "deferred message's final attempt before it deletes the "
        'group', () async {
      await setUpJoined();
      await say(bobGroup(), 1, at: const Duration(minutes: -10));
      await rig.locks.run(
        _c1,
        () => rig.receiver.completeEpoch(
          _c1,
          const MlsPair(1, 1),
          priority: BudgetPriority.user,
        ),
      );
      expect((await receiveRecord()).close!.end, isTrue);
      // A message of the pair deferred after the walk ended (the fast path
      // is not there to list it: stored as a transaction would leave it).
      final bytes = _content('late');
      final late = await say(bobGroup(), 2, at: seconds(-5), bytes: bytes);
      rig.server.rewriteEpoch = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(2));
      rig.server.rewriteLive = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(2));
      await putDeferred(
        DeferredRecord([
          DeferredItem(
            id: _mid(2),
            pair: const MlsPair(1, 1),
            at: late.createdAt.toDateTime().microsecondsSinceEpoch,
            da: rig.clock.now().microsecondsSinceEpoch,
            ct: Uint8List.fromList(late.ciphertext),
            rc: Uint8List.fromList(late.reportCommitment),
            fs: false,
            k: 1,
            la: rig.clock.now().microsecondsSinceEpoch,
            ru: 'bbbbbbbbbbbbbbbb',
          ),
        ]),
      );
      await keepBesideGeneration2();
      engine().failNext['process'] = unavailable;

      // The engine is down: the final attempt is owed, the group stays, and
      // the sink does not answer "walked" (catch-up would record the pair
      // and the next join would delete the group without the attempt).
      Object? refused;
      await rig.locks.run(_c1, () async {
        try {
          await rig.receiver.completeEpoch(
            _c1,
            const MlsPair(1, 1),
            priority: BudgetPriority.user,
          );
        } on Object catch (e) {
          refused = e;
        }
      });
      expect(refused, isA<Exception>());
      expect(await epochOf(1), 1);
      expect(await deferredIds(), [_mid(2)]);
      // Nor does a pass delete it while the engine is held.
      await rig.receiver.pullLive(_c1);
      expect(await epochOf(1), 1);
      expect(await deferredIds(), [_mid(2)]);

      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(2)))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, bytes);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect(await deferredIds(), isEmpty);
      expect((await receiveRecord()).close, isNull);
    });
  });

  group('the engine holds (fix round 1: receiver-wide for device-level '
      'trouble)', () {
    const c2 = '22222222222222222222222222222222';

    /// This device joins a second conversation with bob; returns bob's
    /// group of it.
    Future<RigGroup> joinSecond() async {
      await rig.accept(c2);
      rig.header(c2, 'ref-bob');
      final second = await rig.offer(c2, bob);
      expect(await rig.crypto.processWelcomes(), [c2]);
      engine().calls.clear();
      return second.add.group;
    }

    /// Nothing answers: every engine call runs into its deadline.
    void hang() {
      for (final name in const ['process', 'describe', 'randomBytes']) {
        engine().failAlways[name] = deadline;
      }
    }

    int liveCalls() =>
        rig.server.calls.where((c) => c == 'listMlsMessages').length;

    test('a hung engine seen in one conversation holds engine work in every '
        'conversation', () async {
      await setUpJoined();
      final g2 = await joinSecond();
      await say(bobGroup(), 1);
      final n1 = await say(g2, 2, conversation: c2);
      hang();

      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(first.until, rig.clock.now().add(kEngineBackoff));
      final calls = engine().calls.length;
      final listed = liveCalls();

      // The other conversation makes no engine call at all while the hold
      // stands, and says when it ends; its listing is not gated.
      final second = await rig.receiver.pullLive(c2);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect(second.until, first.until);
      expect(engine().calls.length, calls);
      expect(processedCount(n1.ciphertext), 0);
      expect(liveCalls(), listed + 1);
      expect(
        (await DeferredRecords().read(rig.device.vault, c2)).record.items,
        isEmpty,
      );
      expect(await rig.device.vault.message(c2, _mid(2)), isNull);

      // Nothing was lost: once the hold is over and the engine answers, the
      // other conversation's message decrypts.
      engine().failAlways.clear();
      rig.clock.advance(kEngineBackoff);
      await rig.receiver.pullLive(c2);
      expect(
        (await rig.device.vault.message(c2, _mid(2)))!.state,
        StoredMessageState.visible,
      );
    });

    test('the receiver-wide hold doubles on a second device-level failure '
        'and clears on a success', () async {
      await setUpJoined();
      final g2 = await joinSecond();
      await say(bobGroup(), 1);
      await say(g2, 2, conversation: c2);
      hang();

      final first = await rig.receiver.pullLive(_c1);
      expect(first.until, rig.clock.now().add(kEngineBackoff));
      // The second device-level result, seen by ANOTHER conversation.
      rig.clock.advance(kEngineBackoff);
      final second = await rig.receiver.pullLive(c2);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect(second.until, rig.clock.now().add(kEngineBackoff * 2));
      // And the third.
      rig.clock.advance(kEngineBackoff * 2);
      await say(bobGroup(), 3, at: seconds(1));
      final third = await rig.receiver.pullLive(_c1);
      expect(third.until, rig.clock.now().add(kEngineBackoff * 4));

      // Any engine success ends the doubling.
      engine().failAlways.clear();
      rig.clock.advance(kEngineBackoff * 4);
      await say(bobGroup(), 4, at: seconds(2));
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(4)))!.state, StoredMessageState.visible);
      hang();
      await say(g2, 5, at: seconds(3), conversation: c2);
      final after = await rig.receiver.pullLive(c2);
      expect(after.kind, ReceiveOutcomeKind.stopped);
      expect(after.until, rig.clock.now().add(kEngineBackoff));
    });

    test('app resume clears the engine holds', () async {
      await setUpJoined();
      await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      failNext(m1, [unavailable]);
      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(rig.receiver.engineHeldUntil, first.until);

      // The receiver-wide hold: no wait after a resume.
      resume();
      expect(rig.receiver.engineHeldUntil, isNull);
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);

      // A conversation's own hold (a group-level failure) too.
      await say(bobGroup(), 2, at: seconds(2));
      engine().failState[RigEngine.key(await groupState())] = internal;
      final second = await rig.receiver.pullLive(_c1);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect((await receiveRecord()).gf!.n, 1);
      expect(rig.receiver.engineHeldUntil, isNull);
      engine().failState.clear();
      resume();
      expect(
        (await rig.receiver.pullLive(_c1)).kind,
        ReceiveOutcomeKind.complete,
      );
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);
    });

    test('a group-level failure holds only its own conversation', () async {
      await setUpJoined();
      final g2 = await joinSecond();
      await say(bobGroup(), 1);
      await say(g2, 2, conversation: c2);
      engine().failState[RigEngine.key(await groupState())] = internal;

      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect((await receiveRecord()).gf!.n, 1);

      expect(
        (await rig.receiver.pullLive(c2)).kind,
        ReceiveOutcomeKind.complete,
      );
      expect(
        (await rig.device.vault.message(c2, _mid(2)))!.state,
        StoredMessageState.visible,
      );
    });

    test('an unwitnessed crash whose device probe answers still doubles the '
        'receiver-wide hold', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      final m2 = await say(bobGroup(), 2, at: seconds(1));
      // Each hangs, its describe probe fails and the device probe answers.
      failNext(m1, [deadline]);
      engine().failNext['describe'] = internal;

      final first = await rig.receiver.pullLive(_c1);
      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(first.until, rig.clock.now().add(kEngineBackoff));
      expect(count('randomBytes'), 1);

      // The second in a row, with no other engine success between them:
      // the device probe's own answer does not start the wait again.
      rig.clock.advance(kEngineBackoff);
      failNext(m2, [deadline]);
      engine().failNext['describe'] = internal;
      final second = await rig.receiver.pullLive(_c1);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect(count('randomBytes'), 2);
      expect(second.until, rig.clock.now().add(kEngineBackoff * 2));
      expect(rig.receiver.engineHeldUntil, second.until);
    });

    test('the receiver-wide hold reads as none once its time has '
        'passed', () async {
      await setUpJoined();
      await prime();
      final m1 = await say(bobGroup(), 1, at: seconds(1));
      failNext(m1, [unavailable]);
      final first = await rig.receiver.pullLive(_c1);
      expect(rig.receiver.engineHeldUntil, first.until);

      rig.clock.advance(kEngineBackoff - seconds(1));
      expect(rig.receiver.engineHeldUntil, first.until);
      rig.clock.advance(seconds(1));
      expect(rig.receiver.engineHeldUntil, isNull);
    });

    // The hold check INSIDE the retry's write body (fix round 2 replaced a
    // pin that proved nothing about it). The other conversation's retry is
    // allowed by its caller while no hold stands, then waits for the user's
    // one vault write lock behind this conversation's hanging engine call,
    // which sets the receiver-wide hold before that body starts.
    test('a retry that queued for the vault behind another conversation\'s '
        'hanging engine call makes no engine call once the hold is '
        'set', () async {
      await setUpJoined();
      final g2 = await joinSecond();
      // The other conversation holds a deferred message, due in a new run,
      // with nothing but an engine hold to keep it from the engine.
      final n1 = await say(g2, 2, conversation: c2);
      failNext(n1, [internal]);
      await rig.receiver.pullLive(c2);
      await reconciled(c2);
      nextRun();
      await say(bobGroup(), 1);
      final listed = liveCalls();
      final parked = Completer<void>();
      final answer = Completer<void>();
      engine().onProcessCall[engine().processed.length + 1] = () async {
        // This conversation's engine call is in flight inside its write
        // body until the test lets it run into its deadline.
        parked.complete();
        await answer.future;
        throw deadline;
      };
      final running = rig.receiver.pullLive(_c1);
      await parked.future;
      // The other conversation's pass is started HERE, by the test (started
      // from the engine hook it would run in the zone of the first write
      // body, and the vault's mutex would refuse its write as re-entrant
      // instead of queueing it). Its probe is answered with its stored
      // token on a gap page (not processed: no write) and a walk backoff
      // stands, so the first vault write its pass asks for is its retry.
      rig.server.rewriteLive = (r) => r..gapPageToken = 'gap';
      rig.contexts.of(c2).walkBackoffUntil = rig.clock.now().add(
        kWalkBackoffMax,
      );
      final queued = Completer<void>();
      rig.device.onWriteAsked = () {
        if (!queued.isCompleted) queued.complete();
      };
      final other = rig.receiver.pullLive(c2);
      await queued.future;
      rig.device.onWriteAsked = null;
      // The retry's write is queued behind the first body. Only now does
      // the engine call run into its deadline, and nothing answers after
      // it: the receiver-wide hold is set before the retry's body starts.
      hang();
      answer.complete();

      final first = await running;
      final second = await other;
      rig.server.rewriteLive = null;

      expect(first.kind, ReceiveOutcomeKind.stopped);
      expect(rig.receiver.engineHeldUntil, isNotNull);
      expect(second.kind, ReceiveOutcomeKind.stopped);
      // Both probes were answered (the first conversation's, then the
      // other's with its stored token).
      expect(liveCalls(), listed + 2);
      // The hold was set while the retry waited: it made no engine call.
      expect(processedCount(n1.ciphertext), 1);
      final item = (await DeferredRecords().read(
        rig.device.vault,
        c2,
      )).record.items;
      expect([for (final i in item) (i.k, i.cc, i.cu)], [(1, 0, 0)]);
    });

    // Inverted in fix round 2 (it was `a pass stopped by a failed call still
    // retries a due deferred item`): a pass that listed nothing has not
    // seen whether the message was taken down.
    test('a due retry in a pass whose probe failed does not reach the '
        'engine', () async {
      await setUpJoined();
      final m1 = await say(bobGroup(), 1);
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1)]);
      // Nothing else keeps it from the engine: the since token is stored,
      // no reconcile is armed, no hold stands and the item is due.
      await reconciled();
      nextRun();
      rig.server.onCall = (c) async {
        if (c == 'listMlsMessages') throw const NetworkException('rig');
      };

      final out = await rig.receiver.pullLive(_c1);
      rig.server.onCall = null;

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(rig.receiver.engineHeldUntil, isNull);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(_mid(1)), isNull);
      expect(await deferredIds(), [_mid(1)]);

      // The next pass's probe is answered with the stored token: retried.
      rig.clock.advance(kWalkBackoff);
      await rig.receiver.pullLive(_c1);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });
  });

  group('walks that could never finish (step 2 carry-overs 3 to 5)', () {
    /// Out of range, not a date: 2^53 microseconds is about 9.0e9 s.
    final far = ts.Timestamp()..seconds = Int64(10) * Int64(1000000000000);

    /// Passes, each after the walk backoff of the one before, until [done]
    /// or [most] passes.
    Future<int> passUntil(Future<bool> Function() done, {int most = 20}) async {
      for (var n = 1; n <= most; n++) {
        await rig.receiver.pullLive(_c1);
        if (await done()) return n;
        final until = rig.contexts.of(_c1).walkBackoffUntil;
        if (until != null && rig.clock.now().isBefore(until)) {
          rig.clock.value = until;
        }
      }
      return -1;
    }

    test('a message the live path stored at time 0 is skipped by id in its '
        'epoch walk, which ends, and the commit applies', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1, at: seconds(1));
      final m2 = await say(bobGroup(), 2, at: seconds(2));
      // The server gives message 2 a time this client cannot hold, on every
      // listing.
      pb.ListMessagesResponse live(pb.ListMessagesResponse real) {
        final out = real.deepCopy();
        for (final m in out.messages) {
          if (m.id == _mid(2) || m.id == _mid(4)) m.createdAt = far;
        }
        return out;
      }

      pb.ListEpochMessagesResponse epoch(pb.ListEpochMessagesResponse real) {
        final out = real.deepCopy();
        for (final m in out.messages) {
          if (m.id == _mid(2) || m.id == _mid(4)) m.createdAt = far;
        }
        return out;
      }

      rig.server.rewriteLive = live;
      rig.server.rewriteEpoch = epoch;
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(2)))!.createdAtMicros, 0);
      expect((await row(_mid(2)))!.state, StoredMessageState.visible);

      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(rig.contexts.of(_c1).orderViolation, 0);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect(processedCount(m2.ciphertext), 1);
      // The walk's recorded position is one the record's decoder accepts.
      expect(rig.unexpected, isEmpty);

      // A message with such a time that has NO row is still refused (its
      // position could not be recorded): nothing of the page is processed.
      await say(bobGroup(), 3, at: seconds(3));
      await say(bobGroup(), 4, at: seconds(4));
      rig.server.rewriteLive = (r) => live(r)..gapPageToken = 'gap';
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).orderViolation, 1);
      expect(await row(_mid(3)), isNull);
    });

    test('an undecryptable walk refused for hours in one run is abandoned: '
        'counted, reported once, no row invented, and the waiting commit '
        'applies', () async {
      await setUpJoined();
      // This device joins generation 2; generation 1's group is then gone
      // with its close walk of (1, 1) unfinished in mode u.
      final offer2 = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      await sayMany(1, 5, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      // The server never serves (1, 1) in order.
      rig.server.rewriteEpoch = (real) =>
          rig.server.epochRequests.last.pair == const MlsPair(1, 1)
          ? (real.deepCopy()..clearOrder())
          : real;
      // Bob commits on generation 2: the commit waits behind (1, 1).
      final epoch = (await rig.device.vault.group(_c1, 2))!.epoch;
      final at = rig.server.current(_c1);
      final g2 = offer2.add.group;
      final c = await bob.engine.selfUpdate(bob.state, g2.state);
      g2.state = await bob.engine.confirmCommit(bob.state, c.groupState);
      rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      expect(await rig.receiver.abandonedWalks(_c1), 0);

      final passes = await passUntil(
        () async => await rig.receiver.abandonedWalks(_c1) > 0,
      );

      // In one run the refused pages come 1, 2, 4, 8, 16, 32 minutes and
      // then an hour apart. The first pass waits out the sink's backoff; the
      // refusal of the second is counted at once, the next five fall inside
      // its hour, and the four after them (each more than an hour after the
      // last counted one) make five: the tenth pass gives the walk up.
      expect(passes, 10);
      expect(await rig.receiver.abandonedWalks(_c1), 1);
      expect(rig.unexpected, hasLength(1));
      final e = rig.unexpected.single as E2eePipelineError;
      expect(e.step, 'receive.walk.abandoned');
      rig.unexpected.clear();
      // No row for messages that were never listed.
      for (var i = 1; i <= 5; i++) {
        expect(await row(_mid(i)), isNull);
      }
      // The commit that waited behind it applies, by passes alone (the slot
      // is free for its close walk).
      final n = await passUntil(
        () async => (await rig.device.vault.group(_c1, 2))!.epoch == epoch + 1,
        most: 3,
      );
      expect(n, isNot(-1));
      // Neither the record's normalization nor the sink brings it back.
      expect((await receiveRecord()).close?.pair, isNot(const MlsPair(1, 1)));
      expect(await rig.receiver.abandonedWalks(_c1), 1);
      expect(rig.unexpected, isEmpty);
    });

    test('an abandoned undecryptable walk with no final group left ends the '
        'pass complete, and a decrypting walk is never abandoned', () async {
      await setUpJoined();
      await sayMany(1, 3, start: const Duration(minutes: -10));
      rig.server.rewriteEpoch = (real) => real.deepCopy()..clearOrder();

      // The open walk decrypts: however long the server refuses, it waits.
      final never = await passUntil(
        () async => await rig.receiver.abandonedWalks(_c1) > 0,
        most: 16,
      );
      expect(never, -1);
      expect(rig.contexts.of(_c1).walkBackoff, kWalkBackoffMax);
      expect(rig.unexpected, isEmpty);

      // The group goes (a reset) with an unfinished close walk in mode u.
      // The backoff is still at its maximum from the open walk's failures:
      // none of those count against this walk.
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(pair: MlsPair(1, 1), mode: WalkMode.undecryptable),
        ),
      );
      // Nor does a call that fails (the network): eight of them in a row.
      rig.server.onCall = (c) async {
        if (c == 'listEpochMessages') throw const NetworkException('rig');
      };
      for (var i = 0; i < 8; i++) {
        rig.clock.advance(kWalkBackoffMax);
        await rig.receiver.pullLive(_c1);
      }
      expect(await rig.receiver.abandonedWalks(_c1), 0);
      // Nothing was counted against it: not the open walk's refusals, not
      // the failed calls.
      expect((await receiveRecord()).close!.mf, 0);
      rig.server.onCall = null;
      rig.clock.advance(kWalkBackoffMax);

      // Its own five refused pages, an hour apart, give it up.
      final passes = await passUntil(
        () async => await rig.receiver.abandonedWalks(_c1) > 0,
      );

      expect(passes, kWalkGiveUpAfter);
      expect(rig.unexpected, hasLength(1));
      rig.unexpected.clear();
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);
    });

    /// Generation 1's group is gone with its close walk of (1, 1)
    /// unfinished in mode u ([mf] refusals counted so far), and three
    /// messages of the pair on the server.
    Future<void> goneWithClose({
      int pageSize = kEpochPageSize,
      int mf = 0,
    }) async {
      await setUpJoined(pageSize: pageSize);
      await sayMany(1, 3, start: const Duration(minutes: -10));
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      await putReceiveRecord(
        ReceiveRecord(
          close: WalkEntry(
            pair: const MlsPair(1, 1),
            mode: WalkMode.undecryptable,
            mf: mf,
            mfAt: mf == 0 ? 0 : rig.clock.now().microsecondsSinceEpoch,
          ),
        ),
      );
    }

    test('an undecryptable walk refused across five app runs an hour apart '
        'is abandoned', () async {
      await goneWithClose();
      // The server never serves (1, 1) in order.
      rig.server.rewriteEpoch = (real) => real.deepCopy()..clearOrder();

      for (var run = 1; run <= kWalkGiveUpAfter; run++) {
        expect(await rig.receiver.abandonedWalks(_c1), 0);
        // One pass per run: the walk backoff (memory) never passes its
        // first minute.
        await rig.receiver.pullLive(_c1);
        if (run == kWalkGiveUpAfter) break;
        final close = (await receiveRecord()).close!;
        expect(close.mf, run);
        expect(close.end, isFalse);
        expect(rig.unexpected, isEmpty);
        await rig.restart();
        rig.clock.advance(kWalkRefusalSpacing);
      }

      expect(await rig.receiver.abandonedWalks(_c1), 1);
      expect(rig.unexpected, hasLength(1));
      final e = rig.unexpected.single as E2eePipelineError;
      expect(e.step, 'receive.walk.abandoned');
      rig.unexpected.clear();
      final close = (await receiveRecord()).close!;
      expect((close.end, close.mf, close.mfAt), (true, 0, 0));
      // No row for messages that were never listed.
      expect(await rig.device.vault.messages(_c1, limit: 10), isEmpty);
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);
      expect(await rig.receiver.abandonedWalks(_c1), 1);
    });

    test('refusals within the same hour count once', () async {
      await goneWithClose();
      rig.server.rewriteEpoch = (real) => real.deepCopy()..clearOrder();
      final start = rig.clock.now();

      // Four refused pages in the first quarter of an hour (the backoff of
      // 1, 2 and 4 minutes between them), and a restart in the middle.
      for (var n = 0; n < 4; n++) {
        await rig.receiver.pullLive(_c1);
        final close = (await receiveRecord()).close!;
        expect(close.mf, 1);
        expect(close.mfAt, start.microsecondsSinceEpoch);
        if (n == 1) await rig.restart();
        rig.clock.value =
            rig.contexts.of(_c1).walkBackoffUntil ??
            rig.clock.now().add(kWalkBackoff);
      }
      expect(rig.contexts.of(_c1).orderMissing, greaterThan(1));
      expect(rig.clock.now().difference(start), lessThan(kWalkRefusalSpacing));

      // One second short of the hour: still one.
      rig.clock.value = start.add(kWalkRefusalSpacing - seconds(1));
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).close!.mf, 1);
      // A call that fails (the network) is no refusal, whenever it comes.
      rig.clock.value = start.add(kWalkRefusalSpacing * 2);
      rig.server.onCall = (c) async {
        if (c == 'listEpochMessages') throw const NetworkException('rig');
      };
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).close!.mf, 1);
      rig.server.onCall = null;

      rig.clock.advance(kWalkBackoffMax);
      await rig.receiver.pullLive(_c1);
      final close = (await receiveRecord()).close!;
      expect(close.mf, 2);
      expect(close.mfAt, rig.clock.now().microsecondsSinceEpoch);
      expect(await rig.receiver.abandonedWalks(_c1), 0);
    });

    test('an applied page resets the abandonment count', () async {
      await goneWithClose(pageSize: 2, mf: kWalkGiveUpAfter - 1);
      expect((await receiveRecord()).close!.mf, kWalkGiveUpAfter - 1);
      // The first page is served, every later one is refused.
      var served = 0;
      rig.server.rewriteEpoch = (real) =>
          served++ == 0 ? real : (real.deepCopy()..clearOrder());

      await rig.receiver.pullLive(_c1);

      // The applied page reset the count; the refused one after it is the
      // first of a new streak, not the fifth of the old one.
      final close = (await receiveRecord()).close!;
      expect(close.end, isFalse);
      expect(close.t, isNotEmpty);
      expect(close.mf, 1);
      expect(await rig.receiver.abandonedWalks(_c1), 0);
      expect(rig.unexpected, isEmpty);
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
    });

    test('a walk whose generation has a provisional group is never '
        'abandoned', () async {
      await goneWithClose(mf: kWalkGiveUpAfter - 1);
      // An own init of generation 1 that has not settled: its group can
      // still become final.
      Future<void> putProvisional() => rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: Uint8List(1),
            provisional: true,
            provisionalCreatedAtMicros: rig.clock.now().microsecondsSinceEpoch,
          ),
        ),
      );
      await putProvisional();
      rig.server.rewriteEpoch = (real) => real.deepCopy()..clearOrder();

      // Refused pages hours apart: none is counted, the walk is kept.
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kWalkRefusalSpacing + kWalkBackoffMax);
        await rig.receiver.pullLive(_c1);
        final close = (await receiveRecord()).close!;
        expect((close.end, close.mf), (false, kWalkGiveUpAfter - 1));
      }
      expect(rig.contexts.of(_c1).orderMissing, 3);
      expect(await rig.receiver.abandonedWalks(_c1), 0);
      expect(rig.unexpected, isEmpty);

      // With the provisional group gone the next refused page is the fifth.
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));
      rig.clock.advance(kWalkRefusalSpacing + kWalkBackoffMax);
      await rig.receiver.pullLive(_c1);
      expect(await rig.receiver.abandonedWalks(_c1), 1);
      expect(rig.unexpected, hasLength(1));
      rig.unexpected.clear();
    });

    test('a complete pass between two fruitless catch-ups at one pair does '
        'not end the streak', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1);
      noCommitMessage(2, 5, seconds(1));
      rig.server.livePageSize = 1;
      final first = await rig.receiver.pullLive(_c1);
      expect(first.until, rig.clock.now().add(kWalkBackoff));
      // Nothing waits: a complete pass.
      expect(await rig.receiver.pullLive(_c1), ReceiveOutcome.complete);

      rig.clock.advance(kWalkBackoff);
      await say(bobGroup(), 3, at: seconds(2));
      noCommitMessage(4, 6, seconds(3));
      final second = await rig.receiver.pullLive(_c1);

      // The same pair: the second fruitless catch-up waits twice as long.
      expect(second.kind, ReceiveOutcomeKind.stopped);
      expect(second.until, rig.clock.now().add(kWalkBackoff * 2));
    });
  });

  group('a deferred message that is taken down, cleared or unreadable '
      '(§7.3, §7.6, §8.1)', () {
    /// Message [n] is deferred by a first pull (the since token is saved).
    Future<pb.Message> deferOne(int n, {Duration at = Duration.zero}) async {
      final m = await say(bobGroup(), n, at: at);
      failNext(m, [internal]);
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), contains(_mid(n)));
      return m;
    }

    test('a removed state seen for a deferred id writes a removed row and '
        'purges the item in one transaction', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      rig.changed.clear();
      // One transaction: when the row cannot be written the item stays.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_messages.');
      await rig.receiver.pullLive(_c1);
      expect(await deferredIds(), [_mid(1)]);
      rig.device.cipher.failSeal = null;
      expect(await row(_mid(1)), isNull);

      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.removed);
      expect(r.content, isNull);
      expect(r.mine, isFalse);
      expect(r.createdAtMicros, t0.microsecondsSinceEpoch);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
      expect(
        rig.contexts.of(_c1).tombstoned[_mid(1)],
        StoredMessageState.removed,
      );
      expect(rig.changed, contains(_c1));
    });

    test('a deleted-account state seen for a deferred id writes that row, '
        'and at or before cleared_at the item is only purged', () async {
      await setUpJoined();
      await deferOne(1);
      await deferOne(2, at: seconds(10));
      final s = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          s.copyWith(
            clearedAtMicros: t0.add(seconds(5)).microsecondsSinceEpoch,
          ),
        ),
      );
      for (final n in [1, 2]) {
        rig.server.tombstone(
          _c1,
          _mid(n),
          MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
        );
      }

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect((await row(_mid(2)))!.state, StoredMessageState.deletedAccount);
      expect(await deferredIds(), isEmpty);
    });

    test('a tombstone on a probe page that is not processed still ends its '
        'deferred message as a removed row', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      // A gapped page: never processed as a batch.
      rig.server.rewriteLive = (r) => r..gapPageToken = 'gap';
      rig.server.rewriteEpoch = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(1));

      await rig.receiver.pullLive(_c1);

      expect((await row(_mid(1)))!.state, StoredMessageState.removed);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
    });

    test('a tombstone on a probe page that is not processed is noted for the '
        'run even when its write never starts', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await reconciled();
      // A later run, past the retry spacing: the item is due.
      nextRun();
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      // A gapped page: never processed as a batch. The first write asked
      // for after it was listed (the one for its tombstones) fails before
      // its body runs.
      var listed = false;
      var refuse = false;
      var refusals = 0;
      rig.server.rewriteLive = (r) {
        if (!listed) refuse = true;
        listed = true;
        return r..gapPageToken = 'gap';
      };
      rig.server.rewriteEpoch = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(1));
      rig.device.onWriteAsked = () {
        if (!refuse) return;
        refuse = false;
        refusals++;
        throw StateError('refused');
      };

      await rig.receiver.pullLive(_c1);
      rig.device.onWriteAsked = null;

      // The probe was answered with the stored token, so the due retry was
      // allowed: only the note keeps the stored ciphertext from the engine
      // (it would decrypt, and a removed message would be stored as
      // visible).
      expect(refusals, 1);
      expect(
        rig.contexts.of(_c1).tombstoned[_mid(1)],
        StoredMessageState.removed,
      );
      expect(processedCount(m1.ciphertext), 1);
      expect((await row(_mid(1)))!.state, StoredMessageState.removed);
      expect(await deferredIds(), isEmpty);
    });

    test('a tombstone for an id that is neither stored nor deferred writes '
        'nothing and is remembered for the run', () async {
      await setUpJoined();
      await prime();
      await say(bobGroup(), 1, at: seconds(1));
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);

      await rig.receiver.pullLive(_c1);

      expect(await row(_mid(1)), isNull);
      expect(
        rig.contexts.of(_c1).tombstoned[_mid(1)],
        StoredMessageState.removed,
      );
    });

    test('a replayed deferred record never stores a taken-down message as '
        'visible', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      final key = DeferredRecords.keyOf(_c1);
      final held = (await rig.sealedSetting(key))!;
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.removed);

      // Someone with the vault file puts the old record back, and the app
      // starts again (the tombstones seen in the run are forgotten).
      await rig.replaySealedSetting(key, held);
      expect(await deferredIds(), [_mid(1)]);
      await rig.restart();
      rig.clock.advance(kDeferredRetrySpacing);
      await rig.receiver.pullLive(_c1);

      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.removed);
      expect(r.content, isNull);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);

      // The same at the final attempt of its close walk.
      await rig.replaySealedSetting(key, held);
      await bobSelfUpdate();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await row(_mid(1)))!.state, StoredMessageState.removed);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
    });

    test('a deferred message is not retried between a token retirement and '
        'the next listing', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      final token = (await sync()).sinceToken;
      expect(token, isNotEmpty);
      // The message is taken down, and the server retires the since token
      // that would have listed the change.
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      rig.server.retiredSince.add(token);
      // A later run, past the retry spacing: the item is due.
      nextRun();

      // The retirement pass has listed nothing when its retries run: the
      // stored ciphertext must not reach the engine (it would decrypt, and
      // a removed message would be stored as visible).
      final out = await rig.receiver.pullLive(_c1);
      expect(out.kind, ReceiveOutcomeKind.more);
      expect((await sync()).sinceToken, '');
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(_mid(1)), isNull);
      expect(await deferredIds(), [_mid(1)]);

      // The next listings show its state: a removed row, never the engine.
      for (var i = 0; i < 3 && await row(_mid(1)) == null; i++) {
        await rig.receiver.pullLive(_c1);
        expect(processedCount(m1.ciphertext), 1);
      }
      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.removed);
      expect(r.content, isNull);
      expect(await deferredIds(), isEmpty);
    });

    test('a deferred message is not retried while a reconcile is armed, even '
        'after a new since token was saved', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await reconciled();
      final token = (await sync()).sinceToken;
      // The message is taken down and the since token that would have
      // listed the change is retired. No listing after the retirement
      // carries the change: not the page of the probe that arms the
      // reconcile entry, and not the open walk's pages. Only the by-id
      // tombstone listing (step 2b) could show it.
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      rig.server.retiredSince.add(token);
      rig.server.rewriteLive = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(1));
      rig.server.rewriteEpoch = (r) =>
          r..messages.removeWhere((m) => m.id == _mid(1));
      // Step 2b: and the by-id listing is not available (an older server),
      // so the entry stays armed for the whole test.
      rig.server.tombstoneError = () => const UnknownApiException('x');
      // A later run, past the retry spacing: the item is due.
      nextRun();

      // The retirement.
      final retired = await rig.receiver.pullLive(_c1);
      expect(retired.kind, ReceiveOutcomeKind.more);
      expect((await sync()).sinceToken, '');
      expect((await receiveRecord()).rec!.armed, isFalse);

      // The probe with no token arms the entry, and the open walk's end
      // saves a NEW since token: the stored token is no longer empty.
      for (var i = 0; i < 3 && (await sync()).sinceToken.isEmpty; i++) {
        await rig.receiver.pullLive(_c1);
      }
      final saved = (await sync()).sinceToken;
      expect(saved, isNotEmpty);
      expect(saved, isNot(token));
      expect((await receiveRecord()).rec!.armed, isTrue);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(_mid(1)), isNull);

      // A pass whose probe is answered with the new stored token: the
      // armed entry alone still keeps the stored ciphertext from the
      // engine (it would decrypt, and a removed message would be stored as
      // visible).
      final calls = rig.server.calls.length;
      await rig.receiver.pullLive(_c1);
      expect(rig.server.calls.skip(calls), contains('listMlsMessages'));
      expect((await sync()).sinceToken, isNotEmpty);
      expect((await receiveRecord()).rec!.armed, isTrue);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(_mid(1)), isNull);
      expect(await deferredIds(), [_mid(1)]);
    });

    test('a deferred retry runs after a probe answered with the stored '
        'token', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await reconciled();
      nextRun();
      // A walk backoff alone does not skip the retry.
      final until = rig.clock.now().add(kWalkBackoff);
      rig.contexts.of(_c1).walkBackoffUntil = until;
      final calls = rig.server.calls.length;

      final out = await rig.receiver.pullLive(_c1);

      expect(out.kind, ReceiveOutcomeKind.stopped);
      expect(out.until, until);
      expect(rig.server.calls.skip(calls), ['listMlsMessages']);
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await deferredIds(), isEmpty);
    });

    test('a tombstone on a fast-path page whose batch stopped before it '
        'still keeps its deferred message from the engine', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      await reconciled();
      nextRun();
      // The fast path's page: a new message that sorts first, then the
      // takedown of the deferred one.
      await say(bobGroup(), 2, at: seconds(-1));
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      // The new message's row cannot be written: the batch stops at it,
      // before it reaches the tombstone.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_messages.');

      await rig.receiver.pullLive(_c1);
      rig.device.cipher.failSeal = null;

      // The probe was answered with the stored token, so the retry was
      // allowed; the page's tombstone was noted before the batch ran (the
      // open walk's settle listing stops at the same message).
      expect(await row(_mid(2)), isNull);
      expect(processedCount(m1.ciphertext), 1);
      expect(await row(_mid(1)), isNull);
      expect(await deferredIds(), [_mid(1)]);

      await rig.receiver.pullLive(_c1);
      expect((await row(_mid(1)))!.state, StoredMessageState.removed);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 1);
    });

    test('a retry with an empty since token still runs the checks that need '
        'no engine', () async {
      await setUpJoined();
      await deferOne(1);
      final s = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(_c1, s.copyWith(sinceToken: '')),
      );
      // Its generation's group is gone (a reset), and no listing can
      // re-establish the token.
      await rig.device.vault.transaction((tx) => tx.deleteGroup(_c1, 1));

      await rig.receiver.pullLive(_c1);

      expect((await sync()).sinceToken, '');
      expect((await row(_mid(1)))!.state, StoredMessageState.undecryptable);
      expect(await deferredIds(), isEmpty);
    });

    test('the deferred-record hint is set only after its transaction '
        'committed', () async {
      await setUpJoined();
      await deferOne(1);
      rig.server.tombstone(_c1, _mid(1), MessageState.MESSAGE_STATE_REMOVED);
      // The transaction that would write the removed row and drop the item
      // fails.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_messages.');
      Object? refused;
      await rig.locks.run(_c1, () async {
        try {
          await rig.receiver.completeEpoch(
            _c1,
            const MlsPair(1, 1),
            priority: BudgetPriority.user,
          );
        } on Object catch (e) {
          refused = e;
        }
      });
      rig.device.cipher.failSeal = null;

      expect(refused, isA<Exception>());
      expect(await deferredIds(), [_mid(1)]);
      // The item is still held, and the hint does not say otherwise.
      expect(rig.contexts.of(_c1).deferredEmpty, isFalse);
    });

    test('a stale empty hint costs one engine attempt and nothing '
        'else', () async {
      await setUpJoined();
      final m1 = await deferOne(1);
      // The probe page is not processed, so the open walk lists the message
      // again; while that page is in flight the hint goes stale (it says
      // the record is empty: the file changed under the running app).
      rig.server.rewriteLive = (r) => r..gapPageToken = 'gap';
      rig.server.afterEpochAnswer = () async {
        rig.contexts.of(_c1).deferredEmpty = true;
      };

      await rig.receiver.pullLive(_c1);
      rig.server.afterEpochAnswer = null;

      // One attempt on a message the record held; it is stored once, and
      // the end-of-pass retries (which read the record fresh) drop the item
      // for its stored row.
      expect(processedCount(m1.ciphertext), 2);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
      expect(await rig.device.vault.messages(_c1, limit: 10), hasLength(1));
      expect(await deferredIds(), isEmpty);
    });

    test('cleared_at purges deferred items at or before it in the delete '
        'transaction', () async {
      await setUpJoined();
      await say(bobGroup(), 9, at: seconds(-1));
      await deferOne(1);
      await deferOne(2, at: seconds(10));
      expect((await row(_mid(9)))!.state, StoredMessageState.visible);
      rig.clock.advance(seconds(30));
      rig.server.clearedAt[_c1] = t0.add(seconds(5));
      // One transaction: when the record cannot be written, no row is
      // deleted either.
      rig.device.cipher.failSeal = (label) =>
          label.startsWith('vault_settings.');
      await rig.receiver.applyClearedAtOnce(_c1);
      rig.device.cipher.failSeal = null;
      expect(await row(_mid(9)), isNotNull);
      expect(await deferredIds(), [_mid(1), _mid(2)]);
      rig.changed.clear();

      await rig.receiver.applyClearedAtOnce(_c1);

      expect(await row(_mid(9)), isNull);
      expect(await deferredIds(), [_mid(2)]);
      expect(rig.changed, contains(_c1));
    });

    test('purgeDeferredIn removes the items at or before a time in the '
        "caller's transaction", () async {
      await setUpJoined();
      await deferOne(1);
      await deferOne(2, at: seconds(10));
      final v = rig.device.vault;

      await v.transaction(
        (tx) => rig.receiver.purgeDeferredIn(
          v,
          tx,
          _c1,
          t0.add(seconds(5)).microsecondsSinceEpoch,
        ),
      );

      expect(await deferredIds(), [_mid(2)]);
    });

    test('deferredView lists ids and times newest first and hides those at '
        'or before cleared_at', () async {
      await setUpJoined();
      expect(await rig.receiver.deferredView(_c1), isEmpty);
      await deferOne(1);
      await deferOne(2, at: seconds(10));
      await deferOne(3, at: seconds(20));

      final all = await rig.receiver.deferredView(_c1);
      expect(
        [for (final d in all) (d.id, d.atMicros)],
        [
          for (final (n, s) in [(3, 20), (2, 10), (1, 0)])
            (_mid(n), t0.add(seconds(s)).microsecondsSinceEpoch),
        ],
      );

      final s = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          s.copyWith(
            clearedAtMicros: t0.add(seconds(10)).microsecondsSinceEpoch,
          ),
        ),
      );
      expect(
        [for (final d in await rig.receiver.deferredView(_c1)) d.id],
        [_mid(3)],
      );
    });

    test('an unreadable deferred record resets every walk of the '
        'conversation to its start', () async {
      await setUpJoined();
      final bytes = _content('lost with the record');
      final m1 = await say(bobGroup(), 1, bytes: bytes);
      await say(bobGroup(), 2, at: seconds(1));
      failNext(m1, [internal]);
      await rig.receiver.pullLive(_c1);
      expect((await receiveRecord()).open!.end, isTrue);
      final key = DeferredRecords.keyOf(_c1);
      await rig.replaySealedSetting(key, Uint8List.fromList([1, 2, 3]));
      rig.server.epochRequests.clear();

      await rig.receiver.pullLive(_c1);

      // Replaced by an empty record; the walk listed again from the start
      // and the lost message, listed unstored, was processed as first
      // sight.
      expect(orderedTokens(const MlsPair(1, 1)).first, '');
      final r = (await row(_mid(1)))!;
      expect(r.state, StoredMessageState.visible);
      expect(r.content, bytes);
      expect(await deferredIds(), isEmpty);
      expect(processedCount(m1.ciphertext), 2);
      // Reported once, by its step name only.
      expect(rig.unexpected, hasLength(1));
      final e = rig.unexpected.single as E2eePipelineError;
      expect(e.step, 'receive.deferred.read');
      rig.unexpected.clear();

      // Not reset again: the record reads now.
      rig.server.epochRequests.clear();
      await rig.receiver.pullLive(_c1);
      expect(orderedTokens(const MlsPair(1, 1)), isNot(contains('')));
      expect(rig.unexpected, isEmpty);
    });

    test('an unreadable deferred record resets a close walk too and nothing '
        'is written by the body that met it', () async {
      await setUpJoined();
      await deferOne(1);
      final key = DeferredRecords.keyOf(_c1);
      await putReceiveRecord(
        const ReceiveRecord(
          close: WalkEntry(
            pair: MlsPair(1, 1),
            t: 'tok',
            s: 'tok',
            r: false,
            end: true,
          ),
        ),
      );
      await rig.replaySealedSetting(key, Uint8List.fromList([1, 2, 3]));

      await rig.receiver.pullLive(_c1);

      final close = (await receiveRecord()).close!;
      expect(rig.unexpected, hasLength(1));
      rig.unexpected.clear();
      // The reset walk listed again from the start and ended again.
      expect(orderedTokens(const MlsPair(1, 1)).first, '');
      expect(close.end, isTrue);
      expect((await row(_mid(1)))!.state, StoredMessageState.visible);
    });
  });
}

/// A sink that returns without walking (a buggy sink): catch-up must not
/// apply the commit, since the receiver's record says the walk did not end.
class _NoWalkSink implements EpochMessageSink {
  _NoWalkSink(this.receiver);

  final MessageReceiver receiver;

  @override
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {}

  @override
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {}

  @override
  Future<bool> epochWalkDone(String conversationId, MlsPair pair) =>
      receiver.epochWalkDone(conversationId, pair);
}

Duration seconds(int n) => Duration(seconds: n);
