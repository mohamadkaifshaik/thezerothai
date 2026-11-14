import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/domain/impression_tracker.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<List<String>> sent;
  late bool enabled;
  late DateTime clock;
  Object? failWith;

  ImpressionTracker build() => ImpressionTracker(
    send: (ids) async {
      sent.add(ids);
      final error = failWith;
      if (error != null) throw error;
    },
    isEnabled: () => enabled,
    now: () => clock,
  );

  setUp(() {
    sent = [];
    enabled = true;
    failWith = null;
    clock = DateTime.utc(2026, 11, 14, 6); // 11:30 IST
  });

  test('dedupes an id and sends it once on the 30 s flush', () {
    fakeAsync((async) {
      final tracker = build()
        ..markSeen('a')
        ..markSeen('a')
        ..markSeen('b');
      expect(tracker.pendingCount, 2);

      async.elapse(const Duration(seconds: 29));
      expect(sent, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(sent, [
        ['a', 'b'],
      ]);

      tracker.markSeen('a'); // already sent today
      async.elapse(const Duration(seconds: 60));
      expect(sent, hasLength(1));
      expect(tracker.pendingCount, 0);
    });
  });

  test('splits more than 50 ids into batches of at most 50', () {
    fakeAsync((async) {
      final tracker = build();
      for (var i = 0; i < 120; i++) {
        tracker.markSeen('p$i');
      }
      tracker.flush();
      async.flushMicrotasks();

      expect(sent.map((b) => b.length), [50, 50, 20]);
      expect(sent.expand((b) => b).toSet(), hasLength(120));
    });
  });

  test('flushes at once when the app goes to the background', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      tracker.onBackground();
      async.flushMicrotasks();
      expect(sent, [
        ['a'],
      ]);
      // The pending 30 s timer was cancelled: nothing more goes out.
      async.elapse(const Duration(minutes: 2));
      expect(sent, hasLength(1));
    });
  });

  test('forgets what was sent when the IST day changes', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      tracker.flush();
      async.flushMicrotasks();
      expect(sent, hasLength(1));

      // 18:29 UTC is 23:59 IST: still the same day.
      clock = DateTime.utc(2026, 11, 14, 18, 29);
      tracker.markSeen('a');
      expect(tracker.pendingCount, 0);

      // 18:30 UTC is 00:00 IST of the next day.
      clock = DateTime.utc(2026, 11, 14, 18, 30);
      tracker.markSeen('a');
      expect(tracker.pendingCount, 1);
      tracker.flush();
      async.flushMicrotasks();
      expect(sent, hasLength(2));
    });
  });

  test('istDayOf uses UTC+05:30', () {
    expect(istDayOf(DateTime.utc(2026, 11, 14, 18, 29)), 20261114);
    expect(istDayOf(DateTime.utc(2026, 11, 14, 18, 30)), 20261115);
    expect(istDayOf(DateTime.utc(2026, 12, 31, 20)), 20270101);
  });

  test('flag off: nothing is tracked and no call is made', () {
    fakeAsync((async) {
      enabled = false;
      final tracker = build()..markSeen('a');
      expect(tracker.active, isFalse);
      expect(tracker.pendingCount, 0);
      tracker.onBackground();
      async.elapse(const Duration(minutes: 5));
      expect(sent, isEmpty);
    });
  });

  test('the flag turning off drops what is pending without a call', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      enabled = false;
      async.elapse(const Duration(seconds: 30));
      expect(sent, isEmpty);
      expect(tracker.pendingCount, 0);
    });
  });

  test('FEATURE_DISABLED stops sending until reset', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      failWith = const FeatureDisabledException('off');
      async.elapse(const Duration(seconds: 30));
      expect(sent, hasLength(1));
      expect(tracker.active, isFalse);

      failWith = null;
      tracker.markSeen('b');
      async.elapse(const Duration(minutes: 2));
      expect(sent, hasLength(1), reason: 'no further call this session');

      tracker.reset();
      expect(tracker.active, isTrue);
      tracker.markSeen('b');
      async.elapse(const Duration(seconds: 30));
      expect(sent, hasLength(2));
    });
  });

  test('another error drops the batch silently and does not retry', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      failWith = StateError('boom');
      async.elapse(const Duration(seconds: 30));
      expect(sent, hasLength(1));
      expect(tracker.pendingCount, 0);
      expect(tracker.active, isTrue);

      async.elapse(const Duration(minutes: 5));
      expect(sent, hasLength(1));
      tracker.markSeen('a'); // dropped, but still not re-sent today
      expect(tracker.pendingCount, 0);
    });
  });

  test('reset (sign-out) drops pending ids unsent', () {
    fakeAsync((async) {
      final tracker = build()..markSeen('a');
      tracker.reset();
      async.elapse(const Duration(minutes: 1));
      expect(sent, isEmpty);
    });
  });
}
