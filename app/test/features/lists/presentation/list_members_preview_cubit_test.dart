import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_members_preview_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLists extends Mock implements ListsRepository {}

graph.UserListItem _person(int i) => graph.UserListItem(
  user: common.AuthorSnapshot(userId: 'p$i', handle: 'person$i'),
);

/// The members preview of band B's context pane on `/lists/:id` (T8b).
void main() {
  late _MockLists lists;

  void answer(Future<ListMembersPage> Function() page) => when(
    () => lists.listMembers(
      listId: any(named: 'listId'),
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
      maxEmptyPages: any(named: 'maxEmptyPages'),
    ),
  ).thenAnswer((_) => page());

  setUp(() {
    lists = _MockLists();
    answer(
      () async =>
          ListMembersPage(users: [for (var i = 1; i <= 8; i++) _person(i)]),
    );
  });

  ListMembersPreviewCubit build() =>
      ListMembersPreviewCubit(listId: '77', lists: lists);

  test('asks nothing until loadOnce', () {
    final cubit = build();
    expect(cubit.state.status, ListMembersPreviewStatus.idle);
    verifyNever(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    );
    cubit.close();
  });

  blocTest<ListMembersPreviewCubit, ListMembersPreviewState>(
    'loadOnce: one call of the preview size, at most that many rows; a '
    'second loadOnce does nothing',
    build: build,
    act: (cubit) async {
      await cubit.loadOnce();
      await cubit.loadOnce();
    },
    expect: () => [
      const ListMembersPreviewState(status: ListMembersPreviewStatus.loading),
      isA<ListMembersPreviewState>()
          .having((s) => s.status, 'status', ListMembersPreviewStatus.ready)
          .having((s) => s.users.length, 'rows', kListMembersPreviewLimit),
    ],
    verify: (_) => verify(
      () => lists.listMembers(
        listId: '77',
        pageSize: kListMembersPreviewLimit,
        maxEmptyPages: 2,
      ),
    ).called(1),
  );

  blocTest<ListMembersPreviewCubit, ListMembersPreviewState>(
    'reload does nothing before the first loadOnce',
    build: build,
    act: (cubit) => cubit.reload(),
    expect: () => const <ListMembersPreviewState>[],
  );

  blocTest<ListMembersPreviewCubit, ListMembersPreviewState>(
    'reload asks again and keeps the rows while it is in flight',
    build: build,
    act: (cubit) async {
      await cubit.loadOnce();
      await cubit.reload();
    },
    skip: 2,
    expect: () => [
      isA<ListMembersPreviewState>()
          .having((s) => s.status, 'status', ListMembersPreviewStatus.loading)
          .having((s) => s.users.length, 'rows', kListMembersPreviewLimit),
      isA<ListMembersPreviewState>().having(
        (s) => s.status,
        'status',
        ListMembersPreviewStatus.ready,
      ),
    ],
  );

  for (final (error, status) in <(AppException, ListMembersPreviewStatus)>[
    (
      const FeatureDisabledException('off', feature: 'lists'),
      ListMembersPreviewStatus.unavailable,
    ),
    (const NotFoundException('gone'), ListMembersPreviewStatus.unavailable),
    (const UnknownApiException('boom'), ListMembersPreviewStatus.failed),
  ]) {
    blocTest<ListMembersPreviewCubit, ListMembersPreviewState>(
      '${error.runtimeType} -> ${status.name}',
      setUp: () => answer(() async => throw error),
      build: build,
      act: (cubit) => cubit.loadOnce(),
      expect: () => [
        const ListMembersPreviewState(status: ListMembersPreviewStatus.loading),
        ListMembersPreviewState(status: status),
      ],
    );
  }
}
