import 'package:dzeroth/features/beacons/domain/beacon_text_rules.dart';
import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_plan_form_store.dart';

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

  group('PlanFormMemory persistence', () {
    const good =
        '{"v":1,"duration":90,"spots":5,"cost":3,"chat":3,"community":"c9"}';

    test('loads saved choices once', () async {
      final store = FakePlanFormStore(good);
      final memory = PlanFormMemory(store: store);
      expect(memory.loaded, isFalse);
      await memory.ensureLoaded();
      await memory.ensureLoaded();
      expect(store.reads, 1);
      expect(memory.loaded, isTrue);
      expect(memory.durationMinutes, 90);
      expect(memory.openSpots, 5);
      expect(memory.cost, pb.BeaconCost.BEACON_COST_SPLIT_EVENLY);
      expect(memory.chat, pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT);
      expect(memory.communityId, 'c9');
    });

    for (final bad in [
      'not json',
      '[]',
      '{"v":2,"duration":90}',
      '{"v":1,"duration":"x","spots":99,"cost":42,"chat":0}',
    ]) {
      test('tolerates corrupt data: $bad', () async {
        final memory = PlanFormMemory(store: FakePlanFormStore(bad));
        await memory.ensureLoaded();
        expect(memory.durationMinutes, 60);
        expect(memory.openSpots, 3);
        expect(memory.cost, pb.BeaconCost.BEACON_COST_FREE);
        expect(memory.chat, pb.ChatPreference.CHAT_PREFERENCE_QUIET);
        expect(memory.loaded, isTrue);
      });
    }

    test('a failing read leaves the defaults', () async {
      final store = FakePlanFormStore(good)..readError = StateError('x');
      final memory = PlanFormMemory(store: store);
      await memory.ensureLoaded();
      expect(memory.durationMinutes, 60);
    });

    test('remember(save) writes, a failing write is swallowed', () async {
      final store = FakePlanFormStore(null);
      final memory = PlanFormMemory(store: store)
        ..remember(
          durationMinutes: 30,
          openSpots: 2,
          cost: pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN,
          chat: pb.ChatPreference.CHAT_PREFERENCE_TASK_FOCUSED,
          communityId: null,
          save: true,
        );
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, hasLength(1));
      store.writeError = StateError('disk');
      memory.remember(
        durationMinutes: 30,
        openSpots: 2,
        cost: pb.BeaconCost.BEACON_COST_FREE,
        chat: pb.ChatPreference.CHAT_PREFERENCE_QUIET,
        communityId: null,
        save: true,
      );
      await Future<void>.delayed(Duration.zero);
      final fresh = PlanFormMemory(store: store);
      await fresh.ensureLoaded();
      expect(fresh.durationMinutes, 30);
      expect(fresh.cost, pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN);
    });

    test('forget (sign-out) drops choices and an in-flight load', () async {
      final store = FakePlanFormStore(good);
      final memory = PlanFormMemory(store: store);
      final loading = memory.ensureLoaded();
      memory.forget();
      await loading;
      expect(memory.durationMinutes, 60, reason: 'old account never lands');
      expect(memory.loaded, isFalse);
      store.saved = null;
      await memory.ensureLoaded();
      expect(memory.durationMinutes, 60);
      expect(store.reads, 2);
    });

    test('without a store it stays in memory and counts as loaded', () async {
      final memory = PlanFormMemory();
      expect(memory.loaded, isTrue);
      await memory.ensureLoaded();
    });
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
