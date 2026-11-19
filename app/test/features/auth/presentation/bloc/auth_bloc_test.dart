import 'dart:async';

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
        when(() => authRepository.authStateChanges())
            .thenAnswer((_) => Stream.value(verifiedUser));
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      expect: () => [
        const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'falls back to unauthenticated when the auth stream errors, so the '
      'app does not stay on the splash screen',
      setUp: () {
        when(() => authRepository.authStateChanges())
            .thenAnswer((_) => Stream.error(StateError('auth unavailable')));
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      // A stream error is a lost session, never an explicit sign-out.
      expect: () => [
        const AuthState(
          status: AuthStatus.unauthenticated,
          lastSessionEnd: SessionEnd.sessionLost,
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'settles from the current user when no auth event arrives in time',
      setUp: () {
        when(() => authRepository.authStateChanges())
            .thenAnswer((_) => const Stream.empty());
        when(() => authRepository.currentUser).thenReturn(null);
      },
      build: () => AuthBloc(
        authRepository: authRepository,
        unknownTimeout: const Duration(milliseconds: 10),
      ),
      act: (bloc) => bloc.add(const AuthSubscriptionRequested()),
      wait: const Duration(milliseconds: 50),
      expect: () => [const AuthState(status: AuthStatus.unauthenticated)],
    );

    blocTest<AuthBloc, AuthState>(
      'emits needsEmailVerification for an unverified password account',
      setUp: () {
        when(() => authRepository.authStateChanges())
            .thenAnswer((_) => Stream.value(unverifiedUser));
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
        when(() => authRepository.authStateChanges())
            .thenAnswer((_) => Stream.value(null));
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
        when(() => authRepository.getIdToken(forceRefresh: true))
            .thenAnswer((_) async => 'fresh-token');
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
        verify(() => authRepository.getIdToken(forceRefresh: true)).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'verification check still refreshes the UI even if the token '
      'force-refresh itself fails',
      setUp: () {
        when(() => authRepository.reloadUser()).thenAnswer((_) async {});
        when(() => authRepository.getIdToken(forceRefresh: true))
            .thenThrow(Exception('network blip'));
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

  group('lastSessionEnd', () {
    const otherUser = AppUser(
      uid: 'uid-2',
      email: 'b@example.com',
      emailVerified: true,
      isPasswordProvider: true,
    );
    late StreamController<AppUser?> users;

    setUp(() {
      users = StreamController<AppUser?>();
      when(() => authRepository.authStateChanges())
          .thenAnswer((_) => users.stream);
      // Firebase emits the null user once sign-out completes.
      when(() => authRepository.signOut()).thenAnswer((_) async {
        users.add(null);
      });
    });
    tearDown(() => users.close());

    Future<AuthBloc> signedIn() async {
      final bloc = AuthBloc(authRepository: authRepository)
        ..add(const AuthSubscriptionRequested());
      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.lastSessionEnd, isNull);
      return bloc;
    }

    test('an explicit sign-out ends as userSignedOut', () async {
      final bloc = await signedIn();
      bloc.add(const AuthSignOutRequested());
      await pumpEventQueue();
      expect(bloc.state.status, AuthStatus.unauthenticated);
      expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
      await bloc.close();
    });

    test('the account-deletion screens end as accountDeleted', () async {
      final bloc = await signedIn();
      bloc.add(const AuthSignOutRequested(reason: SessionEnd.accountDeleted));
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.accountDeleted);
      await bloc.close();
    });

    test('a stream error ends as sessionLost', () async {
      final bloc = await signedIn();
      users.addError(StateError('auth broke'));
      await pumpEventQueue();
      expect(bloc.state.status, AuthStatus.unauthenticated);
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    test('a null user without a request (revoked token) ends as '
        'sessionLost', () async {
      final bloc = await signedIn();
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    test('account deletion that nulls the user without a sign-out request '
        '(deleteCurrentUser) ends as accountDeleted, from the repository '
        'intent for that uid', () async {
      when(() => authRepository.takeSessionEndIntent('uid-1'))
          .thenReturn(SessionEnd.accountDeleted);
      final bloc = await signedIn();
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.accountDeleted);
      verify(() => authRepository.takeSessionEndIntent('uid-1')).called(1);
      await bloc.close();
    });

    test('a failed sign-out (the user still signed in) disarms the intent '
        'and says so: a later revoke is sessionLost', () async {
      when(() => authRepository.signOut()).thenThrow(StateError('offline'));
      when(() => authRepository.currentUser).thenReturn(verifiedUser);
      // The failure still reaches the bloc's error handling, as before.
      final errors = <Object>[];
      var failedCalls = 0;
      final done = Completer<void>();
      runZonedGuarded(() async {
        final bloc = AuthBloc(
          authRepository: authRepository,
          onSignOutFailed: (_) => failedCalls++,
        )..add(const AuthSubscriptionRequested());
        users.add(verifiedUser);
        await pumpEventQueue();
        bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
        await pumpEventQueue();
        expect(bloc.state.user, verifiedUser);
        expect(failedCalls, 1);
        users.add(null);
        await pumpEventQueue();
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        await bloc.close();
        done.complete();
      }, (error, _) => errors.add(error));
      await done.future;
      expect(errors, [isA<StateError>()]);
    });

    test('a PARTIAL sign-out failure (Firebase signed out, Google failed) '
        'keeps the intent: the end is still userSignedOut', () async {
      when(() => authRepository.signOut()).thenAnswer((_) async {
        users.add(null);
        throw StateError('google sign-out failed');
      });
      when(() => authRepository.currentUser).thenReturn(null);
      final errors = <Object>[];
      var failedCalls = 0;
      final done = Completer<void>();
      runZonedGuarded(() async {
        final bloc = AuthBloc(
          authRepository: authRepository,
          onSignOutFailed: (_) => failedCalls++,
        )..add(const AuthSubscriptionRequested());
        users.add(verifiedUser);
        await pumpEventQueue();
        bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
        await pumpEventQueue();
        expect(bloc.state.user, isNull);
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        expect(failedCalls, 0);
        await bloc.close();
        done.complete();
      }, (error, _) => errors.add(error));
      await done.future;
      expect(errors, [isA<StateError>()]);
    });

    test('a sign-out event for uid A handled while B is signed in does '
        'NOTHING: B stays signed in, no hook, no intent', () async {
      final explicit = <String>[];
      var before = 0;
      final bloc = AuthBloc(
        authRepository: authRepository,
        beforeSignOut: () async => before++,
        beforeExplicitSignOut: (uid) async => explicit.add(uid),
      )..add(const AuthSubscriptionRequested());
      users.add(verifiedUser);
      await pumpEventQueue();
      // Expressed for another account (e.g. the tab switched users).
      bloc.add(const AuthSignOutRequested(uid: 'uid-other'));
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      expect(explicit, isEmpty);
      expect(before, 0);
      verifyNever(() => authRepository.signOut());
      // B's later revoke is not an explicit end.
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    test('B-I1: a uid-carrying sign-out with NOBODY signed in (account '
        'deletion after Firebase emitted the null user) still runs '
        'beforeSignOut and signOut; it arms nothing', () async {
      final explicit = <String>[];
      var before = 0;
      final bloc = AuthBloc(
        authRepository: authRepository,
        beforeSignOut: () async => before++,
        beforeExplicitSignOut: (uid) async => explicit.add(uid),
      )..add(const AuthSubscriptionRequested());
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.user, isNull);
      bloc.add(
        const AuthSignOutRequested(
          reason: SessionEnd.accountDeleted,
          uid: 'uid-1',
        ),
      );
      await pumpEventQueue();
      expect(before, 1);
      verify(() => authRepository.signOut()).called(1);
      expect(explicit, isEmpty);
      await bloc.close();
    });

    test('m1: an intent already armed for the signed-in user survives a '
        'later mismatched or non-arming event', () async {
      // signOut does not complete the sign-out (the null user comes later).
      when(() => authRepository.signOut()).thenAnswer((_) async {});
      for (final later in const [
        AuthSignOutRequested(uid: 'uid-other'),
        AuthSignOutRequested(arm: false),
      ]) {
        // One stream per bloc (a never-listened controller's close() would
        // not complete, so it is not awaited).
        unawaited(users.close());
        users = StreamController<AppUser?>();
        final bloc = await signedIn();
        bloc.add(
          const AuthSignOutRequested(
            reason: SessionEnd.accountDeleted,
            uid: 'uid-1',
          ),
        );
        await pumpEventQueue();
        bloc.add(later);
        await pumpEventQueue();
        users.add(null);
        await pumpEventQueue();
        expect(
          bloc.state.lastSessionEnd,
          SessionEnd.accountDeleted,
          reason: 'after ${later.uid} / arm ${later.arm}',
        );
        await bloc.close();
      }
    });

    test(
      'N3: a non-arming sign-out (arm: false) signs out as before but '
      'arms nothing and runs no explicit hook: the end is sessionLost',
      () async {
        final explicit = <String>[];
        final bloc = AuthBloc(
          authRepository: authRepository,
          beforeExplicitSignOut: (uid) async => explicit.add(uid),
        )..add(const AuthSubscriptionRequested());
        users.add(verifiedUser);
        await pumpEventQueue();
        bloc.add(const AuthSignOutRequested(arm: false));
        await pumpEventQueue();
        expect(bloc.state.user, isNull);
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        expect(explicit, isEmpty);
        expect(
          const AuthSignOutRequested(arm: false),
          isNot(const AuthSignOutRequested()),
        );
        await bloc.close();
      },
    );

    test('an armed intent runs the explicit hook with its uid', () async {
      final explicit = <String>[];
      final bloc = AuthBloc(
        authRepository: authRepository,
        beforeExplicitSignOut: (uid) async => explicit.add(uid),
      )..add(const AuthSubscriptionRequested());
      users.add(verifiedUser);
      await pumpEventQueue();
      bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
      await pumpEventQueue();
      expect(explicit, ['uid-1']);
      expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
      await bloc.close();
    });

    test(
      'a sign-out event carrying the signed-in uid arms the intent',
      () async {
        final bloc = await signedIn();
        bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
        await pumpEventQueue();
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        expect(
          const AuthSignOutRequested(uid: 'uid-1'),
          AuthSignOutRequested(uid: 'uid-1'.toString()),
          reason: 'value equality, so mocks can verify the uid',
        );
        await bloc.close();
      },
    );

    test('an intent is bound to the uid it was expressed for: a switch to '
        'another user disarms it', () async {
      // signOut does not complete the sign-out; the SDK switches users.
      when(() => authRepository.signOut()).thenAnswer((_) async {});
      final bloc = await signedIn();
      bloc.add(const AuthSignOutRequested());
      await pumpEventQueue();
      users.add(otherUser);
      await pumpEventQueue();
      expect(bloc.state.user, otherUser);
      expect(
        bloc.state.lastSessionEnd,
        isNull,
        reason: 'a switch is not a transition to no user',
      );
      // uid-2's session is later lost: never treated as uid-1's sign-out.
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    test('a sign-out request with nobody signed in arms nothing', () async {
      when(() => authRepository.signOut()).thenAnswer((_) async {});
      final bloc = AuthBloc(authRepository: authRepository)
        ..add(const AuthSubscriptionRequested());
      users.add(null);
      await pumpEventQueue();
      bloc.add(const AuthSignOutRequested());
      await pumpEventQueue();
      users.add(verifiedUser);
      await pumpEventQueue();
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    test('the same user signing in again keeps lastSessionEnd until the '
        'next end', () async {
      final bloc = await signedIn();
      bloc.add(const AuthSignOutRequested());
      await pumpEventQueue();
      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });
  });
}
