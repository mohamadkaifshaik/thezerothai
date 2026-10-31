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
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/geometry.dart';
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

/// The shell's layout rules (W0-6): which navigation, compose control and
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
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
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
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: effectiveBadge),
          if (suggestions != null)
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
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
  }

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
    testWidgets('bottom bar with Home, Notifications and Profile only: no '
        'Settings', (tester) async {
      await pump(tester);

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byIcon(Icons.home), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsWidgets);
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

      await pump(tester, location: '/profile/alice');
      expect(find.byIcon(Icons.person), findsOneWidget);
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

      await tester.tap(find.byIcon(Icons.person_outline).last);
      await tester.pumpAndSettle();
      expect(find.text('profile body'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.text('home body'), findsOneWidget);
    });

    testWidgets('Profile goes home when there is no profile yet', (
      tester,
    ) async {
      await pump(tester, profile: false);

      // (The avatar fallback in the top bar is also person_outline; the bar
      // cell is the last one.)
      await tester.tap(find.byIcon(Icons.person_outline).last);
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
      testWidgets('hidden on Home, where the inline composer is', (
        tester,
      ) async {
        await pump(tester, location: '/home');
        expect(find.byType(FloatingActionButton), findsNothing);
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

      await tester.tap(find.bySemanticsLabel('Account menu'));
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsOneWidget);
      expect(find.text('Alice A'), findsOneWidget);
    });

    testWidgets('Settings is reachable from the drawer', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Account menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings'));
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
      expect(find.bySemanticsLabel('Account menu'), findsNothing);
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
      expect(find.widgetWithText(FilledButton, 'Post'), findsOneWidget);
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

    // W3-21: the card in the real right column at every cell of the matrix
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
            .map((d) => (d.label as Text).data)
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
            .map((d) => (d.label as Text).data)
            .toList();
        expect(labels, ['Home', 'History', 'Profile']);

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

  testWidgets('showComposeFabAt follows the D2 table', (tester) async {
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
      '/home': false,
      '/notifications': false,
      '/bookmarks': false,
      '/settings/blocked': false,
      '/profile/ada': true,
      '/post/1': true,
    });
  });
}
