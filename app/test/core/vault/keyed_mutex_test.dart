import 'dart:async';

import 'package:dzeroth/core/vault/keyed_mutex.dart';
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/vault_owner_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KeyedMutex', () {
    test('runs one key in call order, one at a time', () async {
      final mutex = KeyedMutex();
      final events = <String>[];
      final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
      final results = [
        for (var i = 0; i < 3; i++)
          mutex.run('k', () async {
            events.add('start$i');
            await gates[i].future;
            events.add('end$i');
            return i;
          }),
      ];
      await pumpEventQueue();
      expect(events, ['start0']);
      // Finishing a later one first does not let it jump the queue.
      gates[2].complete();
      gates[1].complete();
      await pumpEventQueue();
      expect(events, ['start0']);
      gates[0].complete();
      expect(await Future.wait(results), [0, 1, 2]);
      expect(events, ['start0', 'end0', 'start1', 'end1', 'start2', 'end2']);
    });

    test(
      'a throwing body releases the key; the error goes to its caller',
      () async {
        final mutex = KeyedMutex();
        final gate = Completer<void>();
        final first = mutex.run<int>('k', () async {
          await gate.future;
          throw StateError('boom');
        });
        final second = mutex.run('k', () async => 2);
        final third = mutex.run<int>('k', () => throw ArgumentError('sync'));
        final fourth = mutex.run('k', () async => 4);
        final firstFailed = expectLater(first, throwsStateError);
        final thirdFailed = expectLater(third, throwsArgumentError);
        gate.complete();
        await firstFailed;
        expect(await second, 2);
        await thirdFailed;
        expect(await fourth, 4);
      },
    );

    test('different keys do not wait for each other', () async {
      final mutex = KeyedMutex();
      final blocker = Completer<void>();
      final slow = mutex.run('a', () => blocker.future);
      expect(await mutex.run('b', () async => 'b'), 'b');
      var aStarted = false;
      final queued = mutex.run('a', () async => aStarted = true);
      await pumpEventQueue();
      expect(aStarted, isFalse);
      blocker.complete();
      await slow;
      expect(await queued, isTrue);
    });

    test('keeps no entry for a key nobody holds or waits for', () async {
      final mutex = KeyedMutex();
      final gate = Completer<void>();
      final a = mutex.run('a', () => gate.future);
      final b = mutex.run('a', () async {});
      final c = mutex.run('b', () async {});
      expect(mutex.debugKeyCount, 2);
      await c;
      await pumpEventQueue();
      expect(mutex.debugKeyCount, 1);
      gate.complete();
      await Future.wait([a, b]);
      await pumpEventQueue();
      expect(mutex.debugKeyCount, 0);
      for (var i = 0; i < 50; i++) {
        await mutex.run('k$i', () async {});
      }
      expect(mutex.debugKeyCount, 0);
    });

    test(
      'debug: nesting the same key fails at once instead of deadlocking',
      () async {
        final mutex = KeyedMutex();
        final order = <String>[];
        await mutex.run('k', () async {
          await expectLater(
            mutex.run('k', () async => order.add('inner')),
            throwsStateError,
          );
          // Another key is fine, even through awaits.
          await Future<void>.delayed(Duration.zero);
          await mutex.run('other', () async => order.add('other'));
        });
        expect(order, ['other']);
        // The failed nested call did not poison the queue.
        expect(await mutex.run('k', () async => 'next'), 'next');
      },
    );

    test('two mutexes do not share holds', () async {
      final one = KeyedMutex();
      final two = KeyedMutex();
      final value = await one.run('k', () => two.run('k', () async => 7));
      expect(value, 7);
    });

    test(
      'work that outlives the body is not counted as holding the key',
      () async {
        final mutex = KeyedMutex();
        final later = Completer<void>();
        final late = Completer<String>();
        await mutex.run('k', () async {
          // The callback runs in the body's zone, after the body finished.
          later.future.then(
            (_) => late.complete(mutex.run('k', () async => 'ran')),
          );
        });
        later.complete();
        await pumpEventQueue();
        expect(await late.future, 'ran');
        expect(await mutex.run('k', () async => 'ok'), 'ok');
      },
    );
  });

  group('IoVaultOwner', () {
    test('always owns, never loses it', () async {
      final VaultOwner owner = IoVaultOwner();
      var lost = 0;
      final sub = owner.lost.listen((_) => lost++);
      expect(owner.supported, isTrue);
      expect(await owner.acquire('u1'), isTrue);
      expect(await owner.acquire('u1'), isTrue);
      expect(await owner.acquire('u2'), isTrue);
      await owner.release();
      await owner.release();
      await pumpEventQueue();
      expect(lost, 0);
      await sub.cancel();
    });

    test('the platform factory gives a native owner on the VM', () async {
      expect(createVaultOwner(), isA<IoVaultOwner>());
    });
  });
}
