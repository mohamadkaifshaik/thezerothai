import 'package:dzeroth/features/beacons/domain/plan_preview.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';

/// The plan a create or edit form would make, for its preview (tablet plan
/// T8d, section 4.1 PlanCreate / PlanEdit).
void main() {
  group('beaconLiveStatus (the server liveStatus rule)', () {
    const cases = <(int, int), pb.BeaconStatus>{
      (0, 1): pb.BeaconStatus.BEACON_STATUS_OPEN,
      (0, 3): pb.BeaconStatus.BEACON_STATUS_OPEN,
      (2, 3): pb.BeaconStatus.BEACON_STATUS_OPEN,
      (3, 3): pb.BeaconStatus.BEACON_STATUS_FULL,
      (4, 3): pb.BeaconStatus.BEACON_STATUS_FULL,
    };
    for (final MapEntry(key: (accepted, spots), value: status)
        in cases.entries) {
      test('$accepted going of $spots -> ${status.name}', () {
        expect(beaconLiveStatus(accepted, spots), status);
      });
    }
  });

  group('draftPlan', () {
    final start = DateTime.now().add(const Duration(hours: 3));

    test('every field as the server stores it, nobody going, OPEN', () {
      final b = draftPlan(
        activity: pb.BeaconActivity.BEACON_ACTIVITY_WALK,
        title: '  Evening walk ',
        details: ' Bring water ',
        venue: ' Park gate  ',
        startAt: start,
        durationMinutes: 90,
        openSpots: 4,
        cost: pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
        chatPreference: pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT,
        organiser: common.AuthorSnapshot(handle: 'alice', displayName: 'Al'),
      );
      expect(b.activity, pb.BeaconActivity.BEACON_ACTIVITY_WALK);
      expect(b.title, 'Evening walk');
      expect(b.details, 'Bring water');
      expect(b.venue, 'Park gate');
      expect(
        b.startAt.toDateTime().millisecondsSinceEpoch,
        start.millisecondsSinceEpoch,
      );
      expect(b.durationMinutes, 90);
      expect(b.openSpots, 4);
      expect(b.acceptedCount, 0);
      expect(b.cost, pb.BeaconCost.BEACON_COST_SPLIT_EVENLY);
      expect(b.chatPreference, pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT);
      expect(b.status, pb.BeaconStatus.BEACON_STATUS_OPEN);
      expect(b.organiser.handle, 'alice');
    });

    test('no organiser without a profile', () {
      final b = draftPlan(
        activity: pb.BeaconActivity.BEACON_ACTIVITY_COFFEE,
        title: '',
        details: '',
        venue: '',
        startAt: start,
        durationMinutes: 60,
        openSpots: 3,
        cost: pb.BeaconCost.BEACON_COST_FREE,
        chatPreference: pb.ChatPreference.CHAT_PREFERENCE_QUIET,
      );
      expect(b.hasOrganiser(), isFalse);
      expect(b.title, isEmpty);
    });
  });

  group('editedPlan', () {
    final start = DateTime.now().add(const Duration(hours: 3));

    test('the four UpdateBeacon fields of the form; the rest as loaded', () {
      final loaded = beaconView(
        startAt: start,
        title: 'Coffee',
        details: 'Old',
        venue: 'Hall',
        openSpots: 5,
        accepted: 2,
        cost: pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
      ).beacon;
      final b = editedPlan(
        loaded,
        title: ' Tea ',
        details: '',
        venue: ' Library ',
        openSpots: 3,
      );
      expect(b.title, 'Tea');
      expect(b.details, isEmpty);
      expect(b.venue, 'Library');
      expect(b.openSpots, 3);
      expect(b.acceptedCount, 2);
      expect(b.cost, pb.BeaconCost.BEACON_COST_SPLIT_EVENLY);
      expect(b.startAt, loaded.startAt);
      expect(b.organiser, loaded.organiser);
      expect(b.status, pb.BeaconStatus.BEACON_STATUS_OPEN);
      // The loaded plan is not changed.
      expect(loaded.title, 'Coffee');
      expect(loaded.openSpots, 5);
    });

    test('a live plan follows the seats: FULL when every seat is taken, '
        'OPEN again with a seat free', () {
      final loaded = beaconView(
        startAt: start,
        openSpots: 3,
        accepted: 2,
      ).beacon;
      expect(
        editedPlan(
          loaded,
          title: 'a',
          details: '',
          venue: 'v',
          openSpots: 2,
        ).status,
        pb.BeaconStatus.BEACON_STATUS_FULL,
      );
      final full = beaconView(
        startAt: start,
        openSpots: 2,
        accepted: 2,
        status: pb.BeaconStatus.BEACON_STATUS_FULL,
      ).beacon;
      expect(
        editedPlan(
          full,
          title: 'a',
          details: '',
          venue: 'v',
          openSpots: 3,
        ).status,
        pb.BeaconStatus.BEACON_STATUS_OPEN,
      );
    });

    test('a cancelled or ended plan keeps its status', () {
      for (final status in [
        pb.BeaconStatus.BEACON_STATUS_CANCELLED,
        pb.BeaconStatus.BEACON_STATUS_ENDED,
      ]) {
        final loaded = beaconView(
          startAt: start,
          openSpots: 3,
          accepted: 3,
          status: status,
        ).beacon;
        expect(
          editedPlan(
            loaded,
            title: 'a',
            details: '',
            venue: 'v',
            openSpots: 3,
          ).status,
          status,
        );
      }
    });
  });
}
