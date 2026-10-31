import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/domain/thread_push_coverage.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
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
    when(() => repo.dropBlockedRequest(any())).thenAnswer((_) async {});
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
      'not when nothing is cached and the first page says 0 (read)',
      () async {
        stubOpen(const ThreadSnapshot(), snap(thread(3)).asFirstPage());
        final reported = <String>[];
        makeReporting(reported);

        await cubit.load();
        await pumpEventQueue();

        expect(reported, isEmpty);
        verifyNever(
          () => repo.markConversationRead(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );
      },
    );

    // W7-27 / W7-19 F-5: a thread opened from a push with nothing cached gets
    // the count from the first ListMessages page.
    group('cold open from a push, nothing cached (W7-27)', () {
      late MessagesBadgeCubit badge;

      ThreadCubit makeWithBadge() => cubit = ThreadCubit(
        repository: repo,
        poller: poller,
        conversationId: kThreadId,
        uuid: uuid,
        onOpenedUnread: badge.clearUnread,
      );

      setUp(() => badge = MessagesBadgeCubit(3));
      tearDown(() => badge.close());

      test(
        'server count 2: one mark-read and the badge lowered by one',
        () async {
          stubOpen(
            const ThreadSnapshot(),
            snap(thread(3), conversation: threadConv(unread: 2)).asFirstPage(),
          );
          makeWithBadge();

          await cubit.load();
          await pumpEventQueue();

          expect(markCalls(), 1);
          expect(badge.state, 2);
        },
      );

      test(
        'a REQUESTS conversation: mark-read, badge unchanged (D10)',
        () async {
          stubOpen(
            const ThreadSnapshot(),
            snap(
              thread(3),
              conversation: threadConv(
                unread: 2,
                state: ConversationState.CONVERSATION_STATE_REQUEST,
                folder: Folder.FOLDER_REQUESTS,
              ),
            ).asFirstPage(),
          );
          makeWithBadge();

          await cubit.load();
          await pumpEventQueue();

          expect(markCalls(), 1);
          expect(badge.state, 3);
        },
      );

      test('first page 0 over a cached unread row: no mark-read, the badge '
          'is lowered once and not again', () async {
        stubOpen(
          snap(thread(3), conversation: threadConv(unread: 3)),
          snap(thread(3), conversation: threadConv()).asFirstPage(),
        );
        makeWithBadge();

        await cubit.load();
        await pumpEventQueue();
        await cubit.refresh();
        await pumpEventQueue();

        verifyNever(
          () => repo.markConversationRead(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );
        expect(badge.state, 2);
      });

      test('a since refresh over a cached unread row still marks it read '
          '(the cached count may be stale, as before)', () async {
        stubOpen(
          snap(thread(3), conversation: threadConv(unread: 3)),
          snap(thread(3), conversation: threadConv(unread: 3)),
        );
        makeWithBadge();

        await cubit.load();
        await pumpEventQueue();

        expect(markCalls(), 1);
        expect(badge.state, 2);
      });
    });

    test('fires from the cached Inbox row a since refresh kept: a since page '
        'has no header, so the cached count stands', () async {
      // Not marked as a first page (mergeThreadHeader keeps the cached count
      // on any page but the first).
      stubOpen(
        const ThreadSnapshot(),
        snap(thread(3), conversation: threadConv(unread: 2)),
      );
      final reported = <String>[];
      makeReporting(reported);

      await cubit.load();
      await pumpEventQueue();

      expect(reported, [kThreadId]);
    });

    test('not for a request: requests never count (D10, S1)', () async {
      final request = threadConv(
        unread: 2,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
        folder: Folder.FOLDER_REQUESTS,
      );
      stubOpen(
        snap(thread(3), conversation: request),
        snap(thread(3), conversation: request),
      );
      final reported = <String>[];
      makeReporting(reported);

      await cubit.load();
      await cubit.refresh();
      await pumpEventQueue();

      expect(reported, isEmpty);
    });

    test('a request opened unread still marks it read', () async {
      final request = threadConv(
        unread: 2,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
        folder: Folder.FOLDER_REQUESTS,
      );
      stubOpen(
        snap(thread(3), conversation: request),
        snap(thread(3), conversation: request),
      );
      makeReporting(<String>[]);

      await cubit.load();
      await pumpEventQueue();

      expect(markCalls(), 1);
    });

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

    test('a successful delete clears the key: a later delete gets a fresh '
        'one', () async {
      when(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async {});
      make();

      expect(await cubit.deleteConversation(), isNull);
      expect(await cubit.deleteConversation(), isNull);

      final keys = verify(
        () => repo.deleteConversation(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).captured;
      expect(keys, ['key-1', 'key-2']);
    });

    test(
      'a failure after a success still reuses its own key on retry',
      () async {
        var calls = 0;
        when(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        ).thenAnswer((_) async {
          calls++;
          if (calls == 2) throw const NetworkException('raw-offline');
        });
        make();

        expect(await cubit.deleteConversation(), isNull); // key-1
        expect(
          await cubit.deleteConversation(),
          isA<NetworkException>(),
        ); // key-2
        expect(await cubit.deleteConversation(), isNull); // key-2 again

        final keys = verify(
          () => repo.deleteConversation(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).captured;
        expect(keys, ['key-1', 'key-2', 'key-2']);
      },
    );

    group('acceptRequest (W7-18)', () {
      pb.Conversation received() =>
          threadConv(state: ConversationState.CONVERSATION_STATE_REQUEST)
              .deepCopy()
            ..folder = Folder.FOLDER_REQUESTS;

      void stubAccept(Future<void> Function() answer) => when(
        () => repo.acceptMessageRequest(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) => answer());

      test('moves the header to an accepted inbox conversation', () async {
        stubOpen(
          snap(thread(1), conversation: received()),
          snap(thread(1), conversation: received()),
        );
        stubAccept(() async {});
        make();
        await cubit.load();
        expect(cubit.state.conversation!.folder, Folder.FOLDER_REQUESTS);

        final error = await cubit.acceptRequest();

        expect(error, isNull);
        expect(
          cubit.state.conversation!.state,
          ConversationState.CONVERSATION_STATE_ACCEPTED,
        );
        expect(cubit.state.conversation!.folder, Folder.FOLDER_INBOX);
        expect(cubit.state.accepting, isFalse);
        verify(
          () => repo.acceptMessageRequest(
            idempotencyKey: 'key-1',
            conversationId: kThreadId,
          ),
        ).called(1);
      });

      test('a failure returns the error, keeps the request, retries with the '
          'same key', () async {
        stubOpen(
          snap(thread(1), conversation: received()),
          snap(thread(1), conversation: received()),
        );
        var fail = true;
        stubAccept(() async {
          if (fail) throw const NetworkException('offline');
        });
        make();
        await cubit.load();

        expect(await cubit.acceptRequest(), isA<NetworkException>());
        expect(cubit.state.accepting, isFalse);
        expect(
          cubit.state.conversation!.state,
          ConversationState.CONVERSATION_STATE_REQUEST,
        );

        fail = false;
        expect(await cubit.acceptRequest(), isNull);
        final keys = verify(
          () => repo.acceptMessageRequest(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).captured;
        expect(keys, ['key-1', 'key-1']);
      });

      test('after Accept the push coverage rule sees an accepted inbox '
          'conversation, so the poller moves to its 30 s hot interval at the '
          'next schedule (no extra request)', () async {
        stubOpen(
          snap(thread(1), conversation: received()),
          snap(thread(1), conversation: received()),
        );
        stubAccept(() async {});
        make();
        await cubit.load();
        bool covered() => pushCoversThread(
          deviceRegistered: true,
          notificationsEnabled: true,
          conversation: cubit.state.conversation,
        );
        expect(covered(), isFalse, reason: 'a request polls at 15 s');
        clearInteractions(repo);
        stubAccept(() async {});

        await cubit.acceptRequest();

        expect(covered(), isTrue);
        verifyNever(() => repo.refreshThread(any()));
      });

      test(
        'NOT_FOUND returns the error and makes the thread unavailable',
        () async {
          stubOpen(
            snap(thread(1), conversation: received()),
            snap(thread(1), conversation: received()),
          );
          stubAccept(
            () async => throw const NotFoundException('raw-not-found'),
          );
          make();
          await cubit.load();
          final stopsBefore = poller.stops;

          final error = await cubit.acceptRequest();

          expect(error, isA<NotFoundException>());
          expect(cubit.state.status, ThreadStatus.unavailable);
          expect(cubit.state.accepting, isFalse);
          expect(poller.stops, greaterThan(stopsBefore));
        },
      );

      test('a second tap while it runs sends '
          'nothing', () async {
        stubOpen(
          snap(thread(1), conversation: received()),
          snap(thread(1), conversation: received()),
        );
        final gate = Completer<void>();
        stubAccept(() => gate.future);
        make();
        await cubit.load();

        final first = cubit.acceptRequest();
        await pumpEventQueue();
        expect(cubit.state.accepting, isTrue);
        expect(await cubit.acceptRequest(), isNull);
        gate.complete();
        await first;

        verify(
          () => repo.acceptMessageRequest(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).called(1);
      });
    });

    test('blocking the peer makes the thread read-only at once', () async {
      stubOpen(snap(thread(1)), snap(thread(1)));
      make();
      await cubit.load();
      expect(cubit.state.readOnly, isFalse);

      cubit.markPeerBlocked();

      expect(cubit.state.readOnly, isTrue);
    });

    test('blocking asks the repository to drop a requester\'s cached row '
        'once', () async {
      stubOpen(snap(thread(1)), snap(thread(1)));
      make();
      await cubit.load();

      cubit.markPeerBlocked();
      cubit.markPeerBlocked();
      await pumpEventQueue();

      verify(() => repo.dropBlockedRequest(kThreadId)).called(1);
    });

    test('a failing cache drop is reported, not thrown, and the thread is '
        'still read-only', () async {
      stubOpen(snap(thread(1)), snap(thread(1)));
      when(() => repo.dropBlockedRequest(any()))
          .thenAnswer((_) async => throw StateError('raw-disk'));
      final reported = <Object>[];
      cubit = ThreadCubit(
        repository: repo,
        poller: poller,
        conversationId: kThreadId,
        uuid: uuid,
        onUnexpectedError: (e, s) => reported.add(e),
      );
      await cubit.load();

      cubit.markPeerBlocked();
      await pumpEventQueue();

      expect(cubit.state.readOnly, isTrue);
      expect(reported, hasLength(1));
    });
  });

  group('a request the caller sent (W7-25b)', () {
    pb.Conversation sent() =>
        threadConv(state: ConversationState.CONVERSATION_STATE_REQUEST);
    pb.Conversation accepted() => threadConv();
    final own = [msg(1, fromSelf: true, secondsAgo: 100)];

    test('a reopen from the cache keeps REQUEST in INBOX', () async {
      stubOpen(
        snap(own, conversation: sent()),
        snap(own, conversation: sent()),
      );
      make();
      await cubit.load();

      expect(isSentRequest(cubit.state.conversation!), isTrue);
    });

    test(
      'a row change flips the header to ACCEPTED without a request',
      () async {
        final changes = StreamController<void>.broadcast();
        addTearDown(changes.close);
        when(() => repo.conversationsChanged).thenAnswer((_) => changes.stream);
        stubOpen(
          snap(own, conversation: sent()),
          snap(own, conversation: sent()),
        );
        make();
        await cubit.load();
        when(() => repo.cachedConversation(kThreadId))
            .thenAnswer((_) async => accepted());

        changes.add(null);
        await pumpEventQueue();

        expect(
          cubit.state.conversation!.state,
          ConversationState.CONVERSATION_STATE_ACCEPTED,
        );
        expect(isSentRequest(cubit.state.conversation!), isFalse);
        verifyNever(() => repo.pollThread(any()));
        verify(() => repo.refreshThread(kThreadId)).called(1); // the open only
      },
    );

    test('a row change that says the same changes nothing', () async {
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      when(() => repo.conversationsChanged).thenAnswer((_) => changes.stream);
      stubOpen(
        snap(own, conversation: sent()),
        snap(own, conversation: sent()),
      );
      make();
      await cubit.load();
      when(() => repo.cachedConversation(kThreadId))
          .thenAnswer((_) async => sent());
      final states = <ThreadState>[];
      final sub = cubit.stream.listen(states.add);

      changes.add(null);
      await pumpEventQueue();
      await sub.cancel();

      expect(states, isEmpty);
    });

    test('can_reply false from the row ends the waiting note', () async {
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      when(() => repo.conversationsChanged).thenAnswer((_) => changes.stream);
      stubOpen(
        snap(own, conversation: sent()),
        snap(own, conversation: sent()),
      );
      make();
      await cubit.load();
      when(() => repo.cachedConversation(kThreadId))
          .thenAnswer((_) async => sent().deepCopy()..canReply = false);

      changes.add(null);
      await pumpEventQueue();

      expect(isSentRequest(cubit.state.conversation!), isFalse);
      expect(cubit.state.readOnly, isTrue);
    });

    test(
      "the peer's message in a poll marks it ACCEPTED here and in the row",
      () async {
        stubOpen(
          snap(own, conversation: sent()),
          snap(own, conversation: sent()),
        );
        make();
        await cubit.load();
        final reply = msg(2, secondsAgo: 5);
        when(() => repo.pollThread(kThreadId))
            .thenAnswer((_) async => const PollResult(newMessages: true));
        when(
          () => repo.cachedThread(kThreadId),
        ).thenAnswer((_) async => snap([reply, ...own], conversation: sent()));

        await cubit.pull();

        expect(
          cubit.state.conversation!.state,
          ConversationState.CONVERSATION_STATE_ACCEPTED,
        );
        expect(cubit.state.messages, hasLength(2));
        verify(() => repo.noteSentRequestAnswered(kThreadId)).called(1);
      },
    );

    test('the caller\'s own new message does not answer the request', () async {
      stubOpen(
        snap(own, conversation: sent()),
        snap(own, conversation: sent()),
      );
      make();
      await cubit.load();
      final second = msg(2, fromSelf: true, secondsAgo: 5);
      when(() => repo.pollThread(kThreadId))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      when(
        () => repo.cachedThread(kThreadId),
      ).thenAnswer((_) async => snap([second, ...own], conversation: sent()));

      await cubit.pull();

      expect(isSentRequest(cubit.state.conversation!), isTrue);
      verifyNever(() => repo.noteSentRequestAnswered(any()));
    });

    test(
      'a received request is never marked answered by a peer message',
      () async {
        final received = threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          folder: Folder.FOLDER_REQUESTS,
        );
        stubOpen(
          snap(thread(1), conversation: received),
          snap(thread(1), conversation: received),
        );
        make();
        await cubit.load();
        when(() => repo.pollThread(kThreadId))
            .thenAnswer((_) async => const PollResult(newMessages: true));
        when(() => repo.cachedThread(kThreadId))
            .thenAnswer((_) async => snap(thread(2), conversation: received));

        await cubit.pull();

        expect(isReceivedRequest(cubit.state.conversation!), isTrue);
        verifyNever(() => repo.noteSentRequestAnswered(any()));
      },
    );
  });
}
