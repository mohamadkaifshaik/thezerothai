import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 13b, fix round of the 13b-i review (task-13b-review.md,
// controller rulings 1-5): the send branches the review found untested.

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
}
