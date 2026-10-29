import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_destination.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
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

import '../../support/theme_harness.dart';

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

/// W7-19: the Messages destination of `MainShell` (F10): which flag
/// combinations show it, where it sits, which locations select it, its
/// badge, and the responsive matrix with the full text-scale axis.
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

  /// Pumps the shell around a fake page per route, the way `AppRouter`'s
  /// ShellRoute builds it. Returns the router for navigation assertions.
  Future<GoRouter> pump(
    WidgetTester tester, {
    String location = '/home',
    Size size = const Size(360, 900),
    Set<String> flags = const {'posts', 'notifications', 'messaging'},
    bool newShell = true,
    MessagesBadgeCubit? messagesBadge,
    UnreadBadgeCubit? unreadBadge,
    Brightness brightness = Brightness.light,
    double textScale = 1,
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
    Widget page(String path) => MainShell(
      location: path,
      child: Center(child: Text('page $path')),
    );
    GoRoute route(String path) => GoRoute(
      path: path,
      builder: (context, state) => page(state.matchedLocation),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        route('/home'),
        route('/notifications'),
        route('/messages'),
        route('/messages/requests'),
        route('/profile/alice'),
        route('/settings'),
      ],
    );
    addTearDown(router.dispose);
    final messages = messagesBadge ?? MessagesBadgeCubit();
    if (messagesBadge == null) addTearDown(messages.close);
    final unread = unreadBadge ?? UnreadBadgeCubit();
    if (unreadBadge == null) addTearDown(unread.close);
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
      (
        'messaging + ui_shell',
        {'posts', 'notifications', 'messaging'},
        true,
        true,
      ),
      (
        'messaging alone (legacy chrome)',
        {'posts', 'notifications', 'messaging'},
        false,
        false,
      ),
      ('ui_shell alone', {'posts', 'notifications'}, true, false),
      ('neither', {'posts', 'notifications'}, false, false),
      (
        'messaging + ui_shell, notifications off',
        {'posts', 'messaging'},
        true,
        true,
      ),
    ];
    for (final (name, flags, newShell, shown) in cases) {
      testWidgets('$name: ${shown ? 'shown' : 'hidden'}', (tester) async {
        await pump(tester, flags: flags, newShell: newShell);
        expect(
          find.byIcon(Icons.mail_outline),
          shown ? findsOneWidget : findsNothing,
        );
        expect(find.byIcon(Icons.mail), findsNothing);
      });
    }
  });

  testWidgets('sits after Notifications and before Profile in the bar', (
    tester,
  ) async {
    await pump(tester);

    final bar = find.byType(AppBottomBar);
    double x(IconData icon) => tester
        .getCenter(find.descendant(of: bar, matching: find.byIcon(icon)))
        .dx;
    expect(x(Icons.home), lessThan(x(Icons.notifications_none)));
    expect(x(Icons.notifications_none), lessThan(x(Icons.mail_outline)));
    expect(x(Icons.mail_outline), lessThan(x(Icons.person_outline)));
  });

  testWidgets('without notifications it follows Home', (tester) async {
    await pump(tester, flags: {'posts', 'messaging'});

    final bar = find.byType(AppBottomBar);
    double x(IconData icon) => tester
        .getCenter(find.descendant(of: bar, matching: find.byIcon(icon)))
        .dx;
    expect(x(Icons.home), lessThan(x(Icons.mail_outline)));
    expect(x(Icons.mail_outline), lessThan(x(Icons.person_outline)));
  });

  group('selection', () {
    for (final location in ['/messages', '/messages/requests']) {
      testWidgets('$location selects Messages with the filled glyph', (
        tester,
      ) async {
        await pump(tester, location: location);

        expect(find.byIcon(Icons.mail), findsOneWidget);
        expect(find.byIcon(Icons.mail_outline), findsNothing);
        expect(find.byIcon(Icons.home), findsNothing);
        final cell = find.ancestor(
          of: find.byIcon(Icons.mail),
          matching: find.bySemanticsLabel('Messages'),
        );
        expect(cell, findsWidgets);
      });
    }

    testWidgets('Home does not select Messages', (tester) async {
      await pump(tester);

      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
      expect(find.byIcon(Icons.home), findsOneWidget);
    });

    testWidgets('tapping it goes to /messages', (tester) async {
      final router = await pump(tester);

      await tester.tap(find.byIcon(Icons.mail_outline));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/messages');
      expect(find.byIcon(Icons.mail), findsOneWidget);
    });

    testWidgets('the rail item goes to /messages too', (tester) async {
      final router = await pump(tester, size: const Size(1200, 900));

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(Icons.mail_outline),
        ),
      );
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/messages');
    });

    testWidgets('with the legacy chrome no tab is selected on /messages', (
      tester,
    ) async {
      await pump(tester, location: '/messages', newShell: false);

      expect(find.byIcon(Icons.mail), findsNothing);
      expect(find.byIcon(Icons.mail_outline), findsNothing);
      expect(find.byIcon(Icons.home), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('badge', () {
    /// What the bar cell for Messages says aloud.
    String spoken(WidgetTester tester) => tester
        .getSemantics(
          find.descendant(
            of: find.byType(AppBottomBar),
            matching: find.bySemanticsLabel(RegExp(r'^Messages')),
          ),
        )
        .label;

    testWidgets('shows the count and speaks it', (tester) async {
      final handle = tester.ensureSemantics();
      final badge = MessagesBadgeCubit(3);
      addTearDown(badge.close);
      await pump(tester, messagesBadge: badge);

      expect(
        find.descendant(of: find.byType(Badge), matching: find.text('3')),
        findsOneWidget,
      );
      expect(spoken(tester), 'Messages, 3 unread conversations');
      handle.dispose();
    });

    testWidgets('one conversation is singular', (tester) async {
      final handle = tester.ensureSemantics();
      final badge = MessagesBadgeCubit(1);
      addTearDown(badge.close);
      await pump(tester, messagesBadge: badge);

      expect(spoken(tester), 'Messages, 1 unread conversation');
      handle.dispose();
    });

    testWidgets('caps at 99+', (tester) async {
      final handle = tester.ensureSemantics();
      final badge = MessagesBadgeCubit(100);
      addTearDown(badge.close);
      await pump(tester, messagesBadge: badge);

      expect(find.text('99+'), findsOneWidget);
      expect(spoken(tester), 'Messages, 99+ unread conversations');
      handle.dispose();
    });

    testWidgets('none: plain label, no badge, and it follows the cubit', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final badge = MessagesBadgeCubit();
      addTearDown(badge.close);
      await pump(tester, messagesBadge: badge);
      expect(find.byType(Badge), findsNothing);
      expect(spoken(tester), 'Messages');

      badge.seed(2);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);

      badge.seed(0);
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsNothing);
      handle.dispose();
    });

    testWidgets('is independent of the notifications badge', (tester) async {
      final messages = MessagesBadgeCubit(2);
      final unread = UnreadBadgeCubit(7);
      addTearDown(messages.close);
      addTearDown(unread.close);
      await pump(tester, messagesBadge: messages, unreadBadge: unread);

      expect(find.text('2'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);

      messages.seed(5);
      await tester.pumpAndSettle();
      expect(find.text('5'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(unread.state, 7);
    });

    testWidgets('a messaging-off caller shows no Messages badge', (
      tester,
    ) async {
      final badge = MessagesBadgeCubit(4);
      addTearDown(badge.close);
      await pump(
        tester,
        flags: {'posts', 'notifications'},
        messagesBadge: badge,
      );

      expect(find.byType(Badge), findsNothing);
    });
  });

  group('responsive matrix', () {
    forEachThemeAndWidth('Messages destination with a 99+ badge: no overflow', (
      tester,
      env,
    ) async {
      final badge = MessagesBadgeCubit(150);
      addTearDown(badge.close);
      final router = await pump(
        tester,
        size: Size(env.size.width, 900),
        brightness: env.brightness,
        textScale: env.textScale,
        messagesBadge: badge,
      );

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);

      // On the Messages page too (filled glyph).
      router.go('/messages');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.mail), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('bar capacity (F10: five items)', () {
    // Home, Explore (W4), Notifications, Messages, Profile is the cap of the
    // phone bar. Explore does not exist yet, so the fifth cell is a stand-in
    // destination; the bar must hold the five with the Messages cell badged
    // "99+", with 48dp targets and no overflow at 360dp and text scale 2.0.
    for (final scale in [1.0, 2.0]) {
      testWidgets('five cells at 360dp, text scale $scale', (tester) async {
        const stand = AppNavDestination(
          icon: Icons.search,
          selectedIcon: Icons.search,
          label: 'Explore',
        );
        final destinations = [
          const AppNavDestination(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            label: 'Home',
          ),
          stand,
          const AppNavDestination(
            icon: Icons.notifications_none,
            selectedIcon: Icons.notifications,
            label: 'Notifications',
            badgeLabel: '12',
            badgeSemanticLabel: '12 unread',
          ),
          const AppNavDestination(
            icon: Icons.mail_outline,
            selectedIcon: Icons.mail,
            label: 'Messages',
            badgeLabel: '99+',
            badgeSemanticLabel: '99+ unread conversations',
          ),
          const AppNavDestination(
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            label: 'Profile',
          ),
        ];
        await pumpThemed(
          tester,
          Align(
            alignment: Alignment.bottomCenter,
            child: AppBottomBar(
              destinations: destinations,
              selectedIndex: 3,
              onSelected: (_) {},
            ),
          ),
          size: const Size(360, 800),
          textScale: scale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(InkResponse), findsNWidgets(5));
        for (final cell in tester.widgetList(find.byType(InkResponse))) {
          final size = tester.getSize(find.byWidget(cell));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        expect(find.byIcon(Icons.mail), findsOneWidget);
        expect(find.text('99+'), findsOneWidget);
      });
    }
  });
}
