import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockLists extends Mock implements ListsRepository {}

class _MockTimeline extends Mock implements TimelineRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/lists` on the real router (W5-11): needs the `lists` flag, else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUpAll(() => registerFallbackValue(HomeTabKind.list));

  Future<(String, _MockLists)> openAt(
    WidgetTester tester,
    Set<String> flags,
    String location,
  ) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final lists = _MockLists();
    when(() => lists.enabled).thenReturn(true);
    when(
      () => lists.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const ListsPage(lists: []));
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: flags,
      ),
    );
    final timeline = _MockTimeline();
    final posts = _MockPosts();
    final tabs = _MockTabs();
    final feed = FeedKey.list('77');
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => timeline.refresh(feed))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => lists.header(any())).thenReturn(null);
    when(() => lists.headerChanges).thenAnswer((_) => const Stream.empty());
    when(() => lists.getList(any()))
        .thenAnswer((_) async => pb.ListInfo(listId: '77', name: 'Friends'));
    when(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    ).thenAnswer((_) async => const ListMembersPage(users: []));
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.tabs).thenReturn(const []);
    when(() => tabs.saving).thenReturn(false);
    final engagement = EngagementCubit(repository: _MockEngagementRepository());
    addTearDown(engagement.close);
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (appRouter.router.routeInformationProvider.value.uri.path, lists);
  }

  test('the paths', () {
    expect(AppRouter.listsPath, '/lists');
    expect(AppRouter.listPath('12'), '/lists/12');
    expect(AppRouter.listMembersPath('12'), '/lists/12/members');
  });

  testWidgets('lists off: /lists and /lists/1 redirect Home, no RPC', (
    tester,
  ) async {
    for (final location in ['/lists', '/lists/1']) {
      final (path, lists) = await openAt(tester, const {}, location);
      expect(path, AppRouter.homePath, reason: location);
      expect(find.byType(ListsScreen), findsNothing);
      verifyNever(
        () => lists.listUserLists(
          ownerId: any(named: 'ownerId'),
          containsUserId: any(named: 'containsUserId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
    }
  });

  testWidgets('lists on: /lists shows the screen', (tester) async {
    final (path, _) = await openAt(tester, const {'lists'}, '/lists');
    expect(path, '/lists');
    expect(find.byType(ListsScreen), findsOneWidget);
  });

  testWidgets('lists on: /lists/77 shows the detail and /lists/77/members '
      'the members', (tester) async {
    var (path, _) = await openAt(tester, const {'lists'}, '/lists/77');
    expect(path, '/lists/77');
    expect(find.byType(ListDetailScreen), findsOneWidget);

    (path, _) = await openAt(tester, const {'lists'}, '/lists/77/members');
    expect(path, '/lists/77/members');
    expect(find.byType(ListMembersScreen), findsOneWidget);
  });

  testWidgets(
    'Manage pinned (/home/pinned) needs lists and ui_shell, else Home',
    (tester) async {
      expect(AppRouter.pinnedPath, '/home/pinned');
      for (final flags in [
        const <String>{},
        const {'lists'},
        const {'ui_shell'},
      ]) {
        final (path, _) = await openAt(tester, flags, AppRouter.pinnedPath);
        expect(path, AppRouter.homePath, reason: '$flags');
        expect(find.byType(ManagePinnedScreen), findsNothing);
      }

      final (path, _) = await openAt(tester, const {
        'lists',
        'ui_shell',
      }, AppRouter.pinnedPath);
      expect(path, AppRouter.pinnedPath);
      expect(find.byType(ManagePinnedScreen), findsOneWidget);
    },
  );
}
