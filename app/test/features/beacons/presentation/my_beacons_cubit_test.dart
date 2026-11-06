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
}
