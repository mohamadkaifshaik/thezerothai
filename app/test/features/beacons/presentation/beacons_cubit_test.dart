import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacons_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacons_state.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as cpb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

pb.BeaconView _view(String id) => pb.BeaconView(
  beacon: pb.Beacon(beaconId: id, title: 'Plan $id'),
  viewer: pb.ViewerState(),
);

cpb.Community _community(String id, String name) => cpb.Community(
  communityId: id,
  name: name,
  viewerRole: cpb.CommunityRole.COMMUNITY_ROLE_MEMBER,
);

/// `/plans`: audience chips (Public, then the caller's joined communities)
/// and one ListBeacons per selected chip, paged with "Load more" (R30).
void main() {
  late _MockBeacons beacons;
  late _MockCommunities communities;
  late List<({String communityId, int limit, String pageToken})> calls;

  setUp(() {
    beacons = _MockBeacons();
    communities = _MockCommunities();
    calls = [];
  });

  void stubList(BeaconsPage Function(String communityId, String token) answer) {
    when(
      () => beacons.listBeacons(
        communityId: any(named: 'communityId'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((inv) async {
      final id = inv.namedArguments[#communityId] as String;
      final token = inv.namedArguments[#pageToken] as String;
      calls.add((
        communityId: id,
        limit: inv.namedArguments[#limit] as int,
        pageToken: token,
      ));
      return answer(id, token);
    });
  }

  void stubMine(List<cpb.Community> mine) {
    when(() => communities.myCommunities(refresh: any(named: 'refresh')))
        .thenAnswer(
          (_) async => MyCommunities(communities: mine, canCreate: false),
        );
  }

  test('communities off: Public only, one public ListBeacons of 20', () async {
    stubList((_, _) => BeaconsPage(views: [_view('1'), _view('2')]));
    final cubit = BeaconsCubit(repository: beacons);

    await cubit.load();

    expect(cubit.state.status, BeaconsLoad.ready);
    expect(cubit.state.audiences, [const BeaconsAudience.public()]);
    expect(cubit.state.selected, const BeaconsAudience.public());
    expect(cubit.state.views.map((v) => v.beacon.beaconId), ['1', '2']);
    expect(cubit.state.hasMore, isFalse);
    expect(calls, [(communityId: '', limit: 20, pageToken: '')]);
    verifyNever(() => communities.myCommunities());
  });

  test('communities on: a chip per joined community, Public still first and '
      'loaded alone', () async {
    stubMine([_community('c1', 'Gardeners'), _community('c2', 'Runners')]);
    stubList((_, _) => BeaconsPage(views: [_view('1')]));
    final cubit = BeaconsCubit(
      repository: beacons,
      communities: communities,
      communitiesEnabled: true,
    );

    await cubit.load();

    expect(cubit.state.audiences, [
      const BeaconsAudience.public(),
      const BeaconsAudience.community('c1', 'Gardeners'),
      const BeaconsAudience.community('c2', 'Runners'),
    ]);
    expect(calls.map((c) => c.communityId), ['']);
  });

  test('select loads that community and replaces the rows', () async {
    stubMine([_community('c1', 'Gardeners')]);
    stubList(
      (id, _) => BeaconsPage(views: [_view(id.isEmpty ? 'pub' : 'c1-a')]),
    );
    final cubit = BeaconsCubit(
      repository: beacons,
      communities: communities,
      communitiesEnabled: true,
    );
    await cubit.load();

    await cubit.select(const BeaconsAudience.community('c1', 'Gardeners'));

    expect(cubit.state.selected.id, 'c1');
    expect(cubit.state.views.single.beacon.beaconId, 'c1-a');
    expect(calls.last.communityId, 'c1');
    expect(calls.last.pageToken, '');
  });

  test(
    'loadMore appends with the token and ends when the token is empty',
    () async {
      stubList(
        (_, token) => token.isEmpty
            ? BeaconsPage(views: [_view('1')], nextPageToken: 't1')
            : BeaconsPage(views: [_view('2')]),
      );
      final cubit = BeaconsCubit(repository: beacons);
      await cubit.load();
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();

      expect(cubit.state.views.map((v) => v.beacon.beaconId), ['1', '2']);
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.loadingMore, isFalse);
      expect(calls.last.pageToken, 't1');
      await cubit.loadMore(); // nothing more to load: no call
      expect(calls, hasLength(2));
    },
  );

  test(
    'a failing communities lookup leaves Public only and still loads',
    () async {
      when(() => communities.myCommunities(refresh: any(named: 'refresh')))
          .thenThrow(NetworkException('offline'));
      stubList((_, _) => BeaconsPage(views: [_view('1')]));
      final cubit = BeaconsCubit(
        repository: beacons,
        communities: communities,
        communitiesEnabled: true,
      );

      await cubit.load();

      expect(cubit.state.audiences, [const BeaconsAudience.public()]);
      expect(cubit.state.status, BeaconsLoad.ready);
      expect(cubit.state.views, hasLength(1));
    },
  );

  test('a refused community chip shows the error and no rows', () async {
    stubMine([_community('c1', 'Gardeners')]);
    stubList((id, _) {
      if (id == 'c1') {
        throw CommunityForbiddenException(CommunityForbiddenReason.notMember);
      }
      return BeaconsPage(views: [_view('pub')]);
    });
    final cubit = BeaconsCubit(
      repository: beacons,
      communities: communities,
      communitiesEnabled: true,
    );
    await cubit.load();

    await cubit.select(const BeaconsAudience.community('c1', 'Gardeners'));

    expect(cubit.state.status, BeaconsLoad.error);
    expect(cubit.state.error, isA<CommunityForbiddenException>());
    expect(cubit.state.views, isEmpty);

    await cubit.select(const BeaconsAudience.public());
    expect(cubit.state.status, BeaconsLoad.ready);
    expect(cubit.state.error, isNull);
    expect(cubit.state.views.single.beacon.beaconId, 'pub');
  });

  test('a stale answer is ignored', () async {
    stubMine([_community('c1', 'Gardeners')]);
    final slowPublic = Completer<BeaconsPage>();
    when(
      () => beacons.listBeacons(
        communityId: any(named: 'communityId'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((inv) {
      final id = inv.namedArguments[#communityId] as String;
      if (id.isEmpty) return slowPublic.future;
      return Future.value(BeaconsPage(views: [_view('c1-a')]));
    });
    final cubit = BeaconsCubit(
      repository: beacons,
      communities: communities,
      communitiesEnabled: true,
    );

    final first = cubit.load();
    await Future<void>.delayed(Duration.zero);
    await cubit.select(const BeaconsAudience.community('c1', 'Gardeners'));
    slowPublic.complete(BeaconsPage(views: [_view('pub')]));
    await first;

    expect(cubit.state.selected.id, 'c1');
    expect(cubit.state.views.single.beacon.beaconId, 'c1-a');
  });
}
