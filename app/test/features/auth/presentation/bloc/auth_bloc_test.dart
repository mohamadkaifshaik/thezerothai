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
      // Fix round 3, m2: stubs that add to the stream use this test's own
      // controller, so a late call left over from an earlier test can never
      // push into the next test's stream. `authStateChanges` reads [users]
      // when the bloc subscribes, inside the test that built it (one test
      // below swaps [users] per bloc).
      final controller = StreamController<AppUser?>();
      users = controller;
      when(() => authRepository.authStateChanges())
          .thenAnswer((_) => users.stream);
      // Firebase emits the null user once sign-out completes.
      when(() => authRepository.signOut()).thenAnswer((_) async {
        if (!controller.isClosed) controller.add(null);
      });
    });
    tearDown(() => users.close());

    Future<AuthBloc> signedIn() async {
      final bloc = AuthBloc(authRepository: authRepository)
        ..add(const AuthSubscriptionRequested());
      addTearDown(bloc.close);
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
      final controller = users;
      when(() => authRepository.signOut()).thenAnswer((_) async {
        controller.add(null);
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
      addTearDown(bloc.close);
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
      addTearDown(bloc.close);
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
        addTearDown(bloc.close);
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
      addTearDown(bloc.close);
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
      addTearDown(bloc.close);
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

  // Ruling 1 (lane D PR 4): the network layer reports a session the server
  // ended (SESSION_ENDED twice, after one forced refresh) through
  // AuthRepository.onServerEndedSession; the bloc signs that uid out as a lost
  // session (the vault is kept), once per burst, and the sign-in screens
  // say why (ruling 2).
  group('session ended by a device removal', () {
    late StreamController<AppUser?> users;
    late int beforeSignOut;
    late int beforeExplicit;

    setUp(() {
      beforeSignOut = 0;
      beforeExplicit = 0;
      // Fix round 3, m2: this test's own controller (see 'lastSessionEnd').
      final controller = StreamController<AppUser?>();
      users = controller;
      when(() => authRepository.authStateChanges())
          .thenAnswer((_) => controller.stream);
      when(() => authRepository.signOut()).thenAnswer((_) async {
        await Future<void>.delayed(Duration.zero);
        if (!controller.isClosed) controller.add(null);
      });
    });
    tearDown(() => users.close());

    /// The hook the bloc gave the repository.
    void Function(String) hookOf() =>
        verify(() => authRepository.onServerEndedSession = captureAny())
                .captured
                .last
            as void Function(String);

    Future<AuthBloc> signedIn() async {
      final bloc = AuthBloc(
        authRepository: authRepository,
        beforeSignOut: () async => beforeSignOut++,
        beforeExplicitSignOut: (_) async => beforeExplicit++,
      )..add(const AuthSubscriptionRequested());
      addTearDown(bloc.close);
      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      return bloc;
    }

    test('signs that uid out as sessionLost (vault kept) and marks the '
        'state for the sign-in copy; no push unregister, no explicit '
        'hook', () async {
      final bloc = await signedIn();
      hookOf()('uid-1');
      await pumpEventQueue();

      expect(bloc.state.status, AuthStatus.unauthenticated);
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      expect(bloc.state.signedOutByDeviceRemoval, isTrue);
      verify(() => authRepository.signOut()).called(1);
      expect(beforeSignOut, 0);
      expect(beforeExplicit, 0);
      await bloc.close();
    });

    // Fix round rulings 3 and 5 (CR M1, N8; SA L1): a cut sign-out that
    // throws leaves the user signed in; the interceptor reports again on the
    // next refusal, and that report signs out.
    var signOutCalls = 0;
    blocTest<AuthBloc, AuthState>(
      'a cut sign-out that throws, then a later report signs out',
      setUp: () {
        signOutCalls = 0;
        when(() => authRepository.currentUser).thenReturn(verifiedUser);
        when(() => authRepository.signOut()).thenAnswer((_) async {
          signOutCalls++;
          if (signOutCalls == 1) throw StateError('platform');
        });
      },
      build: () => AuthBloc(authRepository: authRepository),
      seed: () =>
          const AuthState(status: AuthStatus.authenticated, user: verifiedUser),
      act: (bloc) async {
        // Listens to the group's user stream (its tearDown closes it).
        bloc.add(const AuthSubscriptionRequested());
        bloc.add(const AuthSessionEndedByServer('uid-1'));
        await pumpEventQueue();
        bloc.add(const AuthSessionEndedByServer('uid-1'));
        await pumpEventQueue();
      },
      errors: () => [isA<StateError>()],
      verify: (_) => expect(signOutCalls, 2),
    );

    blocTest<AuthBloc, AuthState>(
      'an explicit sign-out racing a cut wins: userSignedOut, no '
      'device-removal copy',
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) async {
        bloc.add(const AuthSubscriptionRequested());
        users.add(verifiedUser);
        await pumpEventQueue();
        bloc
          ..add(const AuthSignOutRequested(uid: 'uid-1'))
          ..add(const AuthSessionEndedByServer('uid-1'));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(bloc.state.user, isNull);
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      },
    );

    test('a burst of reports signs out once', () async {
      final bloc = await signedIn();
      final hook = hookOf();
      hook('uid-1');
      hook('uid-1');
      hook('uid-1');
      await pumpEventQueue();

      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.signedOutByDeviceRemoval, isTrue);
      await bloc.close();
    });

    test('a report for another account signs nobody out', () async {
      final bloc = await signedIn();
      hookOf()('uid-2');
      await pumpEventQueue();

      verifyNever(() => authRepository.signOut());
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      await bloc.close();
    });

    test('any other end (a revoked token, an explicit sign-out) does not '
        'show the device-removal copy', () async {
      final bloc = await signedIn();
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      users.add(verifiedUser);
      await pumpEventQueue();
      bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      await bloc.close();
    });

    test('signing in again clears the copy, and a later cut signs out '
        'again', () async {
      final bloc = await signedIn();
      final hook = hookOf();
      hook('uid-1');
      await pumpEventQueue();
      expect(bloc.state.signedOutByDeviceRemoval, isTrue);

      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);

      hook('uid-1');
      await pumpEventQueue();
      verify(() => authRepository.signOut()).called(2);
      expect(bloc.state.signedOutByDeviceRemoval, isTrue);
      await bloc.close();
    });

    // Fix round 1, R1: the SDK signed out on its own (its refresh met the
    // cut's revoke) before the cut report landed.
    group('a cut report after the user is already null', () {
      test('upgrades that uid\'s lost session to the removed-device notice, '
          'with no second sign-out', () async {
        final bloc = await signedIn();
        users.add(null);
        await pumpEventQueue();
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);
        hookOf()('uid-1');
        await pumpEventQueue();
        expect(bloc.state.signedOutByDeviceRemoval, isTrue);
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        verifyNever(() => authRepository.signOut());
        await bloc.close();
      });

      test('another uid, an explicit sign-out, or a sign-in since: nothing '
          'changes', () async {
        final bloc = await signedIn();
        final hook = hookOf();
        users.add(null);
        await pumpEventQueue();
        hook('uid-2');
        await pumpEventQueue();
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);

        users.add(verifiedUser);
        await pumpEventQueue();
        bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
        await pumpEventQueue();
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        hook('uid-1');
        await pumpEventQueue();
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);

        // uid-1's lost session, then another account signed in and lost
        // its session since: a late uid-1 report changes nothing.
        users.add(verifiedUser);
        await pumpEventQueue();
        users.add(null);
        await pumpEventQueue();
        users.add(
          const AppUser(
            uid: 'uid-2',
            emailVerified: true,
            isPasswordProvider: true,
          ),
        );
        await pumpEventQueue();
        users.add(null);
        await pumpEventQueue();
        hook('uid-1');
        await pumpEventQueue();
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);
        await bloc.close();
      });
    });

    test('closing the bloc unhooks it from the repository', () async {
      final bloc = await signedIn();
      final hook = hookOf();
      when(() => authRepository.onServerEndedSession).thenReturn(hook);
      await bloc.close();
      verify(() => authRepository.onServerEndedSession = null).called(1);
    });
  });

  // Remover copy (controller ruling 2026-11-27, H1 option b): this device
  // removed another one and the server ended every session; the app signs
  // itself out at once, the vault kept, with the remover's notice.
  group('signed out after removing a device', () {
    late StreamController<AppUser?> users;
    late int beforeSignOut;
    late List<String> beforeExplicit;
    late SignInProbe probe;
    late int probes;

    setUp(() {
      beforeSignOut = 0;
      beforeExplicit = [];
      // Fix round 1, R2: by default the probe finds this sign-in revoked.
      probe = SignInProbe.dead;
      probes = 0;
      // Fix round 3, m2: this test's own controller (see 'lastSessionEnd').
      final controller = StreamController<AppUser?>();
      users = controller;
      when(() => authRepository.authStateChanges())
          .thenAnswer((_) => controller.stream);
      when(() => authRepository.signOut()).thenAnswer((_) async {
        await Future<void>.delayed(Duration.zero);
        if (!controller.isClosed) controller.add(null);
      });
      when(() => authRepository.probeSignIn()).thenAnswer((_) async {
        probes++;
        return probe;
      });
    });
    tearDown(() => users.close());

    void Function(String, SignInProbe?) rawRemovalHookOf() =>
        verify(() => authRepository.onRemovalSignedOutAll = captureAny())
                .captured
                .last
            as void Function(String, SignInProbe?);

    /// The outbox's report: no answer of a probe.
    void Function(String) removalHookOf() {
      final hook = rawRemovalHookOf();
      return (uid) => hook(uid, null);
    }

    Future<SignInProbe> Function(String) checkHookOf() =>
        verify(() => authRepository.onCheckOwnRemoval = captureAny())
                .captured
                .last
            as Future<SignInProbe> Function(String);

    void Function(String) cutHookOf() =>
        verify(() => authRepository.onServerEndedSession = captureAny())
                .captured
                .last
            as void Function(String);

    Future<AuthBloc> signedIn() async {
      final bloc = AuthBloc(
        authRepository: authRepository,
        beforeSignOut: () async => beforeSignOut++,
        beforeExplicitSignOut: (uid) async => beforeExplicit.add(uid),
      )..add(const AuthSubscriptionRequested());
      addTearDown(bloc.close);
      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      return bloc;
    }

    // Fix round 1, R2: the probe decides before anything is signed out.
    test('probe alive (a replay, the same second): no sign-out, no notice, '
        'and a later report probes again', () async {
      probe = SignInProbe.alive;
      final bloc = await signedIn();
      final hook = removalHookOf();
      hook('uid-1');
      await pumpEventQueue();
      expect(probes, 1);
      verifyNever(() => authRepository.signOut());
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      expect(beforeSignOut, 0);

      // Disarmed: the next report is handled again.
      probe = SignInProbe.dead;
      hook('uid-1');
      await pumpEventQueue();
      expect(probes, 2);
      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      await bloc.close();
    });

    test('probe dead: signed out with the remover notice', () async {
      final bloc = await signedIn();
      removalHookOf()('uid-1');
      await pumpEventQueue();
      expect(probes, 1);
      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      await bloc.close();
    });

    for (final failing in [true, false]) {
      test('probe unknown (${failing ? 'it throws' : 'offline'}): signed out '
          'all the same, the server said the sessions ended', () async {
        if (failing) {
          when(() => authRepository.probeSignIn())
              .thenAnswer((_) async => throw StateError('x'));
        } else {
          probe = SignInProbe.unknown;
        }
        final bloc = await signedIn();
        removalHookOf()('uid-1');
        await pumpEventQueue();
        verify(() => authRepository.signOut()).called(1);
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
        await bloc.close();
      });
    }

    test('the outbox replay after a re-sign-in as the same uid, with the '
        'probe alive, signs nobody out', () async {
      final bloc = await signedIn();
      final hook = removalHookOf();
      // The first removal ended this sign-in.
      hook('uid-1');
      await pumpEventQueue();
      expect(bloc.state.user, isNull);
      // The same uid signs in again; a stored intent replays and the
      // server says true again, but this fresh sign-in is past the cut.
      users.add(verifiedUser);
      await pumpEventQueue();
      probe = SignInProbe.alive;
      hook('uid-1');
      await pumpEventQueue();
      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      await bloc.close();
    });

    test('the SDK signing out during the probe still reads as the remover\'s '
        'end', () async {
      final controller = users;
      when(() => authRepository.probeSignIn()).thenAnswer((_) async {
        controller.add(null);
        await pumpEventQueue();
        return SignInProbe.dead;
      });
      final bloc = await signedIn();
      removalHookOf()('uid-1');
      await pumpEventQueue();
      verifyNever(() => authRepository.signOut());
      expect(bloc.state.user, isNull);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      await bloc.close();
    });

    test('signs that uid out as sessionLost (the vault is kept: no explicit '
        'hook) with the remover notice, not the removed-device one; the '
        'push unregister runs', () async {
      final bloc = await signedIn();
      removalHookOf()('uid-1');
      await pumpEventQueue();

      expect(bloc.state.status, AuthStatus.unauthenticated);
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      verify(() => authRepository.signOut()).called(1);
      expect(beforeSignOut, 1);
      expect(beforeExplicit, isEmpty);
      await bloc.close();
    });

    test('a burst of AuthSignedOutAfterOwnRemoval events for the same uid '
        'signs out once', () async {
      final bloc = await signedIn();
      bloc
        ..add(const AuthSignedOutAfterOwnRemoval('uid-1'))
        ..add(const AuthSignedOutAfterOwnRemoval('uid-1'))
        ..add(const AuthSignedOutAfterOwnRemoval('uid-1'));
      await pumpEventQueue();
      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      await bloc.close();
    });

    test('a report for another account signs nobody out', () async {
      final bloc = await signedIn();
      removalHookOf()('uid-2');
      await pumpEventQueue();
      verifyNever(() => authRepository.signOut());
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      await bloc.close();
    });

    test('signing in again clears the notice; the same uid is back', () async {
      final bloc = await signedIn();
      removalHookOf()('uid-1');
      await pumpEventQueue();
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      users.add(verifiedUser);
      await pumpEventQueue();
      expect(bloc.state.user, verifiedUser);
      expect(bloc.state.status, AuthStatus.authenticated);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      await bloc.close();
    });

    test(
      'an explicit sign-out racing it wins: userSignedOut, no notice',
      () async {
        final bloc = await signedIn();
        bloc
          ..add(const AuthSignOutRequested(uid: 'uid-1'))
          ..add(const AuthSignedOutAfterOwnRemoval('uid-1'));
        await pumpEventQueue();
        expect(bloc.state.user, isNull);
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        await bloc.close();
      },
    );

    test('a SESSION_ENDED report while it signs out does not sign out again '
        'nor change the notice', () async {
      final bloc = await signedIn();
      removalHookOf()('uid-1');
      cutHookOf()('uid-1');
      await pumpEventQueue();
      verify(() => authRepository.signOut()).called(1);
      expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      await bloc.close();
    });

    test(
      'a cut sign-out in progress keeps the removed-device notice',
      () async {
        final bloc = await signedIn();
        cutHookOf()('uid-1');
        removalHookOf()('uid-1');
        await pumpEventQueue();
        verify(() => authRepository.signOut()).called(1);
        expect(bloc.state.signedOutByDeviceRemoval, isTrue);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        await bloc.close();
      },
    );

    test('a lost session without the report shows no notice', () async {
      final bloc = await signedIn();
      users.add(null);
      await pumpEventQueue();
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      await bloc.close();
    });

    var calls = 0;
    blocTest<AuthBloc, AuthState>(
      'a sign-out that throws leaves the user signed in and a later report '
      'tries again',
      setUp: () {
        calls = 0;
        when(() => authRepository.currentUser).thenReturn(verifiedUser);
        final controller = users;
        when(() => authRepository.signOut()).thenAnswer((_) async {
          calls++;
          if (calls == 1) throw StateError('platform');
          if (!controller.isClosed) controller.add(null);
        });
      },
      build: () => AuthBloc(authRepository: authRepository),
      act: (bloc) async {
        bloc.add(const AuthSubscriptionRequested());
        users.add(verifiedUser);
        await pumpEventQueue();
        bloc.add(const AuthSignedOutAfterOwnRemoval('uid-1'));
        await pumpEventQueue();
        expect(bloc.state.user, verifiedUser);
        bloc.add(const AuthSignedOutAfterOwnRemoval('uid-1'));
        await pumpEventQueue();
      },
      errors: () => [isA<StateError>()],
      verify: (bloc) {
        expect(calls, 2);
        expect(bloc.state.user, isNull);
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
      },
    );

    test('closing the bloc unhooks it from the repository', () async {
      final bloc = await signedIn();
      final hook = rawRemovalHookOf();
      final check = checkHookOf();
      when(() => authRepository.onRemovalSignedOutAll).thenReturn(hook);
      when(() => authRepository.onCheckOwnRemoval).thenReturn(check);
      await bloc.close();
      verify(() => authRepository.onRemovalSignedOutAll = null).called(1);
      verify(() => authRepository.onCheckOwnRemoval = null).called(1);
    });

    // Fix round 2, F1: the Settings check records the reason first.
    group('checkOwnRemoval (the Settings check)', () {
      test('the SDK signing out during the probe lands with the remover '
          'notice; the report then signs out nobody twice', () async {
        final controller = users;
        when(() => authRepository.probeSignIn()).thenAnswer((_) async {
          probes++;
          controller.add(null);
          await pumpEventQueue();
          return SignInProbe.dead;
        });
        final bloc = await signedIn();
        final answer = await checkHookOf()('uid-1');
        expect(answer, SignInProbe.dead);
        expect(bloc.state.user, isNull);
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
        // The dialog is skipped; the report still lands (backstop no-op).
        rawRemovalHookOf()('uid-1', answer);
        await pumpEventQueue();
        verifyNever(() => authRepository.signOut());
        expect(probes, 1);
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
        await bloc.close();
      });

      test('dead: the reason stays armed and the dialog\'s report signs out '
          'once, with no second probe', () async {
        final bloc = await signedIn();
        final answer = await checkHookOf()('uid-1');
        expect(answer, SignInProbe.dead);
        expect(bloc.state.user, verifiedUser);
        rawRemovalHookOf()('uid-1', answer);
        await pumpEventQueue();
        verify(() => authRepository.signOut()).called(1);
        expect(probes, 1);
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
        await bloc.close();
      });

      // Fix round 3, m1: an armed reason alone (the dialog open, no remover
      // sign-out running) does not hold a real cut back.
      test('dead, the dialog still open: a SESSION_ENDED report for that uid '
          'signs out now, and the cut\'s notice wins', () async {
        final bloc = await signedIn();
        expect(await checkHookOf()('uid-1'), SignInProbe.dead);
        expect(bloc.state.user, verifiedUser);
        cutHookOf()('uid-1');
        await pumpEventQueue();
        verify(() => authRepository.signOut()).called(1);
        expect(bloc.state.user, isNull);
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        expect(bloc.state.signedOutByDeviceRemoval, isTrue);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        expect(beforeSignOut, 0, reason: 'the cut path, not the remover\'s');
        await bloc.close();
      });

      test('alive: no sign-out, and the reason is disarmed (a later lost '
          'session shows no remover notice)', () async {
        probe = SignInProbe.alive;
        final bloc = await signedIn();
        expect(await checkHookOf()('uid-1'), SignInProbe.alive);
        verifyNever(() => authRepository.signOut());
        users.add(null);
        await pumpEventQueue();
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        await bloc.close();
      });

      test(
        'a probed: unknown report signs out without a second probe',
        () async {
          final bloc = await signedIn();
          rawRemovalHookOf()('uid-1', SignInProbe.unknown);
          await pumpEventQueue();
          expect(probes, 0);
          verify(() => authRepository.signOut()).called(1);
          expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
          await bloc.close();
        },
      );

      test(
        'another uid, or nobody signed in: unknown, nothing armed',
        () async {
          final bloc = await signedIn();
          expect(await checkHookOf()('uid-2'), SignInProbe.unknown);
          expect(probes, 0);
          users.add(null);
          await pumpEventQueue();
          expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
          await bloc.close();
        },
      );

      test('backstop: a remover report after the user is already null '
          'upgrades that uid\'s lost session', () async {
        final bloc = await signedIn();
        users.add(null);
        await pumpEventQueue();
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        final hook = rawRemovalHookOf();
        hook('uid-2', null);
        await pumpEventQueue();
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        hook('uid-1', null);
        await pumpEventQueue();
        expect(bloc.state.signedOutAfterOwnRemoval, isTrue);
        expect(bloc.state.signedOutByDeviceRemoval, isFalse);
        verifyNever(() => authRepository.signOut());
        await bloc.close();
      });

      test('backstop: an explicit sign-out is never upgraded', () async {
        final bloc = await signedIn();
        bloc.add(const AuthSignOutRequested(uid: 'uid-1'));
        await pumpEventQueue();
        rawRemovalHookOf()('uid-1', null);
        await pumpEventQueue();
        expect(bloc.state.lastSessionEnd, SessionEnd.userSignedOut);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        await bloc.close();
      });
    });
  });
}
