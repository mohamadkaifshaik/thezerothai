import 'package:dzeroth/features/beacons/domain/tonight_plans.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';

/// Local wall-clock [hour]:[minute] of today plus [days].
DateTime at(int hour, {int minute = 0, int days = 0}) {
  final d = DateTime.now();
  return DateTime(d.year, d.month, d.day + days, hour, minute);
}

pb.NearbyBeacon plan(
  DateTime start, {
  pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
  String id = '1',
}) => pb.NearbyBeacon(
  view: beaconView(startAt: start, status: status, id: id),
);

void main() {
  group('tonightCutoff', () {
    test('before midnight: 04:00 tomorrow', () {
      expect(tonightCutoff(at(21, minute: 30)), at(4, days: 1));
    });

    test('after midnight and before 04:00: 04:00 today', () {
      expect(tonightCutoff(at(1, minute: 15)), at(4));
      expect(tonightCutoff(at(3, minute: 59)), at(4));
    });

    test('from 04:00 on, the next 04:00', () {
      expect(tonightCutoff(at(4)), at(4, days: 1));
      expect(tonightCutoff(at(9)), at(4, days: 1));
    });
  });

  group('countTonightPlans', () {
    final now = at(18);

    test('counts plans from now until 04:00, not the next afternoon', () {
      final count = countTonightPlans(
        [
          plan(at(19), id: '1'),
          plan(at(23, minute: 59), id: '2'),
          plan(at(3, days: 1), id: '3'),
          plan(at(4, days: 1), id: '4'),
          plan(at(15, days: 1), id: '5'),
        ],
        now: now,
        pageSize: 20,
      );
      expect(count, const TonightCount(3));
    });

    test('after midnight the evening before still counts', () {
      final late = at(1);
      final count = countTonightPlans(
        [plan(at(2), id: '1'), plan(at(5), id: '2')],
        now: late,
        pageSize: 20,
      );
      expect(count.count, 1);
    });

    test('after 04:00 the window is the coming night', () {
      final morning = at(9);
      final count = countTonightPlans(
        [plan(at(20), id: '1'), plan(at(2, days: 1), id: '2')],
        now: morning,
        pageSize: 20,
      );
      expect(count.count, 2);
    });

    test('a plan under way counts, an ended or cancelled one does not', () {
      final count = countTonightPlans(
        [
          plan(at(17), id: '1'),
          plan(at(19), id: '2', status: pb.BeaconStatus.BEACON_STATUS_ENDED),
          plan(
            at(20),
            id: '3',
            status: pb.BeaconStatus.BEACON_STATUS_CANCELLED,
          ),
          plan(at(21), id: '4', status: pb.BeaconStatus.BEACON_STATUS_FULL),
        ],
        now: now,
        pageSize: 20,
      );
      expect(count.count, 2);
    });

    test('an under-full page is exact', () {
      final count = countTonightPlans(
        [for (var i = 0; i < 5; i++) plan(at(20), id: '$i')],
        now: now,
        pageSize: 20,
      );
      expect(count, const TonightCount(5));
      expect(count.phrase, '5 plans');
    });

    test('a full page that is all tonight reads N+', () {
      final count = countTonightPlans(
        [for (var i = 0; i < 20; i++) plan(at(20), id: '$i')],
        now: now,
        pageSize: 20,
      );
      expect(count, const TonightCount(20, atLeast: true));
      expect(count.phrase, '20+ plans');
    });

    test('a full page with a later plan in it is exact', () {
      final count = countTonightPlans(
        [
          for (var i = 0; i < 19; i++) plan(at(20), id: '$i'),
          plan(at(12, days: 1), id: 'x'),
        ],
        now: now,
        pageSize: 20,
      );
      expect(count, const TonightCount(19));
    });

    test('a full page where one is cancelled is exact, not N+', () {
      final count = countTonightPlans(
        [
          for (var i = 0; i < 19; i++) plan(at(20), id: '$i'),
          plan(
            at(20),
            id: 'c',
            status: pb.BeaconStatus.BEACON_STATUS_CANCELLED,
          ),
        ],
        now: now,
        pageSize: 20,
      );
      expect(count, const TonightCount(19));
    });

    test('none, and the singular', () {
      expect(countTonightPlans(const [], now: now, pageSize: 20).count, 0);
      expect(
        countTonightPlans([plan(at(20))], now: now, pageSize: 20).phrase,
        '1 plan',
      );
    });
  });
}
