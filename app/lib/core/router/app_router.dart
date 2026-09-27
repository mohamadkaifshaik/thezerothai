import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_state.dart';
import '../../features/auth/presentation/sign_in_screen.dart';
import '../../features/auth/presentation/sign_up_screen.dart';
import '../../features/auth/presentation/widgets/auth_gate.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/onboarding/presentation/bloc/onboarding_state.dart';
import '../../features/onboarding/presentation/create_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../widgets/splash_screen.dart';
import 'go_router_refresh_stream.dart';
import 'main_shell.dart';

/// Builds the app's `go_router`. Redirects branch purely on cached
/// [AuthBloc]/[OnboardingBloc] state — never on a fresh network call — so
/// navigation is instant and never burns an extra `GetMe` (CLAUDE.md prime
/// directive: the client is our cheapest cache).
class AppRouter {
  AppRouter({required AuthBloc authBloc, required OnboardingBloc onboardingBloc})
    : _authBloc = authBloc,
      _onboardingBloc = onboardingBloc;

  final AuthBloc _authBloc;
  final OnboardingBloc _onboardingBloc;

  static const signInPath = '/sign-in';
  static const signUpPath = '/sign-up';
  static const onboardingPath = '/onboarding';
  static const homePath = '/home';
  static const settingsPath = '/settings';
  static String profilePath(String handle) => '/profile/$handle';

  late final GoRouter router = GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream([
      _authBloc.stream,
      _onboardingBloc.stream,
    ]),
    redirect: _redirect,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
      GoRoute(
        path: signInPath,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: signUpPath,
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: onboardingPath,
        builder: (context, state) =>
            const AuthGate(child: CreateProfileScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            MainShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: homePath,
            builder: (context, state) => const AuthGate(child: HomeScreen()),
          ),
          GoRoute(
            path: '/profile/:handle',
            builder: (context, state) => AuthGate(
              child: ProfileScreen(
                handle: state.pathParameters['handle']!,
              ),
            ),
          ),
          GoRoute(
            path: settingsPath,
            builder: (context, state) =>
                const AuthGate(child: SettingsScreen()),
          ),
        ],
      ),
    ],
  );

  String? _redirect(BuildContext context, GoRouterState state) {
    final authState = _authBloc.state;
    final loc = state.matchedLocation;
    final isAuthRoute = loc == signInPath || loc == signUpPath;

    if (authState.status == AuthStatus.unknown) {
      return loc == '/' ? null : '/';
    }
    if (authState.status == AuthStatus.unauthenticated) {
      return isAuthRoute ? null : signInPath;
    }

    // Signed in (authenticated or needsEmailVerification).
    if (isAuthRoute || loc == '/') {
      return homePath;
    }
    if (authState.status == AuthStatus.needsEmailVerification) {
      // AuthGate renders the verification prompt in place; no URL change.
      return null;
    }

    final onboardingStatus = _onboardingBloc.state.status;
    switch (onboardingStatus) {
      case OnboardingStatus.profileRequired:
        return loc == onboardingPath ? null : onboardingPath;
      case OnboardingStatus.ready:
        return loc == onboardingPath ? homePath : null;
      case OnboardingStatus.unknown:
      case OnboardingStatus.loading:
      case OnboardingStatus.error:
        return null;
    }
  }
}
