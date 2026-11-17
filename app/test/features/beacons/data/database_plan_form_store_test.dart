import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/beacons/data/database_plan_form_store.dart';
import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('choices survive a restart and a sign-out wipes them', () async {
    PlanFormMemory(store: DatabasePlanFormStore(db)).remember(
      durationMinutes: 120,
      openSpots: 4,
      cost: pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
      chat: pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT,
      communityId: 'c1',
      save: true,
    );
    await pumpEventQueue();

    final restarted = PlanFormMemory(store: DatabasePlanFormStore(db));
    await restarted.ensureLoaded();
    expect(restarted.durationMinutes, 120);
    expect(restarted.communityId, 'c1');

    await db.clearAll();
    final afterSignOut = PlanFormMemory(store: DatabasePlanFormStore(db));
    await afterSignOut.ensureLoaded();
    expect(afterSignOut.durationMinutes, 60);
    expect(afterSignOut.communityId, isNull);
  });

  test('a write that started before the session ended is dropped', () async {
    final store = DatabasePlanFormStore(db);
    final pending = store.write('{"v":1}');
    db.sessionEpoch.end();
    await pending;
    expect(await store.read(), isNull);
  });
}
