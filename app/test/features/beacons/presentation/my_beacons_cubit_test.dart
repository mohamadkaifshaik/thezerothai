import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacons_state.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/my_beacons_cubit.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

/// `/plans/mine` (R39): window and role go to the server; a selection starts
/// a fresh page; load-more appends.
void main() {
  late _MockBeacons beacons;
  late List<
    ({
      pb.MyBeaconsRole role,
      pb.MyBeaconsWindow window,
      int limit,
      String token,
    })
  >
  calls;
  final now = DateTime.now();

  setUpAll(() {
    registerFallbackValue(pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL);
    registerFallbackValue(pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING);
  });

  setUp(() {
    beacons = _MockBeacons();
    calls = [];
    when(
      () => beacons.listMyBeacons(
        role: any(named: 'role'),
        window: any(named: 'window'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((inv) async {
      final token = inv.namedArguments[#pageToken] as String;
      calls.add((
        role: inv.namedArguments[#role] as pb.MyBeaconsRole,
        window: inv.namedArguments[#window] as pb.MyBeaconsWindow,
        limit: inv.namedArguments[#limit] as int,
        token: token,
      ));
      return token.isEmpty
          ? BeaconsPage(
              views: [beaconView(startAt: now, id: kBeaconIdA)],
              nextPageToken: 't1',
            )
          : BeaconsPage(
              views: [beaconView(startAt: now, id: kBeaconIdB)],
            );
    });
  });

  test('load asks for ALL upcoming, 20 per page', () async {
    final c = MyBeaconsCubit(repository: beacons);
    await c.load();
    expect(c.state.status, BeaconsLoad.ready);
    expect(c.state.views.single.beacon.beaconId, kBeaconIdA);
    expect(c.state.hasMore, isTrue);
    expect(calls.single, (
      role: pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL,
      window: pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
      limit: 20,
      token: '',
    ));
  });

  test(
    'select changes one of window or role, keeps the other, and reloads',
    () async {
      final c = MyBeaconsCubit(repository: beacons);
      await c.load();

      await c.select(window: pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST);
      expect(calls.last.window, pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST);
      expect(calls.last.role, pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL);
      expect(calls.last.token, '');

      await c.select(role: pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER);
      expect(calls.last.window, pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST);
      expect(calls.last.role, pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER);
      expect(c.state.window, pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST);
      expect(c.state.role, pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER);
    },
  );

  test('loadMore appends with the token and ends', () async {
    final c = MyBeaconsCubit(repository: beacons);
    await c.load();
    await c.loadMore();
    expect(c.state.views.map((v) => v.beacon.beaconId), [
      kBeaconIdA,
      kBeaconIdB,
    ]);
    expect(c.state.hasMore, isFalse);
    expect(calls.last.token, 't1');
  });

  test('a failed load is an error', () async {
    when(
      () => beacons.listMyBeacons(
        role: any(named: 'role'),
        window: any(named: 'window'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(NetworkException('offline'));
    final c = MyBeaconsCubit(repository: beacons);
    await c.load();
    expect(c.state.status, BeaconsLoad.error);
    expect(c.state.error, isA<NetworkException>());
  });

  // Tablet T5: the "Your plans" section of `/plans` is this cubit with a
  // page of 2 (tablet plan section 4.1: "one extra list call, limit 2").
  group('Your plans (pageSize 2)', () {
    void answer(BeaconsPage page) {
      when(
        () => beacons.listMyBeacons(
          role: any(named: 'role'),
          window: any(named: 'window'),
          limit: any(named: 'limit'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((inv) async {
        calls.add((
          role: inv.namedArguments[#role] as pb.MyBeaconsRole,
          window: inv.namedArguments[#window] as pb.MyBeaconsWindow,
          limit: inv.namedArguments[#limit] as int,
          token: inv.namedArguments[#pageToken] as String,
        ));
        return page;
      });
    }

    test('one ListMyBeacons of 2: every role, upcoming, first page', () async {
      answer(
        BeaconsPage(
          views: [
            beaconView(startAt: now, id: kBeaconIdA),
            beaconView(startAt: now, id: kBeaconIdB),
          ],
          nextPageToken: '2',
        ),
      );
      final c = MyBeaconsCubit(repository: beacons, pageSize: 2);
      addTearDown(c.close);
      await c.load();

      expect(calls.single, (
        role: pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL,
        window: pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
        limit: 2,
        token: '',
      ));
      expect(c.state.status, BeaconsLoad.ready);
      expect(c.state.views.map((v) => v.beacon.beaconId), [
        kBeaconIdA,
        kBeaconIdB,
      ]);
    });

    test('an empty answer is ready with no rows', () async {
      answer(const BeaconsPage(views: []));
      final c = MyBeaconsCubit(repository: beacons, pageSize: 2);
      addTearDown(c.close);
      await c.load();

      expect(calls.single.limit, 2);
      expect(c.state.status, BeaconsLoad.ready);
      expect(c.state.views, isEmpty);
      expect(c.state.error, isNull);
    });

    test('a failure is an error with no rows', () async {
      when(
        () => beacons.listMyBeacons(
          role: any(named: 'role'),
          window: any(named: 'window'),
          limit: any(named: 'limit'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenThrow(NetworkException('offline'));
      final c = MyBeaconsCubit(repository: beacons, pageSize: 2);
      addTearDown(c.close);
      await c.load();

      expect(c.state.status, BeaconsLoad.error);
      expect(c.state.error, isA<NetworkException>());
      expect(c.state.views, isEmpty);
    });

    test('the default page is still 20', () async {
      final c = MyBeaconsCubit(repository: beacons);
      addTearDown(c.close);
      await c.load();
      expect(calls.single.limit, 20);
    });
  });

  // Tablet T5: the hoisted cubits are shown by two placements (the band A
  // list and the band B list pane); only the route's open refreshes.
  group('ensureLoaded and refresh', () {
    test('ensureLoaded loads the first time only', () async {
      final c = MyBeaconsCubit(repository: beacons, pageSize: 2);
      addTearDown(c.close);
      expect(c.started, isFalse);
      await c.ensureLoaded();
      expect(c.started, isTrue);
      await c.ensureLoaded();
      expect(calls, hasLength(1));
    });

    test('refresh while a load is in flight sends nothing more; after it, '
        'one more', () async {
      final gate = Completer<BeaconsPage>();
      when(
        () => beacons.listMyBeacons(
          role: any(named: 'role'),
          window: any(named: 'window'),
          limit: any(named: 'limit'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((inv) {
        calls.add((
          role: inv.namedArguments[#role] as pb.MyBeaconsRole,
          window: inv.namedArguments[#window] as pb.MyBeaconsWindow,
          limit: inv.namedArguments[#limit] as int,
          token: inv.namedArguments[#pageToken] as String,
        ));
        return calls.length == 1
            ? gate.future
            : Future.value(const BeaconsPage(views: []));
      });
      final c = MyBeaconsCubit(repository: beacons, pageSize: 2);
      addTearDown(c.close);

      final first = c.ensureLoaded();
      await c.refresh();
      expect(calls, hasLength(1));
      gate.complete(const BeaconsPage(views: []));
      await first;

      await c.refresh();
      expect(calls, hasLength(2));
    });
  });
}
