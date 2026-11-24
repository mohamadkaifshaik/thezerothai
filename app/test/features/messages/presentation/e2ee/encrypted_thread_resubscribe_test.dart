import 'dart:async';

import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/thread_test_support.dart';

class _MockRepo extends Mock implements MessagingRepository {}

/// `watchThread`'s stream ENDS when the vault it reads changes. A thread that
/// is still on screen subscribes again, once: a stream that ends at once is
/// not retried until the vault status changes again.
void main() {
  late _MockRepo repo;
  late FakeThreadPoller poller;
  late FakeEncryptedMessaging port;
  late ThreadCubit cubit;
  var usable = true;
  final ref = ThreadRef.conversation(kThreadId);

  int watches() => port.calls.where((c) => c == 'watchThread').length;

  DecryptedMessage entry(String id) =>
      DecryptedMessage(id: id, at: DateTime.now().toUtc(), mine: false);

  EncryptedThread threadOf(List<String> ids) => EncryptedThread(
    conversationId: kThreadId,
    entries: [for (final id in ids) entry(id)],
    security: const ConversationSecurity(
      state: ConversationEncryptionState.ready,
    ),
  );

  setUp(() async {
    usable = true;
    repo = _MockRepo();
    poller = FakeThreadPoller();
    port = FakeEncryptedMessaging();
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversation(any())).thenAnswer((_) async => null);
    final header = threadConv()
      ..encryption = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
    final snapshot = ThreadSnapshot(
      messages: const [],
      conversation: header,
      sinceToken: 's',
    );
    when(() => repo.cachedThread(kThreadId)).thenAnswer((_) async => snapshot);
    when(() => repo.refreshThread(kThreadId)).thenAnswer((_) async => snapshot);
    port.setThread(ref, threadOf(['a']));
    cubit = ThreadCubit(
      repository: repo,
      poller: poller,
      conversationId: kThreadId,
      encrypted: port,
      vaultUsable: () => usable,
    );
    await cubit.load();
    await pumpEventQueue();
  });

  tearDown(() async {
    await cubit.close();
    port.dispose();
  });

  test(
    'a stream that ends is subscribed again, once, and shows new rows',
    () async {
      expect(watches(), 1);
      expect(cubit.state.entries.map((e) => e.id), ['a']);

      port.setThread(ref, threadOf(['a', 'b']));
      port.endWatchers(ref);
      await pumpEventQueue();

      expect(watches(), 2);
      expect(port.watcherCount(ref), 1, reason: 'the old stream is gone');
      port.setThread(ref, threadOf(['c']));
      await pumpEventQueue();
      expect(cubit.state.entries.map((e) => e.id), ['c']);
    },
  );

  test(
    'a new stream that ends at once waits for the next vault change',
    () async {
      port.endWatchers(ref);
      await pumpEventQueue();
      expect(watches(), 2);

      port.endWatchers(ref);
      await pumpEventQueue();
      expect(watches(), 2, reason: 'no loop');

      cubit.refreshVault();
      await pumpEventQueue();
      expect(watches(), 3);
      expect(port.watcherCount(ref), 1);
    },
  );

  test('an unusable vault waits for the vault change', () async {
    usable = false;
    port.endWatchers(ref);
    await pumpEventQueue();
    expect(watches(), 1);
    expect(cubit.state.entries, isEmpty);

    usable = true;
    cubit.refreshVault();
    await pumpEventQueue();
    expect(watches(), 2);
  });

  EncryptedThread withUnreadable() => EncryptedThread(
    conversationId: kThreadId,
    entries: [entry('a')],
    security: const ConversationSecurity(
      state: ConversationEncryptionState.ready,
    ),
    unreadableUnsent: const ['h1'],
  );

  test('the old vault\'s rows and handles are cleared before the new stream '
      'is listened to', () async {
    port.setThread(ref, withUnreadable());
    await pumpEventQueue();
    expect(cubit.state.entries, isNotEmpty);
    expect(cubit.state.unreadableUnsent, ['h1']);

    final seen = <ThreadState>[];
    final sub = cubit.stream.listen(seen.add);
    addTearDown(sub.cancel);
    port.endWatchers(ref);
    await pumpEventQueue();

    // A state with nothing of the old vault came before the new emission.
    expect(
      seen.any((s) => s.entries.isEmpty && s.unreadableUnsent.isEmpty),
      isTrue,
    );
  });

  test('handles are cleared when the vault is not usable even with no '
      'entries', () async {
    port.setThread(
      ref,
      EncryptedThread(
        conversationId: kThreadId,
        security: ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
        unreadableUnsent: ['h1'],
      ),
    );
    await pumpEventQueue();
    expect(cubit.state.entries, isEmpty);
    expect(cubit.state.unreadableUnsent, ['h1']);

    usable = false;
    cubit.refreshVault();
    await pumpEventQueue();
    expect(cubit.state.unreadableUnsent, isEmpty);
  });

  test('closing the cubit leaves no stream behind', () async {
    port.endWatchers(ref);
    await pumpEventQueue();
    expect(port.watcherCount(ref), 1);
    await cubit.close();
    expect(port.watcherCount(ref), 0);
    port.endWatchers(ref);
    await pumpEventQueue();
    expect(watches(), 2, reason: 'a closed cubit does not subscribe again');
  });
}
