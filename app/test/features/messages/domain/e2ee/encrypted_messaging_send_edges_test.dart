import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13b, fix round of the 13b-i review (task-13b-review.md,
// controller rulings 1-5): the send branches the review found untested.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

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

  Future<List<String?>> outboxIds() async => [
    for (final r in (await h.rig.device.vault.outbox()).items) r.conversationId,
  ];

  Future<SendOutcome> sendTo(String id) =>
      port.send(to: ThreadRef.conversation(id), localId: 'local-1', text: 'hi');

  group('a conversation with no stored peer and no cached row (review I1)', () {
    test('a known id is queued and its row saved', () async {
      await h.ready();
      await h.pipeline.known.add(_c2);
      expect(h.pipeline.known.peerOf(_c2), isNull);
      expect(h.rig.server.rows[_c2], isNull);
      final out = await sendTo(_c2);
      expect((out.kind, out.conversationId), (SendOutcomeKind.queued, _c2));
      expect(await outboxIds(), [_c2]);
    });

    test('an id marked only in the cache is queued', () async {
      await h.ready();
      h.rig.server.everEncrypted.add(_c2);
      expect(h.pipeline.known.contains(_c2), isFalse);
      final out = await sendTo(_c2);
      expect((out.kind, out.conversationId), (SendOutcomeKind.queued, _c2));
      expect(await outboxIds(), [_c2]);
    });

    test('an unmarked id is refused retryable: nothing saved, no '
        'GetKeyDevices call', () async {
      await h.ready();
      final gets = h.rig.keys.getCalls.length;
      final out = await sendTo(_c2);
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.retryable),
      );
      expect(await outboxIds(), isEmpty);
      expect(h.rig.keys.getCalls, hasLength(gets));
    });

    test('after markRemoved a known id is refused blocked', () async {
      await h.ready();
      await h.pipeline.known.add(_c2);
      h.deviceKeys.markRemoved();
      final out = await sendTo(_c2);
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.blocked),
      );
      expect(await outboxIds(), isEmpty);
    });
  });

  group('the plaintext answer is asked once more (gate item 3, review '
      'M1)', () {
    pb.Conversation carolRow() => pb.Conversation(
      id: _c2,
      peer: common.AuthorSnapshot(userId: 'ref-carol'),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
    );

    test('a conversation the cache marks encrypted during the lookup is '
        'refused blocked', () async {
      await h.ready();
      expect(h.rig.device.session.mayStart, isTrue);
      h.rig.server.rows[_c2] = carolRow();
      h.rig.keys
        ..peers['ref-carol'] = []
        ..onGet = () async => h.rig.server.everEncrypted.add(_c2);
      final out = await sendTo(_c2);
      expect(h.rig.keys.getCalls, isNotEmpty);
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.blocked),
      );
    });

    test('a recipient whose cached row is marked encrypted during the lookup '
        'is refused blocked', () async {
      await h.ready();
      h.rig.keys
        ..peers['ref-carol'] = []
        ..onGet = () async {
          h.rig.server.rows[_c2] = carolRow();
          h.rig.server.everEncrypted.add(_c2);
        };
      final out = await port.send(
        to: ThreadRef.recipientOf(common.AuthorSnapshot(userId: 'ref-carol')),
        localId: 'local-1',
        text: 'hi',
      );
      expect(h.rig.keys.getCalls, isNotEmpty);
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.blocked),
      );
    });

    test(
      'with nothing marked, a recipient listing no device is plaintext',
      () async {
        await h.ready();
        h.rig.keys.peers['ref-carol'] = [];
        final out = await port.send(
          to: ThreadRef.recipientOf(common.AuthorSnapshot(userId: 'ref-carol')),
          localId: 'local-1',
          text: 'hi',
        );
        expect(out.kind, SendOutcomeKind.notEncrypted);
      },
    );
  });

  group('failures (review M6)', () {
    test('resetConversation throws ResetRefusedException(peerHasNoDevice) '
        'when the peer lists no device', () async {
      await h.offer(_c1, bob);
      await h.ready();
      // Bob's next commit cannot be processed here: the conversation is
      // stuck, so a reset is offered.
      final garbage = rigBytes('a commit no engine can process');
      h.rig.device.engine.failWireAlways[RigEngine.key(garbage)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      h.rig.server.addCommit(
        _c1,
        h.rig.server.current(_c1),
        garbage,
        fromUser: 'user-b',
      );
      expect(await h.pipeline.crypto.catchUp(_c1), CatchUpResult.stuck);
      h.rig.keys.peers['ref-bob'] = [];
      await expectLater(
        port.resetConversation(_c1),
        throwsA(
          isA<ResetRefusedException>().having(
            (e) => e.reason,
            'reason',
            ResetRefusal.peerHasNoDevice,
          ),
        ),
      );
    });

    test('unsentEntries is null, and nothing is reported, while a live '
        "vault's cipher cannot run", () async {
      await h.offer(_c1, bob);
      await h.ready();
      const ref = ThreadRef.conversation(_c1);
      expect(await port.unsentEntries(ref), isEmpty);
      h.rig.device.cipher.unavailable = true;
      expect(h.pipeline.parts, isNotNull);
      final read = await port.unsentEntries(ref);
      h.rig.device.cipher.unavailable = false;
      expect(read, isNull);
      expect(h.reported, isEmpty);
    });
  });
}
