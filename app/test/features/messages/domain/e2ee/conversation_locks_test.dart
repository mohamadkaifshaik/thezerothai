import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/conversation_locks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'one conversation runs one body at a time; others do not wait',
    () async {
      final locks = ConversationLocks();
      final gate = Completer<void>();
      final log = <String>[];
      final first = locks.run('a', () async {
        log.add('a1 start');
        await gate.future;
        log.add('a1 end');
      });
      final second = locks.run('a', () async => log.add('a2'));
      await locks.run('b', () async => log.add('b'));
      expect(log, ['a1 start', 'b']);
      gate.complete();
      await Future.wait([first, second]);
      expect(log, ['a1 start', 'b', 'a1 end', 'a2']);
    },
  );

  test('isHeld is true only inside a body for that id', () async {
    final locks = ConversationLocks();
    expect(locks.isHeld('a'), isFalse);
    final seen = await locks.run('a', () async {
      await Future<void>.delayed(Duration.zero);
      return (a: locks.isHeld('a'), b: locks.isHeld('b'));
    });
    expect(seen, (a: true, b: false));
    expect(locks.isHeld('a'), isFalse);
  });

  test('holdToken differs between two holds and is null outside', () async {
    final locks = ConversationLocks();
    expect(locks.holdToken('a'), isNull);
    final first = await locks.run('a', () async {
      final before = locks.holdToken('a');
      await Future<void>.delayed(Duration.zero);
      expect(locks.holdToken('a'), same(before));
      expect(locks.holdToken('b'), isNull);
      return before;
    });
    final second = await locks.run('a', () async => locks.holdToken('a'));
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(identical(first, second), isFalse);
    expect(locks.holdToken('a'), isNull);
  });
}
