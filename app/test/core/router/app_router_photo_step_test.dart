import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockAccountRepository extends Mock implements AccountRepository {}

class MockAuthRepository extends Mock implements AuthRepository {}

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The optional profile photo step: the router holds a ready session on
/// `/onboarding/photo` only while `photoStepPending`, and never loops.
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
    List<RepositoryProvider<dynamic>>? repositories,
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
        providers: repositories ?? [RepositoryProvider<int>.value(value: 0)],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            // Settings (reached by some redirects) shows the Appearance row.
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
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

  const auth = AuthState(status: AuthStatus.authenticated, user: user);

  testWidgets('pending: /onboarding and any other page go to the photo step', (
    tester,
  ) async {
    for (final path in [
      AppRouter.onboardingPath,
      AppRouter.deleteAccountPath,
      AppRouter.onboardingPhotoPath,
    ]) {
      final result = await openUserRoute(
        tester,
        auth: auth,
        onboarding: const OnboardingState(
          status: OnboardingStatus.ready,
          photoStepPending: true,
        ),
        path: path,
      );
      expect(result, AppRouter.onboardingPhotoPath, reason: path);
    }
  });

  testWidgets('not pending: the photo path is never kept (no loop)', (
    tester,
  ) async {
    final result = await openUserRoute(
      tester,
      auth: auth,
      onboarding: const OnboardingState(status: OnboardingStatus.ready),
      path: AppRouter.onboardingPhotoPath,
    );
    expect(result, isNot(AppRouter.onboardingPhotoPath));
    expect(result, AppRouter.homePath);
  });

  testWidgets('a signed-out visitor never sees the photo step', (tester) async {
    final result = await openUserRoute(
      tester,
      auth: const AuthState(status: AuthStatus.unauthenticated),
      onboarding: const OnboardingState(photoStepPending: true),
      path: AppRouter.onboardingPhotoPath,
    );
    expect(result, AppRouter.welcomePath);
  });
}
