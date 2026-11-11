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

  // F28: start, duration and cost (UpdateBeaconRequest 7-9). Unset means
  // unchanged; a server from before F28 ignores them and answers the old
  // values, which must not read as saved.
  group('start, duration and cost (F28)', () {
    final later = DateTime(now.year, now.month, now.day + 2, 18, 30);
    const split = pb.BeaconCost.BEACON_COST_SPLIT_EVENLY;

    pb.UpdateBeaconRequest? last;
    setUp(() => last = null);

    void answerWith(pb.BeaconView Function(pb.UpdateBeaconRequest r) view) {
      when(
        () => beacons.updateBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          request: any(named: 'request'),
        ),
      ).thenAnswer((inv) async {
        last = inv.namedArguments[#request] as pb.UpdateBeaconRequest;
        return view(last!);
      });
    }

    /// The server applies what it got, as F28 does.
    pb.BeaconView applied(pb.UpdateBeaconRequest r) {
      final v = beaconView(
        startAt: r.hasStartAt() ? r.startAt.toDateTime() : now,
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        accepted: 1,
        canManage: true,
      );
      if (r.hasDurationMinutes()) v.beacon.durationMinutes = r.durationMinutes;
      if (r.hasCost()) v.beacon.cost = r.cost;
      return v;
    }

    Future<EditBeaconCubit> loaded() async {
      final c = EditBeaconCubit(repository: beacons, beaconId: kBeaconIdA);
      addTearDown(c.close);
      await c.load();
      return c;
    }

    test('sends only the schedule fields that changed', () async {
      answerWith(applied);
      final c = await loaded();

      await c.save(
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        startAt: later,
        durationMinutes: 60, // the stored value: not a change
        cost: split,
      );

      expect(last!.hasStartAt(), isTrue);
      expect(last!.startAt.toDateTime(), later.toUtc());
      expect(last!.hasDurationMinutes(), isFalse);
      expect(last!.hasCost(), isTrue);
      expect(last!.cost, split);
      expect(last!.hasTitle(), isFalse);
      expect(c.state.saved, isNotNull);
      expect(c.state.saveError, isNull);
    });

    test('the stored start, duration and cost again: no call', () async {
      answerWith(applied);
      final c = await loaded();

      await c.save(
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        startAt: now,
        durationMinutes: 60,
        cost: pb.BeaconCost.BEACON_COST_FREE,
      );

      expect(last, isNull);
      expect(c.state.saved, isNotNull);
    });

    test('a server that ignores them (before F28): the form stays with its '
        'copy, nothing reads as saved', () async {
      // Applies the title only, as an old server would.
      answerWith(
        (r) => beaconView(
          startAt: now,
          title: r.hasTitle() ? r.title : 'Coffee',
          details: 'Bring a book',
          venue: 'Hall',
          openSpots: 3,
          accepted: 1,
          canManage: true,
        ),
      );
      final c = await loaded();

      await c.save(
        title: 'Tea',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        durationMinutes: 90,
      );

      expect(last!.durationMinutes, 90);
      expect(c.state.saved, isNull);
      expect(c.state.busy, isFalse);
      expect(c.state.saveError, kPlanScheduleNotSaved);
      // The view is the server's: the title went through, so a retry sends
      // the duration alone.
      expect(c.state.view?.beacon.title, 'Tea');
      expect(c.state.view?.beacon.durationMinutes, 60);
    });

    test('a refusal after the start reads as "started"', () async {
      when(
        () => beacons.updateBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          request: any(named: 'request'),
        ),
      ).thenThrow(StateConflictException('started'));
      final c = await loaded();

      await c.save(
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        cost: split,
      );

      expect(
        c.state.saveError,
        "This plan has started, so its time and cost can't change.",
      );
      expect(c.state.saved, isNull);
    });
  });
}
