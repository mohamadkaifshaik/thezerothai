import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/lists_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _svc = '/dzeroth.lists.v1.ListService/';
const _key = 'key-0123456789-abcdef';

pb.ListInfo info(String id, {String name = 'Friends', bool priv = true}) =>
    pb.ListInfo(listId: id, name: name, isPrivate: priv, memberCount: 2);

void main() {
  late FakeTransport transport;
  late ListsRepository repo;
  late List<Object> requests;
  late List<pb.ListInfo> seen;
  late Object Function(String procedure) answer;
  var enabled = true;
  var reported = 0;

  setUp(() {
    enabled = true;
    reported = 0;
    requests = [];
    seen = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = ListsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onUnexpectedError: (_, _) => reported++,
      ),
      onListSeen: seen.add,
    );
  });

  test(
    'createList sends the key and leaves is_private out when null',
    () async {
      answer = (_) => pb.CreateListResponse(list: info('1'));

      final created = await repo.createList(
        idempotencyKey: _key,
        name: 'Friends',
      );

      final sent = requests.single as pb.CreateListRequest;
      expect(sent.idempotencyKey, _key);
      expect(sent.name, 'Friends');
      expect(sent.hasIsPrivate(), isFalse);
      expect(created.listId, '1');
      expect(seen.single.name, 'Friends');
    },
  );

  test('createList sends is_private when given', () async {
    answer = (_) => pb.CreateListResponse(list: info('1', priv: false));

    await repo.createList(idempotencyKey: _key, name: 'Pub', isPrivate: false);

    final sent = requests.single as pb.CreateListRequest;
    expect(sent.hasIsPrivate(), isTrue);
    expect(sent.isPrivate, isFalse);
  });

  test('updateList sends only the fields given (presence)', () async {
    answer = (_) => pb.UpdateListResponse(list: info('1', name: 'New'));

    await repo.updateList(idempotencyKey: _key, listId: '1', description: '');

    final sent = requests.single as pb.UpdateListRequest;
    expect(sent.hasName(), isFalse);
    expect(sent.hasDescription(), isTrue);
    expect(sent.hasIsPrivate(), isFalse);
  });

  test(
    'listUserLists returns the page and containing ids, feeds headers',
    () async {
      answer = (_) => pb.ListUserListsResponse(
        lists: [
          info('1'),
          info('2', name: 'Work'),
        ],
        containingListIds: ['2'],
        nextPageToken: 'n1',
      );

      final page = await repo.listUserLists(containsUserId: 'u9', pageSize: 20);

      final sent = requests.single as pb.ListUserListsRequest;
      expect(sent.containsUserId, 'u9');
      expect(sent.ownerId, isEmpty);
      expect(page.lists.map((l) => l.listId), ['1', '2']);
      expect(page.containingListIds, {'2'});
      expect(page.hasMore, isTrue);
      expect(seen.map((l) => l.name), ['Friends', 'Work']);
    },
  );

  test('get, add, remove, delete and members hit their RPCs', () async {
    answer = (p) => switch (p.substring(_svc.length)) {
      'GetList' => pb.GetListResponse(list: info('1')),
      'AddListMember' => pb.AddListMemberResponse(list: info('1')),
      'RemoveListMember' => pb.RemoveListMemberResponse(list: info('1')),
      'DeleteList' => pb.DeleteListResponse(),
      'ListListMembers' => pb.ListListMembersResponse(nextPageToken: 'm'),
      _ => throw StateError(p),
    };

    await repo.getList('1');
    await repo.addMember(idempotencyKey: _key, listId: '1', userId: 'u');
    await repo.removeMember(idempotencyKey: _key, listId: '1', userId: 'u');
    await repo.deleteList(idempotencyKey: _key, listId: '1');
    final members = await repo.listMembers(listId: '1');

    expect(transport.calledProcedures.map((p) => p.substring(_svc.length)), [
      'GetList',
      'AddListMember',
      'RemoveListMember',
      'DeleteList',
      'ListListMembers',
    ]);
    expect(members.hasMore, isTrue);
  });

  test('flag off: no RPC, FEATURE_DISABLED', () async {
    enabled = false;

    await expectLater(
      repo.getList('1'),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
  });

  test('UNIMPLEMENTED is "not available yet": typed, not reported, '
      'gate stays on', () async {
    answer = (p) => p.endsWith('GetList')
        ? connect.ConnectException(connect.Code.unimplemented, 'nope')
        : pb.ListUserListsResponse();

    await expectLater(
      repo.getList('1'),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureLists,
        ),
      ),
    );
    expect(reported, 0);
    expect(repo.enabled, isTrue);
    await repo.listUserLists();
  });

  test('NOT_FOUND is a typed NotFoundException', () async {
    answer = (_) => connect.ConnectException(connect.Code.notFound, 'not found');

    await expectLater(repo.getList('1'), throwsA(isA<NotFoundException>()));
  });

  test('LIMIT_REACHED carries the limit name', () async {
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
      metadata: {'limit': kListsPerUserLimit},
    );

    await expectLater(
      repo.createList(idempotencyKey: _key, name: 'x'),
      throwsA(
        isA<LimitReachedException>().having(
          (e) => e.quota,
          'quota',
          'lists_per_user',
        ),
      ),
    );
  });

  test('QUOTA_EXCEEDED carries the quota name', () async {
    answer = (_) => serverError(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
      metadata: {'quota': kListAddsQuota},
    );

    await expectLater(
      repo.addMember(idempotencyKey: _key, listId: '1', userId: 'u'),
      throwsA(
        isA<QuotaExceededException>().having(
          (e) => e.quota,
          'quota',
          'list_adds',
        ),
      ),
    );
  });

  test('PROTECTED_ACCOUNT on AddListMember is typed', () async {
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_PROTECTED_ACCOUNT,
    );

    await expectLater(
      repo.addMember(idempotencyKey: _key, listId: '1', userId: 'u'),
      throwsA(isA<ProtectedAccountException>()),
    );
  });

  test('a server FEATURE_DISABLED lists turns the gate off', () async {
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'lists'},
    );

    await expectLater(
      repo.getList('1'),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(repo.enabled, isFalse);
  });
}
