import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/messaging_fixtures.dart';
import '../../../../support/thread_test_support.dart';

class _MockRepo extends Mock implements MessagingRepository {}

void main() {
  late _MockRepo repo;
  late FakeThreadPoller poller;
  late FakeEncryptedMessaging port;
  late ThreadCubit cubit;
  late List<Object> reported;
  final ref = ThreadRef.conversation(kThreadId);

  ThreadSnapshot snap(List<pb.Message> messages, pb.Conversation header) =>
      ThreadSnapshot(messages: messages, conversation: header, sinceToken: 's');

  pb.Conversation header(ConversationEncryption encryption) =>
      threadConv()..encryption = encryption;

  const mls = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
  const none = ConversationEncryption.CONVERSATION_ENCRYPTION_NONE;
  const unspecified =
      ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED;

  /// The cache and the network answer [cached] and [network]; null for the
  /// network means it fails (offline).
  Future<void> open({
    ThreadSnapshot? cached,
    ThreadSnapshot? network,
    bool Function()? usable,
    bool withPort = true,
  }) async {
    when(() => repo.cachedThread(kThreadId))
        .thenAnswer((_) async => cached ?? const ThreadSnapshot());
    if (network == null) {
      when(() => repo.refreshThread(kThreadId))
          .thenThrow(const NetworkException('x'));
    } else {
      when(() => repo.refreshThread(kThreadId))
          .thenAnswer((_) async => network);
    }
    cubit = ThreadCubit(
      repository: repo,
      poller: poller,
      conversationId: kThreadId,
      encrypted: withPort ? port : null,
      vaultUsable: usable ?? () => true,
      onUnexpectedError: (e, _) => reported.add(e),
    );
    await cubit.load();
    await pumpEventQueue();
  }

  setUp(() {
    repo = _MockRepo();
    poller = FakeThreadPoller();
    port = FakeEncryptedMessaging();
    reported = [];
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversation(any())).thenAnswer((_) async => null);
    when(() => repo.noteSentRequestAnswered(any())).thenAnswer((_) async {});
    when(
      () => repo.markConversationRead(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() async {
    await cubit.close();
    port.dispose();
  });

  DecryptedMessage entry(String id, {bool mine = false}) => DecryptedMessage(
    id: id,
    at: DateTime.now().toUtc(),
    mine: mine,
    text: 'secret $id',
  );

  group('whether the conversation is encrypted', () {
    test('an MLS header with a usable vault subscribes and copies entries, '
        'security and hasMore', () async {
      port.setThread(
        ref,
        EncryptedThread(
          conversationId: kThreadId,
          entries: [entry('a')],
          hasMore: true,
          security: const ConversationSecurity(
            state: ConversationEncryptionState.stuck,
            canSend: false,
          ),
        ),
      );
      await open(network: snap(const [], header(mls)));
      expect(cubit.isMls, isTrue);
      expect(cubit.state.encrypted, isTrue);
      expect(port.calls, contains('watchThread'));
      expect(cubit.state.entries.single.id, 'a');
      expect(cubit.state.encryptedHasMore, isTrue);
      expect(cubit.state.security!.state, ConversationEncryptionState.stuck);
      expect(cubit.state.encryptedNoVault, isFalse);
    });

    test('an UNSPECIFIED header is unknown: a cached row with '
        'lastMessage.encrypted makes the thread encrypted', () async {
      final row = header(unspecified)
        ..lastMessage = pb.MessagePreview(encrypted: true);
      await open(
        cached: snap(const [], row),
        network: snap(const [], header(unspecified)),
      );
      expect(cubit.isMls, isTrue);
      expect(cubit.state.encrypted, isTrue);
    });

    test('an UNSPECIFIED header with a loaded message whose mlsGeneration is '
        '1 makes the thread encrypted', () async {
      final m = msg(1)..mlsGeneration = Int64(1);
      await open(network: snap([m], header(unspecified)));
      expect(cubit.isMls, isTrue);
      expect(cubit.state.encrypted, isTrue);
    });

    test('a since refresh answering UNSPECIFIED never turns an encrypted '
        'thread back', () async {
      await open(network: snap(const [], header(mls)));
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(const [], header(unspecified)));
      await cubit.pull();
      expect(cubit.isMls, isTrue);
      expect(cubit.state.mls, isTrue);
      expect(cubit.state.encrypted, isTrue);
      expect(cubit.state.knownPlain, isFalse);
    });

    test(
      'UNSPECIFIED with no other sign shows no note of either kind',
      () async {
        await open(network: snap(const [], header(unspecified)));
        expect(cubit.isMls, isFalse);
        expect(cubit.state.knownPlain, isFalse);
        expect(cubit.state.encrypted, isFalse);
      },
    );

    test('only a NONE header shows the not-encrypted note', () async {
      await open(network: snap(const [], header(none)));
      expect(cubit.state.knownPlain, isTrue);
      expect(cubit.isMls, isFalse);
    });

    test('a plaintext header never subscribes', () async {
      await open(network: snap(const [], header(none)));
      expect(port.calls, isNot(contains('watchThread')));
      expect(cubit.state.encrypted, isFalse);
    });

    test(
      'an empty ready thread alone never makes a thread encrypted',
      () async {
        for (final h in [header(none), header(unspecified)]) {
          await open(network: snap(const [], h));
          expect(cubit.state.encrypted, isFalse);
          expect(cubit.isMls, isFalse);
          expect(port.calls, isNot(contains('watchThread')));
          await cubit.close();
        }
      },
    );

    test('no port: nothing is subscribed and encryptedNoVault is true for an '
        'MLS header', () async {
      await open(network: snap(const [], header(mls)), withPort: false);
      expect(port.calls, isEmpty);
      expect(cubit.state.encrypted, isFalse);
      expect(cubit.state.encryptedNoVault, isTrue);
    });

    test('vault not ready: encryptedNoVault', () async {
      await open(network: snap(const [], header(mls)), usable: () => false);
      expect(port.calls, isNot(contains('watchThread')));
      expect(cubit.state.encryptedNoVault, isTrue);
      expect(cubit.state.encrypted, isFalse);
    });

    test('the vault becoming ready later subscribes', () async {
      var ready = false;
      await open(network: snap(const [], header(mls)), usable: () => ready);
      expect(cubit.state.encrypted, isFalse);
      ready = true;
      cubit.refreshVault();
      await pumpEventQueue();
      expect(cubit.state.encrypted, isTrue);
      expect(cubit.state.encryptedNoVault, isFalse);
      expect(port.calls.where((c) => c == 'watchThread'), hasLength(1));
    });

    test('offline start: no header, hasLocal true, the thread is encrypted '
        'from the vault', () async {
      port.local = {kThreadId};
      port.setThread(
        ref,
        EncryptedThread(
          conversationId: kThreadId,
          entries: [entry('a')],
          security: const ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
        ),
      );
      await open(cached: snap(const [], threadConv()));
      expect(cubit.state.encrypted, isTrue);
      expect(cubit.state.entries.single.id, 'a');
      expect(cubit.state.notice, isNotNull);
    });

    test('encrypted never returns to false', () async {
      await open(network: snap(const [], header(mls)));
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(const [], header(none)));
      await cubit.pull();
      cubit.refreshVault();
      expect(cubit.state.encrypted, isTrue);
      expect(cubit.state.knownPlain, isFalse);
    });

    test('a NONE header for a conversation whose cached row was encrypted '
        'keeps the thread encrypted and never shows the plain composer, for '
        'every vault status that is not ready', () async {
      for (final status in VaultStatus.values) {
        if (status == VaultStatus.ready) continue;
        final row = header(none)
          ..lastMessage = pb.MessagePreview(encrypted: true);
        await open(
          cached: snap(const [], row),
          network: snap(const [], header(none)),
          usable: () => status == VaultStatus.ready,
        );
        expect(cubit.isMls, isTrue, reason: '$status');
        expect(cubit.state.knownPlain, isFalse, reason: '$status');
        expect(cubit.state.encryptedNoVault, isTrue, reason: '$status');
        await cubit.close();
      }
    });

    test('a NONE header for a conversation with hasLocal true stays '
        'encrypted', () async {
      port.local = {kThreadId};
      await open(network: snap(const [], header(none)));
      expect(cubit.isMls, isTrue);
      expect(cubit.state.knownPlain, isFalse);
      expect(cubit.state.encrypted, isTrue);
    });

    test('an empty ready thread from the port for an MLS header shows the '
        'empty state with the composer per canSend', () async {
      await open(network: snap(const [], header(mls)));
      expect(cubit.state.encrypted, isTrue);
      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.security!.canSend, isTrue);
      expect(cubit.state.security!.state, ConversationEncryptionState.ready);
    });
  });

  group('paging, reset and closing', () {
    test('loadMore calls loadOlder', () async {
      port.setThread(
        ref,
        const EncryptedThread(
          hasMore: true,
          security: ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
        ),
      );
      await open(network: snap(const [], header(mls)));
      await cubit.loadMore();
      expect(port.calls.where((c) => c == 'loadOlder'), hasLength(1));
      verifyNever(() => repo.loadOlderMessages(any()));
      expect(cubit.state.loadingMore, isFalse);
    });

    test('loadMore does nothing without older rows', () async {
      await open(network: snap(const [], header(mls)));
      await cubit.loadMore();
      expect(port.calls, isNot(contains('loadOlder')));
    });

    ConversationSecurity canReset({bool sent = false}) => ConversationSecurity(
      state: ConversationEncryptionState.stuck,
      canSend: false,
      canReset: true,
      sentRequest: sent,
    );

    test('resetEncryption calls the port once, sets resetting, and maps a '
        'RateLimitedException to notice', () async {
      port.setThread(ref, EncryptedThread(security: canReset()));
      await open(network: snap(const [], header(mls)));
      port.failNextOn('resetConversation', const RateLimitedException('x'));
      final states = <bool>[];
      final sub = cubit.stream.listen((s) => states.add(s.resetting));
      final done = cubit.resetEncryption();
      await done;
      await sub.cancel();
      expect(port.resetConversations, [kThreadId]);
      expect(states, contains(true));
      expect(cubit.state.resetting, isFalse);
      // The typed failure is kept as resetError (the screen's snackbar).
      expect(cubit.state.resetError, isA<RateLimitedException>());
      await cubit.resetEncryption();
      expect(port.resetConversations, hasLength(2));
    });

    test('resetEncryption maps ResetRefusedException(notAccepted) and '
        'ResetRefusedException(peerHasNoDevice) to their two texts and clears '
        'resetting', () async {
      port.setThread(ref, EncryptedThread(security: canReset()));
      await open(network: snap(const [], header(mls)));
      for (final reason in ResetRefusal.values) {
        port.failNextOn('resetConversation', ResetRefusedException(reason));
        await cubit.resetEncryption();
        final error = cubit.state.resetError;
        expect(error, isA<ResetRefusedException>());
        expect((error! as ResetRefusedException).reason, reason);
        expect(cubit.state.resetting, isFalse);
      }
    });

    test(
      'resetEncryption is refused for a sent request and without canReset',
      () async {
        port.setThread(ref, EncryptedThread(security: canReset(sent: true)));
        await open(network: snap(const [], header(mls)));
        await cubit.resetEncryption();
        expect(port.resetConversations, isEmpty);
      },
    );

    test(
      'an unexpected reset error is reported as a fixed StateError',
      () async {
        port.setThread(ref, EncryptedThread(security: canReset()));
        await open(network: snap(const [], header(mls)));
        port.failNextOn('resetConversation', Exception('secret text'));
        await cubit.resetEncryption();
        expect(reported.single, isA<StateError>());
        expect(reported.single.toString(), isNot(contains('secret')));
      },
    );

    test('closing the cubit cancels the subscription', () async {
      await open(network: snap(const [], header(mls)));
      final before = cubit.state;
      await cubit.close();
      port.setThread(
        ref,
        EncryptedThread(
          entries: [entry('late')],
          security: const ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
        ),
      );
      await pumpEventQueue();
      expect(cubit.state.entries, before.entries);
      expect(reported, isEmpty);
    });

    test('the state prints no text', () async {
      port.setThread(
        ref,
        EncryptedThread(
          entries: [entry('a')],
          security: const ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
        ),
      );
      await open(network: snap(const [], header(mls)));
      expect(cubit.state.toString(), startsWith("Instance of 'ThreadState'"));
    });
  });
}
