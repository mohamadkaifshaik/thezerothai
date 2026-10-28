import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/data/timer_thread_poller.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

class _MockMessagingRepository extends Mock implements MessagingRepository {}

/// `ThreadCubit` + the real `TimerThreadPoller` on a fake clock (W7-15): the
/// wiring `ThreadScreen` builds, without a widget.
void main() {
  ThreadSnapshot snap(List<pb.Message> messages) => ThreadSnapshot(
    messages: messages,
    conversation: threadConv(),
    sinceToken: 's',
  );

  late _MockMessagingRepository repo;
  late List<pb.Message> stored;
  late int polls;
  late PollResult Function() nextPoll;

  setUp(() {
    repo = _MockMessagingRepository();
    stored = msgs(1, 3);
    polls = 0;
    nextPoll = () => const PollResult(newMessages: false);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.cachedThread(any())).thenAnswer((_) async => snap(stored));
    when(() => repo.refreshThread(any())).thenAnswer((_) async => snap(stored));
    when(() => repo.pollThread(any())).thenAnswer((_) async {
      polls++;
      return nextPoll();
    });
    when(
      () => repo.markConversationRead(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) async {});
  });

  (ThreadCubit, TimerThreadPoller, RateLimitHold) build(FakeAsync async) {
    final hold = RateLimitHold(monotonic: () => async.elapsed);
    late final ThreadCubit cubit;
    final poller = TimerThreadPoller(
      pull: () => cubit.pull(),
      rateLimitHold: hold,
      monotonic: () => async.elapsed,
    );
    cubit = ThreadCubit(
      repository: repo,
      poller: poller,
      conversationId: kThreadId,
    );
    return (cubit, poller, hold);
  }

  void elapse(FakeAsync async, Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  test(
    'open does not pull; the first poll is 15 s later and is one request',
    () {
      fakeAsync((async) {
        final (cubit, poller, _) = build(async);
        cubit.load();
        async.flushMicrotasks();

        expect(polls, 0);
        expect(poller.isRunning, isTrue);
        elapse(async, const Duration(seconds: 14));
        expect(polls, 0);
        elapse(async, const Duration(seconds: 1));
        expect(polls, 1);
        cubit.close();
      });
    },
  );

  test('a poll with a new message reaches the screen state and marks read', () {
    fakeAsync((async) {
      final (cubit, _, _) = build(async);
      cubit.load();
      async.flushMicrotasks();
      stored = [msg(4, secondsAgo: 0), ...stored];
      nextPoll = () => const PollResult(newMessages: true);

      elapse(async, const Duration(seconds: 15));

      expect(cubit.state.messages, hasLength(4));
      verify(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
      cubit.close();
    });
  });

  test('hidden: 0 polls for ten minutes; visible again: one at once', () {
    fakeAsync((async) {
      final (cubit, _, _) = build(async);
      cubit.load();
      async.flushMicrotasks();

      cubit.setVisible(false);
      elapse(async, const Duration(minutes: 10));
      expect(polls, 0);

      cubit.setVisible(true);
      async.flushMicrotasks();
      expect(polls, 1);
      cubit.close();
    });
  });

  test('input keeps polling past the 5 minute idle stop', () {
    fakeAsync((async) {
      final (cubit, poller, _) = build(async);
      cubit.load();
      async.flushMicrotasks();

      elapse(async, const Duration(minutes: 6));
      expect(poller.isRunning, isFalse, reason: 'idle for 5 minutes stops it');
      final stopped = polls;
      elapse(async, const Duration(minutes: 3));
      expect(polls, stopped);

      cubit.noteInput();
      elapse(async, const Duration(seconds: 15));
      expect(polls, stopped + 1);
      cubit.close();
    });
  });

  test('a push pulls at once', () {
    fakeAsync((async) {
      final (cubit, _, _) = build(async);
      cubit.load();
      async.flushMicrotasks();

      cubit.onPush();
      async.flushMicrotasks();

      expect(polls, 1);
      cubit.close();
    });
  });

  test('RATE_LIMITED pauses polling through the shared hold', () {
    fakeAsync((async) {
      final (cubit, _, hold) = build(async);
      cubit.load();
      async.flushMicrotasks();
      var limited = true;
      when(() => repo.pollThread(any())).thenAnswer((_) async {
        polls++;
        if (limited) {
          throw const RateLimitedException(
            'slow down',
            retryAfter: Duration(minutes: 2),
          );
        }
        return const PollResult(newMessages: false);
      });

      elapse(async, const Duration(seconds: 15));
      expect(polls, 1);
      expect(hold.check(), isNotNull);

      // Nothing is pulled while it is held.
      elapse(async, const Duration(seconds: 90));
      expect(polls, 1);

      limited = false;
      elapse(async, const Duration(seconds: 60));
      expect(polls, greaterThanOrEqualTo(2));
      cubit.close();
    });
  });

  test('closing the screen stops the timers', () {
    fakeAsync((async) {
      final (cubit, poller, _) = build(async);
      cubit.load();
      async.flushMicrotasks();

      cubit.close();
      elapse(async, const Duration(minutes: 5));

      expect(polls, 0);
      expect(poller.isRunning, isFalse);
    });
  });
}
