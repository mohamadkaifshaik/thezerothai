import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart'
    show kDeviceListReuse;
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_coordinator.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/sync_work_fake.dart';

// Plan 5a Task 13 (step 13-i): the sync triggers over a recording
// [SyncWork]. Each test names the plan's Step 1 test or the gate item of
// task-13-gates.md it covers. The pipeline's own wiring (the real parts, the
// device gate, the budgets) is in e2ee_pipeline_test.dart.

String _c(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  late FakeSyncWork work;
  late List<Object> reported;

  var reportsExpected = false;

  setUp(() {
    work = FakeSyncWork();
    reported = [];
    reportsExpected = false;
  });

  tearDown(() {
    if (!reportsExpected) expect(reported, isEmpty, reason: 'reported');
  });

  SyncCoordinator build(FakeAsync async) {
    final start = DateTime.now().toUtc();
    return SyncCoordinator(
      work: work,
      now: () => start.add(async.elapsed),
      schedule: (delay, run) => Timer(delay, run).cancel,
      onUnexpectedError: (e, _) => reported.add(e),
    );
  }

  /// [sync]'s vault-ready sequence, run to its end, then the calls cleared.
  void ready(FakeAsync async, SyncCoordinator sync, {bool clear = true}) {
    unawaited(sync.onVaultReady());
    async.flushMicrotasks();
    if (clear) work.calls.clear();
  }

  group('vault ready (item 23, 24, 26, 27)', () {
    test(
      'vault ready runs provisional resume, resends, welcomes, the pass and '
      'the removal queue in that order',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..outbox = [_c(7)]
          ..recent = [_c(1)];
        ready(async, sync, clear: false);
        expect(work.calls, [
          'resumeProvisional:background',
          'outbox',
          'drain:${_c(7)}:background',
          'welcomes:background',
          'recent:10',
          'peers:${_c(1)}',
          'pullLive:${_c(1)}:background',
          'catchUp:${_c(1)}:background',
          'reconcile:${_c(1)}:background',
          'removal:vaultReady',
          'sweep',
        ]);
      }),
    );

    test(
      'items 26, 27: every known conversation gets one pass with a catch-up '
      'at app start, in the sweep order, not repeated for the pass',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..recent = [_c(1)]
          ..sweep = [_c(2), _c(1), _c(3)]
          ..groups.addAll([_c(1), _c(2), _c(3)]);
        ready(async, sync, clear: false);
        async.elapse(Duration.zero);
        final swept = [
          for (final c in work.calls)
            if (c.startsWith('pullLive:') || c.startsWith('catchUp:')) c,
        ];
        expect(swept, [
          'pullLive:${_c(1)}:background',
          'catchUp:${_c(1)}:background',
          'pullLive:${_c(2)}:background',
          'catchUp:${_c(2)}:background',
          'pullLive:${_c(3)}:background',
          'catchUp:${_c(3)}:background',
        ]);
      }),
    );

    test(
      'nothing runs after stop or while removed elsewhere',
      () => fakeAsync((async) {
        final sync = build(async);
        work.stopped = true;
        ready(async, sync, clear: false);
        expect(work.calls, isEmpty);
        expect(sync.running, isFalse);

        work.stopped = false;
        ready(async, sync);
        sync.stop();
        sync
          ..onAppResumed()
          ..onPush(_c(1))
          ..onInboxRow(_row(_c(1)))
          ..pollWelcomes();
        unawaited(sync.opened(_c(1)));
        unawaited(sync.refresh(_c(1)));
        async.elapse(const Duration(hours: 2));
        expect(work.calls, isEmpty);
      }),
    );

    test(
      'a sequence stops between steps once the fact says stop',
      () => fakeAsync((async) {
        final sync = build(async);
        final hold = Completer<void>();
        work
          ..recent = [_c(1)]
          ..holdWelcomes = hold;
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        work.stopped = true;
        hold.complete();
        async.flushMicrotasks();
        expect(work.named('recent'), isEmpty);
        expect(work.named('removal'), isEmpty);
      }),
    );
  });

  group('the app-open pass (item 66)', () {
    test(
      'the pass makes one batched device lookup for its 10 peers',
      () => fakeAsync((async) {
        final sync = build(async);
        work.recent = [for (var i = 0; i < 12; i++) _c(i)];
        ready(async, sync, clear: false);
        expect(work.named('recent'), ['recent:$kAppOpenPassConversations']);
        expect(work.named('peers'), [
          'peers:${[for (var i = 0; i < 10; i++) _c(i)].join(',')}',
        ]);
        expect(work.named('reconcile'), [
          for (var i = 0; i < 10; i++) 'reconcile:${_c(i)}:background',
        ]);
      }),
    );

    test('the pass covers the 10 most recent accepted encrypted '
        'conversations and no request', () {
      pb.Conversation row(
        int n, {
        required int at,
        bool encrypted = true,
        ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
        Folder folder = Folder.FOLDER_INBOX,
      }) => pb.Conversation(
        id: _c(n),
        folder: folder,
        state: state,
        updatedAt: ts.Timestamp(seconds: Int64(at)),
        lastMessage: pb.MessagePreview(encrypted: encrypted),
      );
      final rows = [
        for (var i = 0; i < 12; i++) row(i, at: 100 + i),
        row(50, at: 999, state: ConversationState.CONVERSATION_STATE_REQUEST),
        row(51, at: 998, folder: Folder.FOLDER_REQUESTS),
        row(52, at: 997, encrypted: false),
      ];
      expect(passConversationsFrom(rows, kAppOpenPassConversations), [
        for (var i = 11; i >= 2; i--) _c(i),
      ]);
    });

    test(
      'a resume within 30 minutes of a pass makes no key-directory call',
      () => fakeAsync((async) {
        final sync = build(async);
        work.recent = [_c(1)];
        ready(async, sync);
        async.elapse(kDeviceListReuse - const Duration(seconds: 1));
        work.calls.clear();
        sync.onAppResumed();
        async.flushMicrotasks();
        expect(work.named('recent'), isEmpty);
        expect(work.named('peers'), isEmpty);
        expect(work.named('removal'), ['removal:resume']);

        async.elapse(const Duration(seconds: 1));
        work.calls.clear();
        sync.onAppResumed();
        async.flushMicrotasks();
        expect(work.named('peers'), ['peers:${_c(1)}']);
      }),
    );

    test(
      'item 38: a resume resumes every pending commit first, then the pass, '
      'the welcomes and the removal queue',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        async.elapse(kDeviceListReuse);
        work
          ..pendingCommits = [_c(4)]
          ..recent = [_c(1)];
        sync.onAppResumed();
        async.flushMicrotasks();
        expect(
          [
            for (final c in work.calls)
              if (!c.startsWith('pullLive') &&
                  !c.startsWith('catchUp') &&
                  !c.startsWith('reconcile'))
                c,
          ],
          [
            'pendingCommits',
            'resumePending:${_c(4)}:background',
            'recent:10',
            'peers:${_c(1)}',
            'welcomes:background',
            'removal:resume',
          ],
        );
      }),
    );
  });

  group('welcome polls (item 65)', () {
    test(
      'welcomes are polled at ready, resume, push and for an encrypted row '
      'without a group',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync, clear: false);
        expect(work.named('welcomes'), ['welcomes:background']);
        work.calls.clear();
        sync.onAppResumed();
        async.flushMicrotasks();
        expect(work.named('welcomes'), ['welcomes:background']);
        work.calls.clear();
        sync.onPush(_c(1));
        async.flushMicrotasks();
        expect(work.named('welcomes'), ['welcomes:live']);
        work.calls.clear();

        work.groups.add(_c(2));
        sync
          ..onInboxRow(_row(_c(2)))
          ..onInboxRow(_row(_c(3), encrypted: false));
        async.flushMicrotasks();
        expect(work.named('welcomes'), isEmpty);
        sync.onInboxRow(_row(_c(3)));
        async.flushMicrotasks();
        expect(work.named('welcomes'), ['welcomes:background']);
      }),
    );

    test(
      'other reasons poll welcomes at most once per 60 s',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        sync.pollWelcomes();
        async.flushMicrotasks();
        expect(work.named('welcomes'), isEmpty);
        async.elapse(kWelcomePollFloor - const Duration(seconds: 1));
        sync.pollWelcomes();
        async.flushMicrotasks();
        expect(work.named('welcomes'), isEmpty);
        async.elapse(const Duration(seconds: 1));
        sync
          ..pollWelcomes()
          ..pollWelcomes();
        async.flushMicrotasks();
        expect(work.named('welcomes'), hasLength(1));
        // The same row again is another reason: floored.
        sync.onInboxRow(_row(_c(3)));
        async.flushMicrotasks();
        work.calls.clear();
        sync.onInboxRow(_row(_c(3)));
        async.flushMicrotasks();
        expect(work.named('welcomes'), isEmpty);
      }),
    );

    test(
      'triggers during a poll cause exactly one more poll',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        final hold = Completer<void>();
        work.holdWelcomes = hold;
        sync.onAppResumed();
        async.flushMicrotasks();
        sync
          ..onPush(_c(1))
          ..onPush(_c(2))
          ..onAppResumed();
        async.flushMicrotasks();
        expect(work.named('welcomes'), hasLength(1));
        hold.complete();
        async.flushMicrotasks();
        expect(work.named('welcomes'), [
          'welcomes:background',
          'welcomes:live',
        ]);
      }),
    );

    test(
      'item 57: a catch-up waiting for a welcome polls (an other reason)',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        async.elapse(kWelcomePollFloor);
        work
          ..groups.add(_c(1))
          ..catchUps[_c(1)] = CatchUpResult.waitingForWelcome;
        unawaited(sync.refresh(_c(1)));
        work.owed.add(_c(1));
        unawaited(sync.refresh(_c(1)));
        async.flushMicrotasks();
        expect(work.named('welcomes'), ['welcomes:background']);
      }),
    );

    test(
      'a joined conversation gets a pass at once',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        work
          ..joined.add([_c(5)])
          ..groups.add(_c(5));
        sync.onPush(_c(1));
        async.elapse(Duration.zero);
        expect(work.calls, contains('pullLive:${_c(5)}:background'));
      }),
    );
  });

  group('push, open and refresh (items 49, 50, 52)', () {
    test(
      'a push pulls that conversation',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        sync.onPush(_c(1));
        async.flushMicrotasks();
        expect(work.calls, [
          'welcomes:live',
          'catchUp:${_c(1)}:live',
          'pullLive:${_c(1)}:live',
        ]);
      }),
    );

    test(
      'opened runs with user priority ahead of a running background pass',
      () => fakeAsync((async) {
        final sync = build(async);
        final hold = Completer<void>();
        work
          ..recent = [_c(1)]
          ..holdPull[_c(1)] = hold;
        unawaited(sync.onVaultReady());
        async.flushMicrotasks();
        expect(work.calls.last, 'pullLive:${_c(1)}:background');
        work.calls.clear();

        unawaited(sync.opened(_c(2)));
        async.flushMicrotasks();
        expect(work.calls, [
          'resumePending:${_c(2)}:user',
          'catchUp:${_c(2)}:user',
          'pullLive:${_c(2)}:user',
          'clearedAt:${_c(2)}:user',
          'reconcile:${_c(2)}:user',
          'selfUpdate:${_c(2)}:user',
          'drain:${_c(2)}:live',
        ]);
        hold.complete();
        async.flushMicrotasks();
      }),
    );

    test(
      'item 52: repairIfStuck runs only after a catch-up that answered stuck',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        unawaited(sync.opened(_c(1)));
        async.flushMicrotasks();
        expect(work.named('repair'), isEmpty);
        work.catchUps[_c(1)] = CatchUpResult.stuck;
        unawaited(sync.opened(_c(1)));
        async.flushMicrotasks();
        expect(work.named('repair'), ['repair:${_c(1)}']);
        // Stuck in the background: no repair there.
        work.calls.clear();
        sync.onPush(_c(1));
        async.flushMicrotasks();
        expect(work.named('repair'), isEmpty);
      }),
    );

    test(
      'refresh catches up only when owed, pulls and drains in the background',
      () => fakeAsync((async) {
        final sync = build(async);
        ready(async, sync);
        unawaited(sync.refresh(_c(1)));
        async.flushMicrotasks();
        expect(work.calls, [
          'pullLive:${_c(1)}:user',
          'drain:${_c(1)}:background',
        ]);
        work
          ..calls.clear()
          ..owed.add(_c(1));
        unawaited(sync.refresh(_c(1)));
        async.flushMicrotasks();
        expect(work.calls.first, 'catchUp:${_c(1)}:user');
      }),
    );

    test(
      'item 49: no automatic trigger uses user priority',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..recent = [_c(1)]
          ..sweep = [_c(2)]
          ..groups.addAll([_c(1), _c(2)])
          ..pulls[_c(2)] = [ReceiveOutcome.more];
        ready(async, sync, clear: false);
        sync
          ..onAppResumed()
          ..onPush(_c(3))
          ..onInboxRow(_row(_c(4)));
        async.elapse(const Duration(hours: 1));
        expect(work.calls.where((c) => c.endsWith(':user')), isEmpty);
      }),
    );
  });

  group('re-queued passes (items 54-61)', () {
    test(
      'item 54: more is re-queued with a growing backoff, never a spin',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.add(_c(1))
          ..pulls[_c(1)] = List.filled(40, ReceiveOutcome.more, growable: true);
        ready(async, sync);
        sync.onPush(_c(1));
        async.flushMicrotasks();
        work.calls.clear();
        async.elapse(kRequeueFirst - const Duration(milliseconds: 1));
        expect(work.named('pullLive'), isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(work.named('pullLive'), hasLength(1));
        async.elapse(kRequeueFirst);
        expect(work.named('pullLive'), hasLength(1));
        async.elapse(kRequeueFirst);
        expect(work.named('pullLive'), hasLength(2));
        // Over a day: bounded by the doubling up to the cap.
        async.elapse(const Duration(hours: 24));
        expect(work.named('pullLive').length, lessThan(40));
      }),
    );

    test(
      'item 54: held and stopped are honoured at their time',
      () => fakeAsync((async) {
        final sync = build(async);
        final start = DateTime.now().toUtc();
        DateTime at(Duration d) => start.add(async.elapsed).add(d);
        work.groups.add(_c(1));
        ready(async, sync);
        work.pulls[_c(1)] = [
          ReceiveOutcome.held(at(const Duration(minutes: 3))),
        ];
        sync.onPush(_c(1));
        async.flushMicrotasks();
        work.calls.clear();
        async.elapse(const Duration(minutes: 3) - const Duration(seconds: 1));
        expect(work.named('pullLive'), isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(work.named('pullLive'), ['pullLive:${_c(1)}:background']);
      }),
    );

    test(
      'item 54: re-queued passes go round-robin by conversation',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.addAll([_c(1), _c(2)])
          ..pulls[_c(1)] = [ReceiveOutcome.more, ReceiveOutcome.more]
          ..pulls[_c(2)] = [ReceiveOutcome.more, ReceiveOutcome.more];
        ready(async, sync);
        sync
          ..onPush(_c(1))
          ..onPush(_c(2));
        async.flushMicrotasks();
        work.calls.clear();
        async.elapse(const Duration(minutes: 2));
        final order = [for (final c in work.named('pullLive')) c.split(':')[1]];
        expect(order.take(4), [_c(1), _c(2), _c(1), _c(2)]);
      }),
    );

    test(
      'item 55, 58: an interrupted catch-up causes a pull later, never a '
      'catch-up loop',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.add(_c(1))
          ..catchUps[_c(1)] = CatchUpResult.interrupted;
        ready(async, sync);
        sync.onPush(_c(1));
        async.flushMicrotasks();
        expect(work.named('catchUp'), hasLength(1));
        work.calls.clear();
        async.elapse(kRequeueFirst);
        expect(work.named('pullLive'), ['pullLive:${_c(1)}:background']);
        expect(work.named('catchUp'), isEmpty);
      }),
    );

    test(
      'item 56: a conversation with no group that answers stopped is left to '
      'resume, open and push',
      () => fakeAsync((async) {
        final sync = build(async);
        final start = DateTime.now().toUtc();
        ready(async, sync);
        work.pulls[_c(1)] = [
          ReceiveOutcome.stopped(start.add(const Duration(minutes: 1))),
        ];
        sync.onPush(_c(1));
        async.flushMicrotasks();
        work.calls.clear();
        async.elapse(const Duration(hours: 2));
        expect(work.named('pullLive'), isEmpty);
      }),
    );

    test(
      'item 59, 60, 61: a chain that ends complete owes one trailing pass and '
      'drains; the trailing pass catches up when owed',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.add(_c(1))
          ..pulls[_c(1)] = [ReceiveOutcome.more];
        ready(async, sync);
        sync.onPush(_c(1));
        async.flushMicrotasks();
        work.calls.clear();
        async.elapse(kRequeueFirst);
        expect(work.calls, [
          'pullLive:${_c(1)}:background',
          'drain:${_c(1)}:background',
        ]);
        work
          ..calls.clear()
          ..owed.add(_c(1));
        async.elapse(kOwedTrailingPass);
        expect(work.calls, [
          'pullLive:${_c(1)}:background',
          'catchUp:${_c(1)}:background',
        ]);
        work.calls.clear();
        async.elapse(const Duration(hours: 1));
        expect(work.calls, isEmpty);
      }),
    );

    test(
      'item 39: a pause cancels the queue timer; resume arms it again',
      () => fakeAsync((async) {
        final sync = build(async);
        work
          ..groups.add(_c(1))
          ..pulls[_c(1)] = [ReceiveOutcome.more];
        ready(async, sync);
        sync.onPush(_c(1));
        async.flushMicrotasks();
        sync.onAppPaused();
        work.calls.clear();
        async.elapse(const Duration(minutes: 5));
        expect(work.calls, isEmpty);
        sync.onAppResumed();
        async.elapse(Duration.zero);
        expect(work.calls, contains('pullLive:${_c(1)}:background'));
      }),
    );
  });

  group('errors (item 63)', () {
    test(
      'a non-Error exception is reported by step; a StateError is quiet',
      () => fakeAsync((async) {
        reportsExpected = true;
        final sync = build(async);
        work.throwOn['welcomes'] = const NetworkException('x');
        ready(async, sync);
        expect(reported, [isA<E2eePipelineError>()]);
        expect((reported.single as E2eePipelineError).step, 'sync.welcomes');
        work.throwOn['welcomes'] = StateError('closed');
        reported.clear();
        sync.onAppResumed();
        async.flushMicrotasks();
        expect(reported, isEmpty);
        // The sequence went on after the failed step.
        expect(work.named('removal'), ['removal:resume']);
      }),
    );
  });
}

pb.Conversation _row(String id, {bool encrypted = true}) => pb.Conversation(
  id: id,
  peer: common.AuthorSnapshot(userId: 'ref-bob'),
  folder: Folder.FOLDER_INBOX,
  state: ConversationState.CONVERSATION_STATE_ACCEPTED,
  lastMessage: pb.MessagePreview(encrypted: encrypted),
);
