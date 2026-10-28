import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/domain/shells_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

const kShellsUser = AppUser(
  uid: 'uid-1',
  email: 'a@example.com',
  emailVerified: true,
  isPasswordProvider: true,
);

/// Both flags the shell entries need.
const kShellFlags = {kFeatureShells, kFeatureUiShell};

/// Narrows the visible shells for one test and restores all four afterwards.
void useVisibleShells(Set<ShellKind> kinds) {
  final before = kVisibleShells;
  kVisibleShells = kinds;
  addTearDown(() => kVisibleShells = before);
}

/// The real [AppRouter] over mock blocs (the app's navigation and redirects,
/// none of its repositories: the shells take none).
class ShellsApp {
  ShellsApp._(this.router, this.auth, this.onboarding, this._authCtl);

  final AppRouter router;
  final AuthBloc auth;
  final OnboardingBloc onboarding;
  final StreamController<AuthState> _authCtl;

  String get path =>
      router.router.routerDelegate.currentConfiguration.last.matchedLocation;

  /// Signs in (the auth stream emits `authenticated`).
  void signIn() => _authCtl.add(
    const AuthState(status: AuthStatus.authenticated, user: kShellsUser),
  );
}

Future<ShellsApp> pumpShellsApp(
  WidgetTester tester, {
  Set<String> flags = kShellFlags,
  String location = '/home',
  Size size = const Size(360, 800),
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool signedIn = true,
}) async {
  final auth = _MockAuthBloc();
  final onboarding = _MockOnboardingBloc();
  final authCtl = StreamController<AuthState>.broadcast();
  addTearDown(authCtl.close);
  whenListen(
    auth,
    authCtl.stream,
    initialState: signedIn
        ? const AuthState(status: AuthStatus.authenticated, user: kShellsUser)
        : const AuthState(status: AuthStatus.unauthenticated),
  );
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(
        userId: 'uid-1',
        handle: 'alice',
        displayName: 'Alice A',
      ),
      enabledFeatures: flags,
    ),
  );
  final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
  appRouter.router.go(location);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: auth),
        BlocProvider<OnboardingBloc>.value(value: onboarding),
        BlocProvider<ThemeModeCubit>(
          create: (_) => ThemeModeCubit(_NoThemeStore()),
        ),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(brightness: brightness),
        routerConfig: appRouter.router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ShellsApp._(appRouter, auth, onboarding, authCtl);
}

/// Just the [AppDrawer] in a bare `Scaffold` (no Home, so flags such as
/// `posts` need no timeline providers). Returns the opener of the drawer.
Future<Future<void> Function()> pumpBareDrawer(
  WidgetTester tester, {
  required Set<String> flags,
  Size size = const Size(360, 2000),
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) async {
  final auth = _MockAuthBloc();
  final onboarding = _MockOnboardingBloc();
  whenListen(
    auth,
    const Stream<AuthState>.empty(),
    initialState: const AuthState(
      status: AuthStatus.authenticated,
      user: kShellsUser,
    ),
  );
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(
        userId: 'uid-1',
        handle: 'alice',
        displayName: 'Alice A',
      ),
      enabledFeatures: flags,
    ),
  );
  final scaffold = GlobalKey<ScaffoldState>();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          key: scaffold,
          drawer: const AppDrawer(),
          body: const SizedBox(),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: auth),
        BlocProvider<OnboardingBloc>.value(value: onboarding),
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
  );
  return () async {
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
  };
}

/// A `testWidgets` with the semantics tree on (needed by
/// `find.bySemanticsLabel` and `getSemantics`), disposed at the end.
void shellsTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}
