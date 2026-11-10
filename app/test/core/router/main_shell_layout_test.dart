import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/compose_gate.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_account_chip.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/widgets/account_refresh_banner.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contrast.dart';
import '../../support/fake_search_repository.dart';
import '../../support/geometry.dart';
import '../../support/search_field_rig.dart';
import '../../support/suggestions_fixtures.dart';
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

/// The shell's layout rules: which navigation, compose control and
/// drawer each width gets, and where each destination leads.
void main() {
  late _MockOnboardingBloc onboarding;
  late _MockAuthBloc auth;

  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
    registerFallbackValue(const OnboardingUserSignedOut());
  });

  setUp(() {
    onboarding = _MockOnboardingBloc();
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    String location = '/home',
    double width = 360,
    Set<String> flags = const {'posts', 'notifications'},
    UnreadBadgeCubit? badge,
    bool profile = true,
    bool newShell = true,
    SuggestionsCubit? suggestions,
    Widget? body,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool refreshFailed = false,
    double height = 900,
    int pendingFollowRequests = 0,
    GraphRepository? graph,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        refreshFailed: refreshFailed,
        pendingFollowRequestCount: pendingFollowRequests,
        enabledFeatures: {...flags, if (newShell) kFeatureUiShell},
        profile: profile
            ? identity.Profile(
                userId: 'u-alice',
                handle: 'alice',
                displayName: 'Alice A',
              )
            : null,
      ),
    );
    Widget page(String path, String text) => MainShell(
      location: path,
      child: Scaffold(
        appBar: const AppTopBar(title: 'Page'),
        body: body ?? Center(child: Text(text)),
      ),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => page('/home', 'home body'),
        ),
        GoRoute(
          path: '/notifications',
          builder: (context, state) =>
              page('/notifications', 'notifications body'),
        ),
        GoRoute(
          path: '/lists',
          builder: (context, state) => page('/lists', 'lists body'),
        ),
        GoRoute(
          path: '/communities',
          builder: (context, state) => page('/communities', 'communities body'),
        ),
        GoRoute(
          path: '/plans',
          builder: (context, state) => page('/plans', 'plans body'),
        ),
        GoRoute(
          path: '/bookmarks',
          builder: (context, state) => page('/bookmarks', 'bookmarks body'),
        ),
        GoRoute(
          path: '/profile/:handle',
          builder: (context, state) => page(
            '/profile/${state.pathParameters['handle']}',
            'profile body',
          ),
        ),
        GoRoute(
          path: '/u/:handle',
          builder: (context, state) =>
              page('/u/${state.pathParameters['handle']}', 'user body'),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => page('/settings', 'settings body'),
        ),
        GoRoute(
          path: '/settings/blocked',
          builder: (context, state) =>
              page('/settings/blocked', 'blocked body'),
        ),
        GoRoute(
          path: '/settings/handle',
          builder: (context, state) => page('/settings/handle', 'handle body'),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const Text('compose page'),
        ),
      ],
    );
    // The shell reads the cubit whenever the notifications flag is on.
    final effectiveBadge = badge ?? UnreadBadgeCubit(0);
    if (badge == null) addTearDown(effectiveBadge.close);
    final messagesBadge = MessagesBadgeCubit();
    addTearDown(messagesBadge.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: effectiveBadge),
          BlocProvider<MessagesBadgeCubit>.value(value: messagesBadge),
          if (suggestions != null)
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<GraphRepository>.value(
              value: graph ?? _MockGraph(),
            ),
            // The side column's search pill (Explore on, 1200dp and up).
            RepositoryProvider<SearchRepository>.value(
              value: FakeSearchRepository(),
            ),
            RepositoryProvider<RecentSearchesStore>.value(
              value: FakeRecentSearchesStore(),
            ),
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
  }

  group('account refresh banner (A10)', () {
    testWidgets('a failed refresh behind a cached profile shows a '
        'non-blocking Retry over the page', (tester) async {
      await pump(tester, refreshFailed: true);

      expect(find.text(kAccountRefreshFailedMessage), findsOneWidget);
      // The page stays usable underneath.
      expect(find.text('home body'), findsOneWidget);
      expect(find.byType(AppBottomBar), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      verify(() => onboarding.add(any(that: isA<OnboardingRefreshRequested>())))
          .called(1);
    });

    testWidgets('no banner after a successful refresh', (tester) async {
      await pump(tester);

      expect(find.text(kAccountRefreshFailedMessage), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('ui_shell flag off (legacy chrome)', () {
    testWidgets('phone: four destinations incl. Settings, no drawer, FAB on '
        'Home', (tester) async {
      await pump(tester, newShell: false);

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(find.byType(AppDrawer), findsNothing);
      expect(find.byTooltip('New post'), findsOneWidget);
    });

    testWidgets('Settings is the selected destination on /settings', (
      tester,
    ) async {
      await pump(tester, location: '/settings', newShell: false);

      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byTooltip('New post'), findsNothing);
    });

    testWidgets('tapping Settings goes to /settings', (tester) async {
      await pump(tester, newShell: false);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('wide: no account chip', (tester) async {
      await pump(tester, width: 1300, newShell: false);

      expect(find.byType(AppAccountChip), findsNothing);
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(Icons.settings_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  group('phone (360dp)', () {
    testWidgets('bottom bar with Home and Notifications only: no Profile, '
        'no Settings', (tester) async {
      await pump(tester);

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byIcon(Icons.home), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      // The only person glyph left is the avatar fallback in the top bar.
      expect(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.byIcon(Icons.person_outline),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      expect(find.byIcon(Icons.settings), findsNothing);
    });

    testWidgets('Notifications is absent with its flag off', (tester) async {
      await pump(tester, flags: {'posts'});

      expect(find.byIcon(Icons.notifications_none), findsNothing);
    });

    testWidgets('the selected tab follows the location', (tester) async {
      await pump(tester, location: '/notifications');
      expect(find.byIcon(Icons.notifications), findsOneWidget);
      expect(find.byIcon(Icons.home), findsNothing);

      // Profile is not in the phone bar: no cell is selected on it.
      await pump(tester, location: '/profile/alice');
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byIcon(Icons.notifications), findsNothing);
    });

    testWidgets('on Settings no tab is selected', (tester) async {
      await pump(tester, location: '/settings');

      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byIcon(Icons.notifications), findsNothing);
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    });

    testWidgets('tapping the tabs navigates', (tester) async {
      await pump(tester);

      await tester.tap(find.byIcon(Icons.notifications_none));
      await tester.pumpAndSettle();
      expect(find.text('notifications body'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.text('home body'), findsOneWidget);
    });

    testWidgets('the drawer carries the secondaries: Profile, Lists, '
        'Communities, History', (tester) async {
      await pump(
        tester,
        flags: const {'posts', 'lists', 'communities', 'bookmarks'},
      );
      await tester.tap(find.bySemanticsLabel('Open account menu'));
      await tester.pumpAndSettle();

      final drawer = find.byType(AppDrawer);
      for (final label in ['Profile', 'Lists', 'Communities', 'History']) {
        expect(
          find.descendant(of: drawer, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
    });

    testWidgets('Profile is reached through the drawer, not the bar', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.bySemanticsLabel('Open account menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(find.text('profile body'), findsOneWidget);
      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('on the rail, Profile goes home when there is no profile '
        'yet', (tester) async {
      await pump(tester, width: 800, profile: false);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(Icons.person_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('home body'), findsOneWidget);
    });

    testWidgets('the unread badge sits on the Notifications cell', (
      tester,
    ) async {
      final badge = UnreadBadgeCubit(7);
      addTearDown(badge.close);
      await pump(tester, badge: badge);

      expect(find.text('7'), findsOneWidget);
    });

    group('compose button rule (D2)', () {
      testWidgets('shown on Home too; the inline composer is an alternate '
          'entry', (tester) async {
        await pump(tester, location: '/home');
        expect(find.byType(FloatingActionButton), findsOneWidget);
      });

      testWidgets('hidden on Notifications and Settings', (tester) async {
        await pump(tester, location: '/notifications');
        expect(find.byType(FloatingActionButton), findsNothing);
        await pump(tester, location: '/settings');
        expect(find.byType(FloatingActionButton), findsNothing);
      });

      testWidgets('shown on a profile, and opens the composer', (tester) async {
        await pump(tester, location: '/profile/alice');
        expect(find.byType(FloatingActionButton), findsOneWidget);

        await tester.tap(find.byTooltip('New post'));
        await tester.pumpAndSettle();
        expect(find.text('compose page'), findsOneWidget);
      });

      testWidgets('hidden everywhere with the posts flag off', (tester) async {
        await pump(tester, location: '/profile/alice', flags: {});
        expect(find.byType(FloatingActionButton), findsNothing);
      });
    });

    testWidgets('the avatar button in the top bar opens the drawer', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.bySemanticsLabel('Open account menu'));
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsOneWidget);
      expect(find.text('Alice A'), findsOneWidget);
    });

    testWidgets('Settings is reachable from the drawer', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Open account menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings and Privacy'));
      await tester.pumpAndSettle();

      expect(find.text('settings body'), findsOneWidget);
      expect(find.byType(AppDrawer), findsNothing);
    });
  });

  group('tablet (800dp)', () {
    testWidgets('icon rail, round compose button and the avatar chip', (
      tester,
    ) async {
      await pump(tester, width: 800);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(find.byType(AppBottomBar), findsNothing);
      expect(find.byTooltip('New post'), findsOneWidget);
      expect(find.byType(AppAccountChip), findsOneWidget);
      // The collapsed chip is the avatar alone.
      expect(find.text('@alice'), findsNothing);
      // No avatar button / drawer on wide layouts.
      expect(find.bySemanticsLabel('Open account menu'), findsNothing);
    });

    testWidgets('the compose control is on every page, Home included', (
      tester,
    ) async {
      await pump(tester, width: 800, location: '/home');
      expect(find.byTooltip('New post'), findsOneWidget);
      await pump(tester, width: 800, location: '/settings');
      expect(find.byTooltip('New post'), findsNothing);
    });
  });

  group('desktop (1400dp)', () {
    // The side column repeats the viewer's name and a Settings link, so the
    // rail and its chip menu are looked up on their own.
    Finder inRail(Finder f) =>
        find.descendant(of: find.byType(NavigationRail), matching: f);
    Finder menuItem(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is PopupMenuItem),
      matching: find.text(label),
    );

    testWidgets('labelled rail, Post pill, account chip with name', (
      tester,
    ) async {
      await pump(tester, width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(find.text('Home'), findsOneWidget);
      expect(find.widgetWithText(AppPillButton, 'Post'), findsOneWidget);
      expect(inRail(find.text('Alice A')), findsOneWidget);
      expect(inRail(find.text('@alice')), findsOneWidget);
    });

    testWidgets('the chip menu offers Profile, Settings and Sign out', (
      tester,
    ) async {
      await pump(tester, width: 1400);

      await tester.tap(find.byType(AppAccountChip));
      await tester.pumpAndSettle();
      expect(menuItem('Profile'), findsOneWidget);
      expect(menuItem('Settings'), findsOneWidget);
      expect(menuItem('Sign out'), findsOneWidget);

      await tester.tap(menuItem('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Select a setting'), findsOneWidget);
    });

    testWidgets('Sign out in the chip menu dispatches the sign-out event', (
      tester,
    ) async {
      await pump(tester, width: 1400);

      await tester.tap(find.byType(AppAccountChip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      verify(() => auth.add(const AuthSignOutRequested())).called(1);
    });

    testWidgets('the chip menu opens the profile', (tester) async {
      await pump(tester, width: 1400);

      await tester.tap(find.byType(AppAccountChip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile').last);
      await tester.pumpAndSettle();

      expect(find.text('profile body'), findsOneWidget);
    });

    testWidgets('no account chip without a profile', (tester) async {
      await pump(tester, width: 1400, profile: false);

      expect(find.byType(AppAccountChip), findsOneWidget);
      expect(find.text('Alice A'), findsNothing);
    });
  });

  group('side column (desktop)', () {
    testWidgets('absent below 1200dp', (tester) async {
      await pump(tester, width: 1199);
      expect(find.byType(AppSideColumn), findsNothing);
      expect(find.text('@alice'), findsNothing);
    });

    for (final width in [1200.0, 1280.0, 1440.0]) {
      testWidgets('present at ${width.toInt()}dp with the profile card and '
          'real links only', (tester) async {
        await pump(tester, width: width);
        expect(find.byType(AppSideColumn), findsOneWidget);
        expect(find.text('Alice A'), findsWidgets);
        expect(find.text('@alice'), findsWidgets);
        expect(
          find.descendant(
            of: find.byType(AppSideColumn),
            matching: find.text('Privacy Policy'),
          ),
          findsOneWidget,
        );
        // No placeholder for a feature that has no route.
        for (final text in ['Trends', 'Who to follow', 'Premium', 'Terms']) {
          expect(find.textContaining(text), findsNothing, reason: text);
        }
      });
    }

    testWidgets('the profile card opens the own profile', (tester) async {
      await pump(tester, width: 1280);
      await tester.tap(
        find.descendant(
          of: find.byType(AppSideColumn),
          matching: find.text('@alice'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('profile body'), findsOneWidget);
    });

    testWidgets('no loaded profile: no card, nothing fetched', (tester) async {
      await pump(tester, width: 1280, profile: false);
      expect(find.byType(AppSideColumn), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppSideColumn),
          matching: find.textContaining('@'),
        ),
        findsNothing,
      );
      verifyNever(() => onboarding.add(any()));
    });

    testWidgets('quick link Settings navigates to /settings', (tester) async {
      await pump(tester, width: 1280);
      await tester.tap(
        find.descendant(
          of: find.byType(AppSideColumn),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Select a setting'), findsOneWidget);
    });
  });

  group('You might like (W3-19)', () {
    const flags = {'posts', 'graph', 'follow_suggestions'};
    late FakeSuggestionsRepository repo;
    late SuggestionsCubit cubit;

    setUp(() {
      repo = FakeSuggestionsRepository([
        for (var i = 1; i <= 5; i++) suggestedUser(i),
      ]);
      cubit = SuggestionsCubit(repository: repo);
    });

    tearDown(() => cubit.close());

    Finder inColumn(Finder finder) =>
        find.descendant(of: find.byType(AppSideColumn), matching: finder);

    testWidgets('1200dp, new shell, both flags: the card sits between the '
        'profile card and the quick links', (tester) async {
      await pump(tester, width: 1200, flags: flags, suggestions: cubit);

      expect(inColumn(find.text('You might like')), findsOneWidget);
      expect(inColumn(find.byType(UserListRow)), findsNWidgets(3));
      expect(find.text('Who to follow'), findsNothing);
      final profile = tester.getTopLeft(inColumn(find.text('@alice'))).dy;
      final card = tester.getTopLeft(inColumn(find.text('You might like'))).dy;
      final link = tester.getTopLeft(inColumn(find.text('Settings'))).dy;
      expect(profile, lessThan(card));
      expect(card, lessThan(link));
      expect(repo.calls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Show more opens all five inside the column', (tester) async {
      await pump(tester, width: 1280, flags: flags, suggestions: cubit);

      await tester.tap(inColumn(find.text('Show more')));
      await tester.pumpAndSettle();

      expect(inColumn(find.byType(UserListRow)), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('without ui_shell the column shows no card and asks '
        'nothing', (tester) async {
      await pump(
        tester,
        width: 1280,
        flags: flags,
        newShell: false,
        suggestions: cubit,
      );

      expect(find.byType(AppSideColumn), findsOneWidget);
      expect(find.text('You might like'), findsNothing);
      expect(repo.calls, 0);
    });

    for (final missing in ['graph', 'follow_suggestions']) {
      testWidgets('without $missing the column shows no card and asks '
          'nothing', (tester) async {
        await pump(
          tester,
          width: 1280,
          flags: {...flags}..remove(missing),
          suggestions: cubit,
        );

        expect(find.text('You might like'), findsNothing);
        expect(repo.calls, 0);
      });
    }

    testWidgets('below 1200dp there is no column and nothing is asked', (
      tester,
    ) async {
      await pump(tester, width: 1199, flags: flags, suggestions: cubit);

      expect(find.byType(AppSideColumn), findsNothing);
      expect(find.text('You might like'), findsNothing);
      expect(repo.calls, 0);
    });

    testWidgets('no suggestions: the column is unchanged, no gap', (
      tester,
    ) async {
      repo.rows = const [];
      await pump(tester, width: 1280, flags: flags, suggestions: cubit);

      expect(find.text('You might like'), findsNothing);
      expect(inColumn(find.byType(WhoToFollowCard)), findsOneWidget);
      expect(tester.getSize(inColumn(find.byType(WhoToFollowCard))).height, 0);
    });

    testWidgets('a dismissal in the column is gone from the Home card too: '
        'one shared list', (tester) async {
      await pump(
        tester,
        width: 1280,
        flags: flags,
        suggestions: cubit,
        body: const SingleChildScrollView(child: WhoToFollowCard()),
      );
      expect(find.text('User 2'), findsNWidgets(2));

      await tester.tap(inColumn(find.byTooltip('Dismiss @user2')));
      await tester.pumpAndSettle();

      expect(find.text('User 2'), findsNothing);
      expect(find.text('Who to follow'), findsOneWidget);
      expect(find.text('You might like'), findsOneWidget);
    });

    // The card in the real right column at every cell of the matrix
    // (the column exists from 1200dp; below it nothing is drawn or asked).
    forEachThemeAndWidth(
      '1200dp: the card fits the column and its targets '
      'are 48dp',
      (tester, env) async {
        await pump(
          tester,
          width: env.size.width,
          flags: flags,
          suggestions: cubit,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        final column = tester.getRect(find.byType(AppSideColumn));
        final card = tester.getRect(inColumn(find.byType(WhoToFollowCard)));
        expect(card.left, greaterThanOrEqualTo(column.left));
        expect(card.right, lessThanOrEqualTo(column.right + 0.5));
        expect(inColumn(find.byType(UserListRow)), findsNWidgets(3));
        for (var i = 1; i <= 3; i++) {
          expectMinTarget(
            tester,
            inColumn(find.byTooltip('Dismiss @user$i')),
            reason: 'Dismiss @user$i',
          );
        }
        expectMinTarget(
          tester,
          inColumn(find.widgetWithText(TextButton, 'Show more')),
          reason: 'Show more',
        );
        await tester.tap(inColumn(find.text('Show more')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(inColumn(find.byType(UserListRow)), findsNWidgets(5));
      },
      widths: const [1200],
      textScales: kMatrixTextScalesLarge,
    );

    forEachThemeAndWidth(
      '360 and 600dp: no column, nothing asked, no '
      'overflow',
      (tester, env) async {
        await pump(
          tester,
          width: env.size.width,
          flags: flags,
          suggestions: cubit,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(AppSideColumn), findsNothing);
        expect(find.text('You might like'), findsNothing);
        expect(repo.calls, 0);
      },
      widths: const [360, 600],
      textScales: kMatrixTextScalesLarge,
    );
  });

  group('Settings master-detail (W1-7)', () {
    testWidgets('>= 1200dp: the list beside an empty detail pane', (
      tester,
    ) async {
      await pump(tester, width: 1400, location: '/settings');

      expect(find.text('Select a setting'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      final list = tester.getRect(find.text('Appearance'));
      final detail = tester.getRect(find.text('Select a setting'));
      expect(list.right, lessThan(detail.left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row opens its page in the detail pane, the list stays, '
        'its row is selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        width: 1400,
        location: '/settings',
        flags: {'posts', 'graph'},
      );

      await tester.tap(find.text('Blocked accounts'));
      await tester.pumpAndSettle();

      expect(find.text('blocked body'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Select a setting'), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Blocked accounts')),
        isSemantics(isButton: true, isSelected: true),
      );
      handle.dispose();
    });

    testWidgets('a deep link opens the page with the list beside it', (
      tester,
    ) async {
      await pump(
        tester,
        width: 1400,
        location: '/settings/blocked',
        flags: {'posts', 'graph'},
      );

      expect(find.text('blocked body'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('< 1200dp: no master pane, the page is the page', (
      tester,
    ) async {
      await pump(tester, width: 1100, location: '/settings');

      expect(find.text('settings body'), findsOneWidget);
      expect(find.text('Select a setting'), findsNothing);
    });

    testWidgets('flag off: the page, never a master pane', (tester) async {
      await pump(tester, width: 1400, location: '/settings', newShell: false);

      expect(find.text('settings body'), findsOneWidget);
    });
  });

  group('Lists entry (W5-11)', () {
    for (final width in [600.0, 1300.0]) {
      testWidgets('${width.toInt()}dp: a rail destination that opens /lists', (
        tester,
      ) async {
        await pump(tester, width: width, flags: const {'lists'});

        final rail = find.byType(NavigationRail);
        final labels = tester
            .widget<NavigationRail>(rail)
            .destinations
            .map(
              (d) =>
                  ((d.label is Semantics
                              ? (d.label as Semantics).child
                              : d.label)
                          as Text)
                      .data,
            )
            .toList();
        expect(labels, ['Home', 'Lists', 'Profile']);

        await tester.tap(find.byIcon(Icons.list_alt_outlined));
        await tester.pumpAndSettle();
        expect(find.text('lists body'), findsOneWidget);
        expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
      });
    }

    testWidgets('absent with lists off or ui_shell off; never in the phone '
        'bottom bar', (tester) async {
      for (final width in [360.0, 600.0, 1300.0]) {
        await pump(tester, width: width, flags: const {'posts'});
        expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
        await pump(
          tester,
          width: width,
          flags: const {'lists'},
          newShell: false,
        );
        expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
      }
      await pump(tester, flags: const {'lists'});
      expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
    });
  });

  group('Communities entry (W5-31)', () {
    for (final width in [600.0, 1300.0]) {
      testWidgets('${width.toInt()}dp: a rail destination that opens '
          '/communities', (tester) async {
        await pump(tester, width: width, flags: const {'communities'});

        final rail = find.byType(NavigationRail);
        final labels = tester
            .widget<NavigationRail>(rail)
            .destinations
            .map(
              (d) =>
                  ((d.label is Semantics
                              ? (d.label as Semantics).child
                              : d.label)
                          as Text)
                      .data,
            )
            .toList();
        expect(labels, ['Home', 'Communities', 'Profile']);

        await tester.tap(find.byIcon(Icons.groups_outlined));
        await tester.pumpAndSettle();
        expect(find.text('communities body'), findsOneWidget);
        expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
      });
    }

    testWidgets('absent with communities off or ui_shell off; never in the '
        'phone bottom bar', (tester) async {
      for (final width in [360.0, 600.0, 1300.0]) {
        await pump(tester, width: width, flags: const {'posts'});
        expect(find.byIcon(Icons.groups_outlined), findsNothing);
        await pump(
          tester,
          width: width,
          flags: const {'communities'},
          newShell: false,
        );
        expect(find.byIcon(Icons.groups_outlined), findsNothing);
      }
      await pump(tester, flags: const {'communities'});
      expect(find.byIcon(Icons.groups_outlined), findsNothing);
    });
  });

  group('Plans entry (beacons PR 6)', () {
    for (final width in [600.0, 1300.0]) {
      testWidgets('${width.toInt()}dp: a rail destination after Communities '
          'that opens /plans', (tester) async {
        await pump(
          tester,
          width: width,
          flags: const {'communities', 'beacons'},
        );

        final rail = find.byType(NavigationRail);
        final labels = tester
            .widget<NavigationRail>(rail)
            .destinations
            .map(
              (d) =>
                  ((d.label is Semantics
                              ? (d.label as Semantics).child
                              : d.label)
                          as Text)
                      .data,
            )
            .toList();
        expect(labels, ['Home', 'Plans', 'Communities', 'Profile']);

        await tester.tap(find.byIcon(Icons.event_outlined));
        await tester.pumpAndSettle();
        expect(find.text('plans body'), findsOneWidget);
        // The Plans page selects the Plans tab (its filled icon shows).
        expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
        expect(find.byIcon(Icons.event), findsOneWidget);
      });
    }

    testWidgets('absent with beacons off or ui_shell off; a bar cell on '
        'phones (ADR-0034)', (tester) async {
      for (final width in [360.0, 600.0, 1300.0]) {
        await pump(tester, width: width, flags: const {'posts'});
        expect(find.byIcon(Icons.event_outlined), findsNothing);
        await pump(
          tester,
          width: width,
          flags: const {'beacons'},
          newShell: false,
        );
        expect(find.byIcon(Icons.event_outlined), findsNothing);
      }
      await pump(tester, flags: const {'beacons'});
      expect(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.byIcon(Icons.event_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  group('Bookmarks entry (W2-7)', () {
    const on = {'posts', 'bookmarks'};

    for (final width in [600.0, 1300.0]) {
      testWidgets('${width.toInt()}dp: a rail destination between Home and '
          'Profile that opens /bookmarks', (tester) async {
        await pump(tester, width: width, flags: on);

        final rail = find.byType(NavigationRail);
        expect(
          find.descendant(
            of: rail,
            matching: find.byIcon(Icons.bookmark_border),
          ),
          findsOneWidget,
        );
        final labels = tester
            .widget<NavigationRail>(rail)
            .destinations
            .map(
              (d) =>
                  ((d.label is Semantics
                              ? (d.label as Semantics).child
                              : d.label)
                          as Text)
                      .data,
            )
            .toList();
        expect(labels, ['Home', 'History', 'Profile', 'More']);

        await tester.tap(find.byIcon(Icons.bookmark_border));
        await tester.pumpAndSettle();
        expect(find.text('bookmarks body'), findsOneWidget);
        // And it is the selected one there.
        expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
        expect(find.byIcon(Icons.bookmark), findsOneWidget);
      });
    }

    testWidgets('phone: not in the bottom bar, no cell selected on the page', (
      tester,
    ) async {
      await pump(tester, flags: on, location: '/bookmarks');

      expect(find.text('bookmarks body'), findsOneWidget);
      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border), findsNothing);
      expect(find.byIcon(Icons.bookmark), findsNothing);
      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byIcon(Icons.person), findsNothing);
      // Home and Profile still lead where they did.
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.text('home body'), findsOneWidget);
    });

    testWidgets('phone: no compose button on the page', (tester) async {
      await pump(tester, flags: on, location: '/bookmarks');

      expect(find.byTooltip('New post'), findsNothing);
    });

    testWidgets('absent with bookmarks off, with posts off and with ui_shell '
        'off, at every width', (tester) async {
      for (final width in [360.0, 600.0, 1300.0]) {
        for (final (flags, newShell) in [
          (const {'posts'}, true),
          (const {'bookmarks'}, true),
          (on, false),
        ]) {
          await pump(tester, width: width, flags: flags, newShell: newShell);
          expect(
            find.byIcon(Icons.bookmark_border),
            findsNothing,
            reason: '$flags shell=$newShell ${width}dp',
          );
        }
      }
    });
  });

  group('destination model (ADR-0034)', () {
    // The destinations behind flags, in the order the bar and rail show them.
    const gated = [
      ('search', Icons.search, 'Explore'),
      ('beacons', Icons.event_outlined, 'Plans'),
      ('notifications', Icons.notifications_none, 'Notifications'),
      ('messaging', Icons.mail_outline, 'Messages'),
    ];

    List<IconData> barIcons(WidgetTester tester) => [
      for (final icon in tester.widgetList<Icon>(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.byType(Icon),
        ),
      ))
        icon.icon!,
    ];

    NavigationRail rail(WidgetTester tester) =>
        tester.widget<NavigationRail>(find.byType(NavigationRail));

    List<String> railLabels(WidgetTester tester) => rail(tester).destinations
        .map(
          (d) =>
              ((d.label is Semantics ? (d.label as Semantics).child : d.label)
                      as Text)
                  .data!,
        )
        .toList();

    testWidgets('phone: the bar shows the remaining primaries for every '
        'flag set, in order, never Profile', (tester) async {
      for (var mask = 0; mask < 1 << gated.length; mask++) {
        final on = [
          for (var i = 0; i < gated.length; i++)
            if (mask & (1 << i) != 0) gated[i],
        ];
        // Off any tab, so every cell is outlined.
        await pump(
          tester,
          location: '/profile/alice',
          flags: {for (final g in on) g.$1},
        );
        expect(
          barIcons(tester),
          [Icons.home_outlined, for (final g in on) g.$2],
          reason: 'flags ${on.map((g) => g.$1)}',
        );
      }
    });

    for (final width in [834.0, 1440.0]) {
      testWidgets('${width.toInt()}dp: the rail lists the primaries, then '
          'Lists, Communities, History, Profile, More', (tester) async {
        await pump(
          tester,
          width: width,
          flags: const {
            'posts',
            'search',
            'beacons',
            'notifications',
            'messaging',
            'lists',
            'communities',
            'bookmarks',
          },
        );

        expect(railLabels(tester), [
          'Home',
          'Explore',
          'Plans',
          'Notifications',
          'Messages',
          'Lists',
          'Communities',
          'History',
          'Profile',
          'More',
        ]);
        expect(find.byType(AppBottomBar), findsNothing);
      });

      testWidgets('${width.toInt()}dp: with the optional primaries off the '
          'rail keeps Home and Profile', (tester) async {
        await pump(tester, width: width, flags: const {});

        expect(railLabels(tester), ['Home', 'Profile']);
      });
    }

    testWidgets('selection: Profile and /u/ select the Profile rail item; '
        'no phone bar cell is selected', (tester) async {
      const flags = {'search', 'notifications'};
      for (final path in ['/profile/alice', '/u/bob']) {
        await pump(tester, width: 834, location: path, flags: flags);
        expect(
          rail(tester).selectedIndex,
          railLabels(tester).indexOf('Profile'),
          reason: path,
        );

        await pump(tester, location: path, flags: flags);
        expect(barIcons(tester), [
          Icons.home_outlined,
          Icons.search,
          Icons.notifications_none,
        ], reason: path);
      }
    });

    testWidgets('selection: a primary tab is filled on the bar and indexed '
        'on the rail', (tester) async {
      const flags = {'search', 'beacons', 'notifications'};
      await pump(tester, location: '/plans', flags: flags);
      expect(barIcons(tester), [
        Icons.home_outlined,
        Icons.search,
        Icons.event,
        Icons.notifications_none,
      ]);

      await pump(tester, width: 834, location: '/notifications', flags: flags);
      expect(rail(tester).selectedIndex, 3);
    });

    testWidgets('legacy chrome (ui_shell off) keeps its destinations and '
        'order, Profile included', (tester) async {
      const flags = {
        'posts',
        'search',
        'beacons',
        'notifications',
        'messaging',
        'lists',
        'communities',
        'bookmarks',
      };
      await pump(tester, newShell: false, flags: flags);
      expect(barIcons(tester), [
        Icons.home,
        Icons.notifications_none,
        Icons.person_outline,
        Icons.settings_outlined,
      ]);

      await pump(tester, width: 1300, newShell: false, flags: flags);
      // (More is the shell-entries menu; unchanged by the new destination
      // model.)
      expect(railLabels(tester), [
        'Home',
        'Notifications',
        'Profile',
        'Settings',
        'More',
      ]);
    });
  });

  testWidgets('showComposeFabAt hides only where the FAB conflicts', (
    tester,
  ) async {
    final results = <String, bool>{};
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(enabledFeatures: {'posts'}),
    );
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: Builder(
          builder: (context) {
            for (final path in [
              '/home',
              '/notifications',
              '/bookmarks',
              '/settings/blocked',
              '/profile/ada',
              '/post/1',
            ]) {
              results[path] = showComposeFabAt(context, path);
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(results, {
      '/home': true,
      '/notifications': false,
      '/bookmarks': false,
      '/settings/blocked': false,
      '/profile/ada': true,
      '/post/1': true,
    });
  });

  group('rail, compose and account chip style (PR 3.5)', () {
    const allFlags = {
      'posts',
      'search',
      'beacons',
      'notifications',
      'messaging',
      'lists',
      'communities',
      'bookmarks',
    };
    const primaries = ['Home', 'Explore', 'Plans', 'Notifications', 'Messages'];
    Finder inRail(Finder f) =>
        find.descendant(of: find.byType(NavigationRail), matching: f);
    NavigationRail rail(WidgetTester tester) =>
        tester.widget<NavigationRail>(find.byType(NavigationRail));
    List<String> railLabels(WidgetTester tester) => [
      for (final d in rail(tester).destinations)
        ((d.label is Semantics ? (d.label as Semantics).child : d.label)
                as Text)
            .data!,
    ];
    Color painted(WidgetTester tester, Finder f) => tester
        .widget<RichText>(
          find.descendant(of: f, matching: find.byType(RichText)).first,
        )
        .text
        .style!
        .color!;

    for (final width in [834.0, 1440.0]) {
      final w = '${width.toInt()}dp';
      final desktop = width >= AppBreakpoints.tablet;

      testWidgets('$w: the primary five, then the secondaries; no group '
          'divider until T1; the rail is styled', (tester) async {
        await pump(tester, width: width, flags: allFlags);

        final labels = railLabels(tester);
        expect(labels.take(5), primaries);
        expect(labels.skip(5), [
          'Lists',
          'Communities',
          'History',
          'Profile',
          'More',
        ]);
        expect(inRail(find.byType(Divider)), findsNothing);
        final r = rail(tester);
        expect(r.indicatorShape, const StadiumBorder());
        expect(r.indicatorColor, AppColors.light.selectedIndicator);
      });

      testWidgets('$w: the selected destination is announced as selected', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          width: width,
          location: '/notifications',
          flags: allFlags,
        );

        expect(rail(tester).selectedIndex, primaries.indexOf('Notifications'));
        expect(
          tester.getSemantics(inRail(find.byIcon(Icons.notifications))),
          isSemantics(isSelected: true, hasSelectedState: true),
        );
        expect(
          tester.getSemantics(inRail(find.byIcon(Icons.home_outlined))),
          isSemantics(isSelected: false, hasSelectedState: true),
        );
        handle.dispose();
      });

      for (final brightness in Brightness.values) {
        testWidgets('$w ${brightness.name}: the compose label reads on both '
            'gradient stops', (tester) async {
          await pump(tester, width: width, brightness: brightness);
          final colors = brightness == Brightness.dark
              ? AppColors.dark
              : AppColors.light;

          final label = desktop
              ? painted(tester, find.widgetWithText(AppPillButton, 'Post'))
              : painted(tester, inRail(find.byIcon(Icons.edit_outlined)));
          expect(label, colors.primaryFillLabel);
          for (final stop in colors.primaryFillGradient.colors) {
            expect(contrast(label, stop), greaterThanOrEqualTo(4.5));
          }
          expectMinTarget(tester, inRail(find.byTooltip('New post')));

          await tester.tap(find.byTooltip('New post'));
          await tester.pumpAndSettle();
          expect(find.text('compose page'), findsOneWidget);
        });
      }

      for (final newShell in [true, false]) {
        final mode = newShell ? 'ui_shell on' : 'ui_shell off';
        testWidgets('$w $mode: More opens its menu at the item; Escape '
            'closes it and gives the focus back', (tester) async {
          await pump(
            tester,
            width: width,
            flags: const {'posts'},
            newShell: newShell,
          );
          // The item's glyph (the chip's "more" glyph comes after it).
          final more = inRail(find.byIcon(Icons.more_horiz)).first;
          // The keyboard path: focus the item, activate it with Enter.
          final node = Focus.of(tester.element(more));
          node.requestFocus();
          await tester.pump();
          expect(node.hasPrimaryFocus, isTrue);

          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('Articles'), findsOneWidget);
          // The open menu holds the focus.
          expect(node.hasPrimaryFocus, isFalse);
          // Level with the item, to the right of its icon.
          final anchor = tester.getRect(more);
          final menu = tester.getRect(
            find
                .ancestor(
                  of: find.text('Articles'),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(menu.top, closeTo(anchor.top, 1));
          expect(menu.left, closeTo(anchor.right, 1));

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Articles'), findsNothing);
          expect(node.hasPrimaryFocus, isTrue);
        });
      }

      testWidgets('$w: the account chip keeps its tooltip and menu: Profile, '
          'Follow requests (1000+), Settings, Sign out', (tester) async {
        final graph = _MockGraph();
        when(() => graph.followRequestsUnavailable).thenReturn(false);
        await pump(
          tester,
          width: width,
          flags: const {'posts', 'graph', 'private_accounts'},
          pendingFollowRequests: 1500,
          graph: graph,
        );

        final chip = find.byType(AppAccountChip);
        expect(find.byTooltip('Account menu'), findsOneWidget);
        expectMinTarget(tester, chip);
        if (desktop) {
          // As wide as the Post pill.
          expect(tester.getSize(chip).width, AppSize.railPostWidth);
        }
        final button = tester.widget<PopupMenuButton<Object?>>(
          find.descendant(
            of: chip,
            matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
          ),
        );
        expect(button.borderRadius, BorderRadius.circular(AppRadius.pill));

        await tester.tap(chip);
        await tester.pumpAndSettle();
        Finder item(String label) => find.descendant(
          of: find.byWidgetPredicate((w) => w is PopupMenuItem),
          matching: find.text(label),
        );
        const order = ['Profile', 'Follow requests', 'Settings', 'Sign out'];
        final ys = [
          for (final label in order) tester.getCenter(item(label)).dy,
        ];
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i], greaterThan(ys[i - 1]), reason: order[i]);
        }
        expect(find.text('1000+'), findsOneWidget);
      });

      testWidgets('$w ui_shell off: the legacy rail and strong pill, no '
          'chip', (tester) async {
        await pump(tester, width: width, newShell: false);

        final r = rail(tester);
        expect(r.indicatorShape, isNull);
        expect(r.indicatorColor, isNull);
        expect(r.selectedLabelTextStyle, isNull);
        expect(r.unselectedLabelTextStyle, isNull);
        expect(find.byType(AppPillButton), findsNothing);
        expect(inRail(find.byType(FilledButton)), findsOneWidget);
        expect(find.byType(AppAccountChip), findsNothing);
      });
    }

    for (final newShell in [true, false]) {
      final mode = newShell ? 'ui_shell on' : 'ui_shell off';
      void matrix(
        String set,
        List<double> widths, {
        Map<double, double>? heights,
      }) => forEachThemeAndWidth(
        '$mode ($set): the shell fits with 48dp rail targets',
        (tester, env) async {
          await pump(
            tester,
            width: env.size.width,
            height: env.size.height,
            flags: allFlags,
            newShell: newShell,
            brightness: env.brightness,
            textScale: env.textScale,
          );

          expectNoOverflow(tester);
          if (env.size.width >= AppBreakpoints.mobile) {
            expectMinTarget(tester, inRail(find.byTooltip('New post')));
            if (newShell) expectMinTarget(tester, find.byType(AppAccountChip));
          }
        },
        widths: widths,
        textScales: kRedesignTextScales,
        heights: heights,
      );

      matrix('redesign widths', kRedesignWidths, heights: kRedesignHeights);
      matrix('boundaries', kMatrixWidths);
    }
  });
}
