import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

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

  Widget wrap() {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
      ],
      child: const MaterialApp(home: SettingsScreen()),
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
        enabledFeatures: {'account_lifecycle'},
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
}
