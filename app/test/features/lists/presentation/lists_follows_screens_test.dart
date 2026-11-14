import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/lists/domain/lists_feature_flag.dart';
import 'package:dzeroth/features/lists/presentation/discover_lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/lists_flags_support.dart';
import '../../../support/lists_pinned_stub.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockLists extends Mock implements ListsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

const _widths = <double>[390, 800, 1280];
const _scales = <double>[1.0, 2.0];
const _on = {kFeatureLists, kFeatureListFollows, 'posts'};
const _off = {kFeatureLists, 'posts'};

pb.ListInfo _list(
  String id, {
  String owner = 'someone',
  bool isPrivate = false,
  int followers = 12,
  bool following = false,
  String name = 'Coffee club with a rather long name for wrapping',
}) => pb.ListInfo(
  listId: id,
  name: name,
  isPrivate: isPrivate,
  memberCount: 3,
  followerCount: followers,
  followedByViewer: following,
  owner: common.AuthorSnapshot(
    userId: owner,
    handle: 'olivia',
    displayName: 'Olivia',
  ),
);

void main() {
  late _MockLists lists;

  setUpAll(() {
    registerFallbackValue(pb.ListInfo());
    registerFallbackValue(HomeTabKind.list);
  });

  setUp(() {
    lists = _MockLists();
    when(() => lists.enabled).thenReturn(true);
    when(() => lists.headerChanges).thenAnswer((_) => const Stream.empty());
    when(() => lists.header(any())).thenReturn(null);
  });

  void stubOwn(List<pb.ListInfo> own) => when(
    () => lists.listUserLists(
      ownerId: any(named: 'ownerId'),
      containsUserId: any(named: 'containsUserId'),
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
    ),
  ).thenAnswer((_) async => ListsPage(lists: own));

  void stubFollowed(List<pb.ListInfo> rows, {String next = ''}) => when(
    () => lists.listFollowedLists(
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
    ),
  ).thenAnswer((_) async => ListsPage(lists: rows, nextPageToken: next));

  void stubDiscover(List<pb.ListInfo> rows, {String next = ''}) => when(
    () => lists.discoverLists(
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
    ),
  ).thenAnswer((_) async => ListsPage(lists: rows, nextPageToken: next));

  void verifyNoFollowRpcs() {
    verifyNever(
      () => lists.listFollowedLists(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    );
    verifyNever(
      () => lists.discoverLists(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    );
    verifyNever(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
      ),
    );
  }

  // ---------------------------------------------------------------- Lists

  Future<void> openLists(
    WidgetTester tester,
    Set<String> flags, {
    MatrixEnv? env,
    GoRouter? router,
  }) => pumpThemed(
    tester,
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<ListsRepository>.value(value: lists),
        RepositoryProvider<HomeTabsRepository>.value(value: noPinnedTabs()),
      ],
      child: withListsFlags(flags, const ListsScreen()),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(390, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'Lists, list_follows on: Discover entry and "Lists you follow" with '
    'counts, no overflow',
    (tester, env) async {
      stubOwn([_list('1', owner: kListsViewerId)]);
      stubFollowed([_list('2'), _list('3', followers: 1)]);
      await openLists(tester, _on, env: env);

      expectNoOverflow(tester);
      expect(find.text('Discover lists'), findsOneWidget);
      expect(find.text('Lists you follow'), findsOneWidget);
      expect(find.textContaining('12 followers'), findsOneWidget);
      expect(find.textContaining('1 follower'), findsWidgets);
      expect(find.text('Show more'), findsNothing);
    },
    widths: _widths,
    textScales: _scales,
  );

  forEachThemeAndWidth(
    'Lists, list_follows off: no entry, no section, no follow RPC',
    (tester, env) async {
      stubOwn([_list('1', owner: kListsViewerId)]);
      await openLists(tester, _off, env: env);

      expectNoOverflow(tester);
      expect(find.text('Your Lists'), findsOneWidget);
      expect(find.text('Discover lists'), findsNothing);
      expect(find.text('Lists you follow'), findsNothing);
      verifyNoFollowRpcs();
    },
    widths: _widths,
    textScales: _scales,
  );

  testWidgets('Lists, on: an empty followed list hides the section, the '
      'empty own-lists text and Discover still show', (tester) async {
    stubOwn([]);
    stubFollowed([]);
    await openLists(tester, _on);

    expect(find.text('Lists you follow'), findsNothing);
    expect(find.text('Discover lists'), findsOneWidget);
    expect(find.textContaining("haven't created any Lists"), findsOneWidget);
  });

  testWidgets('Lists, on: a failing followed fetch hides the section and '
      'leaves the page alone', (tester) async {
    stubOwn([_list('1', owner: kListsViewerId)]);
    when(
      () => lists.listFollowedLists(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const NetworkException('off'));
    await openLists(tester, _on);

    expect(find.text('Your Lists'), findsOneWidget);
    expect(find.text('Lists you follow'), findsNothing);
  });

  testWidgets('Lists, on: Show more pages by next_page_token', (tester) async {
    stubOwn([]);
    when(
      () => lists.listFollowedLists(
        pageSize: kListFollowsPageSize,
        pageToken: '',
      ),
    ).thenAnswer(
      (_) async => ListsPage(lists: [_list('2')], nextPageToken: 'n'),
    );
    when(
      () => lists.listFollowedLists(
        pageSize: kListFollowsPageSize,
        pageToken: 'n',
      ),
    ).thenAnswer(
      (_) async => ListsPage(lists: [_list('3', name: 'Second page')]),
    );
    await openLists(tester, _on);

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.text('Second page'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('Lists, on: the Discover entry opens the Discover route', (
    tester,
  ) async {
    stubOwn([]);
    stubFollowed([]);
    stubDiscover([]);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => withListsFlags(_on, const ListsScreen()),
        ),
        GoRoute(
          path: AppRouter.discoverListsPath,
          builder: (_, _) => const Text('discover page'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<HomeTabsRepository>.value(value: noPinnedTabs()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Discover lists'));
    await tester.pumpAndSettle();

    expect(find.text('discover page'), findsOneWidget);
  });

  // ------------------------------------------------------------- Discover

  Future<void> openDiscover(WidgetTester tester, {MatrixEnv? env}) =>
      pumpThemed(
        tester,
        RepositoryProvider<ListsRepository>.value(
          value: lists,
          child: withListsFlags(_on, const DiscoverListsScreen()),
        ),
        brightness: env?.brightness ?? Brightness.light,
        size: env?.size ?? const Size(390, 800),
        textScale: env?.textScale ?? 1.0,
        useScaffold: false,
      );

  forEachThemeAndWidth(
    'Discover: rows with follower counts and a Follow toggle; no toggle on '
    'my own List',
    (tester, env) async {
      stubDiscover([
        _list('1'),
        _list('2', following: true),
        _list('3', owner: kListsViewerId),
      ]);
      await openDiscover(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Discover Lists'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.textContaining('12 followers'), findsNWidgets(3));
    },
    widths: _widths,
    textScales: _scales,
  );

  testWidgets('Discover: Follow calls FollowList once and flips the row', (
    tester,
  ) async {
    stubDiscover([_list('1', followers: 12)]);
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '1',
      ),
    ).thenAnswer((_) async => _list('1', followers: 13, following: true));
    await openDiscover(tester);

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.text('Following'), findsOneWidget);
    expect(find.textContaining('13 followers'), findsOneWidget);
    verify(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '1',
      ),
    ).called(1);
  });

  testWidgets('Discover: the 100-follow limit says so and keeps Follow', (
    tester,
  ) async {
    stubDiscover([_list('1')]);
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '1',
      ),
    ).thenThrow(const LimitReachedException('x', quota: kListFollowsLimit));
    await openDiscover(tester);

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.textContaining('follow up to 100 Lists'), findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('Discover: pages on scroll with next_page_token', (tester) async {
    when(
      () => lists.discoverLists(pageSize: kListFollowsPageSize, pageToken: ''),
    ).thenAnswer(
      (_) async => ListsPage(
        lists: [for (var i = 0; i < 3; i++) _list('a$i', name: 'First $i')],
        nextPageToken: 'n',
      ),
    );
    when(
      () => lists.discoverLists(pageSize: kListFollowsPageSize, pageToken: 'n'),
    ).thenAnswer((_) async => ListsPage(lists: [_list('b', name: 'Later')]));
    await openDiscover(tester);
    await tester.pumpAndSettle();

    expect(find.text('Later'), findsOneWidget);
    verify(
      () => lists.discoverLists(pageSize: kListFollowsPageSize, pageToken: 'n'),
    ).called(1);
  });

  testWidgets('Discover: empty and error states', (tester) async {
    stubDiscover([]);
    await openDiscover(tester);
    expect(find.text('No Lists to discover yet'), findsOneWidget);
  });

  // --------------------------------------------------------------- Detail

  Future<void> openDetail(
    WidgetTester tester,
    Set<String> flags,
    pb.ListInfo header, {
    MatrixEnv? env,
  }) async {
    final feed = FeedKey.list('77');
    final timeline = MockTimelineRepository();
    final posts = MockPostsRepository();
    final tabs = _MockTabs();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => lists.header('77')).thenReturn(header);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    await pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: listsFlags(flags),
          child: const ListDetailScreen(listId: '77'),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(390, 800),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  pb.ListInfo detail({
    String owner = 'someone',
    bool isPrivate = false,
    bool following = false,
  }) => _list(
    '77',
    owner: owner,
    isPrivate: isPrivate,
    following: following,
    followers: 42,
    name: 'Friends',
  );

  forEachThemeAndWidth(
    'Detail, list_follows on, someone else\'s public List: Follow and the '
    'count',
    (tester, env) async {
      await openDetail(tester, _on, detail(), env: env);

      expectNoOverflow(tester);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('42 Followers', findRichText: true), findsOneWidget);
    },
    widths: _widths,
    textScales: _scales,
  );

  forEachThemeAndWidth(
    'Detail, list_follows off: neither the button nor the count, no RPC',
    (tester, env) async {
      await openDetail(tester, _off, detail(), env: env);

      expectNoOverflow(tester);
      expect(find.text('Follow'), findsNothing);
      expect(
        find.textContaining('Followers', findRichText: true),
        findsNothing,
      );
      verifyNoFollowRpcs();
    },
    widths: _widths,
    textScales: _scales,
  );

  testWidgets('Detail, on: the owner sees the count but no Follow', (
    tester,
  ) async {
    await openDetail(tester, _on, detail(owner: kListsViewerId));

    expect(find.text('42 Followers', findRichText: true), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
    expect(find.text('Following'), findsNothing);
  });

  testWidgets('Detail, on: a private List of someone else has no Follow', (
    tester,
  ) async {
    await openDetail(tester, _on, detail(isPrivate: true));

    expect(find.text('Follow'), findsNothing);
  });

  testWidgets('Detail, on: Follow then Following unfollows, each with a key', (
    tester,
  ) async {
    final keys = <String>[];
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      return detail(following: true).deepCopy()..followerCount = 43;
    });
    when(
      () => lists.unfollowList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
        current: any(named: 'current'),
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      return detail();
    });
    await openDetail(tester, _on, detail());

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('43 Followers', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(find.text('Follow'), findsOneWidget);

    expect(keys, hasLength(2));
    expect(keys.toSet(), hasLength(2));
    for (final k in keys) {
      expect(k, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    }
  });

  testWidgets('Detail, on: NOT_FOUND on follow shows the unavailable view', (
    tester,
  ) async {
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
      ),
    ).thenThrow(const NotFoundException('gone'));
    await openDetail(tester, _on, detail());

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.textContaining('unavailable'), findsWidgets);
  });

  testWidgets('Detail, on: the follow limit shows its message', (tester) async {
    when(
      () => lists.followList(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
      ),
    ).thenThrow(const LimitReachedException('x', quota: kListFollowsLimit));
    await openDetail(tester, _on, detail());

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.textContaining('follow up to 100 Lists'), findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
  });
}
