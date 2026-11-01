import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/domain/community_role.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _svc = '/dzeroth.communities.v1.CommunityService/';
const _key = 'key-0123456789-abcdef';
const _cid = '1234567890123456789';

pb.Community community({
  String id = _cid,
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_NONE,
}) => pb.Community(
  communityId: id,
  name: 'Gardeners',
  memberCount: Int64(3),
  viewerRole: role,
);

void main() {
  late FakeTransport transport;
  late CommunitiesRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var enabled = true;
  var reported = 0;

  setUp(() {
    enabled = true;
    reported = 0;
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = CommunitiesRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onUnexpectedError: (_, _) => reported++,
      ),
    );
  });

  String lastProcedure() =>
      transport.calledProcedures.last.substring(_svc.length);

  test('createCommunity sends the key, text and rules', () async {
    answer = (_) => pb.CreateCommunityResponse(community: community());

    final r = await repo.createCommunity(
      idempotencyKey: _key,
      name: 'Gardeners',
      description: 'Plants',
      rules: [pb.CommunityRule(title: 'Be kind', text: 'Always')],
    );

    final sent = requests.single as pb.CreateCommunityRequest;
    expect(lastProcedure(), 'CreateCommunity');
    expect(sent.idempotencyKey, _key);
    expect(sent.name, 'Gardeners');
    expect(sent.description, 'Plants');
    expect(sent.rules.single.title, 'Be kind');
    expect(r.community.communityId, _cid);
  });

  test('updateCommunity sends only the fields given (presence)', () async {
    answer = (_) => pb.UpdateCommunityResponse(community: community());

    await repo.updateCommunity(
      idempotencyKey: _key,
      communityId: _cid,
      description: '',
    );

    final sent = requests.single as pb.UpdateCommunityRequest;
    expect(sent.communityId, _cid);
    expect(sent.hasName(), isFalse);
    expect(sent.hasDescription(), isTrue);
    expect(sent.hasRules(), isFalse);
  });

  test('updateCommunity with an empty rules list removes every rule '
      '(set, empty)', () async {
    answer = (_) => pb.UpdateCommunityResponse(community: community());

    await repo.updateCommunity(
      idempotencyKey: _key,
      communityId: _cid,
      rules: const [],
    );

    final sent = requests.single as pb.UpdateCommunityRequest;
    expect(sent.hasRules(), isTrue);
    expect(sent.rules.rules, isEmpty);
  });

  test('join and leave return the header with the server role', () async {
    answer = (p) => p.endsWith('JoinCommunity')
        ? pb.JoinCommunityResponse(
            community: community(role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
          )
        : pb.LeaveCommunityResponse(community: community());

    final joined = await repo.joinCommunity(
      idempotencyKey: _key,
      communityId: _cid,
    );
    final left = await repo.leaveCommunity(
      idempotencyKey: _key,
      communityId: _cid,
    );

    expect((requests[0] as pb.JoinCommunityRequest).communityId, _cid);
    expect((requests[1] as pb.LeaveCommunityRequest).idempotencyKey, _key);
    expect(joined.role, CommunityRole.member);
    expect(left.role, CommunityRole.none);
  });

  test('getCommunity, directory and my communities hit their RPCs', () async {
    answer = (p) => switch (p.substring(_svc.length)) {
      'GetCommunity' => pb.GetCommunityResponse(community: community()),
      'ListCommunities' => pb.ListCommunitiesResponse(
        communities: [
          community(),
          community(id: '2'),
        ],
      ),
      'ListMyCommunities' => pb.ListMyCommunitiesResponse(
        communities: [community()],
        canCreate: true,
        nextPageToken: 'n',
      ),
      _ => throw StateError(p),
    };

    final one = await repo.getCommunity(_cid);
    final directory = await repo.listCommunities(pageSize: 20);
    final mine = await repo.listMyCommunities();

    expect((requests[0] as pb.GetCommunityRequest).communityId, _cid);
    expect((requests[1] as pb.ListCommunitiesRequest).pageSize, 20);
    expect(one.community.name, 'Gardeners');
    expect(directory.communities, hasLength(2));
    expect(directory.hasMore, isFalse);
    expect(mine.canCreate, isTrue);
    expect(mine.hasMore, isTrue);
  });

  test(
    'listMembers defaults to JOINED and passes the filter and token',
    () async {
      answer = (_) => pb.ListCommunityMembersResponse(
        members: [
          pb.CommunityMember(role: pb.CommunityRole.COMMUNITY_ROLE_OWNER),
        ],
        nextPageToken: 'm2',
      );

      final page = await repo.listMembers(communityId: _cid, pageToken: 'm1');
      await repo.listMembers(
        communityId: _cid,
        filter: pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED,
      );

      final first = requests[0] as pb.ListCommunityMembersRequest;
      expect(
        first.filter,
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
      );
      expect(first.pageToken, 'm1');
      expect(
        (requests[1] as pb.ListCommunityMembersRequest).filter,
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED,
      );
      expect(page.members.single.memberRole, CommunityRole.owner);
      expect(page.hasMore, isTrue);
    },
  );

  test(
    'hide, restore, set role and the log hit their RPCs with the key',
    () async {
      answer = (p) => switch (p.substring(_svc.length)) {
        'HideCommunityPost' => pb.HideCommunityPostResponse(),
        'RestoreCommunityPost' => pb.RestoreCommunityPostResponse(),
        'SetMemberRole' => pb.SetMemberRoleResponse(
          role: pb.CommunityRole.COMMUNITY_ROLE_BANNED,
          community: community(role: pb.CommunityRole.COMMUNITY_ROLE_OWNER),
        ),
        'ListModerationLog' => pb.ListModerationLogResponse(
          entries: [pb.ModerationLogEntry(seq: Int64(1))],
        ),
        _ => throw StateError(p),
      };

      await repo.hidePost(
        idempotencyKey: _key,
        communityId: _cid,
        postId: 'p1',
      );
      await repo.restorePost(
        idempotencyKey: _key,
        communityId: _cid,
        postId: 'p1',
      );
      final role = await repo.setMemberRole(
        idempotencyKey: _key,
        communityId: _cid,
        userId: 'u1',
        action: pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN,
      );
      final log = await repo.listModerationLog(communityId: _cid);

      final hide = requests[0] as pb.HideCommunityPostRequest;
      expect(
        [hide.idempotencyKey, hide.communityId, hide.postId],
        [_key, _cid, 'p1'],
      );
      expect((requests[1] as pb.RestoreCommunityPostRequest).postId, 'p1');
      final set = requests[2] as pb.SetMemberRoleRequest;
      expect(set.userId, 'u1');
      expect(set.action, pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN);
      expect(role.role, pb.CommunityRole.COMMUNITY_ROLE_BANNED);
      expect(log.entries, hasLength(1));
      expect(transport.calledProcedures.map((p) => p.substring(_svc.length)), [
        'HideCommunityPost',
        'RestoreCommunityPost',
        'SetMemberRole',
        'ListModerationLog',
      ]);
    },
  );

  test('a retry of a mutation with the same key sends the same key', () async {
    var fail = true;
    answer = (_) => fail
        ? connect.ConnectException(connect.Code.unavailable, 'blip')
        : pb.JoinCommunityResponse(community: community());

    await expectLater(
      repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
      throwsA(isA<NetworkException>()),
    );
    fail = false;
    await repo.joinCommunity(idempotencyKey: _key, communityId: _cid);

    expect(requests, hasLength(2));
    expect(
      (requests[1] as pb.JoinCommunityRequest).idempotencyKey,
      (requests[0] as pb.JoinCommunityRequest).idempotencyKey,
    );
  });

  test('flag off: no RPC, FEATURE_DISABLED communities', () async {
    enabled = false;

    await expectLater(
      repo.getCommunity(_cid),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(
      repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
    expect(repo.enabled, isFalse);
  });

  test('a server FEATURE_DISABLED is typed and stops further calls', () async {
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': kFeatureCommunities},
    );

    await expectLater(
      repo.getCommunity(_cid),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureCommunities,
        ),
      ),
    );
    await expectLater(
      repo.getCommunity(_cid),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, hasLength(1));
  });

  test('UNIMPLEMENTED is "not available yet": typed, not reported, '
      'gate stays on', () async {
    answer = (p) => p.endsWith('GetCommunity')
        ? connect.ConnectException(connect.Code.unimplemented, 'nope')
        : pb.ListCommunitiesResponse();

    await expectLater(
      repo.getCommunity(_cid),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureCommunities,
        ),
      ),
    );
    expect(reported, 0);
    expect(repo.enabled, isTrue);
    await repo.listCommunities();
  });

  test('NOT_FOUND is a typed NotFoundException', () async {
    answer = (_) =>
        connect.ConnectException(connect.Code.notFound, 'community not found');

    await expectLater(
      repo.getCommunity(_cid),
      throwsA(isA<NotFoundException>()),
    );
  });

  test('FORBIDDEN surfaces as CommunityForbiddenException by reason', () async {
    answer = (_) => serverError(
      connect.Code.permissionDenied,
      common.ErrorReason.ERROR_REASON_FORBIDDEN,
      metadata: {'reason': 'banned'},
    );

    await expectLater(
      repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
      throwsA(
        isA<CommunityForbiddenException>().having(
          (e) => e.reason,
          'reason',
          CommunityForbiddenReason.banned,
        ),
      ),
    );
  });

  test(
    'COMMUNITY_STATE surfaces as CommunityStateException by reason',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_COMMUNITY_STATE,
        metadata: {'reason': 'community_archived'},
      );

      await expectLater(
        repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
        throwsA(
          isA<CommunityStateException>().having(
            (e) => e.reason,
            'reason',
            CommunityStateReason.communityArchived,
          ),
        ),
      );
    },
  );

  test(
    'LIMIT_REACHED, QUOTA_EXCEEDED and RATE_LIMITED carry their names',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
        metadata: {'limit': kCommunitiesJoinedLimit},
      );
      await expectLater(
        repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
        throwsA(
          isA<LimitReachedException>().having(
            (e) => e.quota,
            'quota',
            'communities_joined',
          ),
        ),
      );

      answer = (_) => serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
        metadata: {'quota': kCommunityJoinsQuota},
      );
      await expectLater(
        repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
        throwsA(
          isA<QuotaExceededException>().having(
            (e) => e.quota,
            'quota',
            'community_joins',
          ),
        ),
      );

      answer = (_) => serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': kCommunityMutationDailyLimit},
      );
      await expectLater(
        repo.joinCommunity(idempotencyKey: _key, communityId: _cid),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limit',
            'community_mutation_daily',
          ),
        ),
      );
    },
  );
}
