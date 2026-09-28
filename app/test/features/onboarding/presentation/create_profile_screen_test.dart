import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/create_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingHandleChanged(''));
    registerFallbackValue(const AuthSignOutRequested());
  });

  late MockOnboardingBloc onboardingBloc;
  late MockAuthBloc authBloc;

  setUp(() {
    onboardingBloc = MockOnboardingBloc();
    authBloc = MockAuthBloc();
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    when(() => authBloc.add(any())).thenReturn(null);
  });

  Widget wrap() {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
      ],
      child: const MaterialApp(home: CreateProfileScreen()),
    );
  }

  testWidgets('disables Continue until a handle is available and named', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );

    await tester.pumpWidget(wrap());

    final continueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(continueButton.onPressed, isNull);
  });

  testWidgets('enables Continue once the handle is available', (tester) async {
    whenListen(
      onboardingBloc,
      Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.available,
      ),
    );

    await tester.pumpWidget(wrap());

    final continueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(continueButton.onPressed, isNotNull);
  });

  testWidgets('typing a handle dispatches OnboardingHandleChanged', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    when(() => onboardingBloc.add(any())).thenReturn(null);

    await tester.pumpWidget(wrap());
    await tester.enterText(find.widgetWithText(TextField, 'Handle'), 'kaif');

    final captured = verify(() => onboardingBloc.add(captureAny())).captured;
    expect(
      captured.whereType<OnboardingHandleChanged>().map((e) => e.handle),
      contains('kaif'),
    );
  });

  testWidgets('tapping sign out dispatches AuthSignOutRequested', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );

    await tester.pumpWidget(wrap());
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pump();

    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
  });

  testWidgets(
    'shows VerifyEmailView with a banner when CreateProfile found the '
    "caller's email unverified",
    (tester) async {
      whenListen(
        onboardingBloc,
        Stream<OnboardingState>.empty(),
        initialState: const OnboardingState(
          status: OnboardingStatus.emailVerificationRequired,
          handle: 'kaif',
          displayName: 'Kaif',
          error: EmailNotVerifiedException('please verify your email'),
        ),
      );

      await tester.pumpWidget(wrap());

      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.text('please verify your email'), findsOneWidget);
      // The create-profile form is gone, not just covered.
      expect(find.text('Create your profile'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Continue'), findsNothing);
    },
  );

  testWidgets('tapping back on the email-verification prompt dispatches '
      'OnboardingEmailVerificationDismissed', (tester) async {
    whenListen(
      onboardingBloc,
      Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.emailVerificationRequired,
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.tap(find.byType(BackButton));
    await tester.pump();

    verify(
      () => onboardingBloc.add(const OnboardingEmailVerificationDismissed()),
    ).called(1);
  });
}
