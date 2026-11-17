import 'package:dzeroth/features/beacons/domain/beacon_text_rules.dart';
import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Tuesday 2026-11-17, 12:03.
  final now = DateTime(2026, 11, 17, 12, 3);

  test('Now is ten minutes out on a 5-minute mark, inside the window', () {
    final start = quickStartFor(PlanQuickStart.now, now)!;
    expect(start, DateTime(2026, 11, 17, 12, 15));
    expect(beaconStartIssue(start, now), isNull);
  });

  test('Tonight is 19:00, and absent once it is too close', () {
    expect(
      quickStartFor(PlanQuickStart.tonight, now),
      DateTime(2026, 11, 17, 19),
    );
    expect(
      quickStartFor(PlanQuickStart.tonight, DateTime(2026, 11, 17, 18, 50)),
      isNull,
    );
  });

  test('Tomorrow is 10:00 the next day', () {
    expect(
      quickStartFor(PlanQuickStart.tomorrow, now),
      DateTime(2026, 11, 18, 10),
    );
  });

  test('Weekend is the next Saturday 10:00; on a Saturday morning, today', () {
    expect(
      quickStartFor(PlanQuickStart.weekend, now),
      DateTime(2026, 11, 21, 10),
    );
    expect(
      quickStartFor(PlanQuickStart.weekend, DateTime(2026, 11, 21, 8)),
      DateTime(2026, 11, 21, 10),
    );
    // Saturday afternoon: Sunday.
    expect(
      quickStartFor(PlanQuickStart.weekend, DateTime(2026, 11, 21, 15)),
      DateTime(2026, 11, 22, 10),
    );
  });

  test('Custom has no start of its own', () {
    expect(quickStartFor(PlanQuickStart.custom, now), isNull);
  });

  test('the memory keeps in-range choices and resets', () {
    final memory = PlanFormMemory()
      ..remember(
        durationMinutes: 90,
        openSpots: 99,
        cost: pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
        chat: pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT,
        communityId: 'c1',
      );
    expect(memory.durationMinutes, 90);
    expect(memory.openSpots, 3, reason: 'out of range is ignored');
    expect(memory.communityId, 'c1');
    memory.reset();
    expect(memory.durationMinutes, 60);
    expect(memory.communityId, isNull);
  });
}
