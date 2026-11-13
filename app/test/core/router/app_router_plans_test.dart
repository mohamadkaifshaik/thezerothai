import 'dart:async';

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
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/beacons/presentation/plans_list_detail.dart';
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
import 'package:go_router/go_router.dart';
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

/// `/plans...` on the real router. With `beacons` off: the new shell keeps
/// `/plans` (paused) and sends the routes under it there; the legacy chrome
/// sends all of them Home. `/plans/new` is Create, not a plan called "new".
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
    String location, {
    Stream<Set<String>>? flagChanges,
    Size size = const Size(390, 844),
    bool hoisted = false,
  }) async {
    OnboardingState ready(Set<String> set) => OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: 'uid-1', handle: 'me'),
      enabledFeatures: set,
    );
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
      flagChanges?.map(ready) ?? const Stream<OnboardingState>.empty(),
      initialState: ready(flags),
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
    final graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    // The app-level Plans list (AppWidget provides it; tablet T5).
    final session = hoisted ? PlansSession(repository: beacons) : null;
    if (session != null) addTearDown(session.dispose);
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BeaconsRepository>.value(value: beacons),
          RepositoryProvider<GraphRepository>.value(value: graph),
          if (session != null)
            RepositoryProvider<PlansSession>.value(value: session),
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

  const everyPlansRoute = [
    '/plans',
    '/plans/new',
    '/plans/mine',
    '/plans/$kBeaconIdA',
    '/plans/$kBeaconIdA/people',
    '/plans/$kBeaconIdA/edit',
  ];

  testWidgets('beacons off, new shell: /plans stays and is paused, every '
      'route under it lands there, no RPC (ADR-0034 section 4)', (
    tester,
  ) async {
    for (final location in everyPlansRoute) {
      final (path, beacons) = await openAt(tester, const {
        'ui_shell',
      }, location);
      expect(path, AppRouter.plansPath, reason: location);
      expect(find.byType(BeaconsScreen), findsOneWidget, reason: location);
      expect(find.text('Plans are paused'), findsOneWidget, reason: location);
      expect(
        find.text(
          'Your plans and requests are safe. They will show again when Plans '
          'is back.',
        ),
        findsOneWidget,
        reason: location,
      );
      expect(find.byTooltip('New plan'), findsNothing, reason: location);
      for (final screen in [
        BeaconScreen,
        CreateBeaconScreen,
        MyBeaconsScreen,
        BeaconPeopleScreen,
        EditBeaconScreen,
      ]) {
        expect(find.byType(screen), findsNothing, reason: location);
      }
      expect(beacons.calls, isEmpty, reason: location);
    }
  });

  testWidgets('kill switch in mid-session on /plans/<id>, new shell: the '
      'flag drops and the plan redirects to /plans, paused, nothing more '
      'sent', (tester) async {
    final getMe = StreamController<Set<String>>();
    addTearDown(getMe.close);
    final (path, beacons) = await openAt(
      tester,
      const {'beacons', 'ui_shell'},
      '/plans/$kBeaconIdA',
      flagChanges: getMe.stream,
    );
    expect(path, '/plans/$kBeaconIdA');
    expect(find.byType(BeaconScreen), findsOneWidget);
    expect(beacons.calls, ['get']);

    // A fresh GetMe without `beacons`.
    getMe.add(const {'ui_shell'});
    await tester.pumpAndSettle();

    expect(find.byType(BeaconScreen), findsNothing);
    expect(find.byType(BeaconsScreen), findsOneWidget);
    expect(find.text('Plans are paused'), findsOneWidget);
    expect(find.byTooltip('New plan'), findsNothing);
    expect(beacons.calls, ['get']);
    final context = tester.element(find.byType(BeaconsScreen));
    expect(GoRouter.of(context).state.uri.path, AppRouter.plansPath);
  });

  testWidgets('beacons off, legacy chrome (ui_shell off): every route still '
      'redirects Home, no RPC', (tester) async {
    for (final location in everyPlansRoute) {
      final (path, beacons) = await openAt(tester, const {}, location);
      expect(path, AppRouter.homePath, reason: location);
      expect(find.byType(BeaconsScreen), findsNothing);
      expect(find.byType(BeaconScreen), findsNothing);
      expect(find.text('Plans are paused'), findsNothing);
      expect(beacons.calls, isEmpty, reason: location);
    }
  });

  testWidgets('beacons on, new shell: no route redirects', (tester) async {
    for (final location in everyPlansRoute) {
      final (path, _) = await openAt(tester, const {
        'beacons',
        'ui_shell',
      }, location);
      expect(path, location);
      expect(find.text('Plans are paused'), findsNothing, reason: location);
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

  // Tablet T5: the routes are unchanged; on the tablet layout in band B the
  // real router's shell puts the Plans list beside `/plans` and `/plans/:id`
  // only (cold deep links included), with the app-level list.
  group('tablet layout, band B (1024)', () {
    const tablet = {'beacons', 'ui_shell', 'ui_tablet'};

    testWidgets('a cold /plans/<id>: the list pane beside the plan; one list '
        'and one "Your plans" call', (tester) async {
      final (path, beacons) = await openAt(
        tester,
        tablet,
        '/plans/$kBeaconIdA',
        size: const Size(1024, 900),
        hoisted: true,
      );
      expect(path, '/plans/$kBeaconIdA');
      expect(find.byType(PlansListPane), findsOneWidget);
      expect(find.byType(BeaconScreen), findsOneWidget);
      expect(beacons.calls.where((c) => c == 'list:'), hasLength(1));
      expect(beacons.mineLimits, [2]);
      expect(beacons.calls.where((c) => c == 'get'), hasLength(1));
    });

    testWidgets('/plans: the pane and the placeholder', (tester) async {
      final (_, beacons) = await openAt(
        tester,
        tablet,
        '/plans',
        size: const Size(1024, 900),
        hoisted: true,
      );
      expect(find.byType(PlansListPane), findsOneWidget);
      expect(find.text(kPickAPlan), findsOneWidget);
      expect(beacons.calls.where((c) => c == 'list:'), hasLength(1));
    });

    for (final location in [
      '/plans/mine',
      '/plans/new',
      '/plans/$kBeaconIdA/people',
      '/plans/$kBeaconIdA/edit',
    ]) {
      testWidgets('$location: no list pane', (tester) async {
        final (path, beacons) = await openAt(
          tester,
          tablet,
          location,
          size: const Size(1024, 900),
          hoisted: true,
        );
        expect(path, location);
        expect(find.byType(PlansListPane), findsNothing);
        expect(beacons.calls.where((c) => c == 'list:'), isEmpty);
      });
    }

    // A cold or typed form link draws no context pane (the tablet layout
    // has none): the form keeps its own preview inline.
    for (final location in ['/plans/new', '/plans/$kBeaconIdA/edit']) {
      testWidgets('$location (cold): no context pane, the preview inline', (
        tester,
      ) async {
        final (path, _) = await openAt(
          tester,
          tablet,
          location,
          size: const Size(1024, 900),
          hoisted: true,
        );
        expect(path, location);
        expect(find.text('Preview'), findsOneWidget);
      });
    }

    testWidgets('the same cold /plans/<id> on a phone: no pane, no extra '
        'call', (tester) async {
      final (_, beacons) = await openAt(
        tester,
        tablet,
        '/plans/$kBeaconIdA',
        hoisted: true,
      );
      expect(find.byType(PlansListPane), findsNothing);
      expect(beacons.calls, ['get']);
    });
  });
}
