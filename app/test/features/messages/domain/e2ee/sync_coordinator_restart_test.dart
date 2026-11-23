import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_coordinator.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/sync_work_fake.dart';

// Plan 5a Task 13, fix round 1: the coordinator across a restart (the flag
// turning on calls onVaultReady again with no stop()), across a wake (stop()
// then onVaultReady), the interrupted catch-up's welcome poll (I4) and the
// minimum wait of a `held` answer (m2). The rest of the coordinator's tests
// are in sync_coordinator_test.dart.

String _c(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  late FakeSyncWork work;
  late List<Object> reported;

  setUp(() {
    work = FakeSyncWork();
    reported = [];
  });

  tearDown(() => expect(reported, isEmpty, reason: 'reported'));

  SyncCoordinator build(FakeAsync async) {
    final start = DateTime.now().toUtc();
    return SyncCoordinator(
      work: work,
      now: () => start.add(async.elapsed),
      schedule: (delay, run) => Timer(delay, run).cancel,
      onUnexpectedError: (e, _) => reported.add(e),
    );
  }

  group('I1: a restart without stop() loses nothing', () {
    test(
      'a welcome poll in flight is joined and polls once more',
      () => fakeAsync((async) {
        final sync = build(async);
        final hold = work.holdWelcomes = Completer<void>();
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        expect(work.named('welcomes'), hasLength(1));

        // The flag turned on: the same vault starts again.
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        hold.complete();
        async.flushMicrotasks();

        expect(work.named('welcomes'), hasLength(2));
      }),
    );

    test(
      'a queued pass in flight across a restart: the new sweep still runs',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.addAll([_c(1), _c(2)])
          ..sweep = [_c(1)];
        final hold = work.holdPull[_c(1)] = Completer<void>();
        unawaited(sync.onVaultReady());
        async
          ..flushMicrotasks()
          ..elapse(Duration.zero);
        expect(work.named('pullLive'), ['pullLive:${_c(1)}:background']);

        work.sweep = [_c(2)];
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        hold.complete();
        async.elapse(const Duration(minutes: 1));

        expect(
          work.named('pullLive'),
          contains('pullLive:${_c(2)}:background'),
        );
      }),
    );

    test(
      'a queued pass in flight across a wake (stop, then start): the new '
      'sweep still runs',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.addAll([_c(1), _c(2)])
          ..sweep = [_c(1)];
        final hold = work.holdPull[_c(1)] = Completer<void>();
        unawaited(sync.onVaultReady());
        async
          ..flushMicrotasks()
          ..elapse(Duration.zero);

        sync.stop();
        work.sweep = [_c(2)];
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        hold.complete();
        async.elapse(const Duration(minutes: 1));

        expect(
          work.named('pullLive'),
          contains('pullLive:${_c(2)}:background'),
        );
      }),
    );

    test(
      'an opened thread in flight across a restart still reaches its drain',
      () => fakeAsync((async) {
        final sync = build(async);
        work.groups.add(_c(1));
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        work.calls.clear();
        final hold = work.holdPull[_c(1)] = Completer<void>();
        unawaited(sync.opened(_c(1)));
        async.flushMicrotasks();

        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        hold.complete();
        async.flushMicrotasks();

        expect(work.calls, contains('drain:${_c(1)}:live'));
        expect(work.calls, contains('reconcile:${_c(1)}:user'));
      }),
    );

    test(
      'a push in flight across a restart still pulls',
      () => fakeAsync((async) {
        final sync = build(async);
        work.groups.add(_c(1));
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        work.calls.clear();
        final hold = work.holdWelcomes = Completer<void>();
        sync.onPush(_c(1));
        async.flushMicrotasks();

        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        hold.complete();
        async.flushMicrotasks();

        expect(work.calls, contains('pullLive:${_c(1)}:live'));
      }),
    );
  });

  test(
    'm3: a watched thread stays watched across a wake and is refreshed '
    'after the start',
    () => fakeAsync((async) {
      final sync = build(async);
      work.groups.add(_c(1));
      unawaited(sync.onVaultReady());
      async.flushMicrotasks();
      unawaited(sync.opened(_c(1)));
      async.flushMicrotasks();

      sync.stop();
      work.calls.clear();
      unawaited(sync.onVaultReady());
      async.flushMicrotasks();

      expect(sync.isWatched(_c(1)), isTrue);
      expect(work.calls, contains('pullLive:${_c(1)}:user'));
    }),
  );

  test(
    'I4 (item 57): an interrupted catch-up polls welcomes, within the floor',
    () => fakeAsync((async) {
      final sync = build(async);
      work
        ..groups.add(_c(1))
        ..owed.add(_c(1))
        ..catchUps[_c(1)] = CatchUpResult.interrupted;
      unawaited(sync.onVaultReady());
      async
        ..flushMicrotasks()
        ..elapse(kWelcomePollFloor);
      work.calls.clear();

      unawaited(sync.refresh(_c(1)));
      async.flushMicrotasks();
      expect(work.named('welcomes'), ['welcomes:background']);

      // The re-queued pass is interrupted again inside the floor: no poll.
      async.elapse(kRequeueFirst);
      expect(work.named('catchUp'), hasLength(2));
      expect(work.named('welcomes'), hasLength(1));
    }),
  );

  test(
    'm2: held with a time already passed waits the minimum, never a spin',
    () => fakeAsync((async) {
      final sync = build(async);
      final start = DateTime.now().toUtc();
      work.groups.add(_c(1));
      unawaited(sync.onVaultReady());
      async.flushMicrotasks();
      work.pulls[_c(1)] = [ReceiveOutcome.held(start.add(async.elapsed))];
      sync.onPush(_c(1));
      async.flushMicrotasks();
      work.calls.clear();

      async.elapse(kHeldMinWait - const Duration(milliseconds: 1));
      expect(work.named('pullLive'), isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(work.named('pullLive'), hasLength(1));
    }),
  );
}
