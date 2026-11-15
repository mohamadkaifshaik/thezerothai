import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../features/account/presentation/account_deleted_screen.dart';
import '../../../features/account/presentation/delete_account_screen.dart';
import '../../../features/auth/presentation/sign_in_screen.dart';
import '../../../features/auth/presentation/sign_up_screen.dart';
import '../../../features/auth/presentation/welcome_screen.dart';
import '../../../features/auth/presentation/widgets/auth_gate.dart';
import '../../../features/onboarding/presentation/create_profile_screen.dart';
import '../../../features/onboarding/presentation/profile_photo_step_screen.dart';
import '../../../features/onboarding/presentation/session_error_screen.dart';
import '../../widgets/splash_screen.dart';
import '../app_router.dart';

/// Splash, welcome, sign-in, sign-up, onboarding, session-error and the
/// onboarding delete-account routes (all outside the shell).
List<RouteBase> authRoutes() => [
  GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
  GoRoute(
    path: AppRouter.welcomePath,
    builder: (context, state) => const WelcomeScreen(),
  ),
  GoRoute(
    path: AppRouter.signInPath,
    builder: (context, state) => const SignInScreen(),
  ),
  GoRoute(
    path: AppRouter.signUpPath,
    builder: (context, state) => const SignUpScreen(),
  ),
  GoRoute(
    path: AppRouter.onboardingPath,
    builder: (context, state) => const AuthGate(child: CreateProfileScreen()),
  ),
  GoRoute(
    path: AppRouter.onboardingPhotoPath,
    builder: (context, state) =>
        const AuthGate(child: ProfilePhotoStepScreen()),
  ),
  GoRoute(
    path: AppRouter.sessionErrorPath,
    builder: (context, state) => const AuthGate(child: SessionErrorScreen()),
  ),
  // No AuthGate: unverified callers must reach it too (the gate would
  // swap in the verification prompt).
  GoRoute(
    path: AppRouter.onboardingDeletePath,
    // The page adds the bottom inset of the shell's floating bar; out of
    // the shell there is no bar, so the inset (the home indicator) is
    // dropped and the page keeps its own padding.
    builder: (context, state) => MediaQuery.removePadding(
      context: context,
      removeBottom: true,
      child: const DeleteAccountScreen(),
    ),
  ),
];

/// Shown after an account was deleted.
GoRoute accountDeletedRoute() => GoRoute(
  path: AppRouter.accountDeletedPath,
  builder: (context, state) => const AccountDeletedScreen(),
);
