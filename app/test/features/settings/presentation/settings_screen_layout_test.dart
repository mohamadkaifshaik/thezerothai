import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MemoryThemeStore implements ThemeModeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  String? lastUrl;
  int launchCount = 0;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    launchCount++;
    return true;
  }
}

/// The visible rows (title, and the email in parentheses) of every flag
/// combination, captured from origin/main before the restyle (the old
/// `ListTile` screen). The grouped screen must show exactly the same rows in
/// the same order.
const _beforeRows = <(Set<String>, bool, List<String>)>[
  (
    <String>{},
    true,
    ['Email (maya.lindqvist@example.com)', 'Privacy Policy', 'Sign out'],
  ),
  (<String>{}, false, ['Privacy Policy', 'Sign out']),
  (
    {'profile_snapshot'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Edit profile',
      'Change handle',
      'Privacy Policy',
      'Sign out',
    ],
  ),
  (
    {'profile_snapshot'},
    false,
    ['Edit profile', 'Change handle', 'Privacy Policy', 'Sign out'],
  ),
  (
    {'graph'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Blocked accounts',
      'Muted accounts',
      'Privacy Policy',
      'Sign out',
    ],
  ),
  (
    {'graph'},
    false,
    ['Blocked accounts', 'Muted accounts', 'Privacy Policy', 'Sign out'],
  ),
  (
    {'graph', 'profile_snapshot'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Edit profile',
      'Change handle',
      'Blocked accounts',
      'Muted accounts',
      'Privacy Policy',
      'Sign out',
    ],
  ),
  (
    {'graph', 'profile_snapshot'},
    false,
    [
      'Edit profile',
      'Change handle',
      'Blocked accounts',
      'Muted accounts',
      'Privacy Policy',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle'},
    false,
    ['Download my data', 'Privacy Policy', 'Delete account', 'Sign out'],
  ),
  (
    {'account_lifecycle', 'profile_snapshot'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Edit profile',
      'Change handle',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle', 'profile_snapshot'},
    false,
    [
      'Edit profile',
      'Change handle',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle', 'graph'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Blocked accounts',
      'Muted accounts',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle', 'graph'},
    false,
    [
      'Blocked accounts',
      'Muted accounts',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle', 'graph', 'profile_snapshot'},
    true,
    [
      'Email (maya.lindqvist@example.com)',
      'Edit profile',
      'Change handle',
      'Blocked accounts',
      'Muted accounts',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
  (
    {'account_lifecycle', 'graph', 'profile_snapshot'},
    false,
    [
      'Edit profile',
      'Change handle',
      'Blocked accounts',
      'Muted accounts',
      'Download my data',
      'Privacy Policy',
      'Delete account',
      'Sign out',
    ],
  ),
];

const _email = 'maya.lindqvist@example.com';

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;
  late _FakeUrlLauncherPlatform launcher;

  setUp(() {
    authBloc = MockAuthBloc();
    when(() => authBloc.add(any())).thenReturn(null);
    onboardingBloc = MockOnboardingBloc();
    launcher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = launcher;
  });

  Future<GoRouter> open(
    WidgetTester tester, {
    Set<String> flags = const {},
    String? email = _email,
    Brightness brightness = Brightness.dark,
    Size size = const Size(390, 1100),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: AuthState(
        status: AuthStatus.authenticated,
        user: email == null
            ? null
            : AppUser(
                uid: 'uid-1',
                email: email,
                emailVerified: true,
                isPasswordProvider: true,
              ),
      ),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: flags),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SettingsScreen()),
        for (final path in [
          AppRouter.editProfilePath,
          AppRouter.changeHandlePath,
          AppRouter.blockedAccountsPath,
          AppRouter.mutedAccountsPath,
          AppRouter.exportDataPath,
          AppRouter.deleteAccountPath,
        ])
          GoRoute(path: path, builder: (_, _) => Text('opened $path')),
      ],
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: authBloc),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
          BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// The rows, without the Appearance row of the Display group (W0-8): this
  /// parity table predates it and is about the account rows.
  List<String> rows(WidgetTester tester) => [
    for (final row in tester.widgetList<SettingsRow>(find.byType(SettingsRow)))
      if (row.title != 'Appearance')
        [row.title, if (row.subtitle != null) '(${row.subtitle})'].join(' '),
  ];

  const groupTitles = [
    'Account',
    'Display',
    'Privacy & safety',
    'Your data',
    'About',
    'Session',
  ];

  group('rows per flag combination (same as origin/main)', () {
    for (final (flags, withEmail, expected) in _beforeRows) {
      final name = '${flags.toList()..sort()} email=$withEmail';
      testWidgets(name, (tester) async {
        await open(tester, flags: flags, email: withEmail ? _email : null);

        expect(rows(tester), expected);
        // A group header shows only with at least one row in its card.
        final headers = [
          for (final t in groupTitles)
            if (find.text(t).evaluate().isNotEmpty) t,
        ];
        expect(
          headers.length,
          tester.widgetList(find.byType(SettingsGroup)).length,
        );
      });
    }
  });

  testWidgets('everything gated off: only Display, About and Session show', (
    tester,
  ) async {
    await open(tester, email: null);

    expect(find.text('Display'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    for (final hidden in ['Account', 'Privacy & safety', 'Your data']) {
      expect(find.text(hidden), findsNothing);
    }
    expect(find.byType(SettingsGroup), findsNWidgets(3));
  });

  testWidgets('everything on: the six groups, in order, with their rows', (
    tester,
  ) async {
    await open(
      tester,
      flags: {'profile_snapshot', 'graph', 'account_lifecycle'},
    );

    final tops = [
      for (final t in groupTitles) tester.getTopLeft(find.text(t)).dy,
    ];
    expect([...tops]..sort(), tops);
    expect(find.byType(SettingsGroup), findsNWidgets(6));
  });

  group('taps do what they did before', () {
    final navigation = {
      'Edit profile': AppRouter.editProfilePath,
      'Change handle': AppRouter.changeHandlePath,
      'Blocked accounts': AppRouter.blockedAccountsPath,
      'Muted accounts': AppRouter.mutedAccountsPath,
      'Download my data': AppRouter.exportDataPath,
      'Delete account': AppRouter.deleteAccountPath,
    };
    for (final entry in navigation.entries) {
      testWidgets('${entry.key} opens ${entry.value}', (tester) async {
        await open(
          tester,
          flags: {'profile_snapshot', 'graph', 'account_lifecycle'},
        );

        await tester.ensureVisible(find.text(entry.key));
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();

        expect(find.text('opened ${entry.value}'), findsOneWidget);
      });
    }

    testWidgets('Sign out dispatches AuthSignOutRequested', (tester) async {
      await open(tester);

      await tester.tap(find.text('Sign out'));
      await tester.pump();

      verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    });

    testWidgets('Privacy Policy still goes through the launcher', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Privacy Policy'));
      await tester.pump();

      expect(launcher.launchCount, 1);
      expect(launcher.lastUrl, contains('privacy'));
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    });

    testWidgets('the Email row is not tappable and not a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      expect(
        find.ancestor(of: find.text('Email'), matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        tester.getSemantics(find.text('Email')),
        matchesSemantics(label: 'Email\n$_email'),
      );
      handle.dispose();
    });
  });

  testWidgets('the destructive row uses the error color, others do not', (
    tester,
  ) async {
    await open(tester, flags: {'account_lifecycle'});

    final error = Theme.of(tester.element(find.text('Settings')))
        .colorScheme
        .error;
    Color? colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(colorOf('Delete account'), error);
    expect(colorOf('Sign out'), isNot(error));
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.widgetWithText(InkWell, 'Delete account'),
        matching: find.byIcon(Icons.delete_forever_outlined),
      ),
    );
    expect(icon.color, error);
  });

  group('semantics', () {
    testWidgets('group titles are headers; each row is one button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(
        tester,
        flags: {'profile_snapshot', 'graph', 'account_lifecycle'},
      );

      for (final title in groupTitles) {
        expect(
          tester.getSemantics(find.text(title)),
          matchesSemantics(label: title, isHeader: true),
        );
      }
      for (final label in [
        'Edit profile',
        'Change handle',
        'Blocked accounts',
        'Muted accounts',
        'Download my data',
        'Privacy Policy',
        'Delete account',
        'Sign out',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
        expect(
          tester.getSemantics(find.text(label)),
          matchesSemantics(
            label: label,
            isButton: true,
            hasEnabledState: false,
            hasTapAction: true,
          ),
          reason: label,
        );
      }
      handle.dispose();
    });
  });

  group('themes and widths', () {
    for (final brightness in Brightness.values) {
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        testWidgets(
          '${brightness.name} at ${size.width.toInt()}: renders, column '
          'capped on wide screens',
          (tester) async {
            await open(
              tester,
              flags: {'profile_snapshot', 'graph', 'account_lifecycle'},
              brightness: brightness,
              size: size,
            );

            expect(tester.takeException(), isNull);
            final width = tester.getSize(find.byType(ListView)).width;
            expect(
              width,
              size.width >= AppBreakpoints.mobile
                  ? AppBreakpoints.mobile
                  : size.width,
            );
            // Every row is at least the 48 dp target tall.
            for (final row in tester.widgetList(find.byType(SettingsRow))) {
              final height = tester.getSize(find.byWidget(row)).height;
              expect(height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
            }
          },
        );
      }
    }

    for (final brightness in Brightness.values) {
      testWidgets(
        '${brightness.name}: a long email at 2.0 text scale and 320 dp does '
        'not overflow',
        (tester) async {
          await open(
            tester,
            flags: {'profile_snapshot', 'graph', 'account_lifecycle'},
            email:
                'a.very.long.address.that.keeps.going.and.going.and.going@'
                'subdomain.example-company-name.example.com',
            brightness: brightness,
            size: const Size(320, 640),
            textScale: 2,
          );

          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
