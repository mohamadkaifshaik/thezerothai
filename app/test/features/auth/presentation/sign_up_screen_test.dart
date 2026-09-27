import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const AuthEmailSignUpRequested(email: '', password: ''),
    );
  });

  Widget wrap(AuthBloc bloc) {
    final router = GoRouter(
      initialLocation: '/sign-up',
      routes: [
        GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
        GoRoute(path: '/sign-up', builder: (_, _) => const SignUpScreen()),
      ],
    );
    return BlocProvider<AuthBloc>.value(
      value: bloc,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  group('with a real AuthBloc (behavioral)', () {
    late MockAuthRepository authRepository;
    late AuthBloc authBloc;

    setUp(() {
      authRepository = MockAuthRepository();
      authBloc = AuthBloc(authRepository: authRepository);
    });

    tearDown(() => authBloc.close());

    testWidgets('rejects mismatched passwords without calling the repository', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(authBloc));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password1',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'password2',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
      await tester.pump();

      expect(find.text('Passwords do not match'), findsOneWidget);
      verifyNever(
        () => authRepository.signUpWithEmail(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      );
    });

    testWidgets('submits matching credentials to the repository', (
      tester,
    ) async {
      when(
        () => authRepository.signUpWithEmail(
          email: 'user@example.com',
          password: 'password1',
        ),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(authBloc));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password1',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'password1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
      await tester.pumpAndSettle();

      verify(
        () => authRepository.signUpWithEmail(
          email: 'user@example.com',
          password: 'password1',
        ),
      ).called(1);
    });

    testWidgets('navigates back to sign-in', (tester) async {
      await tester.pumpWidget(wrap(authBloc));

      final signInLink = find.text('Already have an account? Sign in');
      await tester.ensureVisible(signInLink);
      await tester.tap(signInLink);
      await tester.pumpAndSettle();

      expect(find.text('Welcome back'), findsOneWidget);
    });
  });

  group('with a seeded AuthBloc state (presentational)', () {
    late MockAuthBloc authBloc;

    setUp(() {
      authBloc = MockAuthBloc();
    });

    testWidgets('shows a failure message from a failed sign-up', (
      tester,
    ) async {
      const failureState = AuthState(failure: AuthFailure.emailAlreadyInUse());
      whenListen(
        authBloc,
        Stream.value(failureState),
        initialState: const AuthState(),
      );
      when(() => authBloc.add(any())).thenReturn(null);

      await tester.pumpWidget(wrap(authBloc));
      await tester.pump();

      expect(
        find.text('An account with this email already exists.'),
        findsOneWidget,
      );
    });
  });
}
