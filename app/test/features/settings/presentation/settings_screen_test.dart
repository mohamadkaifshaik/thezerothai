import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/features/account/domain/account_feature_flag.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _shellDestinations = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
];

/// [screen] inside the shell's phone chrome: the floating bar (`ui_shell` on)
/// or the docked legacy bar.
Widget _inShell(Widget screen, {required bool floating}) => ResponsiveScaffold(
  selectedIndex: null,
  onDestinationSelected: (_) {},
  destinations: _shellDestinations,
  floatingBar: floating,
  body: screen,
);

/// Jumps the page's list to its end: not a user scroll, so the floating bar
/// stays up.
Future<void> _jumpToEnd(WidgetTester tester, Finder inList) async {
  final position = tester
      .state<ScrollableState>(
        find.ancestor(of: inList, matching: find.byType(Scrollable)).first,
      )
      .position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Rect _pillRect(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(AppFloatingBottomBar),
    matching: find.byType(Material),
  ),
);

double _barOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(AppBottomBar),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void _setView(WidgetTester tester, double height) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(360, height);
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    authBloc = MockAuthBloc();
    when(() => authBloc.add(any())).thenReturn(null);
    onboardingBloc = MockOnboardingBloc();
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
  });

  Widget wrap({bool? floatingBar}) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<ThemeModeCubit>(
          create: (_) => ThemeModeCubit(_MemoryThemeStore()),
        ),
        BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
      ],
      child: MaterialApp(
        home: floatingBar == null
            ? const SettingsScreen()
            : _inShell(const SettingsScreen(), floating: floatingBar),
      ),
    );
  }

  testWidgets('shows the signed-in email', (tester) async {
    const user = AppUser(
      uid: 'uid-1',
      email: 'a@example.com',
      emailVerified: true,
      isPasswordProvider: true,
    );
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('a@example.com'), findsOneWidget);
  });

  testWidgets('tapping "Sign out" dispatches AuthSignOutRequested', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );

    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Sign out'));
    await tester.pump();

    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
  });

  testWidgets('shows a "Privacy Policy" list tile', (tester) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('hides "Blocked accounts"/"Muted accounts" when the graph flag '
      'is off, and never offers a private-account toggle', (tester) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('Blocked accounts'), findsNothing);
    expect(find.text('Muted accounts'), findsNothing);
    expect(find.textContaining('Private account'), findsNothing);
  });

  testWidgets(
    '"Edit profile"/"Change handle" follow the profile_snapshot flag',
    (tester) async {
      whenListen(
        authBloc,
        Stream<AuthState>.empty(),
        initialState: const AuthState(),
      );

      await tester.pumpWidget(wrap());
      expect(find.text('Edit profile'), findsNothing);
      expect(find.text('Change handle'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      whenListen(
        onboardingBloc,
        const Stream<OnboardingState>.empty(),
        initialState: const OnboardingState(
          enabledFeatures: {kFeatureProfileSnapshot},
        ),
      );
      await tester.pumpWidget(wrap());
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.text('Change handle'), findsOneWidget);
    },
  );

  testWidgets('"Download my data" follows the account_lifecycle flag', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );

    await tester.pumpWidget(wrap());
    expect(find.text('Download my data'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        enabledFeatures: {kFeatureAccountLifecycle},
      ),
    );
    await tester.pumpWidget(wrap());
    expect(find.text('Download my data'), findsOneWidget);
  });

  testWidgets('shows "Blocked accounts"/"Muted accounts" when the graph flag '
      'is on', (tester) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(enabledFeatures: {'graph'}),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('Blocked accounts'), findsOneWidget);
    expect(find.text('Muted accounts'), findsOneWidget);
  });

  testWidgets('hides "Delete account" when the account_lifecycle flag is off', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );

    await tester.pumpWidget(wrap());
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets('shows "Delete account" with the account_lifecycle flag', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        enabledFeatures: {'account_lifecycle'},
      ),
    );
    await tester.pumpWidget(wrap());
    expect(find.text('Delete account'), findsOneWidget);
  });

  group('under the shell bar (bottom inset)', () {
    Finder signOut() => find
        .ancestor(of: find.text('Sign out'), matching: find.byType(InkWell))
        .first;

    /// The height at which Sign out, the last row, ends 40 dp above the
    /// bottom edge: inside the 90 dp of the floating bar, on a list that
    /// fits the screen without the bar.
    Future<double> shortHeight(WidgetTester tester) async {
      _setView(tester, 2000);
      await tester.pumpWidget(wrap(floatingBar: false));
      await tester.pumpAndSettle();
      return (tester.getRect(signOut()).bottom + 40).roundToDouble();
    }

    setUp(() {
      whenListen(
        authBloc,
        Stream<AuthState>.empty(),
        initialState: const AuthState(),
      );
    });

    testWidgets('ui_shell on: Sign out ends above the pill and takes the '
        'tap', (tester) async {
      final height = await shortHeight(tester);
      _setView(tester, height);
      await tester.pumpWidget(wrap(floatingBar: true));
      await tester.pumpAndSettle();
      await _jumpToEnd(tester, find.text('Sign out'));

      expect(_barOpacity(tester), 1);
      final pill = _pillRect(tester);
      expect(pill.top, height - 90);
      expect(tester.getRect(signOut()).bottom, lessThanOrEqualTo(pill.top));
      await tester.tap(find.text('Sign out'));
      await tester.pump();
      verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    });

    testWidgets('ui_shell off: the docked bar; the list is unchanged', (
      tester,
    ) async {
      final height = await shortHeight(tester);
      _setView(tester, height);
      await tester.pumpWidget(wrap(floatingBar: false));
      await tester.pumpAndSettle();
      final before = tester.getRect(signOut());
      await _jumpToEnd(tester, find.text('Sign out'));

      expect(find.byType(AppFloatingBottomBar), findsNothing);
      final barTop = tester.getRect(find.byType(AppBottomBar)).top;
      expect(barTop, height - 56);
      // The list keeps its 24 dp bottom padding: the docked bar takes the
      // inset.
      final list = tester.widget<ListView>(
        find.ancestor(of: signOut(), matching: find.byType(ListView)),
      );
      expect(list.padding, const EdgeInsets.only(bottom: 24));
      final after = tester.getRect(signOut());
      expect(after.bottom, lessThanOrEqualTo(barTop));
      expect(after.bottom, lessThanOrEqualTo(before.bottom));
    });
  });
}
