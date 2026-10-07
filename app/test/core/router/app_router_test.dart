import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
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

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

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
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: authBloc),
          BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
        ],
        child: MaterialApp.router(routerConfig: appRouter.router),
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

  test('postPath builds the /post/:id deep link', () {
    expect(AppRouter.postPath('123'), '/post/123');
    expect(AppRouter.postPath('a/b'), '/post/a%2Fb');
  });

  testWidgets('/settings/export redirects to /settings when the flag is off', (
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
