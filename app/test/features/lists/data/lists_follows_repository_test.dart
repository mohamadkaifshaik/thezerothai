import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/lists_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

const _key = 'key-0123456789-abcdef';

pb.ListInfo _info(String id, {int followers = 3, bool following = false}) =>
    pb.ListInfo(
      listId: id,
      name: 'List $id',
      followerCount: followers,
      followedByViewer: following,
    );

void main() {
  late FakeTransport transport;
  late ListsRepository repo;
  late List<Object> requests;
  late List<String> procedures;
  late Object Function(String procedure) answer;
  late ServiceFeatureGate gate;
  var enabled = true;

  setUp(() {
    enabled = true;
    requests = [];
    procedures = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      procedures.add(procedure.split('/').last);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    gate = ServiceFeatureGate(
      isEnabled: () => enabled,
      onUnexpectedError: (_, _) {},
    );
    repo = ListsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: gate,
      epoch: SessionEpoch(),
    );
  });

  test('newIdempotencyKey fits 16-64 chars of [A-Za-z0-9_-]', () {
    final key = ListsRepository.newIdempotencyKey();
    expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    expect(ListsRepository.newIdempotencyKey(), isNot(key));
  });

  test('followList sends the key and notes the new header', () async {
    answer = (_) =>
        pb.FollowListResponse(list: _info('1', followers: 4, following: true));

    final list = await repo.followList(idempotencyKey: _key, listId: '1');

    final sent = requests.single as pb.FollowListRequest;
    expect(sent.idempotencyKey, _key);
    expect(sent.listId, '1');
    expect(list.followedByViewer, isTrue);
    expect(repo.header('1')?.followerCount, 4);
  });

  test('unfollowList builds the header from the last one seen', () async {
    repo.noteListInfo(_info('1', followers: 4, following: true));
    answer = (_) => pb.UnfollowListResponse();

    final list = await repo.unfollowList(idempotencyKey: _key, listId: '1');

    expect(list?.followedByViewer, isFalse);
    expect(list?.followerCount, 3);
    expect(repo.header('1')?.followerCount, 3);
  });

  test('unfollowList without a known header returns null', () async {
    answer = (_) => pb.UnfollowListResponse();
    expect(await repo.unfollowList(idempotencyKey: _key, listId: '9'), isNull);
  });

  test(
    'listFollowedLists and discoverLists send page size and token',
    () async {
      answer = (p) => p.endsWith('ListFollowedLists')
          ? pb.ListFollowedListsResponse(
              lists: [_info('1')],
              nextPageToken: 'n',
            )
          : pb.DiscoverListsResponse(lists: [_info('2')], nextPageToken: 'm');

      final followed = await repo.listFollowedLists(pageToken: 't');
      final found = await repo.discoverLists();

      final a = requests[0] as pb.ListFollowedListsRequest;
      expect(a.pageSize, kListFollowsPageSize);
      expect(a.pageToken, 't');
      expect(followed.nextPageToken, 'n');
      expect(
        (requests[1] as pb.DiscoverListsRequest).pageSize,
        kListFollowsPageSize,
      );
      expect(found.lists.single.listId, '2');
      expect(found.hasMore, isTrue);
    },
  );

  test('listSuggestedMembers asks for 10 by default', () async {
    answer = (_) => pb.ListSuggestedMembersResponse(
      users: [graph.UserListItem(user: common.AuthorSnapshot(userId: 'u1'))],
    );

    final users = await repo.listSuggestedMembers(listId: '1');

    final sent = requests.single as pb.ListSuggestedMembersRequest;
    expect(sent.maxResults, kListSuggestionsMax);
    expect(users.single.user.userId, 'u1');
  });

  test('the lists gate being off sends nothing', () async {
    enabled = false;
    await expectLater(
      repo.discoverLists(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
  });

  test('UNIMPLEMENTED reads as "not available yet" for the new flag and does '
      'not trip the lists gate', () async {
    answer = (_) => connect.ConnectException(connect.Code.unimplemented, 'no');

    await expectLater(
      repo.followList(idempotencyKey: _key, listId: '1'),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureListFollows,
        ),
      ),
    );
    expect(gate.enabled, isTrue);
  });

  test('FEATURE_DISABLED of a follow RPC does not switch Lists off', () async {
    answer = (_) => const FeatureDisabledException('off', feature: 'x');
    await expectLater(
      repo.listSuggestedMembers(listId: '1'),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureListSuggestions,
        ),
      ),
    );
    expect(gate.enabled, isTrue);
  });

  test('NOT_FOUND is typed', () async {
    answer = (_) => connect.ConnectException(connect.Code.notFound, 'x');
    await expectLater(
      repo.followList(idempotencyKey: _key, listId: '1'),
      throwsA(isA<NotFoundException>()),
    );
  });
}
