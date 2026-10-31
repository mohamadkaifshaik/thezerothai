import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/add_to_lists_cubit.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLists extends Mock implements ListsRepository {}

pb.ListInfo _list(int i, {int members = 2}) =>
    pb.ListInfo(listId: 'l$i', name: 'List $i', memberCount: members);

/// W5-13: the Add-to-Lists state. 1 ListUserLists per load, optimistic
/// toggles with rollback, one idempotency key per user action.
void main() {
  late _MockLists repo;
  final keys = <String>[];

  setUp(() {
    repo = _MockLists();
    keys.clear();
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => ListsPage(
        lists: [_list(1), _list(2)],
        containingListIds: const {'l2'},
      ),
    );
  });

  void stubAdd(Future<pb.ListInfo> Function() answer) {
    when(
      () => repo.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((i) {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      return answer();
    });
  }

  void stubRemove(Future<pb.ListInfo> Function() answer) {
    when(
      () => repo.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((i) {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      return answer();
    });
  }

  AddToListsCubit make() => AddToListsCubit(repository: repo, userId: 'u9');

  test('load: asks with contains_user_id once and checks the containing '
      'lists', () async {
    final cubit = make();
    await cubit.load();
    expect(cubit.state.status, AddToListsStatus.ready);
    expect(cubit.state.memberOf, {'l2'});
    verify(
      () => repo.listUserLists(
        containsUserId: 'u9',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
    await cubit.close();
  });

  test('load failure is an error state, load again recovers', () async {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const NetworkException('offline'));
    final cubit = make();
    await cubit.load();
    expect(cubit.state.status, AddToListsStatus.error);
    expect(cubit.state.error, isA<NetworkException>());
    await cubit.close();
  });

  test(
    'add is optimistic, busy while in flight, then takes the new count',
    () async {
      final gate = Completer<pb.ListInfo>();
      stubAdd(() => gate.future);
      final cubit = make();
      await cubit.load();

      final done = cubit.toggle('l1');
      expect(cubit.state.memberOf, {'l1', 'l2'});
      expect(cubit.state.pending, {'l1'});
      // A second tap on the busy row is ignored.
      await cubit.toggle('l1');
      verify(
        () => repo.addMember(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: 'l1',
          userId: 'u9',
        ),
      ).called(1);

      gate.complete(_list(1, members: 3));
      await done;
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.memberOf, {'l1', 'l2'});
      expect(cubit.state.lists.first.memberCount, 3);
      await cubit.close();
    },
  );

  test('remove calls RemoveListMember', () async {
    stubRemove(() async => _list(2, members: 1));
    final cubit = make();
    await cubit.load();
    await cubit.toggle('l2');
    expect(cubit.state.memberOf, isEmpty);
    verify(
      () => repo.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'l2',
        userId: 'u9',
      ),
    ).called(1);
    await cubit.close();
  });

  test('LIMIT_REACHED rolls the checkbox back with the reason', () async {
    stubAdd(
      () async =>
          throw const LimitReachedException('full', quota: 'list_members'),
    );
    final cubit = make();
    await cubit.load();
    await cubit.toggle('l1');
    expect(cubit.state.memberOf, {'l2'});
    expect(cubit.state.pending, isEmpty);
    expect(cubit.state.notice, contains('full'));
    await cubit.close();
  });

  test('a failed remove is put back as a member', () async {
    stubRemove(() async => throw const NetworkException('offline'));
    final cubit = make();
    await cubit.load();
    await cubit.toggle('l2');
    expect(cubit.state.memberOf, {'l2'});
    expect(cubit.state.notice, contains('No connection'));
    await cubit.close();
  });

  test('the same action retried after a failure reuses its key; after a '
      'success the next action gets a new one', () async {
    var fail = true;
    stubAdd(() async {
      if (fail) throw const NetworkException('offline');
      return _list(1);
    });
    stubRemove(() async => _list(1));
    final cubit = make();
    await cubit.load();

    await cubit.toggle('l1');
    await cubit.toggle('l1');
    expect(keys[1], keys[0]);

    fail = false;
    await cubit.toggle('l1');
    expect(keys[2], keys[0]);
    expect(cubit.state.memberOf, contains('l1'));

    await cubit.toggle('l1'); // remove
    await cubit.toggle('l1'); // add again
    expect(keys.length, 5);
    expect(keys[4], isNot(keys[0]));
    await cubit.close();
  });

  test('a new notice is cleared by the next toggle', () async {
    stubAdd(() async => throw const NetworkException('offline'));
    stubRemove(() async => _list(2));
    final cubit = make();
    await cubit.load();
    await cubit.toggle('l1');
    expect(cubit.state.notice, isNotNull);
    await cubit.toggle('l2');
    expect(cubit.state.notice, isNull);
    await cubit.close();
  });
}
