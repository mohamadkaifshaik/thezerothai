import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/delete_account_screen.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  late _MockAuthBloc authBloc;
  late _MockOnboardingBloc onboardingBloc;

  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    authBloc = _MockAuthBloc();
    onboardingBloc = _MockOnboardingBloc();
    when(() => authBloc.add(any())).thenReturn(null);
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'u1', handle: 'Kaif'),
      ),
    );
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => const ReauthResult());
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => DateTime(2026));
  });

  Future<GoRouter> pump(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final router = GoRouter(
      initialLocation: AppRouter.deleteAccountPath,
      routes: [
        GoRoute(
          path: AppRouter.deleteAccountPath,
          builder: (_, _) => const DeleteAccountScreen(),
        ),
        GoRoute(
          path: AppRouter.accountDeletedPath,
          builder: (_, _) => const AccountDeletedScreen(),
        ),
        GoRoute(
          path: AppRouter.exportPath,
          builder: (_, _) => const Scaffold(body: Text('export stub')),
        ),
        GoRoute(
          path: AppRouter.signInPath,
          builder: (_, _) => const Scaffold(body: Text('sign in stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<AuthRepository>.value(value: auth),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Finder button() => find.byType(FilledButton);
  bool enabled(WidgetTester tester) =>
      tester.widget<FilledButton>(button()).onPressed != null;

  Future<void> typeHandle(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  testWidgets('explains the consequences and links to the export', (
    tester,
  ) async {
    await pump(tester);

    expect(find.textContaining('permanent'), findsOneWidget);
    expect(find.textContaining('What remains'), findsOneWidget);
    await tester.tap(find.text('Download my data first'));
    await tester.pumpAndSettle();
    expect(find.text('export stub'), findsOneWidget);
  });

  testWidgets('the button stays disabled until the handle matches', (
    tester,
  ) async {
    await pump(tester);

    expect(enabled(tester), isFalse);
    await typeHandle(tester, 'wrong');
    expect(enabled(tester), isFalse);
    await typeHandle(tester, '@kaif ');
    expect(enabled(tester), isTrue);
    verifyNever(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    );
  });

  testWidgets('success re-auths, deletes once, signs out and confirms', (
    tester,
  ) async {
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    verify(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    expect(find.text('Your account is being deleted'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('sign in stub'), findsOneWidget);
  });

  testWidgets('cancelled re-auth sends nothing and says so', (tester) async {
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenThrow(const AuthFailure.cancelled());
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    verifyNever(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    );
    expect(find.textContaining('Nothing was changed'), findsOneWidget);
    expect(enabled(tester), isTrue);
  });

  testWidgets('REAUTH_REQUIRED after re-auth shows an error, no loop', (
    tester,
  ) async {
    when(() => auth.reauthNeedsGesture).thenReturn(true);
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const ReauthRequiredException('stale'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(find.textContaining("couldn't confirm it's you"), findsOneWidget);
    verify(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    verifyNever(() => authBloc.add(any()));
  });

  testWidgets('a network error is friendly and keeps the screen', (
    tester,
  ) async {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const NetworkException('boom'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(find.textContaining('No connection'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('shows progress and blocks a second tap while working', (
    tester,
  ) async {
    final gate = Completer<DateTime?>();
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) => gate.future);
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(enabled(tester), isFalse);
    gate.complete(null);
    await tester.pumpAndSettle();
  });

  for (final size in const [Size(360, 640), Size(800, 1024), Size(1400, 900)]) {
    testWidgets('no overflow at ${size.width.toInt()}dp', (tester) async {
      await pump(tester, size: size);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('handleMatches ignores case, @ and spaces', (tester) async {
    expect(handleMatches(' @KAIF ', 'kaif'), isTrue);
    expect(handleMatches('', ''), isFalse);
    expect(handleMatches('kai', 'kaif'), isFalse);
  });
}
