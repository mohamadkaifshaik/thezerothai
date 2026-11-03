import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

const _key = 'key-0123456789-abcdef';

pb.Community _c(
  String id, {
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
}) => pb.Community(
  communityId: id,
  name: 'C$id',
  memberCount: Int64(3),
  viewerRole: role,
);

/// The caller's communities are a session cache, so the composer's
/// audience picker costs 0 calls once they are known.
void main() {
  late FakeTransport transport;
  late CommunitiesRepository repo;
  late SessionEpoch epoch;
  late int listCalls;
  late List<pb.Community> server;

  setUp(() {
    listCalls = 0;
    server = [_c('1'), _c('2')];
    epoch = SessionEpoch();
    transport = FakeTransport((procedure, input) async {
      if (procedure.endsWith('/ListMyCommunities')) {
        listCalls++;
        return pb.ListMyCommunitiesResponse(communities: server);
      }
      if (procedure.endsWith('/JoinCommunity')) {
        final id = (input as pb.JoinCommunityRequest).communityId;
        return pb.JoinCommunityResponse(community: _c(id));
      }
      if (procedure.endsWith('/LeaveCommunity')) {
        final id = (input as pb.LeaveCommunityRequest).communityId;
        return pb.LeaveCommunityResponse(
          community: _c(id, role: pb.CommunityRole.COMMUNITY_ROLE_NONE),
        );
      }
      throw StateError('unscripted $procedure');
    });
    repo = CommunitiesRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => true,
        onUnexpectedError: (_, _) {},
      ),
      epoch: epoch,
    );
  });

  test('nothing is cached before the first read', () {
    expect(repo.cachedMine, isNull);
  });

  test('the second read is free; refresh asks again', () async {
    await repo.myCommunities();
    await repo.myCommunities();
    expect(listCalls, 1);
    expect(repo.cachedMine!.communities, hasLength(2));
    await repo.myCommunities(refresh: true);
    expect(listCalls, 2);
  });

  test('concurrent readers share one call', () async {
    await Future.wait([repo.myCommunities(), repo.myCommunities()]);
    expect(listCalls, 1);
  });

  test(
    'the Communities screen read fills the cache for the composer',
    () async {
      await repo.listMyCommunities(pageSize: 50);
      await repo.myCommunities();
      expect(listCalls, 1);
    },
  );

  test('a later page never replaces the cache', () async {
    await repo.listMyCommunities(pageToken: 'next');
    expect(repo.cachedMine, isNull);
  });

  test('join adds the community, leave removes it', () async {
    await repo.myCommunities();
    await repo.joinCommunity(idempotencyKey: _key, communityId: '3');
    expect(repo.cachedMine!.communities.map((c) => c.communityId), [
      '1',
      '2',
      '3',
    ]);
    await repo.leaveCommunity(idempotencyKey: _key, communityId: '1');
    expect(repo.cachedMine!.communities.map((c) => c.communityId), ['2', '3']);
    expect(listCalls, 1);
  });

  test('forgetCommunity drops one row', () async {
    await repo.myCommunities();
    repo.forgetCommunity('2');
    expect(repo.cachedMine!.communities.map((c) => c.communityId), ['1']);
  });

  test('sign-out (the session epoch) ends the cache', () async {
    await repo.myCommunities();
    epoch.end();
    expect(repo.cachedMine, isNull);
    await repo.myCommunities();
    expect(listCalls, 2);
  });

  test('a read that finishes after sign-out is not kept', () async {
    final pending = repo.listMyCommunities();
    epoch.end();
    await pending;
    expect(repo.cachedMine, isNull);
  });
}
