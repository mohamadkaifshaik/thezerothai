import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_detail_cubit.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_detail_state.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLists extends Mock implements ListsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

pb.ListInfo _h({int followers = 5, bool following = false}) => pb.ListInfo(
  listId: '77',
  name: 'Friends',
  followerCount: followers,
  followedByViewer: following,
);

void main() {
  late _MockLists lists;
  late ListDetailCubit cubit;

  setUp(() {
    lists = _MockLists();
    final tabs = _MockTabs();
    when(() => lists.header('77')).thenReturn(_h());
    when(() => lists.headerChanges).thenAnswer((_) => const Stream.empty());
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    cubit = ListDetailCubit(listId: '77', lists: lists, tabs: tabs);
  });

  setUpAll(() {
    registerFallbackValue(HomeTabKind.list);
  });

  tearDown(() => cubit.close());

  test(
    'follow moves the count at once, then takes the server header',
    () async {
      final done = Completer<pb.ListInfo>();
      when(
        () => lists.followList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: '77',
        ),
      ).thenAnswer((_) => done.future);

      final future = cubit.toggleFollow();
      expect(cubit.state.header?.followedByViewer, isTrue);
      expect(cubit.state.header?.followerCount, 6);
      expect(cubit.state.followBusy, isTrue);
      // A second tap while in flight does nothing.
      expect(await cubit.toggleFollow(), isNull);

      done.complete(_h(followers: 9, following: true));
      expect(await future, isNull);
      expect(cubit.state.header?.followerCount, 9);
      expect(cubit.state.followBusy, isFalse);
    },
  );

  test('a failure rolls back and is returned', () async {
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
      ),
    ).thenThrow(const NetworkException('off'));

    final error = await cubit.toggleFollow();

    expect(error, isA<NetworkException>());
    expect(cubit.state.header?.followedByViewer, isFalse);
    expect(cubit.state.header?.followerCount, 5);
    expect(cubit.state.followBusy, isFalse);
  });

  test('NOT_FOUND marks the List unavailable', () async {
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
      ),
    ).thenThrow(const NotFoundException('gone'));

    await cubit.toggleFollow();

    expect(cubit.state.status, ListDetailStatus.unavailable);
  });
}
