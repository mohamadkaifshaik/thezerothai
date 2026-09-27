import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/widgets/verify_email_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthEmailVerificationCheckRequested());
    registerFallbackValue(const AuthEmailVerificationResendRequested());
  });

  late MockAuthBloc authBloc;

  setUp(() {
    authBloc = MockAuthBloc();
    when(() => authBloc.add(any())).thenReturn(null);
  });

  Widget wrap() {
    return BlocProvider<AuthBloc>.value(
      value: authBloc,
      child: const MaterialApp(home: VerifyEmailView()),
    );
  }

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: false,
    isPasswordProvider: true,
  );

  testWidgets('shows the pending email and a failure message', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.needsEmailVerification,
        user: user,
        failure: AuthFailure.tooManyRequests(),
      ),
    );

    await tester.pumpWidget(wrap());

    expect(find.textContaining('a@example.com'), findsOneWidget);
    expect(
      find.text('Too many attempts. Please wait and try again.'),
      findsOneWidget,
    );
  });

  testWidgets("tapping I've verified dispatches the check event", (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.needsEmailVerification,
        user: user,
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.tap(find.text("I've verified"));

    verify(
      () => authBloc.add(const AuthEmailVerificationCheckRequested()),
    ).called(1);
  });

  testWidgets('tapping Resend email dispatches the resend event', (
    tester,
  ) async {
    whenListen(
      authBloc,
      Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.needsEmailVerification,
        user: user,
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Resend email'));

    verify(
      () => authBloc.add(const AuthEmailVerificationResendRequested()),
    ).called(1);
  });
}
