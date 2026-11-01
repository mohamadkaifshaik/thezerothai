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
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockGraph extends Mock implements GraphRepository {}

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

/// `/communities...` on the real router (W5-31, W5-32): needs the `communities`
/// flag, else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
    registerFallbackValue(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    );
  });

  Future<(String, _MockCommunities)> openAt(
    WidgetTester tester,
    Set<String> flags,
    String location,
  ) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final communities = _MockCommunities();
    when(() => communities.enabled).thenReturn(true);
    when(
      () => communities.listMyCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => const MyCommunities(communities: [], canCreate: true),
    );
    when(
      () => communities.listCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const CommunitiesPage(communities: []));
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
    final feed = FeedKey.community('77');
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => timeline.refresh(feed))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => communities.getCommunity(any())).thenAnswer(
      (_) async => pb.GetCommunityResponse(
        community: pb.Community(communityId: '77', name: 'Chess club'),
      ),
    );
    when(
      () => communities.listMembers(
        communityId: any(named: 'communityId'),
        filter: any(named: 'filter'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const CommunityMembersPage(members: []));
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
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
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
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
    return (
      appRouter.router.routeInformationProvider.value.uri.path,
      communities,
    );
  }

  test('the paths', () {
    expect(AppRouter.communitiesPath, '/communities');
    expect(AppRouter.communityNewPath, '/communities/new');
    expect(AppRouter.communityPath('12'), '/communities/12');
    expect(AppRouter.communityPath('a b'), '/communities/a%20b');
    expect(AppRouter.communityMembersPath('12'), '/communities/12/members');
  });

  testWidgets('communities off: every route redirects Home, no RPC', (
    tester,
  ) async {
    for (final location in [
      '/communities',
      '/communities/new',
      '/communities/1',
      '/communities/1/members',
    ]) {
      final (path, communities) = await openAt(tester, const {}, location);
      expect(path, AppRouter.homePath, reason: location);
      expect(find.byType(CommunitiesScreen), findsNothing);
      verifyNever(
        () => communities.listMyCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
      verifyNever(() => communities.getCommunity(any()));
    }
  });

  testWidgets('communities on: /communities shows the screen', (tester) async {
    final (path, _) = await openAt(tester, const {
      'communities',
    }, '/communities');
    expect(path, '/communities');
    expect(find.byType(CommunitiesScreen), findsOneWidget);
  });

  testWidgets('communities on: /communities/new is Create, not a community '
      'called "new"', (tester) async {
    final (path, communities) = await openAt(tester, const {
      'communities',
    }, '/communities/new');
    expect(path, '/communities/new');
    expect(find.byType(CreateCommunityScreen), findsOneWidget);
    expect(find.byType(CommunityScreen), findsNothing);
    verifyNever(() => communities.getCommunity(any()));
  });

  testWidgets('communities on: /communities/77 shows the page and '
      '/communities/77/members the members', (tester) async {
    var (path, _) = await openAt(tester, const {
      'communities',
    }, '/communities/77');
    expect(path, '/communities/77');
    expect(find.byType(CommunityScreen), findsOneWidget);

    (path, _) = await openAt(tester, const {
      'communities',
    }, '/communities/77/members');
    expect(path, '/communities/77/members');
    expect(find.byType(CommunityMembersScreen), findsOneWidget);
  });
}
