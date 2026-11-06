import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/edit_beacon_cubit.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

/// `/plans/:id/edit`: load the plan, send only what changed (presence), one
/// key per distinct payload (R36).
void main() {
  late _MockBeacons beacons;
  final now = DateTime.now();

  setUpAll(() => registerFallbackValue(pb.UpdateBeaconRequest()));

  setUp(() {
    beacons = _MockBeacons();
    when(() => beacons.getBeacon(kBeaconIdA)).thenAnswer(
      (_) async => beaconView(
        startAt: now,
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        accepted: 1,
        canManage: true,
      ),
    );
  });

  List<Object?> sent() => verify(
    () => beacons.updateBeacon(
      idempotencyKey: captureAny(named: 'idempotencyKey'),
      request: captureAny(named: 'request'),
    ),
  ).captured;

  test('load is ready with the plan', () async {
    final c = EditBeaconCubit(repository: beacons, beaconId: kBeaconIdA);
    await c.load();
    expect(c.state.loading, isFalse);
    expect(c.state.view?.beacon.title, 'Coffee');
  });

  test(
    'save sends only the changed fields and reports the saved view',
    () async {
      when(
        () => beacons.updateBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          request: any(named: 'request'),
        ),
      ).thenAnswer(
        (_) async => beaconView(startAt: now, title: 'Tea', canManage: true),
      );
      final c = EditBeaconCubit(repository: beacons, beaconId: kBeaconIdA);
      await c.load();

      await c.save(
        title: 'Tea',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
      );

      final captured = sent();
      final r = captured[1] as pb.UpdateBeaconRequest;
      expect(r.beaconId, kBeaconIdA);
      expect(r.hasTitle(), isTrue);
      expect(r.title, 'Tea');
      expect(r.hasDetails(), isFalse);
      expect(r.hasVenue(), isFalse);
      expect(r.hasOpenSpots(), isFalse);
      expect(c.state.saved?.beacon.title, 'Tea');
      expect(c.state.busy, isFalse);
    },
  );

  test('nothing changed: no call, saved is the loaded view', () async {
    final c = EditBeaconCubit(repository: beacons, beaconId: kBeaconIdA);
    await c.load();

    await c.save(
      title: 'Coffee',
      details: 'Bring a book',
      venue: 'Hall',
      openSpots: 3,
    );

    verifyNever(
      () => beacons.updateBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    );
    expect(c.state.saved?.beacon.title, 'Coffee');
  });

  test('a refused save keeps the form with its copy; a retry reuses the key '
      '(Review Focus 4)', () async {
    var fail = true;
    when(
      () => beacons.updateBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    ).thenAnswer((_) async {
      if (fail) throw ValidationException('bad', field: 'open_spots');
      return beaconView(startAt: now, openSpots: 1, canManage: true);
    });
    final c = EditBeaconCubit(repository: beacons, beaconId: kBeaconIdA);
    await c.load();

    await c.save(
      title: 'Coffee',
      details: 'Bring a book',
      venue: 'Hall',
      openSpots: 1,
    );
    expect(
      c.state.saveError,
      "Open spots can't go below the people already going.",
    );
    expect(c.state.saved, isNull);
    fail = false;
    await c.save(
      title: 'Coffee',
      details: 'Bring a book',
      venue: 'Hall',
      openSpots: 1,
    );
    expect(c.state.saved, isNotNull);

    final captured = sent();
    expect(captured[0], captured[2]);
    expect((captured[1] as pb.UpdateBeaconRequest).openSpots, 1);
  });
}
