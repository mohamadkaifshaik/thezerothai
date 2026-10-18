import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/account/presentation/widgets/account_restricted_view.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_gate.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;

  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  setUp(() {
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  Widget wrap({bool withOnboarding = true}) {
    return MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: authBloc),
          if (withOnboarding)
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
        ],
        child: const AuthGate(child: Text('protected child')),
      ),
    );
  }

  testWidgets('a restricted account sees AccountRestrictedView, not the '
      'child', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.ready,
        accountRestricted: true,
      ),
    );

    await tester.pumpWidget(wrap());

    expect(find.byType(AccountRestrictedView), findsOneWidget);
    expect(find.text('protected child'), findsNothing);

    await tester.tap(find.text('Sign out'));
    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
  });

  testWidgets('an unrestricted account sees the child', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(status: OnboardingStatus.ready),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('protected child'), findsOneWidget);
    expect(find.byType(AccountRestrictedView), findsNothing);
  });

  testWidgets('the view swaps in when a later GetMe reports the suspension', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      Stream.value(
        const OnboardingState(
          status: OnboardingStatus.ready,
          accountRestricted: true,
        ),
      ),
      initialState: const OnboardingState(status: OnboardingStatus.ready),
    );

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.byType(AccountRestrictedView), findsOneWidget);
  });

  testWidgets('without an OnboardingBloc in scope the child shows (no throw)', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(withOnboarding: false));

    expect(find.text('protected child'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
