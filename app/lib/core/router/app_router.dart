import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_state.dart';
import '../../features/auth/presentation/sign_in_screen.dart';
import '../../features/auth/presentation/sign_up_screen.dart';
import '../../features/auth/presentation/widgets/auth_gate.dart';
import '../../features/graph/domain/graph_feature_flag.dart';
import '../../features/graph/presentation/managed_accounts_screen.dart';
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
  AppRouter({
    required AuthBloc authBloc,
    required OnboardingBloc onboardingBloc,
  }) : _authBloc = authBloc,
       _onboardingBloc = onboardingBloc;

  final AuthBloc _authBloc;
  final OnboardingBloc _onboardingBloc;

  static const signInPath = '/sign-in';
  static const signUpPath = '/sign-up';
  static const onboardingPath = '/onboarding';
  static const homePath = '/home';
  static const settingsPath = '/settings';
  // The Settings routes land with T15; the constants live here so
  // ProfileHeader and SettingsScreen share one source of truth.
  static const blockedAccountsPath = '/settings/blocked';
  static const mutedAccountsPath = '/settings/muted';
  static String profilePath(String handle) => '/profile/$handle';
  static String followersPath(String handle) => '/profile/$handle/followers';
  static String followingPath(String handle) => '/profile/$handle/following';

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
              child: ProfileScreen(handle: state.pathParameters['handle']!),
            ),
          ),
          GoRoute(
            path: settingsPath,
            builder: (context, state) =>
                const AuthGate(child: SettingsScreen()),
          ),
          GoRoute(
            path: blockedAccountsPath,
            builder: (context, state) =>
                const AuthGate(child: BlockedAccountsScreen()),
          ),
          GoRoute(
            path: mutedAccountsPath,
            builder: (context, state) =>
                const AuthGate(child: MutedAccountsScreen()),
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
        if (loc == onboardingPath) return homePath;
        return _graphFlagRedirect(loc);
      case OnboardingStatus.unknown:
      case OnboardingStatus.loading:
      case OnboardingStatus.error:
      case OnboardingStatus.emailVerificationRequired:
        // CreateProfileScreen renders VerifyEmailView in place for this
        // status; no URL change (same pattern as needsEmailVerification
        // above).
        return null;
    }
  }

  static final _graphOnlyRoutes = RegExp(
    r'^/settings/(?:blocked|muted)$',
  );

  /// Graph-only routes redirect away when the graph feature flag is off for
  /// this caller (ADR-0008 D6) — belt-and-suspenders alongside hiding the
  /// UI entry points that link to them.
  String? _graphFlagRedirect(String loc) {
    if (_onboardingBloc.state.enabledFeatures.contains(kFeatureGraph)) {
      return null;
    }
    if (_graphOnlyRoutes.hasMatch(loc)) return settingsPath;
    return null;
  }
}
