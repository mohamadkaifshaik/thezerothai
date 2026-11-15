import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/location/data/location_repository.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pbenum.dart' as pbe;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

pb.LocationSettings _settings({String? area, bool granted = false}) =>
    pb.LocationSettings(
      area: area == null
          ? null
          : pb.AreaSummary(
              areaId: area,
              name: 'Some Area',
              kind: pbe.AreaKind.AREA_KIND_AREA,
              cityId: 'in.x',
              cityName: 'Xcity',
            ),
      consent: granted
          ? pb.ConsentState(
              action: pbe.LocationConsentAction.LOCATION_CONSENT_ACTION_GRANTED,
              copyVersion: 1,
            )
          : null,
      requiredCopyVersion: 1,
      currentCopyVersion: 4,
    );

void main() {
  late FakeTransport transport;
  late List<Object> requests;
  late bool enabled;
  late SessionEpoch epoch;
  Object? fail;
  var listPages = <pb.ListAreasResponse>[];

  LocationRepository build({int pageSize = 2}) => LocationRepository(
    apiClient: ApiClient.withTransport(transport),
    gate: ServiceFeatureGate(isEnabled: () => enabled),
    epoch: epoch,
    pageSize: pageSize,
  );

  setUp(() {
    enabled = true;
    fail = null;
    requests = [];
    epoch = SessionEpoch();
    listPages = [];
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final error = fail;
      if (error != null) throw error;
      return switch (input) {
        pb.GetLocationSettingsRequest() => pb.GetLocationSettingsResponse(
          settings: _settings(area: 'in.x.one', granted: true),
        ),
        pb.SetAreaRequest r => pb.SetAreaResponse(
          settings: _settings(area: r.areaId, granted: true),
        ),
        pb.ClearAreaRequest() => pb.ClearAreaResponse(settings: _settings()),
        pb.ListAreasRequest() => listPages.removeAt(0),
        _ => throw StateError('unexpected $input'),
      };
    });
  });

  test('getSettings maps the area and consent and is memoised', () async {
    final repo = build();
    final a = await repo.getSettings();
    final b = await repo.getSettings();
    expect(a.area?.id, 'in.x.one');
    expect(a.area?.label, 'Some Area, Xcity');
    expect(a.consentValid, isTrue);
    expect(a.currentCopyVersion, 4);
    expect(identical(a, b), isTrue);
    expect(requests, hasLength(1));
  });

  test('refresh and a new session epoch read again', () async {
    final repo = build();
    await repo.getSettings();
    await repo.getSettings(refresh: true);
    epoch.end();
    await repo.getSettings();
    expect(requests, hasLength(3));
  });

  test('a failed read is not remembered', () async {
    final repo = build();
    fail = connect.ConnectException(connect.Code.unavailable, 'down');
    await expectLater(repo.getSettings(), throwsA(isA<AppException>()));
    fail = null;
    await repo.getSettings();
    expect(requests, hasLength(2));
  });

  test('reads and clear bypass a closed gate; set does not', () async {
    enabled = false;
    final repo = build();
    await repo.getSettings();
    await repo.clearArea();
    expect(requests, hasLength(2));
    await expectLater(
      repo.setArea('in.x.one'),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(repo.catalog(), throwsA(isA<FeatureDisabledException>()));
    expect(requests, hasLength(2));
  });

  test('setArea sends the consent and a fresh key, then publishes', () async {
    final repo = build();
    final seen = <LocationSettingsData>[];
    repo.changes.listen(seen.add);
    await repo.setArea(
      'in.x.one',
      consent: const ConsentGrantData(copyVersion: 1, adultConfirmed: true),
    );
    await repo.setArea('in.x.two');
    final first = requests[0] as pb.SetAreaRequest;
    final second = requests[1] as pb.SetAreaRequest;
    expect(first.consent.copyVersion, 1);
    expect(first.consent.adultConfirmed, isTrue);
    expect(second.hasConsent(), isFalse);
    expect(first.idempotencyKey, isNot(second.idempotencyKey));
    expect(first.idempotencyKey, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(2));
    // The memo now holds the stored answer: no extra read.
    expect((await repo.getSettings()).area?.id, 'in.x.two');
    expect(requests, hasLength(2));
  });

  test('clearArea returns settings without an area', () async {
    final data = await build().clearArea();
    expect(data.area, isNull);
    expect(
      transportProcedure(transport),
      '/dzeroth.location.v1.LocationService/ClearArea',
    );
  });

  test('consent_required maps to a state conflict', () async {
    fail = connect.ConnectException(
      connect.Code.failedPrecondition,
      'consent',
      details: [
        connect.ErrorDetail(
          'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
          common.ErrorDetail(metadata: {'reason': 'consent_required'}.entries)
              .writeToBuffer(),
        ),
      ],
    );
    await expectLater(
      build().setArea('in.x.one'),
      throwsA(
        isA<StateConflictException>().having(
          (e) => e.reason,
          'reason',
          'consent_required',
        ),
      ),
    );
  });

  test(
    'catalog pages to the end and keeps the cache on not_modified',
    () async {
      pb.Area area(String id) => pb.Area(
        areaId: id,
        name: id,
        kind: pbe.AreaKind.AREA_KIND_AREA,
        cityId: 'in.x',
        cityName: 'Xcity',
        aliases: ['al'],
      );
      listPages = [
        pb.ListAreasResponse(
          areas: [area('in.x.a'), area('in.x.b')],
          nextPageToken: 't',
          version: Int64(7),
        ),
        pb.ListAreasResponse(areas: [area('in.x.c')], version: Int64(7)),
      ];
      final repo = build();
      final first = await repo.catalog();
      expect(first.areas.map((a) => a.ref.id), ['in.x.a', 'in.x.b', 'in.x.c']);
      expect(first.version, 7);
      expect(first.areas.first.aliases, ['al']);
      expect((requests[1] as pb.ListAreasRequest).pageToken, 't');

      listPages = [pb.ListAreasResponse(notModified: true, version: Int64(7))];
      final second = await repo.catalog();
      expect(identical(first, second), isTrue);
      expect((requests.last as pb.ListAreasRequest).knownVersion, Int64(7));
    },
  );
}

String transportProcedure(FakeTransport t) => t.calledProcedures.last;
