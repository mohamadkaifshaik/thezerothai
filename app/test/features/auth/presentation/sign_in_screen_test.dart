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
      const AuthEmailSignInRequested(email: '', password: ''),
    );
  });

  Widget wrap(AuthBloc bloc) {
    final router = GoRouter(
      initialLocation: '/sign-in',
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

    testWidgets('shows validation errors for an empty form', (tester) async {
      await tester.pumpWidget(wrap(authBloc));

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();

      expect(find.text('Enter your email'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
      verifyNever(
        () => authRepository.signInWithEmail(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      );
    });

    testWidgets('submits valid credentials to the repository', (tester) async {
      when(
        () => authRepository.signInWithEmail(
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
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      verify(
        () => authRepository.signInWithEmail(
          email: 'user@example.com',
          password: 'password1',
        ),
      ).called(1);
    });

    testWidgets('navigates to sign-up', (tester) async {
      await tester.pumpWidget(wrap(authBloc));

      await tester.tap(find.text("Don't have an account? Sign up"));
      await tester.pumpAndSettle();

      expect(find.text('Create your account'), findsOneWidget);
    });

    testWidgets('shows just the Privacy Policy link, no sentence', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(authBloc));

      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.textContaining('18 or older'), findsNothing);
    });
  });

  group('with a seeded AuthBloc state (presentational)', () {
    late MockAuthBloc authBloc;

    setUp(() {
      authBloc = MockAuthBloc();
    });

    testWidgets('shows a spinner while a sign-in is submitting', (
      tester,
    ) async {
      const state = AuthState(isSubmitting: true);
      whenListen(authBloc, Stream<AuthState>.empty(), initialState: state);

      await tester.pumpWidget(wrap(authBloc));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
    });

    testWidgets('shows a failure message and dismisses it', (tester) async {
      const failureState = AuthState(failure: AuthFailure.invalidCredentials());
      whenListen(
        authBloc,
        Stream.value(failureState),
        initialState: const AuthState(),
      );
      when(() => authBloc.add(any())).thenReturn(null);

      await tester.pumpWidget(wrap(authBloc));
      await tester.pump();

      expect(find.text('Incorrect email or password.'), findsOneWidget);
      verify(() => authBloc.add(const AuthFailureDismissed())).called(1);
    });
  });
}
