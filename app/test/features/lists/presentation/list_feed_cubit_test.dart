import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/lists_feature_flag.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_feed_cubit.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_feed_state.dart';
import 'package:dzeroth/features/lists/presentation/lists_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLists extends Mock implements ListsRepository {}

pb.ListInfo _l(String id, {int followers = 5, bool following = false}) =>
    pb.ListInfo(
      listId: id,
      name: 'List $id',
      followerCount: followers,
      followedByViewer: following,
    );

void main() {
  late _MockLists repo;
  late List<String> tokens;
  late Map<String, ListsPage> pages;

  setUp(() {
    repo = _MockLists();
    tokens = [];
    pages = {};
  });

  ListFeedCubit make({bool leaves = false}) => ListFeedCubit(
    repository: repo,
    unfollowedLeavesFeed: leaves,
    fetch: (token) async {
      tokens.add(token);
      return pages[token] ?? const ListsPage(lists: []);
    },
  );

  blocTest<ListFeedCubit, ListFeedState>(
    'load then loadMore pages by next_page_token and skips repeats',
    setUp: () {
      pages = {
        '': ListsPage(lists: [_l('a'), _l('b')], nextPageToken: 't1'),
        't1': ListsPage(lists: [_l('b'), _l('c')]),
      };
    },
    build: make,
    act: (c) async {
      await c.load();
      await c.loadMore();
      await c.loadMore(); // no token left: nothing is fetched
    },
    verify: (c) {
      expect(tokens, ['', 't1']);
      expect(c.state.lists.map((l) => l.listId), ['a', 'b', 'c']);
      expect(c.state.hasMore, isFalse);
    },
  );

  blocTest<ListFeedCubit, ListFeedState>(
    'a failed first page is an error state',
    build: () => ListFeedCubit(
      repository: repo,
      fetch: (_) async => throw const NetworkException('off'),
    ),
    act: (c) => c.load(),
    verify: (c) {
      expect(c.state.status, ListFeedStatus.error);
      expect(c.state.error, isA<NetworkException>());
    },
  );

  test('a failed next page keeps the rows and offers a retry', () async {
    var calls = 0;
    final c = ListFeedCubit(
      repository: repo,
      fetch: (token) async {
        calls++;
        if (token.isEmpty) {
          return ListsPage(lists: [_l('a')], nextPageToken: 't1');
        }
        throw const NetworkException('off');
      },
    );
    await c.load();
    await c.loadMore();
    expect(calls, 2);
    expect(c.state.lists, hasLength(1));
    expect(c.state.loadMoreFailed, isTrue);
    await c.close();
  });

  test(
    'follow is optimistic, uses a fresh key and keeps the server row',
    () async {
      pages = {
        '': ListsPage(lists: [_l('a', followers: 5)]),
      };
      String? key;
      when(
        () => repo.followList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: 'a',
        ),
      ).thenAnswer((i) async {
        key = i.namedArguments[#idempotencyKey] as String;
        return _l('a', followers: 6, following: true);
      });
      final c = make();
      await c.load();
      final future = c.toggleFollow('a');
      expect(c.state.lists.single.followedByViewer, isTrue);
      expect(c.state.lists.single.followerCount, 6);
      expect(c.state.busyIds, {'a'});
      expect(await future, isNull);
      expect(c.state.busyIds, isEmpty);
      expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
      await c.close();
    },
  );

  test('unfollow in Discover keeps the row, count goes down', () async {
    pages = {
      '': ListsPage(lists: [_l('a', following: true)]),
    };
    when(
      () => repo.unfollowList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'a',
        current: any(named: 'current'),
      ),
    ).thenAnswer((_) async => null);
    final c = make();
    await c.load();
    expect(await c.toggleFollow('a'), isNull);
    expect(c.state.lists.single.followedByViewer, isFalse);
    expect(c.state.lists.single.followerCount, 4);
    await c.close();
  });

  test('unfollow in "Lists you follow" removes the row', () async {
    pages = {
      '': ListsPage(lists: [_l('a', following: true), _l('b')]),
    };
    when(
      () => repo.unfollowList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'a',
        current: any(named: 'current'),
      ),
    ).thenAnswer((_) async => null);
    final c = make(leaves: true);
    await c.load();
    await c.toggleFollow('a');
    expect(c.state.lists.map((l) => l.listId), ['b']);
    await c.close();
  });

  test('the follow limit rolls back and returns a limit message', () async {
    pages = {
      '': ListsPage(lists: [_l('a')]),
    };
    when(
      () => repo.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'a',
      ),
    ).thenThrow(const LimitReachedException('limit', quota: kListFollowsLimit));
    final c = make();
    await c.load();
    final error = await c.toggleFollow('a');
    expect(error, isA<LimitReachedException>());
    expect(listsErrorMessage(error!), contains('follow up to 100 Lists'));
    expect(c.state.lists.single.followedByViewer, isFalse);
    expect(c.state.lists.single.followerCount, 5);
    expect(c.state.busyIds, isEmpty);
    await c.close();
  });

  test('NOT_FOUND on follow drops the row', () async {
    pages = {
      '': ListsPage(lists: [_l('a'), _l('b')]),
    };
    when(
      () => repo.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'a',
      ),
    ).thenThrow(const NotFoundException('gone'));
    final c = make();
    await c.load();
    final error = await c.toggleFollow('a');
    expect(listsErrorMessage(error!), 'This List is unavailable.');
    expect(c.state.lists.map((l) => l.listId), ['b']);
    await c.close();
  });
}
