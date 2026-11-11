import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_search_repository.dart';
import 'fake_transport.dart';
import 'search_field_rig.dart';
import 'suggestions_fixtures.dart';
import 'timeline_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The Lists pages' flags, the context pane's global-set flags and the
/// tablet shell's two.
const kListsTabletFlags = <String>{
  'lists',
  'posts',
  'search',
  'trends',
  'graph',
  'follow_suggestions',
  'reports',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3),
/// each with the Lists pages' own flags on.
final kListsFlagModes = <String, Set<String>>{
  'neither': {
    for (final f in kListsTabletFlags)
      if (f != kFeatureUiShell && f != kFeatureUiTablet) f,
  },
  'ui_shell only': {
    for (final f in kListsTabletFlags)
      if (f != kFeatureUiTablet) f,
  },
  'ui_tablet only': {
    for (final f in kListsTabletFlags)
      if (f != kFeatureUiShell) f,
  },
  'ui_shell + ui_tablet': kListsTabletFlags,
};

/// The signed-in viewer.
const kRigViewerId = 'u-alice';

/// The rig's List (the detail, its members, the pinned Home tab).
const kRigListId = '77';

/// The other person whose Lists `/u/:id/lists` shows.
const kRigOwnerId = 'o1';

/// The members of [kRigListId], newest first: (id, handle, name).
const kRigMembers = <(String, String, String)>[
  ('m1', 'mia', 'Mia'),
  ('m2', 'noah', 'Noah'),
  ('m3', 'zoe', 'Zoe'),
];

/// The real `ListsRepository` and `HomeTabsRepository` over a
/// [FakeTransport] that plays the ListService and SetHomeTabs, with a call
/// log by RPC name (`ListUserLists`, `GetList`, `ListListMembers`,
/// `RemoveListMember`, `SetHomeTabs`).
class FakeListsServer {
  FakeListsServer() {
    final api = ApiClient.withTransport(FakeTransport(_handle));
    final gate = ServiceFeatureGate(
      isEnabled: () => true,
      onUnexpectedError: (_, _) {},
    );
    tabs = HomeTabsRepository(apiClient: api, gate: gate, epoch: epoch);
    lists = ListsRepository(
      apiClient: api,
      gate: gate,
      epoch: epoch,
      onListSeen: tabs.noteListInfo,
    );
  }

  final epoch = SessionEpoch();
  late final HomeTabsRepository tabs;
  late final ListsRepository lists;

  /// Every call, in order, by RPC name.
  final calls = <String>[];

  /// True: the viewer owns [kRigListId] (Edit, Remove, "Manage members").
  bool viewerOwnsList = false;

  /// The members of [kRigListId] ([kRigMembers] by default).
  List<(String, String, String)> members = List.of(kRigMembers);

  /// Non-null: ListListMembers waits for it.
  Completer<void>? holdMembers;

  /// Non-null: ListListMembers fails with it (once per value).
  connect.Code? membersError;

  /// Non-null: ListUserLists waits for it.
  Completer<void>? holdUserLists;

  /// Non-null: GetList and the list timeline answer NOT_FOUND.
  bool listGone = false;

  /// The other person's public Lists (empty: "No public Lists").
  bool ownerHasLists = true;

  int count(String rpc) => calls.where((c) => c == rpc).length;

  common.AuthorSnapshot get _owner => viewerOwnsList
      ? common.AuthorSnapshot(
          userId: kRigViewerId,
          handle: 'alice',
          displayName: 'Alice A',
        )
      : common.AuthorSnapshot(
          userId: kRigOwnerId,
          handle: 'olivia',
          displayName: 'Olivia Owner',
        );

  /// The header of [kRigListId].
  pb.ListInfo get header => pb.ListInfo(
    listId: kRigListId,
    name: 'Friends',
    description: 'People I like to read',
    memberCount: members.length,
    owner: _owner,
  );

  pb.ListInfo _other(String id, String name, common.AuthorSnapshot owner) =>
      pb.ListInfo(listId: id, name: name, memberCount: 2, owner: owner);

  /// Pins [kRigListId] on Home, as `GetMe` would.
  void pinRigList() => tabs.adoptFromMe([
    common.HomeTab(kind: common.HomeTabKind.HOME_TAB_KIND_LIST, id: kRigListId),
  ], epoch: epoch.value);

  Future<Object> _handle(String procedure, Object input) async {
    calls.add(procedure.split('/').last);
    if (input is pb.ListUserListsRequest) {
      await holdUserLists?.future;
      if (input.ownerId.isEmpty) {
        final me = common.AuthorSnapshot(
          userId: kRigViewerId,
          handle: 'alice',
          displayName: 'Alice A',
        );
        return pb.ListUserListsResponse(
          lists: [if (viewerOwnsList) header, _other('78', 'Books', me)],
        );
      }
      final olivia = common.AuthorSnapshot(
        userId: kRigOwnerId,
        handle: 'olivia',
        displayName: 'Olivia Owner',
      );
      return pb.ListUserListsResponse(
        lists: ownerHasLists
            ? [_other('79', 'Chess', olivia), _other('80', 'Runners', olivia)]
            : [],
      );
    }
    if (input is pb.GetListRequest) {
      if (listGone) throw connect.ConnectException(connect.Code.notFound, 'gone');
      return pb.GetListResponse(list: header);
    }
    if (input is pb.ListListMembersRequest) {
      await holdMembers?.future;
      final error = membersError;
      if (error != null) {
        membersError = null;
        throw connect.ConnectException(error, 'fake');
      }
      final size = input.pageSize <= 0 ? members.length : input.pageSize;
      return pb.ListListMembersResponse(
        users: [
          for (final (id, handle, name) in members.take(size))
            graph.UserListItem(
              user: common.AuthorSnapshot(
                userId: id,
                handle: handle,
                displayName: name,
              ),
            ),
        ],
      );
    }
    if (input is pb.RemoveListMemberRequest) {
      members.removeWhere((m) => m.$1 == input.userId);
      return pb.RemoveListMemberResponse(list: header);
    }
    if (input is tl.SetHomeTabsRequest) {
      return tl.SetHomeTabsResponse(tabs: input.tabs);
    }
    throw StateError('unexpected $procedure');
  }
}

/// The real `MainShell` in a real `ShellRoute` around the real Lists pages
/// (`ListsScreen`, `ListDetailScreen`, `ListMembersScreen`,
/// `ManagePinnedScreen`, `UserListsScreen`) over a [FakeListsServer], with
/// the shared cubits of the context pane's global set over fakes. `/home`,
/// `/profile/:handle` and `/u/:userId` are stubs, so a test can push a Lists
/// page over another page as the app does.
class ListsTabletRig {
  ListsTabletRig();

  final server = FakeListsServer();
  final search = FakeSearchRepository()
    ..trendsResult = TrendsResult(
      trends: [for (var i = 1; i <= 3; i++) searchTrend('tag$i', 100 * i, i)],
      computedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
  final suggestionsRepository = FakeSuggestionsRepository([
    for (var i = 1; i <= 3; i++) suggestedUser(i),
  ]);
  final timeline = MockTimelineRepository();
  final posts = MockPostsRepository();
  late GoRouter router;

  /// The location of the top page (a pushed one too).
  Uri get uri => router.state.uri;

  /// Pumps the shell at [location], then pushes each of [push] in turn (as
  /// the app's rows and buttons do) and settles.
  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.listsPath,
    List<String> push = const [],
    Object? pushExtra,
    double width = 1024,
    double height = 900,
    Set<String> flags = kListsTabletFlags,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
    bool settle = true,
  }) async {
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(
          userId: kRigViewerId,
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final trends = TrendsCubit(repository: search);
    addTearDown(trends.close);
    final suggestions = SuggestionsCubit(repository: suggestionsRepository);
    addTearDown(suggestions.close);
    final graphRepository = _MockGraph();
    when(() => graphRepository.followRequestsUnavailable).thenReturn(false);
    registerFallbackValue(const FeedKey.home());
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(any())).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(any())).thenAnswer((invocation) async {
      final feed = invocation.positionalArguments.first as FeedKey;
      if (feed == FeedKey.list(kRigListId)) {
        // The list timeline brings the header, as the real repository does.
        if (server.listGone) {
          throw const NotFoundException('gone');
        }
        server.lists.noteListInfo(server.header);
      }
      return snapshotOf([]);
    });

    Widget stub(String text, [List<Widget> actions = const []]) => Scaffold(
      appBar: AppBar(title: Text(text)),
      body: Column(children: [Text('$text body'), ...actions]),
    );

    router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => MainShell(
            location: state.matchedLocation,
            uri: state.uri,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (context, state) => stub('Home stub'),
            ),
            GoRoute(
              path: AppRouter.pinnedPath,
              builder: (context, state) => const ManagePinnedScreen(),
            ),
            GoRoute(
              path: AppRouter.listsPath,
              builder: (context, state) => const ListsScreen(),
            ),
            GoRoute(
              path: '/lists/:id',
              builder: (context, state) =>
                  ListDetailScreen(listId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/lists/:id/members',
              builder: (context, state) =>
                  ListMembersScreen(listId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/u/:userId',
              builder: (context, state) => stub('User stub'),
            ),
            GoRoute(
              path: '/u/:userId/lists',
              builder: (context, state) => UserListsScreen(
                userId: state.pathParameters['userId']!,
                handle: state.extra as String?,
              ),
            ),
            GoRoute(
              path: '/profile/:handle',
              builder: (context, state) => stub('Profile stub'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: server.lists),
          RepositoryProvider<HomeTabsRepository>.value(value: server.tabs),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
            BlocProvider<TrendsCubit>.value(value: trends),
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
            builder: (context, child) => Directionality(
              textDirection: textDirection,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester, settle);
    for (final path in push) {
      unawaited(router.push(path, extra: pushExtra));
      await _settle(tester, settle);
    }
  }

  /// [settle] false pumps two frames instead (the first frame, then the one
  /// the pages' leases announce): a held call spins forever.
  Future<void> _settle(WidgetTester tester, bool settle) async {
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  /// Resizes the window and settles.
  Future<void> resize(
    WidgetTester tester,
    double width, [
    double? height,
  ]) async {
    tester.view.physicalSize = Size(
      width,
      height ?? tester.view.physicalSize.height,
    );
    await tester.pumpAndSettle();
  }
}

/// The route child (the primary pane on the tablet layout, the whole body
/// elsewhere): the top Lists page.
Finder findListsPage() => find.byWidgetPredicate(
  (w) =>
      w is ListsScreen ||
      w is ListDetailScreen ||
      w is ListMembersScreen ||
      w is ManagePinnedScreen ||
      w is UserListsScreen,
);

/// [finder] inside a Lists page.
Finder inListsPage(Finder finder) =>
    find.descendant(of: findListsPage(), matching: finder);
