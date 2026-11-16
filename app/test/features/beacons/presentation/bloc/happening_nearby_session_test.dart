import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/happening_nearby_session.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/beacons_fixtures.dart';
import '../../../../support/fake_beacons_server.dart';
import '../../../../support/fake_location_repository.dart';

void main() {
  late FakeBeaconsServer beacons;
  late FakeLocationRepository location;
  late DateTime now;
  late HappeningNearbySession session;

  DateTime evening() {
    final d = DateTime.now();
    return DateTime(d.year, d.month, d.day, 18);
  }

  pb.NearbyBeacon plan(int i, {Duration after = const Duration(hours: 2)}) =>
      pb.NearbyBeacon(
        view: beaconView(startAt: now.add(after), id: '${4000 + i}'),
      );

  int nearbyCalls() => beacons.calls.where((c) => c == 'nearby').length;

  setUp(() {
    now = evening();
    beacons = FakeBeaconsServer()
      ..nearbyArea = fakeAreaOne
      ..nearby.addAll([plan(1), plan(2), plan(3)]);
    location = FakeLocationRepository(
      settings: const LocationSettingsData(area: fakeAreaOne),
    );
    session = HappeningNearbySession(
      beacons: beacons,
      location: location,
      clock: () => now,
    );
    addTearDown(session.dispose);
  });

  test('sends nothing until asked, then one call that answers', () async {
    expect(nearbyCalls(), 0);
    await session.ensure();
    expect(nearbyCalls(), 1);
    final r = session.result.value!;
    expect(r.tonight.count, 3);
    expect(r.areaName, 'Alpha Nagar');
    expect(r.areaLabel, 'Alpha Nagar, Testville');
  });

  test('two pages asking at once make one call', () async {
    await Future.wait([session.ensure(), session.ensure()]);
    await session.ensure();
    expect(nearbyCalls(), 1);
  });

  test('refetches after 5 minutes, not before', () async {
    await session.ensure();
    now = now.add(const Duration(minutes: 4, seconds: 59));
    await session.ensure();
    expect(nearbyCalls(), 1);
    now = now.add(const Duration(seconds: 1));
    await session.ensure();
    expect(nearbyCalls(), 2);
  });

  test('no saved area: no Nearby call and no result', () async {
    location.settings = const LocationSettingsData();
    await session.ensure();
    expect(nearbyCalls(), 0);
    expect(session.result.value, isNull);
  });

  test('a failure is no result and is not retried within 5 minutes', () async {
    beacons.nearbyRefusals.add(const NetworkException('offline'));
    await session.ensure();
    expect(session.result.value, isNull);
    await session.ensure();
    expect(nearbyCalls(), 1);
  });

  test('no plan tonight: no result', () async {
    beacons.nearby
      ..clear()
      ..add(plan(1, after: const Duration(days: 2)));
    await session.ensure();
    expect(session.result.value, isNull);
  });

  test('a full page of tonight reads N+', () async {
    beacons.nearby
      ..clear()
      ..addAll([for (var i = 0; i < 20; i++) plan(i)])
      ..add(plan(99));
    await session.ensure();
    expect(session.result.value!.tonight.phrase, '20+ plans');
  });

  test('reset and a changed area drop the answer', () async {
    await session.ensure();
    session.reset();
    expect(session.result.value, isNull);
    await session.ensure();
    expect(nearbyCalls(), 2);
    await location.setArea(fakeAreaTwo.id);
    await Future<void>.delayed(Duration.zero);
    expect(session.result.value, isNull);
    await session.ensure();
    expect(nearbyCalls(), 3);
  });

  test('a flag going off drops it', () async {
    await session.ensure();
    session.featuresChanged({'beacons'}, {'beacons', 'location'});
    expect(session.result.value, isNull);
  });
}
