import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_people_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/beacons/presentation/my_beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/plans_list_detail.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'beacons_fixtures.dart';
import 'fake_beacons_server.dart';

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

/// Plans (`beacons`) and the tablet shell's two flags.
const kPlansTabletFlags = <String>{
  kFeatureBeacons,
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3),
/// each with `beacons` on: only `ui_shell` + `ui_tablet` draws the tablet
/// layout, so only that mode may show "Your plans" and the list pane.
const kPlansFlagModes = <String, Set<String>>{
  'neither': {kFeatureBeacons},
  'ui_shell only': {kFeatureBeacons, kFeatureUiShell},
  'ui_tablet only': {kFeatureBeacons, kFeatureUiTablet},
  'ui_shell + ui_tablet': kPlansTabletFlags,
};

/// The public plans of the rig, in list order.
const kRigPlans = <(String, String)>[
  (kBeaconIdA, 'Coffee at noon'),
  (kBeaconIdB, 'Evening walk'),
  ('1234567890123456791', 'Study group'),
];

/// The caller's own plans (ListMyBeacons), in order.
const kRigMine = <(String, String)>[
  ('2234567890123456781', 'My run'),
  ('2234567890123456782', 'My lunch'),
  ('2234567890123456783', 'My film'),
];

/// The real `MainShell` in a real `ShellRoute` around the real Plans pages
/// (`BeaconsScreen`, `BeaconScreen`, `BeaconPeopleScreen`, `MyBeaconsScreen`)
/// over a [FakeBeaconsServer], with the app-level [PlansSession] provided
/// (as `AppWidget` does) unless `hoisted: false`. `/plans/new` and
/// `/plans/:id/edit` are stubs.
class PlansTabletRig {
  PlansTabletRig() {
    final now = DateTime.now();
    var hour = 1;
    for (final (id, title) in kRigPlans) {
      server.public.add(
        beaconView(
          startAt: now.add(Duration(hours: hour++)),
          id: id,
          title: title,
          venue: 'Venue of $title',
        ),
      );
    }
    for (final (id, title) in kRigMine) {
      server.mine.add(
        beaconView(
          startAt: now.add(Duration(hours: hour++)),
          id: id,
          title: title,
          venue: 'Venue of $title',
        ),
      );
    }
  }

  final server = FakeBeaconsServer();
  late GoRouter router;

  /// The hoisted session, or null with `hoisted: false`.
  PlansSession? session;

  /// Emits a new `enabled_features` set (a fresh `GetMe`).
  final flagChanges = StreamController<Set<String>>.broadcast();

  /// The location of the top page (a pushed one too).
  Uri get uri => router.state.uri;

  /// How many times [call] reached the server.
  int count(String call) => server.calls.where((c) => c == call).length;

  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.plansPath,
    double width = 1024,
    double height = 900,
    Set<String> flags = kPlansTabletFlags,
    bool hoisted = true,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    addTearDown(flagChanges.close);
    OnboardingState ready(Set<String> set) => OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: set,
      profile: identity.Profile(
        userId: 'u-alice',
        handle: 'alice',
        displayName: 'Alice A',
      ),
    );
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      flagChanges.stream.map(ready),
      initialState: ready(flags),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'u-alice',
          email: 'alice@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    if (hoisted) {
      final s = session = PlansSession(repository: server);
      addTearDown(s.dispose);
    }

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
              builder: (context, state) =>
                  const Scaffold(body: Text('home body')),
            ),
            GoRoute(
              path: AppRouter.plansPath,
              builder: (context, state) => const BeaconsScreen(),
            ),
            GoRoute(
              path: AppRouter.planNewPath,
              builder: (context, state) =>
                  Scaffold(appBar: AppBar(title: const Text('New plan stub'))),
            ),
            GoRoute(
              path: AppRouter.plansMinePath,
              builder: (context, state) => const MyBeaconsScreen(),
            ),
            GoRoute(
              path: '/plans/:id',
              builder: (context, state) =>
                  BeaconScreen(beaconId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/plans/:id/people',
              builder: (context, state) =>
                  BeaconPeopleScreen(beaconId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/plans/:id/edit',
              builder: (context, state) =>
                  Scaffold(appBar: AppBar(title: const Text('Edit stub'))),
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
          RepositoryProvider<BeaconsRepository>.value(value: server),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          if (session case final s?)
            RepositoryProvider<PlansSession>.value(value: s),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
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
    await tester.pumpAndSettle();
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

/// Band B's list pane, or nothing.
Finder findPlansPane() => find.byType(PlansListPane);

/// [finder] inside the list pane.
Finder inPlansPane(Finder finder) =>
    find.descendant(of: findPlansPane(), matching: finder);

/// The shell page (the primary pane, or the whole body off the tablet
/// layout): the route child, not the list pane.
Finder findShellPage() => find.byWidgetPredicate(
  (w) =>
      w is BeaconsScreen ||
      w is BeaconScreen ||
      w is BeaconPeopleScreen ||
      w is MyBeaconsScreen,
);

/// [finder] inside the route child.
Finder inShellPage(Finder finder) =>
    find.descendant(of: findShellPage(), matching: finder);
