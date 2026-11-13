import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacons_state.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as cpb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// Tablet plan section 5.2: the Plans list cubit (and the "Your plans" one)
/// hoisted above both placements (the band A list and the band B list
/// pane), created lazily, rebuilt when the flags it captured change, and
/// dropped on a sign-out, an account switch or `beacons` turning off.
void main() {
  late FakeBeaconsServer server;
  late _MockCommunities communities;
  var communitiesOn = false;
  final now = DateTime.now();

  setUp(() {
    server = FakeBeaconsServer()
      ..public.add(beaconView(startAt: now.add(const Duration(hours: 1))))
      ..mine.addAll([
        beaconView(startAt: now.add(const Duration(hours: 2)), id: 'm1'),
        beaconView(startAt: now.add(const Duration(hours: 3)), id: 'm2'),
        beaconView(startAt: now.add(const Duration(hours: 4)), id: 'm3'),
      ]);
    communities = _MockCommunities();
    communitiesOn = false;
    when(() => communities.enabled).thenAnswer((_) => communitiesOn);
    when(
      () => communities.myCommunities(refresh: any(named: 'refresh')),
    ).thenAnswer(
      (_) async => MyCommunities(
        communities: [cpb.Community(communityId: 'c1', name: 'Coffee club')],
        canCreate: false,
      ),
    );
  });

  PlansSession session() {
    final s = PlansSession(repository: server, communities: communities);
    addTearDown(s.dispose);
    return s;
  }

  test('nothing is created or sent until a placement reads it', () {
    final s = session();
    expect(s.listIfCreated, isNull);
    expect(s.yourPlansIfCreated, isNull);
    expect(server.calls, isEmpty);
  });

  test('both placements read the same instances; reading sends nothing', () {
    final s = session();
    final list = s.list;
    final mine = s.yourPlans;
    expect(s.list, same(list));
    expect(s.yourPlans, same(mine));
    expect(server.calls, isEmpty);
  });

  test('"Your plans" asks ListMyBeacons for 2', () async {
    final s = session();
    await s.yourPlans.ensureLoaded();
    expect(PlansSession.yourPlansLimit, 2);
    expect(server.mineLimits, [2]);
    expect(s.yourPlans.state.views.map((v) => v.beacon.beaconId), ['m1', 'm2']);
  });

  test('"Your plans" empty: ready with no rows', () async {
    server.mine.clear();
    final s = session();
    await s.yourPlans.ensureLoaded();
    expect(s.yourPlans.state.status, BeaconsLoad.ready);
    expect(s.yourPlans.state.views, isEmpty);
  });

  test('"Your plans" failing leaves the list alone', () async {
    final s = session();
    await s.list.ensureLoaded();
    server.refusals.add(NetworkException('offline'));
    await s.yourPlans.ensureLoaded();
    expect(s.yourPlans.state.status, BeaconsLoad.error);
    expect(s.list.state.status, BeaconsLoad.ready);
    expect(s.list.state.error, isNull);
  });

  test('reset closes and drops both, and tells the placements', () async {
    final s = session();
    var notified = 0;
    s.changes.addListener(() => notified++);
    final list = s.list;
    final mine = s.yourPlans;
    await list.ensureLoaded();

    s.reset();

    expect(list.isClosed, isTrue);
    expect(mine.isClosed, isTrue);
    expect(s.listIfCreated, isNull);
    expect(s.yourPlansIfCreated, isNull);
    expect(notified, 1);
    // The next account's read is a fresh, empty cubit; nothing is sent.
    final calls = server.calls.length;
    expect(s.list, isNot(same(list)));
    expect(s.list.state.views, isEmpty);
    expect(server.calls, hasLength(calls));
  });

  test('reset with nothing created tells nobody', () {
    final s = session();
    var notified = 0;
    s.changes.addListener(() => notified++);
    s.reset();
    expect(notified, 0);
  });

  test('beacons turning off drops both', () async {
    final s = session();
    var notified = 0;
    s.changes.addListener(() => notified++);
    final list = s.list;
    await list.ensureLoaded();

    s.featuresChanged(const {});

    expect(list.isClosed, isTrue);
    expect(s.listIfCreated, isNull);
    expect(notified, 1);
  });

  test('the same flags keep the same list (no rebuild, no call)', () async {
    final s = session();
    final list = s.list;
    await list.ensureLoaded();
    final calls = server.calls.length;
    var notified = 0;
    s.changes.addListener(() => notified++);

    s.featuresChanged(const {kFeatureBeacons});

    expect(s.list, same(list));
    expect(list.isClosed, isFalse);
    expect(server.calls, hasLength(calls));
    expect(notified, 0);
  });

  test('communities turning on rebuilds a loaded list and loads it again: '
      'the chips come back', () async {
    final s = session();
    final list = s.list;
    await list.ensureLoaded();
    expect(list.state.audiences, [const BeaconsAudience.public()]);
    var notified = 0;
    s.changes.addListener(() => notified++);

    communitiesOn = true;
    s.featuresChanged(const {kFeatureBeacons, kFeatureCommunities});
    final rebuilt = s.list;
    await rebuilt.ensureLoaded();

    expect(list.isClosed, isTrue);
    expect(rebuilt, isNot(same(list)));
    expect(rebuilt.started, isTrue);
    expect(rebuilt.state.audiences.map((a) => a.name), [
      'Public',
      'Coffee club',
    ]);
    expect(notified, 1);
  });

  test('communities turning off rebuilds it with Public only', () async {
    communitiesOn = true;
    final s = session();
    final list = s.list;
    await list.ensureLoaded();
    expect(list.state.audiences, hasLength(2));

    communitiesOn = false;
    s.featuresChanged(const {kFeatureBeacons});
    await s.list.ensureLoaded();

    expect(list.isClosed, isTrue);
    expect(s.list.state.audiences, [const BeaconsAudience.public()]);
  });

  test('a flag change before any load drops the list without a call', () {
    final s = session();
    final list = s.list;

    communitiesOn = true;
    s.featuresChanged(const {kFeatureBeacons, kFeatureCommunities});

    expect(list.isClosed, isTrue);
    expect(s.listIfCreated, isNull);
    expect(server.calls, isEmpty);
  });

  test(
    '"Your plans" does not depend on communities: kept on that change',
    () async {
      final s = session();
      final mine = s.yourPlans;
      await mine.ensureLoaded();

      communitiesOn = true;
      s.featuresChanged(const {kFeatureBeacons, kFeatureCommunities});

      expect(s.yourPlans, same(mine));
      expect(mine.isClosed, isFalse);
    },
  );

  test('refreshAfterWrite reloads what was loaded, nothing else', () async {
    final s = session();
    await s.list.ensureLoaded();
    server.calls.clear();

    s.refreshAfterWrite();
    await pumpEventQueue();

    expect(server.calls, ['list:']);
    expect(s.yourPlansIfCreated, isNull);

    await s.yourPlans.ensureLoaded();
    server.calls.clear();
    s.refreshAfterWrite();
    await pumpEventQueue();
    expect(server.calls, unorderedEquals(['list:', 'mine']));
  });

  test('dispose closes both', () async {
    final s = PlansSession(repository: server, communities: communities);
    final list = s.list;
    final mine = s.yourPlans;
    s.dispose();
    expect(list.isClosed, isTrue);
    expect(mine.isClosed, isTrue);
  });
}
