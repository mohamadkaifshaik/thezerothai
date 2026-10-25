import 'package:dzeroth/features/posts/domain/schedule_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client mirror of the server's scheduling window (CMP-D6). The clock is
/// a parameter of every function; the base date is built from the current
/// year only so no fixed absolute date appears in the test.
void main() {
  // 10:07:30 on a mid-year day in the device zone.
  final now = DateTime(DateTime.now().year, 6, 15, 10, 7, 30);

  test('the constants match the server config', () {
    expect(kScheduledMinLead, const Duration(minutes: 2));
    expect(kScheduledHorizon, const Duration(days: 60));
  });

  test('the helper texts are the specified ones', () {
    expect(kScheduleTooSoonMessage, 'Pick a time at least 2 minutes from now');
    expect(kScheduleTooFarMessage, 'Pick a time within 60 days');
    expect(ScheduleProblem.tooSoon.message, kScheduleTooSoonMessage);
    expect(ScheduleProblem.tooFar.message, kScheduleTooFarMessage);
  });

  group('truncatedToMinute', () {
    test('cuts seconds and below, keeping the zone kind', () {
      final local = DateTime(now.year, 1, 2, 3, 4, 59, 999);
      expect(truncatedToMinute(local), DateTime(now.year, 1, 2, 3, 4));
      expect(truncatedToMinute(local).isUtc, isFalse);
      final utc = DateTime.utc(now.year, 1, 2, 3, 4, 59, 999);
      expect(truncatedToMinute(utc), DateTime.utc(now.year, 1, 2, 3, 4));
      expect(truncatedToMinute(utc).isUtc, isTrue);
    });

    test(
      'subtracts the part below a minute as a duration, from any instant',
      () {
        // Rebuilding a local time from its fields can move it in a DST gap or
        // overlap; subtracting cannot, so the difference is exactly the part
        // below the minute, whatever the zone of the machine.
        final below = const Duration(
          seconds: 59,
          milliseconds: 999,
          microseconds: 123,
        );
        for (final time in [
          DateTime(now.year, 3, 30, 2, 30, 59, 999, 123),
          DateTime(now.year, 10, 26, 1, 30, 59, 999, 123),
          DateTime(now.year, 6, 15, 10, 7, 59, 999, 123),
          DateTime.utc(now.year, 6, 15, 10, 7, 59, 999, 123),
        ]) {
          final cut = truncatedToMinute(time);
          expect(time.difference(cut), below, reason: '$time');
          expect(cut.isUtc, time.isUtc, reason: '$time');
        }
      },
    );

    test('a whole minute is left alone', () {
      final exact = DateTime(now.year, 6, 15, 10, 7);
      expect(truncatedToMinute(exact), exact);
    });
  });

  group('defaultPublishAt', () {
    test('next whole minute plus the minimum lead', () {
      expect(
        defaultPublishAt(now),
        DateTime(now.year, 6, 15, 10, 10),
        reason: '10:07:30 -> 10:08 -> 10:10',
      );
    });

    test('on an exact minute it still moves to the next one', () {
      final exact = DateTime(now.year, 6, 15, 10, 7);
      expect(defaultPublishAt(exact), DateTime(now.year, 6, 15, 10, 10));
    });

    test('is always schedulable at the moment it is made', () {
      for (var s = 0; s < 60; s += 7) {
        final t = DateTime(now.year, 6, 15, 23, 58, s);
        expect(scheduleProblem(defaultPublishAt(t), t), isNull, reason: '$s');
      }
    });
  });

  group('scheduleProblem', () {
    test('earlier than now is too soon', () {
      expect(
        scheduleProblem(now.subtract(const Duration(minutes: 5)), now),
        ScheduleProblem.tooSoon,
      );
    });

    test('inside the 2 minute lead is too soon (compared by the minute)', () {
      // now + 2 min = 10:09:30; the minute 10:09 is before it.
      expect(
        scheduleProblem(DateTime(now.year, 6, 15, 10, 9), now),
        ScheduleProblem.tooSoon,
      );
    });

    test('the first schedulable minute is accepted', () {
      expect(scheduleProblem(DateTime(now.year, 6, 15, 10, 10), now), isNull);
    });

    test('exactly now + lead is accepted', () {
      final exact = DateTime(now.year, 6, 15, 10, 7);
      expect(scheduleProblem(exact.add(kScheduledMinLead), exact), isNull);
    });

    test('inside the horizon is accepted', () {
      expect(scheduleProblem(now.add(const Duration(days: 59)), now), isNull);
    });

    test('exactly at the horizon (by the minute) is accepted', () {
      final exact = DateTime(now.year, 6, 15, 10, 7);
      expect(scheduleProblem(exact.add(kScheduledHorizon), exact), isNull);
    });

    test('a minute past the horizon is too far', () {
      final exact = DateTime(now.year, 6, 15, 10, 7);
      expect(
        scheduleProblem(
          exact.add(kScheduledHorizon + const Duration(minutes: 1)),
          exact,
        ),
        ScheduleProblem.tooFar,
      );
    });

    test('a UTC value is compared as the same instant', () {
      expect(
        scheduleProblem(now.add(const Duration(hours: 3)).toUtc(), now),
        isNull,
      );
    });
  });
}
