import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/user_list_cubit.dart';
import 'package:dzeroth/features/graph/presentation/bloc/user_list_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';

graph.UserListItem _item(String id) {
  return graph.UserListItem(
    user: common.AuthorSnapshot(userId: id, handle: id),
  );
}

void main() {
  group('loadFirstPage', () {
    blocTest<UserListCubit, UserListState>(
      'loads the first page',
      build: () => UserListCubit(
        fetchPage: ({required pageSize, required pageToken}) async {
          expect(pageToken, '');
          return GraphPage(
            items: [_item('a'), _item('b')],
            nextPageToken: 'p2',
          );
        },
      ),
      act: (cubit) => cubit.loadFirstPage(),
      expect: () => [
        const UserListState(),
        isA<UserListState>()
            .having((s) => s.status, 'status', UserListStatus.ready)
            .having((s) => s.items.length, 'items.length', 2)
            .having((s) => s.hasMore, 'hasMore', true),
      ],
    );

    blocTest<UserListCubit, UserListState>(
      'a rate-limited response never triggers an auto-retry',
      build: () => UserListCubit(
        fetchPage: ({required pageSize, required pageToken}) async {
          throw const RateLimitedException('slow down');
        },
      ),
      act: (cubit) => cubit.loadFirstPage(),
      expect: () => [
        const UserListState(),
        isA<UserListState>().having(
          (s) => s.status,
          'status',
          UserListStatus.rateLimited,
        ),
      ],
    );

    blocTest<UserListCubit, UserListState>(
      'a NOT_FOUND target surfaces as an error state',
      build: () => UserListCubit(
        fetchPage: ({required pageSize, required pageToken}) async {
          throw const NotFoundException("doesn't exist");
        },
      ),
      act: (cubit) => cubit.loadFirstPage(),
      expect: () => [
        const UserListState(),
        isA<UserListState>().having(
          (s) => s.status,
          'status',
          UserListStatus.error,
        ),
      ],
    );
  });

  group('loadMore', () {
    blocTest<UserListCubit, UserListState>(
      'appends the next page and never re-fetches a page already loaded',
      build: () {
        var calls = 0;
        return UserListCubit(
          fetchPage: ({required pageSize, required pageToken}) async {
            calls++;
            if (pageToken.isEmpty) {
              return GraphPage(items: [_item('a')], nextPageToken: 'p2');
            }
            expect(pageToken, 'p2');
            expect(calls, 2);
            return GraphPage(items: [_item('b')], nextPageToken: '');
          },
        );
      },
      act: (cubit) async {
        await cubit.loadFirstPage();
        await cubit.loadMore();
      },
      expect: () => [
        const UserListState(),
        isA<UserListState>().having((s) => s.items.length, 'items', 1),
        isA<UserListState>().having(
          (s) => s.status,
          'status',
          UserListStatus.loadingMore,
        ),
        isA<UserListState>()
            .having((s) => s.items.length, 'items', 2)
            .having((s) => s.hasMore, 'hasMore', false),
      ],
    );

    blocTest<UserListCubit, UserListState>(
      'does nothing when there is no more page',
      build: () => UserListCubit(
        fetchPage: ({required pageSize, required pageToken}) async {
          return GraphPage(items: [_item('a')], nextPageToken: '');
        },
      ),
      act: (cubit) async {
        await cubit.loadFirstPage();
        await cubit.loadMore();
      },
      expect: () => [
        const UserListState(),
        isA<UserListState>().having((s) => s.hasMore, 'hasMore', false),
      ],
    );
  });

  group('removeUser / restoreItem', () {
    blocTest<UserListCubit, UserListState>(
      'optimistically removes a row, and restoreItem puts it back at the '
      'same index (undo)',
      build: () => UserListCubit(
        fetchPage: ({required pageSize, required pageToken}) async {
          return GraphPage(
            items: [_item('a'), _item('b'), _item('c')],
            nextPageToken: '',
          );
        },
      ),
      act: (cubit) async {
        await cubit.loadFirstPage();
        final removed = cubit.removeUser('b');
        expect(removed, isNotNull);
        cubit.restoreItem(removed!.$1, removed.$2);
      },
      expect: () => [
        const UserListState(),
        isA<UserListState>().having((s) => s.items.length, 'items', 3),
        isA<UserListState>().having((s) => s.items.length, 'items', 2).having(
          (s) => s.items.map((i) => i.user.userId),
          'ids',
          ['a', 'c'],
        ),
        isA<UserListState>().having((s) => s.items.length, 'items', 3).having(
          (s) => s.items.map((i) => i.user.userId),
          'ids',
          ['a', 'b', 'c'],
        ),
      ],
    );
  });
}
