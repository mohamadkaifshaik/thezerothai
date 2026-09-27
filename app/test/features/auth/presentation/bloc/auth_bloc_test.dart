import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late MockAuthRepository authRepository;

  const verifiedUser = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  const unverifiedUser = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: false,
    isPasswordProvider: true,
  );

  setUp(() {
    authRepository = MockAuthRepository();
  });

  group('AuthBloc', () {
    test('initial state is unknown, no user', () {
      final bloc = AuthBloc(authRepository: authRepository);
      expect(bloc.state, const AuthState());
      bloc.close();
    });

    blocTest<AuthBloc, AuthState>(
      'emits authenticated when the repository reports a verified user',
      setUp: () {
        when(
          () => authRepository.authStateChanges(),
        ).thenAnswer((_) => Stream.value(verifiedUser));
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      expect: () => [
        const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'emits needsEmailVerification for an unverified password account',
      setUp: () {
        when(
          () => authRepository.authStateChanges(),
        ).thenAnswer((_) => Stream.value(unverifiedUser));
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      expect: () => [
        const AuthState(
          status: AuthStatus.needsEmailVerification,
          user: unverifiedUser,
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when signed out',
      setUp: () {
        when(
          () => authRepository.authStateChanges(),
        ).thenAnswer((_) => Stream.value(null));
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      expect: () => [const AuthState(status: AuthStatus.unauthenticated)],
    );

    blocTest<AuthBloc, AuthState>(
      'sign-in sets isSubmitting then clears it on success',
      setUp: () {
        when(
          () => authRepository.signInWithEmail(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenAnswer((_) async {});
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(
        const AuthEmailSignInRequested(email: 'a@example.com', password: 'x'),
      ),
      expect: () => [
        const AuthState(isSubmitting: true),
        const AuthState(isSubmitting: false),
      ],
      verify: (_) {
        verify(
          () => authRepository.signInWithEmail(
            email: 'a@example.com',
            password: 'x',
          ),
        ).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'sign-in surfaces an AuthFailure',
      setUp: () {
        when(
          () => authRepository.signInWithEmail(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(const AuthFailure.invalidCredentials());
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(
        const AuthEmailSignInRequested(email: 'a@example.com', password: 'x'),
      ),
      expect: () => [
        const AuthState(isSubmitting: true),
        const AuthState(
          isSubmitting: false,
          failure: AuthFailure.invalidCredentials(),
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'verification check force-refreshes the ID token so the server sees '
      'email_verified',
      setUp: () {
        when(() => authRepository.reloadUser()).thenAnswer((_) async {});
        when(
          () => authRepository.getIdToken(forceRefresh: true),
        ).thenAnswer((_) async => 'fresh-token');
        when(() => authRepository.currentUser).thenReturn(verifiedUser);
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthEmailVerificationCheckRequested()),
      expect: () => [
        const AuthState(isSubmitting: true),
        const AuthState(isSubmitting: false),
        const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
      ],
      verify: (_) {
        verify(() => authRepository.reloadUser()).called(1);
        verify(
          () => authRepository.getIdToken(forceRefresh: true),
        ).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'verification check still refreshes the UI even if the token '
      'force-refresh itself fails',
      setUp: () {
        when(() => authRepository.reloadUser()).thenAnswer((_) async {});
        when(
          () => authRepository.getIdToken(forceRefresh: true),
        ).thenThrow(Exception('network blip'));
        when(() => authRepository.currentUser).thenReturn(verifiedUser);
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthEmailVerificationCheckRequested()),
      expect: () => [
        const AuthState(isSubmitting: true),
        const AuthState(isSubmitting: false),
        const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'sign-out delegates to the repository',
      setUp: () {
        when(() => authRepository.signOut()).thenAnswer((_) async {});
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSignOutRequested()),
      verify: (_) {
        verify(() => authRepository.signOut()).called(1);
      },
    );
  });
}
