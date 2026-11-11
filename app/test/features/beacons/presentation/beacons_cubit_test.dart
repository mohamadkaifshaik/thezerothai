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

  // Tablet T5: the hoisted list is shown by two placements; the band B list
  // pane only makes sure it is loaded, the route's open refreshes it, and a
  // refresh never doubles a load in flight.
  group('ensureLoaded and refresh', () {
    test('ensureLoaded loads the first time only', () async {
      stubList((_, _) => BeaconsPage(views: [_view('1')]));
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);

      expect(cubit.started, isFalse);
      await cubit.ensureLoaded();
      expect(cubit.started, isTrue);
      await cubit.ensureLoaded();
      expect(calls, hasLength(1));
      expect(cubit.state.views.single.beacon.beaconId, '1');
    });

    test(
      'refresh while the first load is in flight sends nothing more',
      () async {
        final gate = Completer<BeaconsPage>();
        when(
          () => beacons.listBeacons(
            communityId: any(named: 'communityId'),
            limit: any(named: 'limit'),
            pageToken: any(named: 'pageToken'),
          ),
        ).thenAnswer((inv) {
          calls.add((
            communityId: inv.namedArguments[#communityId] as String,
            limit: inv.namedArguments[#limit] as int,
            pageToken: inv.namedArguments[#pageToken] as String,
          ));
          return calls.length == 1
              ? gate.future
              : Future.value(BeaconsPage(views: [_view('2')]));
        });
        final cubit = BeaconsCubit(repository: beacons);
        addTearDown(cubit.close);

        final first = cubit.ensureLoaded();
        await cubit.refresh();
        expect(calls, hasLength(1));
        gate.complete(BeaconsPage(views: [_view('1')]));
        await first;
        expect(cubit.state.views.single.beacon.beaconId, '1');

        // Done: a refresh is one more ListBeacons, and the rows stay on screen
        // while it runs (no skeleton).
        final again = cubit.refresh();
        expect(cubit.state.status, BeaconsLoad.ready);
        await again;
        expect(calls, hasLength(2));
        expect(cubit.state.views.single.beacon.beaconId, '2');
      },
    );

    test(
      'a failed load still counts as started; refresh tries again',
      () async {
        var fail = true;
        when(
          () => beacons.listBeacons(
            communityId: any(named: 'communityId'),
            limit: any(named: 'limit'),
            pageToken: any(named: 'pageToken'),
          ),
        ).thenAnswer((inv) async {
          calls.add((communityId: '', limit: 20, pageToken: ''));
          if (fail) throw NetworkException('offline');
          return BeaconsPage(views: [_view('1')]);
        });
        final cubit = BeaconsCubit(repository: beacons);
        addTearDown(cubit.close);

        await cubit.ensureLoaded();
        expect(cubit.state.status, BeaconsLoad.error);
        await cubit.ensureLoaded();
        expect(calls, hasLength(1));

        fail = false;
        await cubit.refresh();
        expect(calls, hasLength(2));
        expect(cubit.state.status, BeaconsLoad.ready);
      },
    );
  });

  // F29: the activity chips. The server filters (a filtered first page is
  // never emptied on the client); a server without the filter answers the
  // whole list, and the rows of other activities are dropped.
  group('activity filter (F29)', () {
    const coffee = pb.BeaconActivity.BEACON_ACTIVITY_COFFEE;
    const walk = pb.BeaconActivity.BEACON_ACTIVITY_WALK;
    const all = pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED;
    late List<({String communityId, pb.BeaconActivity activity, String token})>
    sent;

    setUpAll(() => registerFallbackValue(all));

    pb.BeaconView act(String id, pb.BeaconActivity a) =>
        _view(id)..beacon.activity = a;

    void stubActivity(
      BeaconsPage Function(pb.BeaconActivity activity, String token) answer,
    ) {
      sent = [];
      when(
        () => beacons.listBeacons(
          communityId: any(named: 'communityId'),
          limit: any(named: 'limit'),
          pageToken: any(named: 'pageToken'),
          activity: any(named: 'activity'),
        ),
      ).thenAnswer((inv) async {
        final a = inv.namedArguments[#activity] as pb.BeaconActivity;
        final token = inv.namedArguments[#pageToken] as String;
        sent.add((
          communityId: inv.namedArguments[#communityId] as String,
          activity: a,
          token: token,
        ));
        return answer(a, token);
      });
    }

    test('starts on All and sends no filter', () async {
      stubActivity((_, _) => BeaconsPage(views: [act('1', coffee)]));
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.activity, all);
      expect(sent.single.activity, all);
    });

    test('selectActivity loads a fresh first page of that activity', () async {
      stubActivity(
        (a, _) => a == coffee
            ? BeaconsPage(views: [act('c', coffee)])
            : BeaconsPage(views: [act('1', walk)], nextPageToken: 't1'),
      );
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);
      await cubit.load();

      final pending = cubit.selectActivity(coffee);
      expect(cubit.state.activity, coffee);
      expect(cubit.state.status, BeaconsLoad.loading);
      expect(cubit.state.views, isEmpty);
      expect(cubit.state.hasMore, isFalse);
      await pending;

      expect(cubit.state.views.single.beacon.beaconId, 'c');
      expect(sent.last, (communityId: '', activity: coffee, token: ''));

      // The same chip again sends nothing; All goes back to the whole list.
      await cubit.selectActivity(coffee);
      expect(sent, hasLength(2));
      await cubit.selectActivity(all);
      expect(sent.last.activity, all);
      expect(cubit.state.views.single.beacon.beaconId, '1');
    });

    test('Load more keeps the activity', () async {
      stubActivity(
        (a, token) => token.isEmpty
            ? BeaconsPage(views: [act('1', a)], nextPageToken: 't1')
            : BeaconsPage(views: [act('2', a)]),
      );
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.selectActivity(walk);

      await cubit.loadMore();

      expect(sent.last, (communityId: '', activity: walk, token: 't1'));
      expect(cubit.state.views.map((v) => v.beacon.beaconId), ['1', '2']);
    });

    test('switching the audience keeps the activity; a reload keeps it '
        'too', () async {
      stubMine([_community('c1', 'Gardeners')]);
      stubActivity((a, _) => BeaconsPage(views: [act('x', a)]));
      final cubit = BeaconsCubit(
        repository: beacons,
        communities: communities,
        communitiesEnabled: true,
      );
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.selectActivity(walk);

      await cubit.select(const BeaconsAudience.community('c1', 'Gardeners'));
      expect(sent.last, (communityId: 'c1', activity: walk, token: ''));

      await cubit.load();
      expect(sent.last, (communityId: 'c1', activity: walk, token: ''));
      expect(cubit.state.activity, walk);
    });

    test('a server without the filter: rows of other activities are '
        'dropped, on the first page and on Load more', () async {
      // An old server ignores `activity` and answers everything.
      stubActivity(
        (_, token) => token.isEmpty
            ? BeaconsPage(
                views: [act('w1', walk), act('c1', coffee), act('w2', walk)],
                nextPageToken: 't1',
              )
            : BeaconsPage(views: [act('c2', coffee), act('w3', walk)]),
      );
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.views, hasLength(3));

      await cubit.selectActivity(coffee);
      expect(cubit.state.views.map((v) => v.beacon.beaconId), ['c1']);
      await cubit.loadMore();
      expect(cubit.state.views.map((v) => v.beacon.beaconId), ['c1', 'c2']);
    });

    test('a filtered page left empty that has more keeps its token (Load '
        'more, not the empty state)', () async {
      stubActivity(
        (_, token) => token.isEmpty
            ? BeaconsPage(views: [act('w1', walk)], nextPageToken: 't1')
            : BeaconsPage(views: [act('c1', coffee)]),
      );
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.selectActivity(coffee);
      expect(cubit.state.status, BeaconsLoad.ready);
      expect(cubit.state.views, isEmpty);
      expect(cubit.state.hasMore, isTrue);
      await cubit.loadMore();
      expect(cubit.state.views.single.beacon.beaconId, 'c1');
    });

    test('a stale answer of the previous activity is ignored', () async {
      final slow = Completer<BeaconsPage>();
      sent = [];
      when(
        () => beacons.listBeacons(
          communityId: any(named: 'communityId'),
          limit: any(named: 'limit'),
          pageToken: any(named: 'pageToken'),
          activity: any(named: 'activity'),
        ),
      ).thenAnswer((inv) {
        final a = inv.namedArguments[#activity] as pb.BeaconActivity;
        if (a == all) return slow.future;
        return Future.value(BeaconsPage(views: [act('c', coffee)]));
      });
      final cubit = BeaconsCubit(repository: beacons);
      addTearDown(cubit.close);

      final first = cubit.load();
      await Future<void>.delayed(Duration.zero);
      await cubit.selectActivity(coffee);
      slow.complete(BeaconsPage(views: [act('w', walk)]));
      await first;

      expect(cubit.state.activity, coffee);
      expect(cubit.state.views.single.beacon.beaconId, 'c');
    });
  });
}
