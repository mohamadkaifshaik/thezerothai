import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

/// W7-19: the Messages badge. Counts conversations with unread messages,
/// seeded by GetMe, moved locally by foreground pushes and by opening a
/// conversation; never calls the API.
void main() {
  final a = 'a' * 32;
  final b = 'b' * 32;
  final c = 'c' * 32;

  late MessagesBadgeCubit cubit;

  setUp(() => cubit = MessagesBadgeCubit());
  tearDown(() => cubit.close());

  group('seed', () {
    test('sets the count; a negative count is 0', () {
      cubit.seed(3);
      expect(cubit.state, 3);
      cubit.seed(-4);
      expect(cubit.state, 0);
    });

    test('starts from the constructor value', () {
      expect(MessagesBadgeCubit(5).state, 5);
    });

    test('a fresh seed forgets local bookkeeping: the server is the truth', () {
      cubit
        ..seed(1)
        ..onMessagePush(a);
      expect(cubit.state, 2);

      cubit.seed(1);
      expect(cubit.state, 1);
      // Counted again after the seed.
      expect(cubit.onMessagePush(a), isTrue);
      expect(cubit.state, 2);
    });

    test('is ignored once closed', () async {
      final closed = MessagesBadgeCubit(2);
      await closed.close();
      closed.seed(9); // must not throw
      expect(closed.state, 2);
    });
  });

  group('foreground message push', () {
    test('a conversation that is not open adds one', () {
      cubit.seed(2);
      expect(cubit.onMessagePush(a), isTrue);
      expect(cubit.state, 3);
    });

    test('is counted per conversation, not per push', () {
      expect(cubit.onMessagePush(a), isTrue);
      expect(cubit.onMessagePush(a), isFalse);
      expect(cubit.onMessagePush(a), isFalse);
      expect(cubit.state, 1);

      expect(cubit.onMessagePush(b), isTrue);
      expect(cubit.state, 2);
    });

    test('an open conversation is not counted (the thread polls instead)', () {
      cubit.seed(2);
      cubit.opened(a);
      expect(cubit.onMessagePush(a), isFalse);
      expect(cubit.state, 2);
      // Another conversation still counts while this one is open.
      expect(cubit.onMessagePush(b), isTrue);
      expect(cubit.state, 3);
    });

    test('counts again once the conversation was closed', () {
      cubit
        ..opened(a)
        ..closed(a);
      expect(cubit.onMessagePush(a), isTrue);
      expect(cubit.state, 1);
    });

    test('an empty conversation id is ignored', () {
      expect(cubit.onMessagePush(''), isFalse);
      expect(cubit.state, 0);
    });
  });

  group('open and close', () {
    test('opening a conversation a push counted takes it out again', () {
      cubit
        ..seed(1)
        ..onMessagePush(a);
      expect(cubit.state, 2);

      cubit.opened(a);
      expect(cubit.state, 1);
    });

    test('opening a conversation nothing counted changes nothing', () {
      cubit.seed(3);
      cubit.opened(a);
      expect(cubit.state, 3);
    });

    test(
      'open threads are counted: two on the stack, one closed, still open',
      () {
        cubit
          ..opened(a)
          ..opened(a)
          ..closed(a);
        expect(cubit.onMessagePush(a), isFalse);

        cubit.closed(a);
        expect(cubit.onMessagePush(a), isTrue);
      },
    );

    test('closing what was never opened does nothing', () {
      cubit.closed(a);
      expect(cubit.onMessagePush(a), isTrue);
    });
  });

  group('clearUnread (the thread found it unread on open)', () {
    test('takes the conversation out of the count, once', () {
      cubit.seed(3);
      cubit.clearUnread(a);
      expect(cubit.state, 2);
      cubit.clearUnread(a);
      expect(cubit.state, 2);
    });

    test('three seeded conversations opened one by one reach zero', () {
      cubit.seed(3);
      for (final id in [a, b, c]) {
        cubit.opened(id);
        cubit.clearUnread(id);
        cubit.closed(id);
      }
      expect(cubit.state, 0);
    });

    test('never goes below zero', () {
      cubit.clearUnread(a);
      expect(cubit.state, 0);
    });

    test('opened then clearUnread for a pushed conversation drops it once', () {
      cubit
        ..seed(0)
        ..onMessagePush(a);
      cubit
        ..opened(a)
        ..clearUnread(a);
      expect(cubit.state, 0);
    });

    test('a conversation read earlier counts again when pushed again', () {
      cubit.seed(1);
      cubit.clearUnread(a);
      expect(cubit.state, 0);

      expect(cubit.onMessagePush(a), isTrue);
      expect(cubit.state, 1);
      cubit.clearUnread(a);
      expect(cubit.state, 0);
    });

    test('an empty id is ignored', () {
      cubit.seed(2);
      cubit.clearUnread('');
      expect(cubit.state, 2);
    });
  });

  test('emits only on a change', () async {
    final seen = <int>[];
    final sub = cubit.stream.listen(seen.add);
    cubit
      ..seed(2)
      ..seed(2)
      ..onMessagePush(a)
      ..onMessagePush(a)
      ..clearUnread(b);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, [2, 3, 2]);
  });
}
