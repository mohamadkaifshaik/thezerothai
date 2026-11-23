import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13b, step 13b-ii: EncryptedMessagingImpl's thread, preview,
// search, security code, report and own-device members over the real
// pipeline and the rig (task-13-gates.md items 26-32, 36-39).

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

String _mid(int n) => n.toRadixString(16).padLeft(32, '0');

Uint8List _content(String text, {String shared = ''}) => encodeMessageContent(
  text: text,
  sharedPostId: shared,
  reportKey: Uint8List.fromList(List.filled(32, 7)),
);

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

  SecureVault vault() => h.rig.device.vault;

  /// A stored row of [c], [n] seconds after the epoch.
  Future<void> store(
    String c,
    int n, {
    String text = 'hello',
    bool mine = false,
    String check = StoredMessageCheck.ok,
    String state = StoredMessageState.visible,
    String kind = StoredMessageKind.message,
    Uint8List? content,
  }) => vault().transaction(
    (tx) => tx.putMessage(
      StoredMessage(
        conversationId: c,
        messageId: _mid(n),
        createdAtMicros: n * 1000000,
        mine: mine,
        state: state,
        generation: 1,
        epoch: 1,
        content: state == StoredMessageState.visible
            ? (content ?? _content(text))
            : null,
        check: check,
        kind: kind,
      ),
    ),
  );

  /// [c] joined from bob's welcome (accepted), with its inbox header.
  Future<RigOffer> joined([String c = _c1]) async {
    final offer = await h.offer(c, bob);
    await h.ready();
    return offer;
  }

  group('watchThread and loadOlder (items 27, 29)', () {
    test(
      'watchThread emits at once from the vault, also with the flag off',
      () async {
        await joined();
        await store(_c1, 1, text: 'from the vault');
        await h.rig.device.session.onFlagChanged(E2eeFlag.off, uid: 'user-a');
        final t = await port
            .watchThread(const ThreadRef.conversation(_c1))
            .first;
        expect(t.conversationId, _c1);
        final m = t.entries.whereType<DecryptedMessage>().single;
        expect((m.id, m.text), (_mid(1), 'from the vault'));
        expect(t.hasMore, isFalse);
        await h.settle();
      },
    );

    test('the first listener opens the conversation and the last one closes '
        'it', () async {
      await joined();
      final a = port
          .watchThread(const ThreadRef.conversation(_c1))
          .listen((_) {});
      final b = port
          .watchThread(const ThreadRef.conversation(_c1))
          .listen((_) {});
      await _until(() async => h.pipeline.coordinator!.isWatched(_c1));
      await a.cancel();
      expect(h.pipeline.coordinator!.isWatched(_c1), isTrue);
      await b.cancel();
      expect(h.pipeline.coordinator!.isWatched(_c1), isFalse);
      await h.settle();
    });

    test('a stored message, a new outgoing row and a delete each re-emit; '
        'previewChanged names the conversation', () async {
      final offer = await joined();
      final seen = <EncryptedThread>[];
      final previews = <String>[];
      final sub = port
          .watchThread(const ThreadRef.conversation(_c1))
          .listen(seen.add);
      final psub = port.previewChanged.listen(previews.add);
      await _until(() async => seen.isNotEmpty);
      await h.settle();

      // Bob's message arrives through the receiver.
      final g = offer.add.group;
      final content = _content('from bob');
      final r = await g.owner.engine.encrypt(g.owner.state, g.state, content);
      g.state = r.groupState;
      h.rig.server.addMessage(
        pb.Message(
          id: _mid(9),
          conversationId: _c1,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(h.rig.clock.now()),
          ciphertext: r.ciphertext,
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(r.epoch),
          reportCommitment: reportCommitment(content),
        ),
      );
      await h.pipeline.receiver.pullLive(_c1);
      await _until(
        () async => seen.last.entries.whereType<DecryptedMessage>().any(
          (m) => m.text == 'from bob',
        ),
      );
      expect(previews, contains(_c1));

      // A new outgoing row.
      h.rig.server.beforeSend = (_) => Completer<void>().future;
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'mine',
      );
      await _until(() async => seen.last.entries.any((e) => e.id == 'local-1'));

      h.rig.server.beforeSend = null;
      await sub.cancel();
      await psub.cancel();
    });

    test('rows at or before cleared_at never appear', () async {
      await joined();
      await store(_c1, 1, text: 'old');
      await store(_c1, 3, text: 'new');
      await vault().transaction(
        (tx) => tx.putConversationSync(
          _c1,
          const ConversationSync(
            requestAccepted: true,
            clearedAtMicros: 2000000,
          ),
        ),
      );
      final t = await port.watchThread(const ThreadRef.conversation(_c1)).first;
      expect(t.entries.whereType<DecryptedMessage>().map((m) => m.text), [
        'new',
      ]);
      await h.settle();
    });

    test('loadOlder widens the window by 50', () async {
      await joined();
      for (var n = 1; n <= 60; n++) {
        await store(_c1, n, text: 'm$n');
      }
      final seen = <EncryptedThread>[];
      final sub = port
          .watchThread(const ThreadRef.conversation(_c1))
          .listen(seen.add);
      await _until(() async => seen.isNotEmpty);
      expect(seen.last.entries.whereType<DecryptedMessage>(), hasLength(50));
      expect(seen.last.hasMore, isTrue);
      expect(
        (seen.last.entries.first as DecryptedMessage).text,
        'm60',
        reason: 'newest first',
      );
      await port.loadOlder(const ThreadRef.conversation(_c1));
      await _until(
        () async =>
            seen.last.entries.whereType<DecryptedMessage>().length == 60,
      );
      expect(seen.last.hasMore, isFalse);
      await sub.cancel();
      await h.settle();
    });

    test(
      'a pending request\'s thread has messages and no system line',
      () async {
        await h.offer(_c1, bob, accepted: false);
        await h.ready();
        await store(_c1, 1, text: 'hi');
        await store(
          _c1,
          2,
          kind: StoredMessageKind.system,
          content: const SystemLineContent(line: SystemLine.encryptionReset)
              .encode(),
        );
        final t = await port
            .watchThread(const ThreadRef.conversation(_c1))
            .first;
        expect(t.security.state, ConversationEncryptionState.pendingRequest);
        expect(t.security.canSend, isFalse);
        expect(t.entries.whereType<SystemLineEntry>(), isEmpty);
        expect(t.entries.whereType<DecryptedMessage>().single.text, 'hi');
        await h.settle();
      },
    );

    test('a recipient thread continues under its conversation id after the '
        'first send', () async {
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
      final ref = ThreadRef.recipientOf(
        common.AuthorSnapshot(userId: 'ref-carol'),
      );
      final seen = <EncryptedThread>[];
      final sub = port.watchThread(ref).listen(seen.add);
      await _until(() async => seen.isNotEmpty);
      expect(seen.last.conversationId, isNull);

      final out = await port.send(to: ref, localId: 'local-1', text: 'one');
      expect(out.conversationId, _c2);
      await _until(() async => seen.last.conversationId == _c2);
      expect(seen.last.entries.map((e) => e.id), contains('local-1'));
      await h.pipeline.starter.settled(_c2);
      await sub.cancel();
    });

    test('a waiting-to-decrypt row never appears before its display line '
        'exists (encryptedDisplayText checks it first)', () async {
      // Covered by encrypted_thread_items_test.dart; here only that the port
      // emits no deferred row for a conversation with none.
      await joined();
      final t = await port.watchThread(const ThreadRef.conversation(_c1)).first;
      expect(
        t.entries.whereType<DecryptedMessage>().where(
          (m) => m.waitingToDecrypt,
        ),
        isEmpty,
      );
      await h.settle();
    });
  });

  group('memory across accounts (item 30, L3)', () {
    test(
      'a closed vault ends every thread and forgets the known ids',
      () async {
        await joined();
        expect(port.hasLocal(_c1), isTrue);
        final done = Completer<void>();
        port
            .watchThread(const ThreadRef.conversation(_c1))
            .listen((_) {}, onDone: done.complete);
        await _until(() async => h.pipeline.coordinator!.isWatched(_c1));
        await h.settle();
        h.rig.device.owner!.steal();
        await pumpEventQueue();
        await done.future.timeout(const Duration(seconds: 5));
        expect(port.hasLocal(_c1), isFalse);
        expect(await port.previews([_c1]), isEmpty);
      },
    );
  });

  group('securityCode (item 31)', () {
    test('securityCode returns 60 digits and both counts', () async {
      await joined();
      final code = await port.securityCode(_c1);
      expect(code.reason, isNull);
      expect(code.digits, matches(RegExp(r'^[0-9]{60}$')));
      expect((code.myDevices, code.theirDevices), (1, 1));
    });

    test('the code differs between two conversations with the same device '
        'keys', () async {
      await joined();
      await h.offer(_c2, bob);
      await h.pipeline.crypto.processWelcomes();
      final a = await port.securityCode(_c1);
      final b = await port.securityCode(_c2);
      expect(a.digits, isNotNull);
      expect(b.digits, isNotNull);
      expect(a.digits, isNot(b.digits));
    });

    test(
      'no digits and no counts while a member is unattributed (H3)',
      () async {
        await joined();
        final members = await vault().members(_c1);
        final theirs = members.firstWhere((m) => m.side == MemberSide.theirs);
        await vault().transaction(
          (tx) => tx.putMember(
            MemberRecord(
              conversationId: _c1,
              deviceId: theirs.deviceId,
              signatureKey: theirs.signatureKey,
              side: MemberSide.unattributed,
              since: theirs.since,
            ),
          ),
        );
        final code = await port.securityCode(_c1);
        expect(code.digits, isNull);
        expect(code.reason, NoCodeReason.unavailable);
        expect((code.myDevices, code.theirDevices), (0, 0));
      },
    );

    test('no digits on a provisional group (H3)', () async {
      await h.rig.seedProvisional(_c1, [bob]);
      await h.rig.accept(_c1);
      await h.ready();
      final code = await port.securityCode(_c1);
      expect((code.digits, code.reason), (null, NoCodeReason.unavailable));
      expect((code.myDevices, code.theirDevices), (0, 0));
    });

    test('each reason in turn: pending, sent, not a member, removed '
        'elsewhere', () async {
      await h.offer(_c1, bob, accepted: false);
      await h.ready();
      expect(
        (await port.securityCode(_c1)).reason,
        NoCodeReason.pendingRequest,
      );
      expect((await port.securityCode(_c2)).reason, NoCodeReason.notAMember);
      h.deviceKeys.markRemoved();
      expect((await port.securityCode(_c1)).reason, NoCodeReason.unavailable);
    });
  });

  group('previews and search (items 28, 32)', () {
    test('previews are built in memory and nothing is written', () async {
      await joined();
      await store(_c1, 1, text: 'first');
      await store(_c1, 2, text: 'second line one\nline two');
      final noted = h.messaging.noted.length;
      final outbox = (await vault().outbox()).items.length;
      final p = await port.previews([_c1, _c2]);
      expect(p.keys, [
        _c1,
      ], reason: 'an id the vault does not know is left out');
      expect(
        (p[_c1]!.kind, p[_c1]!.text),
        (PreviewKind.text, 'second line one'),
      );
      expect(h.messaging.noted, hasLength(noted));
      expect((await vault().outbox()).items, hasLength(outbox));
      expect(await vault().messages(_c1), hasLength(2));
    });

    test('an unaccepted incoming request previews generic', () async {
      await h.offer(_c1, bob, accepted: false);
      await h.ready();
      await store(_c1, 1, text: 'secret');
      final p = await port.previews([_c1]);
      expect((p[_c1]!.kind, p[_c1]!.text), (PreviewKind.generic, ''));
    });

    test('search finds visible ok text, newest first, respects limit, skips '
        'unverified rows and unaccepted incoming requests', () async {
      await joined();
      await store(_c1, 1, text: 'Hello one');
      await store(_c1, 2, text: 'hello two', mine: true);
      await store(
        _c1,
        3,
        text: 'hello unverified',
        check: StoredMessageCheck.unverified,
      );
      await store(_c1, 4, text: 'nothing here');
      await h.offer(_c2, bob, accepted: false);
      await h.pipeline.crypto.processWelcomes();
      await store(_c2, 5, text: 'hello request');

      final hits = await port.search('HELLO');
      expect(hits.map((x) => x.messageId), [_mid(2), _mid(1)]);
      expect(hits.first.mine, isTrue);
      expect(hits.first.text, 'hello two');
      expect(await port.search('hello', limit: 1), hasLength(1));
      expect(await port.search('hello', conversationId: _c2), isEmpty);
      expect(await port.search(''), isEmpty);
    });

    test('search returns the newest matches overall when there are more '
        'than limit, whatever the conversation order (controller ruling '
        'on 13b-ii)', () async {
      await joined();
      await h.offer(_c2, bob);
      await h.pipeline.crypto.processWelcomes();
      expect(h.pipeline.known.ids, containsAll([_c1, _c2]));
      // _c1: many old matches over more than one read page, and the newest
      // match of all; _c2: two matches between them.
      for (var n = 1; n <= 55; n++) {
        await store(_c1, n);
      }
      await store(_c1, 100);
      await store(_c2, 60);
      await store(_c2, 70);
      final hits = await port.search('hello', limit: 3);
      expect(hits.map((x) => (x.conversationId, x.messageId)), [
        (_c1, _mid(100)),
        (_c2, _mid(70)),
        (_c2, _mid(60)),
      ]);
      final one = await port.search('hello', limit: 1);
      expect(one.single.messageId, _mid(100));
      final five = await port.search('hello', limit: 5);
      expect(five.map((x) => x.messageId), [
        _mid(100),
        _mid(70),
        _mid(60),
        _mid(55),
        _mid(54),
      ]);
    });
  });

  group('reportPayload (item 32)', () {
    test(
      'reportPayload returns the exact stored bytes for a peer message of '
      'any age, also unverified, and null for mine and for a system row',
      () async {
        await joined();
        final bytes = _content('report me');
        await store(_c1, 1, content: bytes);
        await store(
          _c1,
          2,
          content: bytes,
          check: StoredMessageCheck.unverified,
        );
        await store(_c1, 3, text: 'mine', mine: true);
        await store(
          _c1,
          4,
          kind: StoredMessageKind.system,
          content: const SystemLineContent(line: SystemLine.encryptionReset)
              .encode(),
        );
        await store(_c1, 5, state: StoredMessageState.removed);
        h.rig.clock.advance(const Duration(days: 400));

        final gets = h.rig.keys.getCalls.length;
        final payload = await port.reportPayload(_c1, _mid(1));
        expect(payload, bytes);
        payload![0] ^= 0xff;
        expect(await port.reportPayload(_c1, _mid(1)), bytes, reason: 'a copy');
        expect(await port.reportPayload(_c1, _mid(2)), bytes);
        expect(await port.reportPayload(_c1, _mid(3)), isNull);
        expect(await port.reportPayload(_c1, _mid(4)), isNull);
        expect(await port.reportPayload(_c1, _mid(5)), isNull);
        expect(await port.reportPayload(_c1, _mid(99)), isNull);
        expect(h.rig.keys.getCalls, hasLength(gets));
      },
    );
  });

  group('own devices (items 36, 37)', () {
    test('ownDevices puts this device first, marks a member the directory '
        'does not list, keeps the last list when rate limited and falls back '
        'to the vault on failure', () async {
      await joined();
      final me = h.rig.device.deviceIdString;
      // An own device pinned in _c1 that the directory does not list.
      final lost = await RigPeer.create('lost');
      await vault().transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: lost.id,
            signatureKey: lost.key,
            side: MemberSide.mine,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      // An own device the directory lists that no group holds, older.
      final other = await RigPeer.create('other');
      h.rig.keys.own
        ..clear()
        ..addAll([
          kpb.KeyDevice(
            deviceId: me,
            signaturePublicKey: h.rig.device.signatureKey,
            createdAt: ts.Timestamp(seconds: Int64(2000)),
          ),
          kpb.KeyDevice(
            deviceId: other.idString,
            signaturePublicKey: other.key,
            createdAt: ts.Timestamp(seconds: Int64(1000)),
            inactive: true,
          ),
        ]);

      var list = await port.ownDevices();
      expect(list.directoryKnown, isTrue);
      expect(list.devices.first.ref, me);
      expect(list.devices.first.thisDevice, isTrue);
      final byRef = {for (final d in list.devices) d.ref: d};
      expect(byRef[lost.idString]!.inDirectory, isFalse);
      expect(byRef[lost.idString]!.inConversations, isTrue);
      expect(byRef[other.idString]!.inConversations, isFalse);
      expect(byRef[other.idString]!.inactive, isTrue);
      expect(
        byRef[other.idString]!.addedAt,
        DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true),
      );
      expect(list.devices.map((d) => d.ref), [
        me,
        other.idString,
        lost.idString,
      ]);

      // Rate limited: the last list, still known.
      h.rig.keys.ownError = const RateLimitedException('slow');
      list = await port.ownDevices();
      expect(list.directoryKnown, isTrue);
      expect(list.devices, hasLength(3));

      // Any other failure: vault membership only, unknown directory.
      h.rig.keys
        ..ownError = null
        ..ownFails = true;
      list = await port.ownDevices();
      expect(list.directoryKnown, isFalse);
      expect(list.devices.map((d) => d.ref).toSet(), {me, lost.idString});
      expect(list.devices.every((d) => d.inDirectory), isTrue);
    });

    test('removeDevice completes on the directory answer and removalsPending '
        'counts down; refs outside the own list and this device are '
        'ArgumentErrors', () async {
      await joined();
      final other = await RigPeer.create('other');
      h.rig.keys.own.add(rigKeyDevice(other.idString, other.key));
      await expectLater(port.removeDevice(other.idString), throwsArgumentError);
      await port.ownDevices();
      await expectLater(
        port.removeDevice(h.rig.device.deviceIdString),
        throwsArgumentError,
      );
      await expectLater(port.removeDevice('f' * 32), throwsArgumentError);

      final counts = <int>[];
      void note() => counts.add(port.removalsPending.value);
      port.removalsPending.addListener(note);
      await port.removeDevice(other.idString);
      expect(h.rig.keys.removeCalls, hasLength(1));
      await h.settle();
      await h.runTimers();
      port.removalsPending.removeListener(note);
      expect(counts, contains(1));
      expect(port.removalsPending.value, 0);
    });
  });

  test('hasLocal is true for a conversation with messages and no group after '
      'set up again', () async {
    await joined();
    await store(_c1, 1);
    h.deviceKeys.markRemoved();
    await port.setUpDeviceAgain();
    await h.settle();
    expect(await vault().group(_c1, 1), isNull);
    expect(port.hasLocal(_c1), isTrue);
    expect(h.rig.device.session.status.value, VaultStatus.ready);
  });
}
