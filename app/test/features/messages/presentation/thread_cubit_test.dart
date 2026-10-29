import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

class MockMessagingRepository extends Mock implements MessagingRepository {}

class _SeqUuid implements Uuid {
  int n = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #v4) return 'key-${++n}';
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late MockMessagingRepository repo;
  late FakeThreadPoller poller;
  late ThreadCubit cubit;
  late _SeqUuid uuid;

  ThreadSnapshot snap(
    List<pb.Message> messages, {
    pb.Conversation? conversation,
    bool more = false,
  }) => ThreadSnapshot(
    messages: messages,
    conversation: conversation ?? threadConv(),
    sinceToken: 's',
    olderPageToken: more ? 'older' : '',
  );

  /// Messages numbered 1..n, newest first, all from the peer.
  List<pb.Message> thread(int n) => msgs(1, n);

  ThreadCubit make({String? id}) => cubit = ThreadCubit(
    repository: repo,
    poller: poller,
    conversationId: id ?? kThreadId,
    uuid: uuid,
  );

  setUp(() {
    repo = MockMessagingRepository();
    poller = FakeThreadPoller();
    uuid = _SeqUuid();
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(
      () => repo.markConversationRead(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() => cubit.close());

  void stubOpen(ThreadSnapshot cached, ThreadSnapshot network) {
    when(() => repo.cachedThread(kThreadId)).thenAnswer((_) async => cached);
    when(() => repo.refreshThread(kThreadId)).thenAnswer((_) async => network);
  }

  int markCalls() => verify(
    () => repo.markConversationRead(
      idempotencyKey: any(named: 'idempotencyKey'),
      conversationId: kThreadId,
    ),
  ).callCount;

  group('ids', () {
    test('a malformed id is unavailable and sends nothing', () async {
      for (final id in ['', 'c1', 'A' * 32, 'g' * 32, '${'a' * 31}/']) {
        make(id: id);
        expect(cubit.state.status, ThreadStatus.unavailable, reason: id);
        await cubit.load();
        await cubit.close();
      }
      verifyNever(() => repo.cachedThread(any()));
      verifyNever(() => repo.refreshThread(any()));
      expect(isConversationId(hexId(0xabc)), isTrue);
    });
  });

  group('load', () {
    test('renders the cache, then the network; starts the poller', () async {
      final network = Completer<ThreadSnapshot>();
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(3)));
      when(() => repo.refreshThread(kThreadId))
          .thenAnswer((_) => network.future);
      make();
      final states = <ThreadState>[];
      final sub = cubit.stream.listen(states.add);

      final loading = cubit.load();
      await pumpEventQueue();

      expect(cubit.state.status, ThreadStatus.ready);
      expect(cubit.state.messages, hasLength(3));
      expect(cubit.state.refreshing, isTrue);
      expect(poller.starts, 1);

      network.complete(snap(thread(5)));
      await loading;

      expect(cubit.state.messages, hasLength(5));
      expect(cubit.state.refreshing, isFalse);
      await sub.cancel();
      verify(() => repo.refreshThread(kThreadId)).called(1);
    });

    test('with no cache it stays loading until the network answers', () async {
      final network = Completer<ThreadSnapshot>();
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => const ThreadSnapshot());
      when(() => repo.refreshThread(kThreadId))
          .thenAnswer((_) => network.future);
      make();

      final loading = cubit.load();
      await pumpEventQueue();
      expect(cubit.state.status, ThreadStatus.loading);

      network.complete(snap(thread(2)));
      await loading;
      expect(cubit.state.status, ThreadStatus.ready);
    });

    test('NOT_FOUND is unavailable and stops the poller', () async {
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => const ThreadSnapshot());
      when(() => repo.refreshThread(kThreadId))
          .thenThrow(const NotFoundException('nope'));
      make();

      await cubit.load();

      expect(cubit.state.status, ThreadStatus.unavailable);
      expect(poller.running, isFalse);
    });

    test('a failure with nothing cached blocks; Retry recovers', () async {
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => const ThreadSnapshot());
      when(() => repo.refreshThread(kThreadId))
          .thenThrow(const NetworkException('offline'));
      make();

      await cubit.load();
      expect(cubit.state.status, ThreadStatus.error);
      expect(cubit.state.error, isA<NetworkException>());

      when(() => repo.refreshThread(kThreadId))
          .thenAnswer((_) async => snap(thread(1)));
      await cubit.refresh();
      expect(cubit.state.status, ThreadStatus.ready);
      expect(cubit.state.error, isNull);
    });

    test('a failure over cached messages is a notice', () async {
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(2)));
      when(() => repo.refreshThread(kThreadId))
          .thenThrow(const NetworkException('offline'));
      make();

      await cubit.load();

      expect(cubit.state.status, ThreadStatus.ready);
      expect(cubit.state.messages, hasLength(2));
      expect(cubit.state.notice, isA<NetworkException>());
    });

    test(
      'a held RATE_LIMITED answer sends nothing and shows a notice',
      () async {
        when(() => repo.cachedThread(kThreadId))
            .thenAnswer((_) async => snap(thread(2)));
        when(() => repo.rateLimitedFor())
            .thenReturn(const RateLimitedException('slow down'));
        make();

        await cubit.load();

        verifyNever(() => repo.refreshThread(any()));
        expect(cubit.state.notice, isA<RateLimitedException>());
      },
    );

    test('read-only follows can_reply of the header', () async {
      stubOpen(
        snap(thread(1), conversation: threadConv(canReply: false)),
        snap(thread(1), conversation: threadConv(canReply: false)),
      );
      make();
      expect(cubit.state.readOnly, isFalse);

      await cubit.load();
      expect(cubit.state.readOnly, isTrue);
    });
  });

  group('onOpenedUnread (W7-19, the Messages badge)', () {
    ThreadCubit makeReporting(List<String> reported) => cubit = ThreadCubit(
      repository: repo,
      poller: poller,
      conversationId: kThreadId,
      uuid: uuid,
      onOpenedUnread: reported.add,
    );

    test('fires once when the cached header says unread', () async {
      stubOpen(
        snap(thread(3), conversation: threadConv(unread: 2)),
        snap(thread(3), conversation: threadConv(unread: 2)),
      );
      final reported = <String>[];
      makeReporting(reported);

      await cubit.load();
      await pumpEventQueue();

      expect(reported, [kThreadId]);
    });

    test(
      'fires when only the network header says unread (nothing cached)',
      () async {
        stubOpen(
          const ThreadSnapshot(),
          snap(thread(3), conversation: threadConv(unread: 1)),
        );
        final reported = <String>[];
        makeReporting(reported);

        await cubit.load();

        expect(reported, [kThreadId]);
      },
    );

    test('not for a conversation that was read when opened', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      final reported = <String>[];
      makeReporting(reported);

      await cubit.load();
      await pumpEventQueue();

      expect(reported, isEmpty);
    });

    test('not for messages that arrive while the thread is open', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      final reported = <String>[];
      makeReporting(reported);
      await cubit.load();
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId)).thenAnswer(
        (_) async => snap(thread(4), conversation: threadConv(unread: 1)),
      );

      await cubit.pull();
      await pumpEventQueue();

      expect(reported, isEmpty);
    });

    test('once only, however many refreshes see the unread count', () async {
      stubOpen(
        snap(thread(3), conversation: threadConv(unread: 2)),
        snap(thread(3), conversation: threadConv(unread: 2)),
      );
      final reported = <String>[];
      makeReporting(reported);

      await cubit.load();
      await cubit.refresh();
      await pumpEventQueue();

      expect(reported, [kThreadId]);
    });
  });

  group('mark read', () {
    test('on open with unread above 0, once, with one key', () async {
      stubOpen(
        snap(thread(3), conversation: threadConv(unread: 2)),
        snap(thread(3), conversation: threadConv(unread: 2)),
      );
      make();

      await cubit.load();
      await pumpEventQueue();

      final captured = verify(
        () => repo.markConversationRead(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).captured;
      expect(captured, ['key-1']);
    });

    test('not with unread 0', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();

      await cubit.load();
      await pumpEventQueue();

      verifyNever(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });

    test('a message from the peer arriving while visible marks read', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(4)));

      final result = await cubit.pull();
      await pumpEventQueue();

      expect(result.newMessages, isTrue);
      expect(cubit.state.messages, hasLength(4));
      expect(markCalls(), 1);
    });

    test('the caller\'s own new message does not mark read', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      final withOwn = [msg(9, fromSelf: true, secondsAgo: 0), ...thread(3)];
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(withOwn));

      await cubit.pull();
      await pumpEventQueue();

      expect(cubit.state.messages, hasLength(4));
      verifyNever(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });

    test('not while hidden; on becoming visible', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      cubit.setVisible(false);
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(4)));

      await cubit.pull();
      await pumpEventQueue();
      verifyNever(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );

      cubit.setVisible(true);
      await pumpEventQueue();
      expect(markCalls(), 1);
      expect(poller.visibility, [false, true]);
    });

    test('a failed mark keeps the key for the next attempt', () async {
      stubOpen(
        snap(thread(3), conversation: threadConv(unread: 1)),
        snap(thread(3), conversation: threadConv(unread: 1)),
      );
      var fail = true;
      when(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async {
        if (fail) throw const NetworkException('offline');
      });
      make();
      await cubit.load();
      await pumpEventQueue();
      expect(cubit.state.status, ThreadStatus.ready);

      fail = false;
      cubit.setVisible(false);
      cubit.setVisible(true);
      await pumpEventQueue();

      final keys = verify(
        () => repo.markConversationRead(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).captured;
      expect(keys, ['key-1', 'key-1']);
    });
  });

  group('polling', () {
    test('a pull at the bottom shows new messages at once', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(5)));

      await cubit.pull();

      expect(cubit.state.messages, hasLength(5));
      expect(cubit.state.pendingNew, 0);
    });

    test('a pull while scrolled up is held back, then shown', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      cubit.setAtBottom(false);
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(5)));

      await cubit.pull();

      expect(cubit.state.messages, hasLength(3));
      expect(cubit.state.pendingNew, 2);

      cubit.showNew();
      expect(cubit.state.messages, hasLength(5));
      expect(cubit.state.pendingNew, 0);
    });

    test('reaching the bottom shows what was held back', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      cubit.setAtBottom(false);
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snap(thread(4)));
      await cubit.pull();
      expect(cubit.state.pendingNew, 1);

      cubit.setAtBottom(true);

      expect(cubit.state.messages, hasLength(4));
      expect(cubit.state.pendingNew, 0);
    });

    test('a poll with nothing new does not touch the cache', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      clearInteractions(repo);
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: false));

      final result = await cubit.pull();

      expect(result.newMessages, isFalse);
      verifyNever(() => repo.cachedThread(any()));
    });

    test('RATE_LIMITED is rethrown for the poller and shown', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      when(() => repo.pollThread(kThreadId)).thenThrow(
        const RateLimitedException('slow', retryAfter: Duration(seconds: 30)),
      );

      await expectLater(cubit.pull(), throwsA(isA<RateLimitedException>()));

      expect(cubit.state.notice, isA<RateLimitedException>());
      expect(cubit.state.status, ThreadStatus.ready);
    });

    test('another failure is a notice; the next good poll clears it', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      when(() => repo.pollThread(kThreadId))
          .thenThrow(const NetworkException('offline'));
      await cubit.pull();
      expect(cubit.state.notice, isA<NetworkException>());

      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: false));
      await cubit.pull();
      expect(cubit.state.notice, isNull);
    });

    test('NOT_FOUND on a poll makes the screen unavailable', () async {
      stubOpen(snap(thread(3)), snap(thread(3)));
      make();
      await cubit.load();
      when(() => repo.pollThread(kThreadId))
          .thenThrow(const NotFoundException('gone'));

      await cubit.pull();

      expect(cubit.state.status, ThreadStatus.unavailable);
      expect(poller.running, isFalse);
    });

    test('visibility, input and push are forwarded to the poller', () async {
      make();

      cubit.setVisible(false);
      cubit.setVisible(false);
      cubit.setVisible(true);
      cubit.noteInput();
      cubit.onPush();

      expect(poller.visibility, [false, true]);
      expect(poller.inputs, 1);
      expect(poller.pushes, 1);
    });

    test('closing disposes the poller', () async {
      make();
      await cubit.close();
      expect(poller.disposed, isTrue);
    });
  });

  group('older pages', () {
    test('loadMore appends the page and keeps the order', () async {
      stubOpen(snap(msgs(6, 10), more: true), snap(msgs(6, 10), more: true));
      when(() => repo.loadOlderMessages(kThreadId))
          .thenAnswer((_) async => snap(msgs(1, 10)));
      make();
      await cubit.load();
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();

      expect(cubit.state.messages, hasLength(10));
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.messages.first.id, hexId(10));
      expect(cubit.state.messages.last.id, hexId(1));
    });

    test('a second loadMore while one runs is ignored', () async {
      stubOpen(snap(msgs(6, 10), more: true), snap(msgs(6, 10), more: true));
      final page = Completer<ThreadSnapshot>();
      when(() => repo.loadOlderMessages(kThreadId))
          .thenAnswer((_) => page.future);
      make();
      await cubit.load();

      final first = cubit.loadMore();
      await cubit.loadMore();
      page.complete(snap(msgs(1, 10)));
      await first;

      verify(() => repo.loadOlderMessages(kThreadId)).called(1);
    });

    test('a failure shows the retry; retry loads', () async {
      stubOpen(snap(msgs(6, 10), more: true), snap(msgs(6, 10), more: true));
      when(() => repo.loadOlderMessages(kThreadId))
          .thenThrow(const NetworkException('offline'));
      make();
      await cubit.load();

      await cubit.loadMore();
      expect(cubit.state.loadMoreFailed, isTrue);
      expect(cubit.state.loadingMore, isFalse);

      // No automatic retry while it is failed.
      await cubit.loadMore();
      verify(() => repo.loadOlderMessages(kThreadId)).called(1);

      when(() => repo.loadOlderMessages(kThreadId))
          .thenAnswer((_) async => snap(msgs(1, 10)));
      await cubit.retryLoadMore();
      expect(cubit.state.loadMoreFailed, isFalse);
      expect(cubit.state.messages, hasLength(10));
    });

    test('older messages do not count as new', () async {
      stubOpen(snap(msgs(6, 10), more: true), snap(msgs(6, 10), more: true));
      when(() => repo.loadOlderMessages(kThreadId))
          .thenAnswer((_) async => snap(msgs(1, 10)));
      make();
      await cubit.load();

      await cubit.loadMore();
      await pumpEventQueue();

      verifyNever(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });
  });

  group('delete and block', () {
    test(
      'delete calls the repository, stops the poller, returns null',
      () async {
        when(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        ).thenAnswer((_) async {});
        make();

        final error = await cubit.deleteConversation();

        expect(error, isNull);
        expect(poller.stops, 1);
        expect(cubit.state.deleting, isFalse);
      },
    );

    test(
      'a failed delete returns the error and retries with the same key',
      () async {
        var fail = true;
        when(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        ).thenAnswer((_) async {
          if (fail) throw const NetworkException('offline');
        });
        make();

        expect(await cubit.deleteConversation(), isA<NetworkException>());
        fail = false;
        expect(await cubit.deleteConversation(), isNull);

        final keys = verify(
          () => repo.deleteConversation(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).captured;
        expect(keys, ['key-1', 'key-1']);
      },
    );

    test('blocking the peer makes the thread read-only at once', () async {
      stubOpen(snap(thread(1)), snap(thread(1)));
      make();
      await cubit.load();
      expect(cubit.state.readOnly, isFalse);

      cubit.markPeerBlocked();

      expect(cubit.state.readOnly, isTrue);
    });
  });
}
