import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/nearby_plans_cubit.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';

const _alpha = AreaRef(
  id: 'in.x.a',
  name: 'Alpha',
  type: AreaType.area,
  cityId: 'in.x',
  cityName: 'Xcity',
);

void main() {
  late FakeBeaconsServer server;
  late NearbyPlansCubit cubit;
  final start = DateTime.now().add(const Duration(days: 1));

  pb.NearbyBeacon row(int i) => pb.NearbyBeacon(
    view: beaconView(startAt: start, id: '${2000 + i}', title: 'Plan $i'),
    proximity: pb.AreaProximity.AREA_PROXIMITY_SAME_AREA,
  );

  setUp(() {
    server = FakeBeaconsServer()..nearbyArea = _alpha;
    cubit = NearbyPlansCubit(repository: server);
  });

  tearDown(() => cubit.close());

  test('no stored area: the prompt state, nothing listed', () async {
    server.nearbyRefusals.add(const StateConflictException(kAreaNotSetReason));

    await cubit.load();

    expect(cubit.state.load, NearbyLoad.noArea);
    expect(cubit.state.items, isEmpty);
  });

  test('loads the first page with the area and the count', () async {
    server.nearby.addAll([for (var i = 0; i < 3; i++) row(i)]);
    server.nearbyCount = pb.NearbyCount(few: true);

    await cubit.load();

    expect(cubit.state.load, NearbyLoad.ready);
    expect(cubit.state.items, hasLength(3));
    expect(cubit.state.area, _alpha);
    expect(cubit.state.count?.few, isTrue);
    expect(cubit.state.hasMore, isFalse);
    expect(cubit.state.canSwitchScope, isTrue);
  });

  test('a city area cannot switch scope', () async {
    server.nearbyArea = const AreaRef(
      id: 'in.x',
      name: 'Xcity',
      type: AreaType.city,
      cityId: 'in.x',
      cityName: 'Xcity',
    );

    await cubit.load();

    expect(cubit.state.canSwitchScope, isFalse);
  });

  test('pages with the cursor and stops at the end', () async {
    server.nearby.addAll([for (var i = 0; i < 25; i++) row(i)]);

    await cubit.load();
    expect(cubit.state.items, hasLength(20));
    expect(cubit.state.hasMore, isTrue);

    await cubit.loadMore();
    expect(cubit.state.items, hasLength(25));
    expect(cubit.state.hasMore, isFalse);
    expect(cubit.state.loadingMore, isFalse);

    await cubit.loadMore();
    expect(server.calls, ['nearby', 'nearby']);
  });

  test('a failed next page keeps the rows and the cursor', () async {
    server.nearby.addAll([for (var i = 0; i < 25; i++) row(i)]);
    await cubit.load();
    server.nearbyRefusals.add(const NetworkException('offline'));

    await cubit.loadMore();

    expect(cubit.state.load, NearbyLoad.ready);
    expect(cubit.state.items, hasLength(20));
    expect(cubit.state.hasMore, isTrue);
    expect(cubit.state.error, isA<NetworkException>());
  });

  test('switching scope starts a fresh page at that scope', () async {
    server.nearby.addAll([for (var i = 0; i < 3; i++) row(i)]);
    await cubit.load();

    await cubit.setScope(pb.NearbyScope.NEARBY_SCOPE_CITY);

    expect(cubit.state.scope, pb.NearbyScope.NEARBY_SCOPE_CITY);
    expect(cubit.state.load, NearbyLoad.ready);
    expect(server.nearbyScopes, [
      pb.NearbyScope.NEARBY_SCOPE_AREA,
      pb.NearbyScope.NEARBY_SCOPE_CITY,
    ]);

    // The same scope again sends nothing.
    await cubit.setScope(pb.NearbyScope.NEARBY_SCOPE_CITY);
    expect(server.nearbyScopes, hasLength(2));
  });

  test('a failed first page is an error that load() retries', () async {
    server.nearbyRefusals.add(const NetworkException('offline'));

    await cubit.load();
    expect(cubit.state.load, NearbyLoad.error);
    expect(cubit.state.error, isA<NetworkException>());

    server.nearby.add(row(1));
    await cubit.load();
    expect(cubit.state.load, NearbyLoad.ready);
    expect(cubit.state.items, hasLength(1));
  });

  test('FEATURE_DISABLED is its own state', () async {
    server.nearbyRefusals.add(
      const FeatureDisabledException('off', feature: 'location'),
    );

    await cubit.load();

    expect(cubit.state.load, NearbyLoad.disabled);
  });

  test('a refresh keeps the rows on screen while it runs', () async {
    server.nearby.addAll([for (var i = 0; i < 3; i++) row(i)]);
    await cubit.load();
    final loads = <NearbyLoad>[];
    final sub = cubit.stream.listen((s) => loads.add(s.load));

    await cubit.load();
    await sub.cancel();

    expect(loads, everyElement(NearbyLoad.ready));
  });
}
