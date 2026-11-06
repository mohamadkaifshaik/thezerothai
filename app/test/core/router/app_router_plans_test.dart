import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_people_screen.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/my_beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/beacons_fixtures.dart';
import '../../support/fake_beacons_server.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

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

/// `/plans...` on the real router: needs the `beacons` flag, else Home
/// (Review Focus 5); `/plans/new` is Create, not a plan called "new".
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUpAll(() {
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(HomeTabKind.community);
  });

  Future<(String, FakeBeaconsServer)> openAt(
    WidgetTester tester,
    Set<String> flags,
    String location,
  ) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final beacons = FakeBeaconsServer();
    beacons.public.add(
      beaconView(startAt: DateTime.now().add(const Duration(hours: 2))),
    );
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
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(any()))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => timeline.refresh(any()))
        .thenAnswer((_) async => const TimelineSnapshot());
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
          RepositoryProvider<BeaconsRepository>.value(value: beacons),
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
    return (appRouter.router.routeInformationProvider.value.uri.path, beacons);
  }

  test('the paths', () {
    expect(AppRouter.plansPath, '/plans');
    expect(AppRouter.planNewPath, '/plans/new');
    expect(AppRouter.planPath('12 3'), '/plans/12%203');
  });

  testWidgets('beacons off: every route redirects Home, no RPC', (
    tester,
  ) async {
    for (final location in [
      '/plans',
      '/plans/new',
      '/plans/mine',
      '/plans/$kBeaconIdA',
      '/plans/$kBeaconIdA/people',
      '/plans/$kBeaconIdA/edit',
    ]) {
      final (path, beacons) = await openAt(tester, const {}, location);
      expect(path, AppRouter.homePath, reason: location);
      expect(find.byType(BeaconsScreen), findsNothing);
      expect(find.byType(BeaconScreen), findsNothing);
      expect(beacons.calls, isEmpty, reason: location);
    }
  });

  testWidgets('beacons on: /plans shows the list', (tester) async {
    final (path, beacons) = await openAt(tester, const {'beacons'}, '/plans');
    expect(path, '/plans');
    expect(find.byType(BeaconsScreen), findsOneWidget);
    expect(beacons.calls, ['list:']);
  });

  testWidgets('beacons on: /plans/new is Create, not a plan called "new"', (
    tester,
  ) async {
    final (path, beacons) = await openAt(tester, const {
      'beacons',
    }, '/plans/new');
    expect(path, '/plans/new');
    expect(find.byType(CreateBeaconScreen), findsOneWidget);
    expect(find.byType(BeaconScreen), findsNothing);
    expect(beacons.calls, isEmpty);
  });

  testWidgets('beacons on: /plans/<id> shows the plan', (tester) async {
    final (path, beacons) = await openAt(tester, const {
      'beacons',
    }, '/plans/$kBeaconIdA');
    expect(path, '/plans/$kBeaconIdA');
    expect(find.byType(BeaconScreen), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(beacons.calls, ['get']);
  });

  testWidgets('beacons on: /plans/mine is My plans, not a plan called "mine"', (
    tester,
  ) async {
    final (path, beacons) = await openAt(tester, const {
      'beacons',
    }, '/plans/mine');
    expect(path, '/plans/mine');
    expect(find.byType(MyBeaconsScreen), findsOneWidget);
    expect(find.byType(BeaconScreen), findsNothing);
    expect(beacons.calls, ['mine']);
  });

  testWidgets('beacons on: /plans/<id>/people and /plans/<id>/edit', (
    tester,
  ) async {
    var (path, beacons) = await openAt(tester, const {
      'beacons',
    }, '/plans/$kBeaconIdA/people');
    expect(path, '/plans/$kBeaconIdA/people');
    expect(find.byType(BeaconPeopleScreen), findsOneWidget);
    // The fixture's viewer is not going: the people screen reads the plan
    // and shows the gate copy without a list read.
    expect(beacons.calls, ['get']);

    (path, beacons) = await openAt(tester, const {
      'beacons',
    }, '/plans/$kBeaconIdA/edit');
    expect(path, '/plans/$kBeaconIdA/edit');
    expect(find.byType(EditBeaconScreen), findsOneWidget);
    expect(beacons.calls, ['get']);
  });
}
