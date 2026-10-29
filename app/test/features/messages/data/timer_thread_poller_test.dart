import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/messages/data/timer_thread_poller.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';

class _Harness {
  _Harness(
    this.async, {
    bool pushRegistered = false,
    bool Function()? pushCoverage,
    bool visible = true,
  }) {
    hold = RateLimitHold(monotonic: () => async.elapsed);
    poller = TimerThreadPoller(
      pull: _pull,
      rateLimitHold: hold,
      monotonic: () => async.elapsed,
      pushRegistered: pushRegistered,
      pushCoverage: pushCoverage,
      visible: visible,
    );
  }

  final FakeAsync async;
  late final RateLimitHold hold;
  late final TimerThreadPoller poller;
  final List<Duration> pulls = [];
  Completer<PollResult>? gate;
  PollResult Function()? nextResult;

  Future<PollResult> _pull() {
    pulls.add(async.elapsed);
    final g = gate;
    if (g != null) return g.future;
    return Future.value(
      nextResult?.call() ?? const PollResult(newMessages: false),
    );
  }

  void elapse(Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }
}

void main() {
  group('pushCoverage (W7-19: push that can reach this thread)', () {
    test('true: the hot interval is 30 s', () {
      fakeAsync((async) {
        final h = _Harness(async, pushCoverage: () => true)..poller.start();
        h.elapse(const Duration(seconds: 95));
        expect(h.pulls.map((d) => d.inSeconds), [30, 60, 90]);
        h.poller.dispose();
      });
    });

    test('false overrides pushRegistered: 15 s', () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          pushRegistered: true,
          pushCoverage: () => false,
        )..poller.start();
        h.elapse(const Duration(seconds: 50));
        expect(h.pulls.map((d) => d.inSeconds), [15, 30, 45]);
        h.poller.dispose();
      });
    });

    test('is asked at every schedule: a thread muted meanwhile speeds up', () {
      fakeAsync((async) {
        var covered = true;
        final h = _Harness(async, pushCoverage: () => covered)..poller.start();
        h.elapse(const Duration(seconds: 31));
        expect(h.pulls.map((d) => d.inSeconds), [30]);

        covered = false;
        h.elapse(const Duration(seconds: 50));
        // The wait armed at 30 s used the old answer (60 s); the next ones
        // follow the new one.
        expect(h.pulls.map((d) => d.inSeconds), [30, 60, 75]);
        h.poller.dispose();
      });
    });

    test('without it, pushRegistered decides as before', () {
      fakeAsync((async) {
        final h = _Harness(async, pushRegistered: true)..poller.start();
        h.elapse(const Duration(seconds: 35));
        expect(h.pulls.map((d) => d.inSeconds), [30]);
        h.poller.dispose();
      });
    });
  });

  test('schedule is 15 s while hot, 45 s while warm, then stops at 5 min', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      h.elapse(const Duration(minutes: 10));
      final secs = h.pulls.map((d) => d.inSeconds).toList();
      expect(secs, [15, 30, 45, 60, 75, 90, 105, 120, 165, 210, 255]);
      expect(h.poller.isRunning, isFalse);
      h.poller.dispose();
    });
  });

  test('a new message keeps the thread hot and defers the stop', () {
    fakeAsync((async) {
      final h = _Harness(async);
      var n = 0;
      h.nextResult = () => PollResult(newMessages: ++n == 8); // at 120 s
      h.poller.start();
      h.elapse(const Duration(seconds: 120));
      expect(h.pulls.length, 8);
      h.elapse(const Duration(seconds: 16));
      expect(h.pulls.last.inSeconds, 135); // still 15 s apart
      h.poller.dispose();
    });
  });

  test('a hidden app sends 0 polls and resumes with an immediate pull', () {
    fakeAsync((async) {
      final h = _Harness(async, visible: false)..poller.start();
      h.elapse(const Duration(minutes: 3));
      expect(h.pulls, isEmpty);

      h.poller.setVisible(true);
      h.async.flushMicrotasks();
      expect(h.pulls, [const Duration(minutes: 3)]);

      h.poller.setVisible(false);
      final before = h.pulls.length;
      h.elapse(const Duration(minutes: 1));
      expect(h.pulls.length, before);
      h.poller.dispose();
    });
  });

  test('RATE_LIMITED holds polling until the hold clears', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      h.hold.record(
        const RateLimitedException('x', retryAfter: Duration(seconds: 60)),
      );
      h.elapse(const Duration(seconds: 59));
      expect(h.pulls, isEmpty);
      h.poller.onPush(); // a push is held too
      h.elapse(Duration.zero);
      expect(h.pulls, isEmpty);
      h.elapse(const Duration(seconds: 2));
      expect(h.pulls, hasLength(1));
      expect(h.pulls.first.inSeconds, 60);
      h.poller.dispose();
    });
  });

  test(
    'a RATE_LIMITED answer from the pull is recorded and pauses polling',
    () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.nextResult = () => throw const RateLimitedException(
          'x',
          retryAfter: Duration(minutes: 1),
        );
        h.poller.start();
        h.elapse(const Duration(seconds: 15));
        expect(h.pulls, hasLength(1));
        expect(h.hold.check(), isNotNull);
        h.elapse(const Duration(seconds: 59));
        expect(h.pulls, hasLength(1)); // held until 75 s
        h.nextResult = null;
        h.elapse(const Duration(seconds: 2));
        expect(h.pulls, hasLength(2));
        h.poller.dispose();
      });
    },
  );

  test('a push or a resume pulls immediately', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      h.elapse(const Duration(seconds: 5));
      h.poller.onPush();
      h.async.flushMicrotasks();
      expect(h.pulls, [const Duration(seconds: 5)]);
      h.elapse(const Duration(seconds: 2));
      h.poller.setVisible(false);
      h.poller.setVisible(true);
      h.async.flushMicrotasks();
      expect(h.pulls.last.inSeconds, 7);
      expect(h.pulls, hasLength(2));
      h.poller.dispose();
    });
  });

  test('Android hot interval is 30 s with push, warm stays 45 s', () {
    fakeAsync((async) {
      final h = _Harness(async, pushRegistered: true)..poller.start();
      h.elapse(const Duration(seconds: 125));
      expect(h.pulls.map((d) => d.inSeconds), [30, 60, 90, 120]);
      h.elapse(const Duration(seconds: 50));
      expect(h.pulls.last.inSeconds, 165);
      h.poller.dispose();
    });
  });

  test('input restarts a poller that stopped from idleness', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      h.elapse(const Duration(minutes: 6));
      expect(h.poller.isRunning, isFalse);
      final before = h.pulls.length;
      h.poller.noteInput();
      expect(h.poller.isRunning, isTrue);
      h.elapse(const Duration(seconds: 15));
      expect(h.pulls.length, before + 1);
      h.poller.dispose();
    });
  });

  test('pulls never overlap; triggers coalesce into one follow-up', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      h.gate = Completer<PollResult>();
      h.elapse(const Duration(seconds: 15));
      expect(h.pulls, hasLength(1));
      h.poller.onPush();
      h.poller.onPush();
      h.poller.setVisible(false);
      h.poller.setVisible(true); // pending trigger while in flight
      h.elapse(const Duration(seconds: 40)); // timer ticks dropped too
      expect(h.pulls, hasLength(1));

      final g = h.gate!;
      h.gate = null;
      g.complete(const PollResult(newMessages: false));
      h.async.flushMicrotasks();
      expect(h.pulls, hasLength(2)); // exactly one follow-up
      h.poller.dispose();
    });
  });

  test('dispose cancels timers and ignores later calls', () {
    fakeAsync((async) {
      final h = _Harness(async)..poller.start();
      expect(async.pendingTimers, isNotEmpty);
      h.poller.dispose();
      expect(async.pendingTimers, isEmpty);
      h.poller.onPush();
      h.poller.setVisible(false);
      h.poller.setVisible(true);
      h.poller.noteInput();
      h.poller.start();
      h.elapse(const Duration(minutes: 6));
      expect(h.pulls, isEmpty);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('an unexpected pull error is reported and the schedule continues', () {
    fakeAsync((async) {
      final errors = <Object>[];
      final hold = RateLimitHold(monotonic: () => async.elapsed);
      var calls = 0;
      final poller = TimerThreadPoller(
        pull: () async {
          calls++;
          throw StateError('boom');
        },
        rateLimitHold: hold,
        monotonic: () => async.elapsed,
        onError: (e, _) => errors.add(e),
      )..start();
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(calls, 2);
      expect(errors, hasLength(2));
      poller.dispose();
    });
  });
}
