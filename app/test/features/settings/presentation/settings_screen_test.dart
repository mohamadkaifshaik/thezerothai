import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  late MockAuthBloc authBloc;

  setUp(() {
    authBloc = MockAuthBloc();
    when(() => authBloc.add(any())).thenReturn(null);
  });

  Widget wrap() {
    return BlocProvider<AuthBloc>.value(
      value: authBloc,
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
}
