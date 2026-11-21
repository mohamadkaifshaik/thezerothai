import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
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

  group('the fake enforces the port rules', () {
    EncryptedThread thread(DecryptedMessage m) =>
        EncryptedThread(security: ready, entries: [m]);
    void refuses(DecryptedMessage m) => expect(
      () => FakeEncryptedMessaging().setThread(ref, thread(m)),
      throwsA(isA<AssertionError>()),
    );
    void accepts(DecryptedMessage m) =>
        FakeEncryptedMessaging().setThread(ref, thread(m));

    test('a delivered own undecryptable row (a lost own send) is accepted', () {
      accepts(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          state: EncryptedMessageState.undecryptable,
        ),
      );
    });

    test('a received undecryptable row is accepted', () {
      accepts(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          state: EncryptedMessageState.undecryptable,
        ),
      );
    });

    test('waitingToDecrypt is false unless it is asked for', () {
      expect(
        DecryptedMessage(id: 'a', at: _at, mine: false).waitingToDecrypt,
        isFalse,
      );
    });

    test('a waiting-to-decrypt row is accepted as an undecryptable row that '
        'is not mine', () {
      accepts(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          state: EncryptedMessageState.undecryptable,
          waitingToDecrypt: true,
        ),
      );
    });

    test('waitingToDecrypt is refused on a visible row, on a row that is '
        'mine and on a removed row', () {
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          text: 't',
          waitingToDecrypt: true,
        ),
      );
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          state: EncryptedMessageState.undecryptable,
          waitingToDecrypt: true,
        ),
      );
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          state: EncryptedMessageState.removed,
          waitingToDecrypt: true,
        ),
      );
    });

    test('a problem is set only with progress notSent', () {
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          problem: SendProblem.retryable,
        ),
      );
      accepts(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.retryable,
        ),
      );
    });

    test('an error is set only with problem refused', () {
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.blocked,
          error: const FeatureDisabledException('off'),
        ),
      );
      accepts(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.refused,
          error: const FeatureDisabledException('off'),
        ),
      );
    });

    test('canReport only on a visible message that is not mine', () {
      refuses(DecryptedMessage(id: 'a', at: _at, mine: true, canReport: true));
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          state: EncryptedMessageState.removed,
          canReport: true,
        ),
      );
      accepts(DecryptedMessage(id: 'a', at: _at, mine: false, canReport: true));
    });

    test(
      'a refused outcome carries a problem and a queued one carries none',
      () {
        final fake = FakeEncryptedMessaging();
        expect(
          () =>
              fake.nextSendOutcome = const SendOutcome(SendOutcomeKind.refused),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => fake.nextSendOutcome = const SendOutcome(
            SendOutcomeKind.queued,
            problem: SendProblem.blocked,
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => fake.nextSendOutcome = const SendOutcome(
            SendOutcomeKind.notEncrypted,
            problem: SendProblem.blocked,
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => fake.nextSendOutcome = SendOutcome(
            SendOutcomeKind.notEncrypted,
            error: const FeatureDisabledException('off'),
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => fake.nextSendOutcome = SendOutcome(
            SendOutcomeKind.refused,
            problem: SendProblem.blocked,
            error: const FeatureDisabledException('off'),
          ),
          throwsA(isA<AssertionError>()),
        );
        fake.nextSendOutcome = const SendOutcome(
          SendOutcomeKind.refused,
          problem: SendProblem.tryTomorrow,
        );
      },
    );

    test('a received row must be delivered', () {
      refuses(
        DecryptedMessage(
          id: 'a',
          at: _at,
          mine: false,
          progress: SendProgress.notSent,
          problem: SendProblem.retryable,
        ),
      );
    });
  });

  group('the scripting seam', () {
    test('queued outcomes are returned in order, then the default', () async {
      final fake = FakeEncryptedMessaging()
        ..nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted)
        ..queueSendOutcomes(const [
          SendOutcome(SendOutcomeKind.refused, problem: SendProblem.blocked),
          SendOutcome(SendOutcomeKind.queued),
        ]);
      expect(
        (await fake.send(to: ref, localId: 'a', text: 'x')).kind,
        SendOutcomeKind.refused,
      );
      expect(
        (await fake.send(to: ref, localId: 'b', text: 'x')).kind,
        SendOutcomeKind.queued,
      );
      expect(
        (await fake.send(to: ref, localId: 'c', text: 'x')).kind,
        SendOutcomeKind.notEncrypted,
      );
      expect(
        () => fake.queueSendOutcomes(const [
          SendOutcome(SendOutcomeKind.refused),
        ]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('failNextOn fails only the named method once', () async {
      final fake = FakeEncryptedMessaging()
        ..failNextOn('ownDevices', StateError('x'));
      await fake.retrySend('a');
      await expectLater(fake.ownDevices(), throwsStateError);
      await fake.ownDevices();
    });
  });

  group('the fake throws as the port documents', () {
    test(
      'setUpDeviceAgain throws StateError when not removed elsewhere',
      () async {
        final fake = FakeEncryptedMessaging();
        await expectLater(fake.setUpDeviceAgain(), throwsStateError);
        fake.removedElsewhere.value = true;
        await fake.setUpDeviceAgain();
        expect(fake.setUpAgainCalls, 2);
      },
    );

    test('setUpDeviceAgain when not removed is a StateError even with a failure scripted', () async {
      final fake = FakeEncryptedMessaging()..failNext = ArgumentError('x');
      await expectLater(fake.setUpDeviceAgain(), throwsStateError);
    });

    test('a send repeated after a refused outcome is accepted', () async {
      final fake = FakeEncryptedMessaging()
        ..nextSendOutcome = const SendOutcome(
          SendOutcomeKind.refused,
          problem: SendProblem.tryTomorrow,
        );
      await fake.send(to: ref, localId: 'r1', text: 'x');
      await fake.send(to: ref, localId: 'r1', text: 'x');
      fake.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
      await fake.send(to: ref, localId: 'r1', text: 'x');
      expect(fake.sent, hasLength(3));
    });

    test(
      'a send repeated after a queued outcome is an ArgumentError',
      () async {
        final fake = FakeEncryptedMessaging();
        await fake.send(to: ref, localId: 'q1', text: 'x');
        await expectLater(
          fake.send(to: ref, localId: 'q1', text: 'x'),
          throwsArgumentError,
        );
      },
    );

    test('removeDevice throws ArgumentError for this device', () async {
      final fake = FakeEncryptedMessaging()
        ..setOwnDevices(
          const OwnDeviceList(
            devices: [
              OwnDevice(ref: 'me', thisDevice: true),
              OwnDevice(ref: 'other', thisDevice: false),
            ],
          ),
        );
      await expectLater(fake.removeDevice('me'), throwsArgumentError);
      await fake.removeDevice('other');
      expect(fake.removedDevices, ['other']);
    });

    test(
      'send throws ArgumentError for a localId that is already an unsent row',
      () async {
        final fake = FakeEncryptedMessaging()
          ..setThread(
            ref,
            thread0(
              DecryptedMessage(
                id: 'u1',
                at: _at,
                mine: true,
                progress: SendProgress.waiting,
              ),
            ),
          );
        await expectLater(
          fake.send(to: ref, localId: 'u1', text: 'x'),
          throwsArgumentError,
        );
        await fake.send(to: ref, localId: 'u2', text: 'x');
        await expectLater(
          fake.send(to: ref, localId: 'u2', text: 'x'),
          throwsArgumentError,
        );
      },
    );
  });

  test('two watchers of one ref both receive later threads', () async {
    final fake = FakeEncryptedMessaging();
    final a = <EncryptedThread>[];
    final b = <EncryptedThread>[];
    final sa = fake.watchThread(ref).listen(a.add);
    final sb = fake.watchThread(ref).listen(b.add);
    await pumpEventQueue();
    fake.setThread(
      ref,
      const EncryptedThread(conversationId: 'c1', security: ready),
    );
    await pumpEventQueue();
    expect(a, hasLength(2));
    expect(b, hasLength(2));
    await sa.cancel();
    fake.setThread(
      ref,
      const EncryptedThread(conversationId: 'c1', security: ready),
    );
    await pumpEventQueue();
    expect(b, hasLength(3));
    await sb.cancel();
    fake.dispose();
  });

  test('scripting helpers behave as screen tests rely on', () async {
    final fake = FakeEncryptedMessaging();
    expect(
      () => fake.setSecurityCode('c1', const SecurityCode(digits: '123')),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => fake.setSecurityCode('c1', const SecurityCode()),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => fake.setSecurityCode(
        'c1',
        SecurityCode(digits: '1' * 60, reason: NoCodeReason.unavailable),
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => fake.setSecurityCode(
        'c1',
        const SecurityCode(reason: NoCodeReason.unavailable, myDevices: 1),
      ),
      throwsA(isA<AssertionError>()),
    );
    fake.setSecurityCode('c1', SecurityCode(digits: '1' * 60));
    expect((await fake.securityCode('c1')).digits, '1' * 60);
    expect((await fake.securityCode('zz')).reason, NoCodeReason.unavailable);

    final changed = <String>[];
    final sub = fake.previewChanged.listen(changed.add);
    fake.setPreviews({
      'c1': const ConversationPreview(kind: PreviewKind.generic),
      'c2': const ConversationPreview(kind: PreviewKind.generic),
    });
    await pumpEventQueue();
    expect(changed, unorderedEquals(['c1', 'c2']));
    expect((await fake.previews(['c1', 'nope'])).keys, ['c1']);
    await sub.cancel();

    fake.local = {'c1'};
    expect(fake.hasLocal('c1'), isTrue);
    expect(fake.hasLocal('c2'), isFalse);

    EncryptedSearchHit hit(String c, String m) => EncryptedSearchHit(
      conversationId: c,
      messageId: m,
      at: _at,
      mine: false,
      text: 't',
    );
    fake.setSearchHits([hit('c1', 'm1'), hit('c2', 'm2'), hit('c1', 'm3')]);
    expect(await fake.search('t'), hasLength(3));
    expect(
      (await fake.search('t', conversationId: 'c1')).map((h) => h.messageId),
      ['m1', 'm3'],
    );
    expect(await fake.search('t', limit: 1), hasLength(1));
    expect(fake.searchQueries, ['t', 't', 't']);

    const list = OwnDeviceList(
      devices: [OwnDevice(ref: 'o', thisDevice: false)],
    );
    fake.setOwnDevices(list);
    expect(await fake.ownDevices(), same(list));
    await fake.removeDevice('o');
    expect(fake.removedDevices, ['o']);
    expect(fake.calls, containsAllInOrder(['ownDevices', 'removeDevice']));
    fake.dispose();
  });
}

EncryptedThread thread0(DecryptedMessage m) => EncryptedThread(
  security: const ConversationSecurity(
    state: ConversationEncryptionState.ready,
  ),
  entries: [m],
);
