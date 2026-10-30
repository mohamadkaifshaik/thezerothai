import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/search_pill_button.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_search_repository.dart';

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

/// W4-17/18: the Explore destination of `MainShell` (second after Home, needs
/// `search` + `ui_shell`), the screen at the responsive widths and text scales,
/// and the desktop side column's search pill (hidden on Explore itself).
void main() {
  late _MockOnboardingBloc onboarding;
  late _MockAuthBloc auth;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  Future<GoRouter> pump(
    WidgetTester tester, {
    String location = '/explore',
    Size size = const Size(360, 900),
    Set<String> flags = const {'posts', 'notifications', 'search'},
    bool newShell = true,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    FakeSearchRepository? search,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {...flags, if (newShell) kFeatureUiShell},
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    GoRoute route(String path, Widget Function() child) => GoRoute(
      path: path,
      builder: (context, state) =>
          MainShell(location: state.matchedLocation, child: child()),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        route('/home', () => const Center(child: Text('page home'))),
        route('/explore', () => const ExploreScreen()),
        route('/notifications', () => const Center(child: Text('page n'))),
        route('/profile/alice', () => const Center(child: Text('page p'))),
        GoRoute(
          path: '/search',
          builder: (context, state) => Scaffold(
            body: Text('search q=${state.uri.queryParameters['q']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final unread = UnreadBadgeCubit();
    addTearDown(unread.close);
    final trends = TrendsCubit(repository: search ?? FakeSearchRepository());
    addTearDown(trends.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
          BlocProvider<TrendsCubit>.value(value: trends),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: RepositoryProvider<GraphRepository>.value(
          value: _MockGraph(),
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

  group('which flag combinations show the destination', () {
    final cases = <(String, Set<String>, bool, bool)>[
      ('search + ui_shell', {'posts', 'search'}, true, true),
      ('search alone (legacy chrome)', {'posts', 'search'}, false, false),
      ('ui_shell alone', {'posts'}, true, false),
      ('neither', {'posts'}, false, false),
    ];
    for (final (name, flags, newShell, shown) in cases) {
      testWidgets('$name: ${shown ? 'shown' : 'hidden'}', (tester) async {
        await pump(tester, location: '/home', flags: flags, newShell: newShell);
        expect(
          find.descendant(
            of: find.byType(AppBottomBar),
            matching: find.byIcon(Icons.search),
          ),
          shown ? findsOneWidget : findsNothing,
        );
      });
    }
  });

  testWidgets('sits second, right after Home, in the bar', (tester) async {
    await pump(tester, location: '/home');

    final bar = find.byType(AppBottomBar);
    double x(IconData icon) => tester
        .getCenter(find.descendant(of: bar, matching: find.byIcon(icon)))
        .dx;
    expect(x(Icons.home), lessThan(x(Icons.search)));
    expect(x(Icons.search), lessThan(x(Icons.notifications_none)));
    expect(x(Icons.notifications_none), lessThan(x(Icons.person_outline)));
  });

  testWidgets('/explore selects it with the selected glyph', (tester) async {
    await pump(tester);

    expect(find.byIcon(Icons.manage_search), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.byIcon(Icons.home), findsNothing);
  });

  testWidgets('tapping it goes to /explore (a root: no back button)', (
    tester,
  ) async {
    final router = await pump(tester, location: '/home');

    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.byIcon(Icons.search),
      ),
    );
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/explore');
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('Trending'), findsOneWidget);
  });

  testWidgets('the rail item goes to /explore too', (tester) async {
    final router = await pump(
      tester,
      location: '/home',
      size: const Size(1200, 900),
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.search),
      ),
    );
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/explore');
  });

  testWidgets('the centre pill opens the search page', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(SearchPillButton));
    await tester.pumpAndSettle();

    expect(find.text('search q=null'), findsOneWidget);
  });

  group('desktop side column pill (W4-18)', () {
    testWidgets('shows on Home at 1200', (tester) async {
      await pump(tester, location: '/home', size: const Size(1200, 900));
      expect(find.byType(SearchPillButton), findsOneWidget);
    });

    testWidgets('is hidden on /explore (only the centre header has it)', (
      tester,
    ) async {
      await pump(tester, size: const Size(1536, 900));
      expect(find.byType(SearchPillButton), findsOneWidget);
      final x = tester.getCenter(find.byType(SearchPillButton)).dx;
      expect(x, lessThan(1536 - AppSize.sideColumn));
    });

    testWidgets('is absent with search off', (tester) async {
      await pump(
        tester,
        location: '/home',
        size: const Size(1536, 900),
        flags: {'posts'},
      );
      expect(find.byType(SearchPillButton), findsNothing);
    });

    testWidgets('opens the search page', (tester) async {
      await pump(tester, location: '/home', size: const Size(1200, 900));
      await tester.tap(find.byType(SearchPillButton));
      await tester.pumpAndSettle();
      expect(find.text('search q=null'), findsOneWidget);
    });
  });

  group('responsive matrix: no overflow', () {
    for (final size in const [
      Size(360, 740),
      Size(600, 900),
      Size(1200, 900),
      Size(1536, 900),
    ]) {
      for (final brightness in Brightness.values) {
        for (final scale in const [1.0, 1.5, 2.0]) {
          testWidgets('${size.width.toInt()}dp ${brightness.name} x$scale', (
            tester,
          ) async {
            await pump(
              tester,
              size: size,
              brightness: brightness,
              textScale: scale,
            );
            expect(tester.takeException(), isNull);
            expect(find.text('Trending'), findsOneWidget);
            expect(find.byType(SearchPillButton), findsOneWidget);
            final pill = tester.getSize(find.byType(SearchPillButton));
            expect(pill.height, greaterThanOrEqualTo(48));
          });
        }
      }
    }
  });

  testWidgets('semantics: the pill is a labelled button', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(
      tester.getSemantics(find.byType(SearchPillButton)),
      matchesSemantics(label: 'Search', isButton: true, hasTapAction: true),
    );
    handle.dispose();
  });

  group('trends (W4-17/18)', () {
    const withTrends = {'posts', 'search', 'trends'};

    Trend trend(int rank, {String? tag, int posts = 120}) =>
        Trend(tag: tag ?? 'tag$rank', rank: rank, postCount: Int64(posts));

    FakeSearchRepository repo(int n) =>
        FakeSearchRepository()
          ..trendsResult = TrendsResult(
            trends: [for (var i = 1; i <= n; i++) trend(i)],
            computedAt: DateTime.now().subtract(const Duration(hours: 2)),
          );

    testWidgets('flag off: no trends section, no call', (tester) async {
      final search = repo(3);
      await pump(tester, search: search);
      expect(find.text('Trending today'), findsNothing);
      expect(search.calls, isEmpty);
    });

    testWidgets('Explore shows 10 rows, Show more expands to 30', (
      tester,
    ) async {
      final search = repo(30);
      await pump(tester, flags: withTrends, search: search);
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find
            .descendant(
              of: find.byType(ExploreScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('#tag10'), findsOneWidget);
      expect(find.text('#tag11', skipOffstage: false), findsNothing);
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('#tag30'),
        400,
        scrollable: find
            .descendant(
              of: find.byType(ExploreScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('#tag30'), findsOneWidget);
    });

    testWidgets('a row shows rank, name and compact count; tap searches', (
      tester,
    ) async {
      final search = FakeSearchRepository()
        ..trendsResult = TrendsResult(
          trends: [trend(1, tag: 'launch', posts: 1200)],
          computedAt: DateTime.now(),
        );
      await pump(tester, flags: withTrends, search: search);
      expect(find.text('1 · Trending'), findsOneWidget);
      expect(find.text('#launch'), findsOneWidget);
      expect(find.text('1.2K posts'), findsOneWidget);
      await tester.tap(find.text('#launch'));
      await tester.pumpAndSettle();
      expect(find.text('search q=#launch'), findsOneWidget);
    });

    testWidgets('empty list: Nothing is trending yet', (tester) async {
      final search = FakeSearchRepository()
        ..trendsResult = const TrendsResult();
      await pump(tester, flags: withTrends, search: search);
      expect(find.text('Nothing is trending yet'), findsOneWidget);
    });

    testWidgets('a failed first call shows a message and Retry', (
      tester,
    ) async {
      final search = FakeSearchRepository()
        ..error = const SearchRateLimitedException();
      await pump(tester, flags: withTrends, search: search);
      expect(find.textContaining('a bit too fast'), findsOneWidget);
      search
        ..error = null
        ..trendsResult = TrendsResult(
          trends: [trend(1)],
          computedAt: DateTime.now(),
        );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('#tag1'), findsOneWidget);
      expect(search.calls.length, 2);
    });

    testWidgets('a list over 36 hours old says so', (tester) async {
      final search = FakeSearchRepository()
        ..trendsResult = TrendsResult(
          trends: [trend(1)],
          computedAt: DateTime.now().subtract(const Duration(hours: 40)),
        );
      await pump(tester, flags: withTrends, search: search);
      expect(find.textContaining('more than a day old'), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED hides the section quietly', (tester) async {
      final search = FakeSearchRepository()
        ..error = const SearchUnavailableException('trends');
      await pump(tester, flags: withTrends, search: search);
      expect(find.text('Nothing is trending yet'), findsNothing);
      expect(find.textContaining('loaded'), findsNothing);
    });

    testWidgets('side column card: top 5, Show more goes to Explore', (
      tester,
    ) async {
      final search = repo(8);
      await pump(
        tester,
        location: '/home',
        size: const Size(1200, 900),
        flags: withTrends,
        search: search,
      );
      expect(find.text("What's happening"), findsOneWidget);
      expect(find.text('#tag5'), findsOneWidget);
      expect(find.text('#tag6'), findsNothing);
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(find.text('Trending today'), findsOneWidget);
    });

    testWidgets('card flag off: no card, no call', (tester) async {
      final search = repo(8);
      await pump(
        tester,
        location: '/home',
        size: const Size(1200, 900),
        search: search,
      );
      expect(find.text("What's happening"), findsNothing);
      expect(search.calls, isEmpty);
    });

    testWidgets('Explore + side column at 1200: exactly one GetTrends', (
      tester,
    ) async {
      final search = repo(8);
      await pump(
        tester,
        size: const Size(1200, 900),
        flags: withTrends,
        search: search,
      );
      expect(find.text("What's happening"), findsOneWidget);
      expect(find.text('Trending today'), findsOneWidget);
      expect(search.calls, ['trends:']);
    });

    for (final size in const [Size(360, 740), Size(1536, 900)]) {
      for (final b in Brightness.values) {
        testWidgets('no overflow at ${size.width.toInt()}dp ${b.name} x2.0', (
          tester,
        ) async {
          await pump(
            tester,
            size: size,
            flags: withTrends,
            search: repo(30),
            textScale: 2,
            brightness: b,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
