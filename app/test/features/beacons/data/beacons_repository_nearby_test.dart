import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pb.dart' as loc;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pbenum.dart'
    as locenum;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

/// `ListNearbyBeacons` through the repository.
void main() {
  late FakeTransport transport;
  late BeaconsRepository repo;
  late List<Object> requests;
  late Object Function() answer;
  var enabled = true;

  setUp(() {
    enabled = true;
    requests = [];
    answer = () => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer();
      if (r is Exception) throw r;
      return r;
    });
    repo = BeaconsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => enabled),
    );
  });

  test('sends the stored area (empty id), scope and cursor', () async {
    answer = () => pb.ListNearbyBeaconsResponse();

    await repo.listNearby(
      scope: pb.NearbyScope.NEARBY_SCOPE_CITY,
      limit: 20,
      pageToken: 'p2',
    );

    final sent = requests.single as pb.ListNearbyBeaconsRequest;
    expect(transport.calledProcedures.single, endsWith('ListNearbyBeacons'));
    expect(sent.areaId, isEmpty);
    expect(sent.scope, pb.NearbyScope.NEARBY_SCOPE_CITY);
    expect(sent.limit, 20);
    expect(sent.pageToken, 'p2');
  });

  test('maps the items, the resolved area and the count', () async {
    answer = () => pb.ListNearbyBeaconsResponse(
      items: [
        pb.NearbyBeacon(
          view: pb.BeaconView(beacon: pb.Beacon(beaconId: '1')),
          proximity: pb.AreaProximity.AREA_PROXIMITY_NEIGHBOURING,
        ),
      ],
      nextPageToken: 'next',
      area: loc.AreaSummary(
        areaId: 'in.x.a',
        name: 'Alpha',
        kind: locenum.AreaKind.AREA_KIND_AREA,
        cityId: 'in.x',
        cityName: 'Xcity',
      ),
      count: pb.NearbyCount(plans: 14),
    );

    final page = await repo.listNearby();

    expect(page.items.single.view.beacon.beaconId, '1');
    expect(
      page.items.single.proximity,
      pb.AreaProximity.AREA_PROXIMITY_NEIGHBOURING,
    );
    expect(page.hasMore, isTrue);
    expect(page.area?.id, 'in.x.a');
    expect(page.area?.type, AreaType.area);
    expect(page.area?.cityName, 'Xcity');
    expect(page.count?.plans, 14);
  });

  test('a later page has no count and an unset area stays null', () async {
    answer = () => pb.ListNearbyBeaconsResponse();

    final page = await repo.listNearby(pageToken: 'p2');

    expect(page.count, isNull);
    expect(page.area, isNull);
    expect(page.hasMore, isFalse);
  });

  test('area_not_set is a typed state conflict', () async {
    answer = () => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      metadata: {'reason': 'area_not_set'},
    );

    await expectLater(
      repo.listNearby(),
      throwsA(
        isA<StateConflictException>().having(
          (e) => e.reason,
          'reason',
          'area_not_set',
        ),
      ),
    );
  });

  test('beacons flag off: no RPC', () async {
    enabled = false;

    await expectLater(
      repo.listNearby(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'a location FEATURE_DISABLED is typed and does not switch Plans off',
    () async {
      answer = () => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'location'},
      );

      await expectLater(
        repo.listNearby(),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            'location',
          ),
        ),
      );
      expect(repo.enabled, isTrue);
    },
  );
}
