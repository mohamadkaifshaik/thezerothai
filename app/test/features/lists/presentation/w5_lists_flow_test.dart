import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/lists/presentation/widgets/add_to_lists_sheet.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
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

import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/fake_transport.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

/// W5-16: the Part A journey across screens with the REAL `ListsRepository`
/// and `HomeTabsRepository` over a small stateful fake server: Lists, create,
/// add a person from their profile, open the List, pin it, see its Home tab,
/// the members page, unpin. The list timeline (`GetListTimeline`, drift) is a
/// mocked `TimelineRepository`: drift does not run in `testWidgets`.
void main() {
  final feedL1 = FeedKey.list('L1');
  late List<String> calls;
  late List<tl.SetHomeTabsRequest> homeTabWrites;
  late List<pb.ListInfo> serverLists;
  late Set<String> containing;
  late ListsRepository lists;
  late HomeTabsRepository tabs;
  late _MockOnboarding onboarding;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late PendingPostsCubit pending;
  late PushCubit push;
  late PushOptInCubit optIn;
  late GoRouter router;

  setUp(() {
    calls = [];
    homeTabWrites = [];
    serverLists = [];
    containing = {};
    final epoch = SessionEpoch();
    final api = ApiClient.withTransport(
      FakeTransport((procedure, input) async {
        calls.add(procedure.split('/').last);
        if (input is pb.CreateListRequest) {
          final info = pb.ListInfo(
            listId: 'L1',
            name: input.name,
            isPrivate: input.isPrivate,
            memberCount: 0,
            owner: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          );
          serverLists.add(info);
          return pb.CreateListResponse(list: info);
        }
        if (input is pb.ListUserListsRequest) {
          return pb.ListUserListsResponse(
            lists: serverLists,
            containingListIds: input.containsUserId.isEmpty ? [] : containing,
          );
        }
        if (input is pb.AddListMemberRequest) {
          containing.add(input.listId);
          final info = serverLists.single..memberCount = 1;
          return pb.AddListMemberResponse(list: info);
        }
        if (input is pb.GetListRequest) {
          return pb.GetListResponse(list: serverLists.single);
        }
        if (input is pb.ListListMembersRequest) {
          return pb.ListListMembersResponse(
            users: [
              graph.UserListItem(
                user: common.AuthorSnapshot(
                  userId: 'u9',
                  handle: 'kaif',
                  displayName: 'Kaif',
                ),
              ),
            ],
          );
        }
        if (input is tl.SetHomeTabsRequest) {
          homeTabWrites.add(input);
          return tl.SetHomeTabsResponse(tabs: input.tabs);
        }
        throw StateError('unexpected $procedure');
      }),
    );
    final gate = ServiceFeatureGate(
      isEnabled: () => true,
      onUnexpectedError: (_, _) {},
    );
    tabs = HomeTabsRepository(apiClient: api, gate: gate, epoch: epoch);
    lists = ListsRepository(
      apiClient: api,
      gate: gate,
      epoch: SessionEpoch(),
      onListSeen: tabs.noteListInfo,
    );
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: const {'posts', 'lists', 'ui_shell', 'graph'},
      ),
    );
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    pending = PendingPostsCubit();
    final notifications = _MockNotifications();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(messaging: FakePushMessaging(), repository: notifications);
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    for (final feed in [const FeedKey.home(), feedL1]) {
      when(() => timeline.sinceRefresh(feed)).thenReturn(null);
      when(() => timeline.sinceRefreshAttempt(feed))
          .thenReturn(const Duration(seconds: 5));
    }
    when(() => timeline.cached(const FeedKey.home()))
        .thenAnswer((_) async => snapshotOf([3, 2, 1]));
    when(() => timeline.refresh(const FeedKey.home()))
        .thenAnswer((_) async => snapshotOf([3, 2, 1]));
    when(() => timeline.cached(feedL1))
        .thenAnswer((_) async => snapshotOf([11]));
    when(() => timeline.refresh(feedL1)).thenAnswer((_) async {
      // The list timeline brings the header, as the real repository does.
      lists.noteListInfo(serverLists.single);
      return snapshotOf([11]);
    });
    router = GoRouter(
      initialLocation: AppRouter.listsPath,
      routes: [
        GoRoute(
          path: AppRouter.homePath,
          builder: (_, _) => const HomeScreen(),
        ),
        GoRoute(
          path: AppRouter.pinnedPath,
          builder: (_, _) => const ManagePinnedScreen(),
        ),
        GoRoute(
          path: AppRouter.listsPath,
          builder: (_, _) => const ListsScreen(),
        ),
        GoRoute(
          path: '/lists/:id',
          builder: (_, s) => ListDetailScreen(listId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/lists/:id/members',
          builder: (_, s) => ListMembersScreen(listId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/profile-stub',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAddToListsSheet(
                  context,
                  repository: lists,
                  userId: 'u9',
                  handle: 'kaif',
                ),
                child: const Text('Add to Lists'),
              ),
            ),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  testWidgets('create, add a person, pin, Home tab, members, unpin', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Lists: empty, create one (private by default).
    expect(find.textContaining("haven't created any Lists"), findsOneWidget);
    await tester.tap(find.byTooltip('Create a new List'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Reading');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(calls.where((c) => c == 'CreateList'), hasLength(1));

    // 2. From the person's profile: Add to Lists, tap the row, Done.
    router.go('/profile-stub');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Lists'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading'), findsOneWidget);
    await tester.tap(find.textContaining('Reading'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'AddListMember'), hasLength(1));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // 3. The List page: header, Pin.
    router.go('/lists/L1');
    await tester.pumpAndSettle();
    expect(find.text('Reading'), findsWidgets);
    expect(find.textContaining('1 member'), findsWidgets);
    expect(find.text('post 11'), findsOneWidget);
    expect(
      calls.where((c) => c == 'GetList'),
      isEmpty,
      reason: 'the timeline brought the header: no GetList',
    );
    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();
    expect(homeTabWrites, hasLength(1));
    expect(homeTabWrites.single.tabs.single.id, 'L1');
    expect(find.text('Unpin from Home'), findsOneWidget);

    // 4. Members page.
    await tester.tap(find.textContaining('1 member').first);
    await tester.pumpAndSettle();
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Kaif'), findsOneWidget);

    // 5. Home: Following plus the pinned tab; its rows come from the cache.
    router.go(AppRouter.homePath);
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Reading'), findsOneWidget);
    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    expect(find.text('post 11'), findsOneWidget);
    expect(find.text('post 3'), findsNothing);

    // 6. Back to the List page and Unpin: the tab is gone, Following shows.
    router.go('/lists/L1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin from Home'));
    await tester.pumpAndSettle();
    expect(homeTabWrites, hasLength(2));
    expect(homeTabWrites.last.tabs, isEmpty);
    expect(find.text('Pin to Home'), findsOneWidget);
    router.go(AppRouter.homePath);
    await tester.pumpAndSettle();
    expect(find.text('Reading'), findsNothing);
    expect(find.text('post 3'), findsOneWidget);

    // Every request went to ListService or SetHomeTabs, and nothing was
    // asked twice that the journey did not need.
    expect(calls.where((c) => c == 'SetHomeTabs'), hasLength(2));
    expect(calls.where((c) => c == 'ListListMembers'), hasLength(1));
  });
}
