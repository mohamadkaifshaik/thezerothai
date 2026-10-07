import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUp(() {
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
  });

  Future<String> openUserRoute(
    WidgetTester tester, {
    required AuthState auth,
    required OnboardingState onboarding,
    String? path,
  }) async {
    whenListen(authBloc, const Stream<AuthState>.empty(), initialState: auth);
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: onboarding,
    );
    final appRouter = AppRouter(
      authBloc: authBloc,
      onboardingBloc: onboardingBloc,
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: _MockAccounts()),
          RepositoryProvider<AuthRepository>.value(value: _MockAuth()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (_, _) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    appRouter.router.go(path ?? AppRouter.profileByIdPath('someone'));
    await tester.pump();
    await tester.pump();
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  testWidgets('/u/:userId redirects a signed-out visitor to sign-in', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.unauthenticated),
      onboarding: const OnboardingState(),
    );

    expect(path, AppRouter.signInPath);
  });

  testWidgets('/u/:userId redirects a user without a profile to onboarding', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: const OnboardingState(
        status: OnboardingStatus.profileRequired,
      ),
    );

    expect(path, AppRouter.onboardingPath);
  });

  testWidgets('/settings/delete-account redirects to settings with the flag '
      'off', (tester) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: const OnboardingState(status: OnboardingStatus.ready),
      path: AppRouter.deleteAccountPath,
    );

    expect(path, AppRouter.settingsPath);
  });

  testWidgets('/settings/delete-account stays with the flag on', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'account_lifecycle'},
      ),
      path: AppRouter.deleteAccountPath,
    );

    expect(path, AppRouter.deleteAccountPath);
  });

  testWidgets('signed-out users go from /settings/delete-account and /home to '
      'sign-in', (tester) async {
    for (final target in const [AppRouter.deleteAccountPath, '/home']) {
      final path = await openUserRoute(
        tester,
        auth: const AuthState(status: AuthStatus.unauthenticated),
        onboarding: const OnboardingState(),
        path: target,
      );
      expect(path, AppRouter.signInPath, reason: target);
    }
  });

  testWidgets('the deleted page renders while auth is still unknown', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(),
      onboarding: const OnboardingState(),
      path: AppRouter.accountDeletedPath,
    );

    expect(path, AppRouter.accountDeletedPath);
    expect(find.text('Your account is being deleted'), findsOneWidget);
  });

  testWidgets('/settings/export also redirects with the flag off', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: const OnboardingState(status: OnboardingStatus.ready),
      path: AppRouter.exportDataPath,
    );

    expect(path, AppRouter.settingsPath);
  });

  testWidgets('the deleted page is reachable signed out', (tester) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.unauthenticated),
      onboarding: const OnboardingState(),
      path: AppRouter.accountDeletedPath,
    );

    expect(path, AppRouter.accountDeletedPath);
  });

  test('postPath builds the /post/:id deep link', () {
    expect(AppRouter.postPath('123'), '/post/123');
    expect(AppRouter.postPath('a/b'), '/post/a%2Fb');
  });

  testWidgets('/post/:id redirects a signed-out visitor to sign-in', (
    tester,
  ) async {
    final path = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.unauthenticated),
      onboarding: const OnboardingState(),
      path: AppRouter.postPath('123'),
    );

    expect(path, AppRouter.signInPath);
  });
}
