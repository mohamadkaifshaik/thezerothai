import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_editor_cubit.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLists extends Mock implements ListsRepository {}

/// W5-11: one idempotency key per user action, reused on retry (rule 4).
void main() {
  late _MockLists repo;
  final keys = <String>[];

  setUp(() {
    repo = _MockLists();
    keys.clear();
  });

  void stubCreate(Object? Function() answer) {
    when(
      () => repo.createList(
        idempotencyKey: any(named: 'idempotencyKey'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        isPrivate: any(named: 'isPrivate'),
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      final r = answer();
      if (r is Exception) throw r;
      return r as pb.ListInfo;
    });
  }

  test('a retry of the same payload reuses the key; an edited payload '
      'gets a new one', () async {
    var fail = true;
    stubCreate(
      () => fail
          ? const NetworkException('offline')
          : pb.ListInfo(listId: 'l1', name: 'A'),
    );
    final cubit = ListEditorCubit(repository: repo);

    await cubit.save(name: 'A', description: '', isPrivate: true);
    expect(cubit.state.error, isNotNull);
    await cubit.save(name: 'A', description: '', isPrivate: true);
    expect(keys[1], keys[0]);

    await cubit.save(name: 'AB', description: '', isPrivate: true);
    expect(keys[2], isNot(keys[0]));

    fail = false;
    await cubit.save(name: 'AB', description: '', isPrivate: true);
    expect(keys[3], keys[2]);
    expect(cubit.state.outcome?.list?.listId, 'l1');
    await cubit.close();
  });

  test('delete treats NOT_FOUND as deleted', () async {
    when(
      () => repo.deleteList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
      ),
    ).thenThrow(const NotFoundException('gone'));
    final cubit = ListEditorCubit(
      repository: repo,
      existing: pb.ListInfo(listId: 'l1', name: 'A'),
    );
    await cubit.delete();
    expect(cubit.state.outcome?.deletedId, 'l1');
    await cubit.close();
  });
}
