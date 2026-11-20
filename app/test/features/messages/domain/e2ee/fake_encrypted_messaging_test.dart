import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart'
    show AuthorSnapshot;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encrypted_messaging.dart';

final _at = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

void main() {
  const ref = ThreadRef.conversation('c1');
  const ready = ConversationSecurity(state: ConversationEncryptionState.ready);

  test(
    'watchThread emits the current thread at once and again after setThread',
    () async {
      final fake = FakeEncryptedMessaging();
      fake.setThread(
        ref,
        const EncryptedThread(conversationId: 'c1', security: ready),
      );
      final seen = <EncryptedThread>[];
      final sub = fake.watchThread(ref).listen(seen.add);
      await pumpEventQueue();
      expect(seen, hasLength(1));
      fake.setThread(
        ref,
        EncryptedThread(
          conversationId: 'c1',
          security: ready,
          entries: [DecryptedMessage(id: 'a', at: _at, mine: true, text: 'hi')],
        ),
      );
      await pumpEventQueue();
      expect(seen, hasLength(2));
      expect(seen.last.entries, hasLength(1));
      await sub.cancel();
    },
  );

  test('watchThread for an unknown ref emits an empty ready thread with canSend true', () async {
    final fake = FakeEncryptedMessaging();
    final t = await fake
        .watchThread(ThreadRef.recipientOf(AuthorSnapshot(userId: 'u1')))
        .first;
    expect(t.security.state, ConversationEncryptionState.ready);
    expect(t.security.canSend, isTrue);
    expect(t.entries, isEmpty);
    expect(t.conversationId, isNull);
  });

  test('send records the call and returns nextSendOutcome', () async {
    final fake = FakeEncryptedMessaging()
      ..nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    final out = await fake.send(to: ref, localId: 'l1', text: 'x');
    expect(out.kind, SendOutcomeKind.notEncrypted);
    expect(fake.calls, ['send']);
    expect(fake.sent.single.localId, 'l1');
  });

  test(
    'send stays pending while holdSend is set and answers when it completes',
    () async {
      final fake = FakeEncryptedMessaging()..holdSend = Completer<void>();
      var done = false;
      final f = fake
          .send(to: ref, localId: 'l1', text: 'x')
          .then((_) => done = true);
      await pumpEventQueue();
      expect(fake.calls, ['send']);
      expect(done, isFalse);
      fake.holdSend!.complete();
      await f;
      expect(done, isTrue);
    },
  );

  test('failNext throws once', () async {
    final fake = FakeEncryptedMessaging()..failNext = StateError('x');
    await expectLater(fake.retrySend('a'), throwsStateError);
    await fake.retrySend('a');
    expect(fake.failNext, isNull);
  });

  test('failNext can throw a ResetRefusedException from resetConversation, with its reason', () async {
    final fake = FakeEncryptedMessaging()
      ..failNext = const ResetRefusedException(ResetRefusal.notAccepted);
    await expectLater(
      fake.resetConversation('c1'),
      throwsA(
        isA<ResetRefusedException>().having(
          (e) => e.reason,
          'reason',
          ResetRefusal.notAccepted,
        ),
      ),
    );
  });

  test('checkRemovedAgain is recorded and counted', () async {
    final fake = FakeEncryptedMessaging();
    await fake.checkRemovedAgain();
    expect(fake.calls, ['checkRemovedAgain']);
    expect(fake.checkRemovedAgainCalls, 1);
  });

  test('a visible unverified message with text is refused by the fake', () {
    final fake = FakeEncryptedMessaging();
    expect(
      () => fake.setThread(
        ref,
        EncryptedThread(
          security: ready,
          entries: [
            DecryptedMessage(
              id: 'a',
              at: _at,
              mine: false,
              check: MessageCheck.unverified,
              text: 'leaked',
            ),
          ],
        ),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('ThreadRef equality', () {
    expect(
      const ThreadRef.conversation('a'),
      const ThreadRef.conversation('a'),
    );
    expect(
      const ThreadRef.conversation('a').hashCode,
      const ThreadRef.conversation('a').hashCode,
    );
    expect(
      const ThreadRef.conversation('a'),
      isNot(const ThreadRef.conversation('b')),
    );
    expect(
      ThreadRef.recipientOf(AuthorSnapshot(userId: 'a')),
      ThreadRef.recipientOf(AuthorSnapshot(userId: 'a')),
    );
    expect(
      ThreadRef.recipientOf(AuthorSnapshot(userId: 'a')),
      isNot(const ThreadRef.conversation('a')),
    );
  });

  test('no port type overrides toString', () {
    final values = <Object>[
      const ThreadRef.conversation('a'),
      ready,
      DecryptedMessage(id: 'a', at: _at, mine: true, text: 't'),
      SystemLineEntry(id: 's', at: _at, kind: SystemLineKind.deviceAdded),
      const EncryptedThread(security: ready),
      const SendOutcome(SendOutcomeKind.queued),
      const SecurityCode(),
      const ConversationPreview(kind: PreviewKind.text, text: 't'),
      EncryptedSearchHit(
        conversationId: 'c',
        messageId: 'm',
        at: _at,
        mine: true,
        text: 't',
      ),
      const OwnDevice(ref: 'r', thisDevice: true),
      const OwnDeviceList(),
      const ResetRefusedException(ResetRefusal.notAccepted),
    ];
    for (final v in values) {
      expect(
        v.toString(),
        startsWith('Instance of'),
        reason: '${v.runtimeType}',
      );
    }
  });
}
