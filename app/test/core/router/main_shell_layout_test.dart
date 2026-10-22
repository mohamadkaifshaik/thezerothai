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
        body: Center(child: Text(text)),
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
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: MaterialApp.router(theme: appLightTheme, routerConfig: router),
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
      '/settings/blocked': false,
      '/profile/ada': true,
      '/post/1': true,
    });
  });
}
