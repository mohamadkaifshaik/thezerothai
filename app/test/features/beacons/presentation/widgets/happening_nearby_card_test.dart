import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/happening_nearby_session.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/beacons_fixtures.dart';
import '../../../../support/fake_beacons_server.dart';
import '../../../../support/fake_location_repository.dart';
import '../../../../support/fake_search_repository.dart';
import '../../../../support/search_field_rig.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

const _all = {'posts', 'beacons', 'location', 'search'};
const _pages = ['/home', '/drafts', '/plans', '/plans/mine'];

void main() {
  late FakeBeaconsServer beacons;
  late FakeLocationRepository location;
  late HappeningNearbySession session;
  late _MockOnboarding onboarding;
  late _MockAuth auth;

  pb.NearbyBeacon tonightPlan(int i) {
    final d = DateTime.now();
    // An hour from now when that is before 04:00 tomorrow, which is always
    // true except in the last hour before it; the session's own clock is
    // pinned below so the window is the one the plans are built for.
    final start = DateTime(
      d.year,
      d.month,
      d.day,
      18,
    ).add(Duration(minutes: i));
    return pb.NearbyBeacon(
      view: beaconView(startAt: start, id: '${5000 + i}'),
    );
  }

  setUp(() {
    final d = DateTime.now();
    final noon = DateTime(d.year, d.month, d.day, 12);
    beacons = FakeBeaconsServer()
      ..nearbyArea = fakeAreaOne
      ..nearby.addAll([for (var i = 0; i < 14; i++) tonightPlan(i)]);
    location = FakeLocationRepository(
      settings: const LocationSettingsData(area: fakeAreaOne),
    );
    session = HappeningNearbySession(
      beacons: beacons,
      location: location,
      clock: () => noon,
    );
    addTearDown(session.dispose);
    onboarding = _MockOnboarding();
    auth = _MockAuth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  Future<GoRouter> pump(
    WidgetTester tester, {
    String location = '/home',
    double width = 1440,
    Set<String> flags = _all,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool withSession = true,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {...flags, kFeatureUiShell},
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    Widget page(String path) => MainShell(
      location: path,
      child: Scaffold(
        appBar: const AppTopBar(title: 'Page'),
        body: Center(child: Text('body $path')),
      ),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        for (final p in [..._pages, '/explore'])
          GoRoute(
            path: p,
            builder: (context, state) => page(state.uri.toString()),
          ),
      ],
    );
    final badge = UnreadBadgeCubit(0);
    addTearDown(badge.close);
    final messagesBadge = MessagesBadgeCubit();
    addTearDown(messagesBadge.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: badge),
          BlocProvider<MessagesBadgeCubit>.value(value: messagesBadge),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<SearchRepository>.value(
              value: FakeSearchRepository(),
            ),
            RepositoryProvider<RecentSearchesStore>.value(
              value: FakeRecentSearchesStore(),
            ),
            if (withSession)
              RepositoryProvider<HappeningNearbySession>.value(value: session),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  int nearbyCalls() => beacons.calls.where((c) => c == 'nearby').length;
  final card = find.byKey(const ValueKey('happening-nearby'));

  for (final page in _pages) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('1440 $page ${brightness.name} x$scale shows the hero '
            'without overflow', (tester) async {
          await pump(
            tester,
            location: page,
            brightness: brightness,
            textScale: scale,
          );
          expect(card, findsOneWidget);
          expect(find.text('HAPPENING NEARBY'), findsOneWidget);
          expect(find.textContaining('14 plans'), findsOneWidget);
          expect(find.text('Near Alpha Nagar, Testville'), findsOneWidget);
          expect(find.text('See plans'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('one semantics button label', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(
      find.bySemanticsLabel('14 plans tonight near Alpha Nagar. See plans'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('two pages, one RPC', (tester) async {
    final router = await pump(tester, location: '/home');
    router.go('/drafts');
    await tester.pumpAndSettle();
    router.go('/plans/mine');
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(nearbyCalls(), 1);
  });

  testWidgets('tap opens Explore on Nearby', (tester) async {
    final router = await pump(tester);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(router.state.uri.toString(), '/explore?tab=nearby');
  });

  group('gating: no box and no RPC', () {
    for (final entry in {
      'location off': {'posts', 'beacons', 'search'},
      'beacons off': {'posts', 'location', 'search'},
      'search off': {'posts', 'beacons', 'location'},
    }.entries) {
      testWidgets(entry.key, (tester) async {
        await pump(tester, flags: entry.value);
        expect(card, findsNothing);
        expect(nearbyCalls(), 0);
        expect(location.calls, isEmpty);
      });
    }

    for (final width in [360.0, 834.0, 1199.0]) {
      testWidgets('width $width', (tester) async {
        await pump(tester, width: width);
        expect(card, findsNothing);
        expect(nearbyCalls(), 0);
        expect(location.calls, isEmpty);
      });
    }

    testWidgets('no saved area', (tester) async {
      location.settings = const LocationSettingsData();
      await pump(tester);
      expect(card, findsNothing);
      expect(nearbyCalls(), 0);
    });

    testWidgets('count 0', (tester) async {
      beacons.nearby.clear();
      await pump(tester);
      expect(card, findsNothing);
    });

    testWidgets('a failed call', (tester) async {
      beacons.nearbyRefusals.add(const NetworkException('offline'));
      await pump(tester);
      expect(card, findsNothing);
    });

    testWidgets('a page that is not one of the four', (tester) async {
      await pump(tester, location: '/explore');
      expect(card, findsNothing);
      expect(nearbyCalls(), 0);
    });

    testWidgets('no session above', (tester) async {
      await pump(tester, withSession: false);
      expect(card, findsNothing);
    });
  });
}
