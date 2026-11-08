import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/session_error_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/posts_fixtures.dart';

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

/// A10: a session whose GetMe failed with nothing usable to show
/// (`OnboardingStatus.error`) lands on a full-screen Retry, never Home with
/// every flag off ("coming soon" everywhere).
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  const unknown = AuthState();
  const signedOut = AuthState(status: AuthStatus.unauthenticated);
  const signedIn = AuthState(status: AuthStatus.authenticated, user: user);
  const idle = OnboardingState();
  const failed = OnboardingState(
    status: OnboardingStatus.error,
    error: NetworkException('offline'),
  );
  const ready = OnboardingState(
    status: OnboardingStatus.ready,
    enabledFeatures: {'posts'},
  );

  late _MockAuthBloc auth;
  late _MockOnboardingBloc onboarding;
  late AppRouter appRouter;

  void setStates(AuthState a, OnboardingState o) {
    when(() => auth.state).thenReturn(a);
    when(() => onboarding.state).thenReturn(o);
  }

  setUpAll(() => registerFallbackValue(const OnboardingRefreshRequested()));

  setUp(() {
    auth = _MockAuthBloc();
    onboarding = _MockOnboardingBloc();
    whenListen(auth, const Stream<AuthState>.empty(), initialState: unknown);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: idle,
    );
    appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
  });

  Future<String> resolve(WidgetTester tester, String location) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final matches = await appRouter.router.routeInformationParser
        .parseRouteInformationWithDependencies(
          RouteInformation(uri: Uri.parse(location)),
          context,
        );
    return matches.uri.path;
  }

  group('redirects', () {
    testWidgets('an error never opens Home or any other page', (tester) async {
      setStates(signedIn, failed);
      for (final loc in [
        AppRouter.homePath,
        AppRouter.signInPath,
        AppRouter.onboardingPath,
        AppRouter.settingsPath,
        '/',
      ]) {
        expect(
          await resolve(tester, loc),
          AppRouter.sessionErrorPath,
          reason: loc,
        );
      }
      // The delete-account page stays reachable.
      expect(
        await resolve(tester, AppRouter.onboardingDeletePath),
        AppRouter.onboardingDeletePath,
      );
    });

    testWidgets('the error page holds while a retry loads, then lands Home', (
      tester,
    ) async {
      setStates(
        signedIn,
        const OnboardingState(status: OnboardingStatus.loading),
      );
      expect(
        await resolve(tester, AppRouter.sessionErrorPath),
        AppRouter.sessionErrorPath,
      );
      setStates(signedIn, ready);
      expect(
        await resolve(tester, AppRouter.sessionErrorPath),
        AppRouter.homePath,
      );
    });

    testWidgets('a retry that says profile required goes to onboarding', (
      tester,
    ) async {
      setStates(
        signedIn,
        const OnboardingState(status: OnboardingStatus.profileRequired),
      );
      expect(
        await resolve(tester, AppRouter.sessionErrorPath),
        AppRouter.onboardingPath,
      );
    });

    testWidgets('a deep link survives the error page', (tester) async {
      final target = '/post/${postId(7)}';
      setStates(signedOut, idle);
      expect(await resolve(tester, target), AppRouter.signInPath);

      setStates(signedIn, failed);
      expect(
        await resolve(tester, AppRouter.signInPath),
        AppRouter.sessionErrorPath,
      );

      setStates(signedIn, ready);
      expect(await resolve(tester, AppRouter.sessionErrorPath), target);
    });

    testWidgets('signed out on the error page goes to sign-in', (tester) async {
      setStates(signedOut, idle);
      expect(
        await resolve(tester, AppRouter.sessionErrorPath),
        AppRouter.signInPath,
      );
    });
  });

  group('through the real UI', () {
    late StreamController<AuthState> authEvents;
    late StreamController<OnboardingState> onboardingEvents;

    setUp(() {
      authEvents = StreamController<AuthState>.broadcast();
      onboardingEvents = StreamController<OnboardingState>.broadcast();
      addTearDown(authEvents.close);
      addTearDown(onboardingEvents.close);
    });

    void emit(AuthState a, OnboardingState o) {
      setStates(a, o);
      authEvents.add(a);
      onboardingEvents.add(o);
    }

    Future<String Function()> pumpApp(WidgetTester tester) async {
      whenListen(auth, authEvents.stream, initialState: unknown);
      whenListen(onboarding, onboardingEvents.stream, initialState: idle);
      appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      );
      await tester.pump();
      return () => appRouter.router.routeInformationProvider.value.uri.path;
    }

    testWidgets('shows the error with a Retry that refreshes GetMe', (
      tester,
    ) async {
      final path = await pumpApp(tester);

      emit(signedIn, failed);
      await tester.pump();
      await tester.pump();

      expect(path(), AppRouter.sessionErrorPath);
      expect(find.byType(SessionErrorScreen), findsOneWidget);
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      verify(() => onboarding.add(any(that: isA<OnboardingRefreshRequested>())))
          .called(1);
    });

    testWidgets('Retry shows even for an error type the shared view would '
        'not offer a retry for', (tester) async {
      await pumpApp(tester);

      emit(
        signedIn,
        const OnboardingState(
          status: OnboardingStatus.error,
          error: DegradedModeException('limited'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(SessionErrorScreen), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('a retry in flight shows a spinner, not the error', (
      tester,
    ) async {
      await pumpApp(tester);
      emit(signedIn, failed);
      await tester.pump();
      await tester.pump();

      emit(signedIn, const OnboardingState(status: OnboardingStatus.loading));
      await tester.pump();
      await tester.pump();

      expect(find.byType(SessionErrorScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });
}
