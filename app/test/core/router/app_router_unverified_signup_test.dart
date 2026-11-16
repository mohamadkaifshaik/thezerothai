import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/splash_screen.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/widgets/verify_email_view.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/create_profile_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

/// A new email/password account is `needsEmailVerification` and gets no GetMe
/// until it is verified (OnboardingBloc stays idle). The router sends it
/// Home, where the shell used to hold the splash for ever (flags pending)
/// instead of showing the verification prompt; once verified, GetMe saying
/// "no profile" must land on the create-handle page without a restart.
void main() {
  const unverifiedUser = AppUser(
    uid: 'uid-1',
    email: 'new@example.com',
    emailVerified: false,
    isPasswordProvider: true,
  );
  const verifiedUser = AppUser(
    uid: 'uid-1',
    email: 'new@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  late _MockAuthBloc auth;
  late _MockOnboardingBloc onboarding;
  late StreamController<AuthState> authStates;
  late StreamController<OnboardingState> onboardingStates;
  late AppRouter appRouter;

  Future<void> pump(WidgetTester tester, AuthState initial) async {
    auth = _MockAuthBloc();
    onboarding = _MockOnboardingBloc();
    authStates = StreamController<AuthState>.broadcast();
    onboardingStates = StreamController<OnboardingState>.broadcast();
    addTearDown(authStates.close);
    addTearDown(onboardingStates.close);
    whenListen(auth, authStates.stream, initialState: initial);
    whenListen(
      onboarding,
      onboardingStates.stream,
      initialState: const OnboardingState(),
    );
    appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    addTearDown(appRouter.router.dispose);
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
        ],
        child: RepositoryProvider<GraphRepository>.value(
          value: _MockGraph(),
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
            routerConfig: appRouter.router,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a new unverified account sees the verification prompt, not '
      'the splash', (tester) async {
    await pump(
      tester,
      const AuthState(
        status: AuthStatus.needsEmailVerification,
        user: unverifiedUser,
      ),
    );

    expect(find.byType(VerifyEmailView), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('verified, GetMe says no profile: the create-handle page '
      'without a restart', (tester) async {
    await pump(
      tester,
      const AuthState(
        status: AuthStatus.needsEmailVerification,
        user: unverifiedUser,
      ),
    );
    expect(find.byType(VerifyEmailView), findsOneWidget);

    // "I've verified": authenticated; GetMe loads, then answers no profile.
    when(() => auth.state).thenReturn(
      const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
    );
    authStates.add(auth.state);
    when(() => onboarding.state)
        .thenReturn(const OnboardingState(status: OnboardingStatus.loading));
    onboardingStates.add(onboarding.state);
    await tester.pump();
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);

    when(() => onboarding.state).thenReturn(
      const OnboardingState(status: OnboardingStatus.profileRequired),
    );
    onboardingStates.add(onboarding.state);
    await tester.pump();
    await tester.pump();

    expect(find.byType(CreateProfileScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('a new Google account (authenticated at once) reaches the '
      'create-handle page', (tester) async {
    await pump(
      tester,
      const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
    );
    when(() => onboarding.state).thenReturn(
      const OnboardingState(status: OnboardingStatus.profileRequired),
    );
    onboardingStates.add(onboarding.state);
    await tester.pump();
    await tester.pump();

    expect(find.byType(CreateProfileScreen), findsOneWidget);
  });
}
