import 'dart:async';

import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart'
    show SessionEndedException;
import 'package:dzeroth/core/network/auth_token_provider.dart'
    show DeadSignInException;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/session_tokens.dart';

class _MockFirebaseAuth extends Mock implements fb.FirebaseAuth {}

class _MockGoogleSignIn extends Mock implements GoogleSignIn {}

class _MockGoogleSignInAccount extends Mock implements GoogleSignInAccount {}

class _MockUserCredential extends Mock implements fb.UserCredential {}

class _MockUser extends Mock implements fb.User {}

class _MockUserInfo extends Mock implements fb.UserInfo {}

class _MockUserMetadata extends Mock implements fb.UserMetadata {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MockFirebaseAuth firebaseAuth;
  late _MockGoogleSignIn googleSignIn;

  setUpAll(() {
    registerFallbackValue(fb.GoogleAuthProvider());
    registerFallbackValue(fb.GoogleAuthProvider.credential(idToken: 'x'));
  });

  setUp(() {
    firebaseAuth = _MockFirebaseAuth();
    googleSignIn = _MockGoogleSignIn();
  });

  group('SESSION_ENDED seam (AuthTokenProvider)', () {
    test('refreshIdToken forces a new token from the SDK', () async {
      final user = _MockUser();
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.getIdToken(true)).thenAnswer((_) async => 'fresh');
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      expect(await repo.refreshIdToken(), 'fresh');
      verify(() => user.getIdToken(true)).called(1);
    });

    // Remover copy defensive fix (controller ruling 2026-11-27): a refresh
    // the server will never grant again (H1 revoked the refresh token) signs
    // out, so the null user reaches the auth bloc as a lost session instead
    // of every call failing as a NetworkException while "signed in".
    for (final code in [
      'user-token-expired',
      'invalid-user-token',
      'user-disabled',
      'user-not-found',
    ]) {
      test('a token fetch failing with $code signs out and rethrows', () async {
        final user = _MockUser();
        when(() => user.uid).thenReturn('uid-1');
        when(() => firebaseAuth.currentUser).thenReturn(user);
        when(() => user.getIdToken(false))
            .thenThrow(fb.FirebaseAuthException(code: code));
        when(() => firebaseAuth.signOut()).thenAnswer((_) async {});
        final repo = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        );
        await expectLater(
          repo.getIdToken(),
          throwsA(
            isA<fb.FirebaseAuthException>().having((e) => e.code, 'code', code),
          ),
        );
        verify(() => firebaseAuth.signOut()).called(1);
      });
    }

    // Fix round 1, R1 (code M1): a forced refresh never signs out; a dead
    // one is told apart as DeadSignInException.
    test('a forced refresh failing with user-token-expired does NOT sign '
        'out and throws DeadSignInException (the SESSION_ENDED '
        'interceptor\'s refresh)', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.getIdToken(true))
          .thenThrow(fb.FirebaseAuthException(code: 'user-token-expired'));
      when(() => firebaseAuth.signOut()).thenAnswer((_) async {});
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      await expectLater(
        repo.refreshIdToken(),
        throwsA(isA<DeadSignInException>()),
      );
      await expectLater(
        repo.getIdToken(forceRefresh: true),
        throwsA(isA<fb.FirebaseAuthException>()),
      );
      verifyNever(() => firebaseAuth.signOut());
    });

    test('a forced refresh failing otherwise rethrows the SDK error', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.getIdToken(true))
          .thenThrow(fb.FirebaseAuthException(code: 'network-request-failed'));
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      await expectLater(
        repo.refreshIdToken(),
        throwsA(isA<fb.FirebaseAuthException>()),
      );
    });

    // Fix round 1, R2: the probe is one forced refresh that never signs out.
    group('probeSignIn', () {
      Future<SignInProbe> probeWith(Object? error) async {
        final user = _MockUser();
        when(() => user.uid).thenReturn('uid-1');
        when(() => firebaseAuth.currentUser).thenReturn(user);
        if (error == null) {
          when(() => user.getIdToken(true)).thenAnswer((_) async => 'fresh');
        } else {
          when(() => user.getIdToken(true)).thenThrow(error);
        }
        final repo = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        );
        final probe = await repo.probeSignIn();
        verify(() => user.getIdToken(true)).called(1);
        verifyNever(() => firebaseAuth.signOut());
        return probe;
      }

      test('a new token: alive', () async {
        expect(await probeWith(null), SignInProbe.alive);
      });

      test('a dead sign-in: dead', () async {
        expect(
          await probeWith(fb.FirebaseAuthException(code: 'user-token-expired')),
          SignInProbe.dead,
        );
      });

      test('offline, or anything else: unknown', () async {
        expect(
          await probeWith(
            fb.FirebaseAuthException(code: 'network-request-failed'),
          ),
          SignInProbe.unknown,
        );
        expect(await probeWith(StateError('x')), SignInProbe.unknown);
      });

      test('nobody signed in: unknown, no call', () async {
        when(() => firebaseAuth.currentUser).thenReturn(null);
        final repo = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        );
        expect(await repo.probeSignIn(), SignInProbe.unknown);
      });
    });

    // Fix round 1, R3 (security L1): a fetch that started before an auth
    // event (here: the same uid signing in again) never signs out.
    test('a stale dead fetch from before a new auth event does not sign '
        'out', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => user.email).thenReturn(null);
      when(() => user.displayName).thenReturn(null);
      when(() => user.emailVerified).thenReturn(true);
      when(() => user.providerData).thenReturn([]);
      when(() => firebaseAuth.currentUser).thenReturn(user);
      final changes = StreamController<fb.User?>();
      addTearDown(changes.close);
      when(() => firebaseAuth.userChanges()).thenAnswer((_) => changes.stream);
      when(() => firebaseAuth.signOut()).thenAnswer((_) async {});
      final gate = Completer<String>();
      when(() => user.getIdToken(false)).thenAnswer((_) => gate.future);
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      final sub = repo.authStateChanges().listen((_) {});
      addTearDown(sub.cancel);

      final fetch = repo.getIdToken();
      // The same uid signs in again while the old fetch runs.
      changes.add(user);
      await pumpEventQueue();
      gate.completeError(fb.FirebaseAuthException(code: 'user-token-expired'));
      await expectLater(fetch, throwsA(isA<fb.FirebaseAuthException>()));
      verifyNever(() => firebaseAuth.signOut());
    });

    // Fix round 1, R4 (code m3): a burst of dead fetches signs out once.
    test('a burst of dead fetches shares one sign-out', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.getIdToken(false))
          .thenThrow(fb.FirebaseAuthException(code: 'user-token-expired'));
      final signOut = Completer<void>();
      when(() => firebaseAuth.signOut()).thenAnswer((_) => signOut.future);
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      final fetches = [
        for (var i = 0; i < 3; i++)
          expectLater(
            repo.getIdToken(),
            throwsA(isA<fb.FirebaseAuthException>()),
          ),
      ];
      await pumpEventQueue();
      signOut.complete();
      await Future.wait(fetches);
      verify(() => firebaseAuth.signOut()).called(1);
    });

    test('a transient token failure (network) does not sign out', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.getIdToken(false))
          .thenThrow(fb.FirebaseAuthException(code: 'network-request-failed'));
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      await expectLater(
        repo.getIdToken(),
        throwsA(isA<fb.FirebaseAuthException>()),
      );
      verifyNever(() => firebaseAuth.signOut());
    });

    test('a dead token after the SDK already signed out signs out nothing '
        'more', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      var current = true;
      when(() => firebaseAuth.currentUser)
          .thenAnswer((_) => current ? user : null);
      when(() => user.getIdToken(false)).thenAnswer((_) async {
        current = false;
        throw fb.FirebaseAuthException(code: 'user-token-expired');
      });
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      await expectLater(
        repo.getIdToken(),
        throwsA(isA<fb.FirebaseAuthException>()),
      );
      verifyNever(() => firebaseAuth.signOut());
    });

    test('no user: no token and no call', () async {
      when(() => firebaseAuth.currentUser).thenReturn(null);
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      expect(await repo.getIdToken(), isNull);
    });

    test('end to end through the auth bloc: a dead token leaves the app '
        'signed out as sessionLost (no notice, vault kept)', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => user.email).thenReturn('a@example.com');
      when(() => user.displayName).thenReturn(null);
      when(() => user.emailVerified).thenReturn(true);
      when(() => user.providerData).thenReturn([]);
      fb.User? current = user;
      final changes = StreamController<fb.User?>();
      addTearDown(changes.close);
      when(() => firebaseAuth.currentUser).thenAnswer((_) => current);
      when(() => firebaseAuth.userChanges()).thenAnswer((_) => changes.stream);
      when(() => firebaseAuth.signOut()).thenAnswer((_) async {
        current = null;
        changes.add(null);
      });
      when(() => user.getIdToken(false))
          .thenThrow(fb.FirebaseAuthException(code: 'user-token-expired'));
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      final bloc = AuthBloc(authRepository: repo)
        ..add(const AuthSubscriptionRequested());
      changes.add(user);
      await pumpEventQueue();
      expect(bloc.state.status, AuthStatus.authenticated);

      await expectLater(repo.getIdToken(), throwsA(anything));
      await pumpEventQueue();
      expect(bloc.state.status, AuthStatus.unauthenticated);
      expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
      expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
      expect(bloc.state.signedOutByDeviceRemoval, isFalse);
      await bloc.close();
    });

    // Fix round 1, R1: through the real AuthRepository, ApiClient (its
    // SessionEndedInterceptor) and AuthBloc. The removed device's call is
    // refused SESSION_ENDED and its forced refresh is dead (H1 revoked its
    // refresh token): it lands with the removed device's notice, whether or
    // not the SDK signed out on its own first.
    for (final sdkSignsOutFirst in [false, true]) {
      test('SESSION_ENDED then a dead refresh: the removed-device notice '
          '(the SDK ${sdkSignsOutFirst ? 'signs out first' : 'does not sign '
                    'out'})', () async {
        final user = _MockUser();
        when(() => user.uid).thenReturn('uid-1');
        when(() => user.email).thenReturn('a@example.com');
        when(() => user.displayName).thenReturn(null);
        when(() => user.emailVerified).thenReturn(true);
        when(() => user.providerData).thenReturn([]);
        fb.User? current = user;
        final changes = StreamController<fb.User?>();
        addTearDown(changes.close);
        when(() => firebaseAuth.currentUser).thenAnswer((_) => current);
        when(() => firebaseAuth.userChanges())
            .thenAnswer((_) => changes.stream);
        var signOuts = 0;
        when(() => firebaseAuth.signOut()).thenAnswer((_) async {
          signOuts++;
          current = null;
          changes.add(null);
        });
        when(() => user.getIdToken(false))
            .thenAnswer((_) async => idTokenFor('uid-1'));
        when(() => user.getIdToken(true)).thenAnswer((_) async {
          if (sdkSignsOutFirst) {
            current = null;
            changes.add(null);
            await pumpEventQueue();
          }
          throw fb.FirebaseAuthException(code: 'user-token-expired');
        });
        final repo = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        );
        final bloc = AuthBloc(authRepository: repo)
          ..add(const AuthSubscriptionRequested());
        changes.add(user);
        await pumpEventQueue();
        expect(bloc.state.status, AuthStatus.authenticated);

        final http = RecordingHttp(respond: (_) => sessionEndedError());
        final api = ApiClient(
          baseUrl: 'https://api.example.test',
          authTokens: repo,
          appCheckTokens: ScriptedAppCheck(),
          sessionUid: () => bloc.state.user?.uid,
          httpClient: http.client,
        );
        final error = await guardApiCall(
          () => api.identity.getMe(identity.GetMeRequest()),
        ).then<Object?>((_) => null, onError: (Object e) => e);
        await pumpEventQueue();

        expect(error, isA<SessionEndedException>());
        // No retry after a dead refresh.
        expect(http.sent, hasLength(1));
        expect(bloc.state.status, AuthStatus.unauthenticated);
        expect(bloc.state.lastSessionEnd, SessionEnd.sessionLost);
        expect(bloc.state.signedOutByDeviceRemoval, isTrue);
        expect(bloc.state.signedOutAfterOwnRemoval, isFalse);
        // The refresh itself never signed out; only the bloc's cut path
        // (when the SDK had not already).
        expect(signOuts, sdkSignsOutFirst ? 0 : 1);
        await bloc.close();
      });
    }

    test('reportRemovalSignedOutAll tells onRemovalSignedOutAll, and is a '
        'no-op without it', () {
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      repo.reportRemovalSignedOutAll('uid-1');
      final seen = <(String, SignInProbe?)>[];
      repo.onRemovalSignedOutAll = (uid, probed) => seen.add((uid, probed));
      repo.reportRemovalSignedOutAll('uid-1');
      repo.reportRemovalSignedOutAll('uid-1', probed: SignInProbe.unknown);
      expect(seen, [('uid-1', null), ('uid-1', SignInProbe.unknown)]);
    });

    // Fix round 2, F1: the Settings check goes through the bloc's hook.
    test(
      'checkOwnRemoval uses onCheckOwnRemoval, else a plain probe',
      () async {
        when(() => firebaseAuth.currentUser).thenReturn(null);
        final repo = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        );
        expect(await repo.checkOwnRemoval('uid-1'), SignInProbe.unknown);
        final asked = <String>[];
        repo.onCheckOwnRemoval = (uid) async {
          asked.add(uid);
          return SignInProbe.alive;
        };
        expect(await repo.checkOwnRemoval('uid-1'), SignInProbe.alive);
        expect(asked, ['uid-1']);
      },
    );

    test('reportSessionEnded tells onServerEndedSession, and is a no-op '
        'without '
        'it', () {
      final repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
      repo.reportSessionEnded('uid-1');
      final seen = <String>[];
      repo.onServerEndedSession = seen.add;
      repo.reportSessionEnded('uid-1');
      expect(seen, ['uid-1']);
    });
  });

  // Fix round ruling 4 (CR M2, SA L5): "straight to the password prompt"
  // follows reauthenticate's own order (Google, then Apple, then password),
  // so a mixed account gets the Continue step and its popup opens on a tap.
  group('reauthUsesPassword', () {
    bool usesPassword(List<String> providers) {
      final user = _MockUser();
      final infos = [
        for (final id in providers)
          (() {
            final i = _MockUserInfo();
            when(() => i.providerId).thenReturn(id);
            return i;
          })(),
      ];
      when(() => user.providerData).thenReturn(infos);
      when(() => firebaseAuth.currentUser).thenReturn(user);
      return AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      ).reauthUsesPassword;
    }

    test('password only: true', () {
      expect(usesPassword(['password']), isTrue);
    });

    test('Google and a password (mixed): false, Google is used', () {
      expect(usesPassword(['password', 'google.com']), isFalse);
    });

    test('Apple and a password (mixed): false, Apple is used', () {
      expect(usesPassword(['apple.com', 'password']), isFalse);
    });

    test('Google only: false', () {
      expect(usesPassword(['google.com']), isFalse);
    });

    test('nobody signed in: false', () {
      when(() => firebaseAuth.currentUser).thenReturn(null);
      expect(
        AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
        ).reauthUsesPassword,
        isFalse,
      );
    });
  });

  group('account-deletion session end', () {
    late _MockUser user;
    late AuthRepository repo;

    setUp(() {
      user = _MockUser();
      when(() => user.uid).thenReturn('uid-1');
      when(() => firebaseAuth.currentUser).thenReturn(user);
      repo = AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      );
    });

    test('deleteCurrentUser records accountDeleted for that uid before the '
        'delete, consumed once', () async {
      SessionEnd? seenDuringDelete;
      when(user.delete).thenAnswer((_) async {
        // Firebase may emit the null user before delete() returns.
        seenDuringDelete = repo.takeSessionEndIntent('uid-1');
      });
      await repo.deleteCurrentUser();
      expect(seenDuringDelete, SessionEnd.accountDeleted);
      expect(repo.takeSessionEndIntent('uid-1'), isNull);
    });

    test('a failed delete withdraws the record', () async {
      when(user.delete).thenThrow(fb.FirebaseAuthException(code: 'network'));
      await expectLater(repo.deleteCurrentUser(), throwsA(anything));
      expect(repo.takeSessionEndIntent('uid-1'), isNull);
    });

    test('the record is bound to its uid and consumed by any end', () {
      repo.noteAccountDeleted('uid-1');
      expect(repo.takeSessionEndIntent('uid-2'), isNull);
      expect(
        repo.takeSessionEndIntent('uid-1'),
        isNull,
        reason: 'consumed by the first end it was asked about',
      );
      repo.noteAccountDeleted('uid-1');
      repo.clearAccountDeleted('uid-2');
      expect(repo.takeSessionEndIntent('uid-1'), SessionEnd.accountDeleted);
    });

    test('an accepted deletion (noteAccountDeleted) is handed to the '
        'listener at once (the vault journals the wipe); the client '
        'delete\'s own provisional record is not', () async {
      final heard = <String>[];
      repo.onAccountDeleted = heard.add;
      when(user.delete).thenThrow(fb.FirebaseAuthException(code: 'network'));
      await expectLater(repo.deleteCurrentUser(), throwsA(anything));
      expect(heard, isEmpty);
      repo.noteAccountDeleted('uid-1');
      expect(heard, ['uid-1']);
    });
  });

  group('signUpWithEmail', () {
    test('a failed first verification email does not fail sign-up', () async {
      final credential = _MockUserCredential();
      final user = _MockUser();
      when(
        () => firebaseAuth.createUserWithEmailAndPassword(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => credential);
      when(() => credential.user).thenReturn(user);
      when(user.sendEmailVerification)
          .thenThrow(fb.FirebaseAuthException(code: 'too-many-requests'));
      await AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
      ).signUpWithEmail(email: 'new@example.com', password: 'longpassword1');
      verify(user.sendEmailVerification).called(1);
    });
  });

  group('password reset', () {
    AuthRepository repo() =>
        AuthRepository(firebaseAuth: firebaseAuth, googleSignIn: googleSignIn);

    test(
      'sends a reset email through Firebase using a trimmed address',
      () async {
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenAnswer((_) async {});
        await repo().sendPasswordResetEmail(' person@example.com ');
        verify(
          () =>
              firebaseAuth.sendPasswordResetEmail(email: 'person@example.com'),
        ).called(1);
      },
    );

    test('unknown addresses have the same success result', () async {
      when(
        () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
      ).thenThrow(fb.FirebaseAuthException(code: 'user-not-found'));
      await repo().sendPasswordResetEmail('person@example.com');
    });

    test('network and rate-limit failures remain actionable', () async {
      for (final entry in {
        'network-request-failed': const AuthFailure.network(),
        'too-many-requests': const AuthFailure.tooManyRequests(),
      }.entries) {
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenThrow(fb.FirebaseAuthException(code: entry.key));
        await expectLater(
          repo().sendPasswordResetEmail('person@example.com'),
          throwsA(entry.value),
        );
      }
    });

    test('every other Firebase code is the neutral success, never a raw '
        'message', () async {
      for (final code in [
        'user-not-found',
        'user-disabled',
        'invalid-email',
        'missing-email',
        'internal-error',
        'operation-not-allowed',
        'some-new-code',
      ]) {
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenThrow(
          fb.FirebaseAuthException(code: code, message: 'raw $code detail'),
        );
        // A fresh repository per code: no cooldown carried between them.
        await expectLater(
          repo().sendPasswordResetEmail('person@example.com'),
          completes,
          reason: code,
        );
      }
    });

    group('cooldown', () {
      late DateTime now;
      late AuthRepository repository;

      setUp(() {
        now = DateTime.now();
        repository = AuthRepository(
          firebaseAuth: firebaseAuth,
          googleSignIn: googleSignIn,
          clock: () => now,
        );
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenAnswer((_) async {});
      });

      test('a repeat for the same address inside 60 s is a neutral success '
          'without a second email', () async {
        await repository.sendPasswordResetEmail('person@example.com');
        now = now.add(const Duration(seconds: 59));
        await repository.sendPasswordResetEmail(' Person@Example.com ');
        verify(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).called(1);

        now = now.add(const Duration(seconds: 1));
        await repository.sendPasswordResetEmail('person@example.com');
        verify(
          () =>
              firebaseAuth.sendPasswordResetEmail(email: 'person@example.com'),
        ).called(1);
      });

      test('another address is not held back', () async {
        await repository.sendPasswordResetEmail('a@example.com');
        await repository.sendPasswordResetEmail('b@example.com');
        verify(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).called(2);
      });

      test('a neutral (unknown account) answer starts the cooldown too, so '
          'known and unknown addresses look alike', () async {
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenThrow(fb.FirebaseAuthException(code: 'user-not-found'));
        await repository.sendPasswordResetEmail('nobody@example.com');
        await repository.sendPasswordResetEmail('nobody@example.com');
        verify(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).called(1);
      });

      test('a network or throttle failure does not start it', () async {
        for (final code in ['network-request-failed', 'too-many-requests']) {
          when(
            () =>
                firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
          ).thenThrow(fb.FirebaseAuthException(code: code));
          await expectLater(
            repository.sendPasswordResetEmail('person@example.com'),
            throwsA(isA<AuthFailure>()),
          );
        }
        when(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).thenAnswer((_) async {});
        await repository.sendPasswordResetEmail('person@example.com');
        verify(
          () => firebaseAuth.sendPasswordResetEmail(email: any(named: 'email')),
        ).called(3);
      });
    });
  });

  group('signInWithGoogle on web', () {
    AuthRepository repo() => AuthRepository(
      firebaseAuth: firebaseAuth,
      googleSignIn: googleSignIn,
      isWeb: true,
    );

    test('uses the Firebase popup and never touches google_sign_in', () async {
      when(() => firebaseAuth.signInWithPopup(any()))
          .thenAnswer((_) async => _MockUserCredential());

      await repo().signInWithGoogle(webClientId: 'web-client');

      final captured = verify(() => firebaseAuth.signInWithPopup(captureAny()))
          .captured;
      expect(captured.single, isA<fb.GoogleAuthProvider>());
      verifyZeroInteractions(googleSignIn);
    });

    test('closing the popup maps to AuthFailure.cancelled', () async {
      when(() => firebaseAuth.signInWithPopup(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'popup-closed-by-user'));

      await expectLater(
        repo().signInWithGoogle(),
        throwsA(const AuthFailure.cancelled()),
      );
    });

    test('a blocked popup explains how to fix it', () async {
      when(() => firebaseAuth.signInWithPopup(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'popup-blocked'));

      await expectLater(
        repo().signInWithGoogle(),
        throwsA(
          isA<AuthUnknown>().having(
            (f) => f.message,
            'message',
            contains('pop-ups'),
          ),
        ),
      );
    });
  });

  group('Google Sign-In client ids per platform', () {
    Future<void> signIn(TargetPlatform platform) async {
      final account = _MockGoogleSignInAccount();
      when(
        () => googleSignIn.initialize(
          clientId: any(named: 'clientId'),
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenAnswer((_) async {});
      when(() => googleSignIn.supportsAuthenticate()).thenReturn(true);
      when(() => googleSignIn.authenticate()).thenAnswer((_) async => account);
      when(() => account.authentication).thenReturn(
        const GoogleSignInAuthentication(idToken: 'google-id-token'),
      );
      when(() => firebaseAuth.signInWithCredential(any()))
          .thenAnswer((_) async => _MockUserCredential());
      await AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        googleIosClientId: 'ios-client.apps.googleusercontent.com',
        isWeb: false,
        platform: platform,
      ).signInWithGoogle(webClientId: 'web-client');
    }

    test('iOS initializes Google Sign-In with the iOS clientId', () async {
      await signIn(TargetPlatform.iOS);
      verify(
        () => googleSignIn.initialize(
          clientId: 'ios-client.apps.googleusercontent.com',
          serverClientId: 'web-client',
        ),
      ).called(1);
    });

    test('Android never receives the iOS clientId', () async {
      await signIn(TargetPlatform.android);
      verify(() => googleSignIn.initialize(serverClientId: 'web-client'))
          .called(1);
      verifyNever(
        () => googleSignIn.initialize(
          clientId: any(named: 'clientId'),
          serverClientId: any(named: 'serverClientId'),
        ),
      );
    });
  });

  group('signInWithGoogle on mobile', () {
    test('passes the web client id as serverClientId and signs in to '
        'Firebase with the Google ID token', () async {
      final account = _MockGoogleSignInAccount();
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenAnswer((_) async {});
      when(() => googleSignIn.supportsAuthenticate()).thenReturn(true);
      when(() => googleSignIn.authenticate()).thenAnswer((_) async => account);
      when(() => account.authentication).thenReturn(
        const GoogleSignInAuthentication(idToken: 'google-id-token'),
      );
      when(() => firebaseAuth.signInWithCredential(any()))
          .thenAnswer((_) async => _MockUserCredential());

      await AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        isWeb: false,
      ).signInWithGoogle(webClientId: 'prod-web-client');

      verify(() => googleSignIn.initialize(serverClientId: 'prod-web-client'))
          .called(1);
      final credential =
          verify(() => firebaseAuth.signInWithCredential(captureAny()))
                  .captured
                  .single
              as fb.AuthCredential;
      expect(credential.providerId, 'google.com');
      verifyNever(() => firebaseAuth.signInWithPopup(any()));
    });
  });

  group('reauthenticate', () {
    late _MockUser user;

    void stubProviders(String id) {
      final i = _MockUserInfo();
      when(() => i.providerId).thenReturn(id);
      when(() => user.providerData).thenReturn([i]);
    }

    AuthRepository repo({bool isWeb = false}) => AuthRepository(
      firebaseAuth: firebaseAuth,
      googleSignIn: googleSignIn,
      isWeb: isWeb,
    );

    setUp(() {
      user = _MockUser();
      when(() => firebaseAuth.currentUser).thenReturn(user);
      when(() => user.email).thenReturn('a@b.c');
      when(() => user.getIdToken(true)).thenAnswer((_) async => 'fresh');
    });

    test('password: prompts, re-authenticates, then force-refreshes the '
        'token', () async {
      stubProviders('password');
      when(() => user.reauthenticateWithCredential(any()))
          .thenAnswer((_) async => _MockUserCredential());

      final result = await repo().reauthenticate(
        promptPassword: () async => 'pw',
      );

      expect(result.appleAuthorizationCode, isNull);
      verifyInOrder([
        () => user.reauthenticateWithCredential(any()),
        () => user.getIdToken(true),
      ]);
    });

    test(
      'password: a dismissed prompt is cancelled and sends nothing',
      () async {
        stubProviders('password');

        await expectLater(
          repo().reauthenticate(promptPassword: () async => null),
          throwsA(const AuthFailure.cancelled()),
        );
        verifyNever(() => user.reauthenticateWithCredential(any()));
        verifyNever(() => user.getIdToken(true));
      },
    );

    test('google on web uses the popup', () async {
      stubProviders('google.com');
      when(() => user.reauthenticateWithPopup(any()))
          .thenAnswer((_) async => _MockUserCredential());

      await repo(isWeb: true).reauthenticate(promptPassword: () async => null);

      verify(() => user.reauthenticateWithPopup(any())).called(1);
      verify(() => user.getIdToken(true)).called(1);
    });

    test('closing the web popup maps to cancelled', () async {
      stubProviders('google.com');
      when(() => user.reauthenticateWithPopup(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'popup-closed-by-user'));

      await expectLater(
        repo(isWeb: true).reauthenticate(promptPassword: () async => null),
        throwsA(const AuthFailure.cancelled()),
      );
    });

    test('google on mobile re-authenticates with the Google credential and '
        'the configured web client id', () async {
      stubProviders('google.com');
      final account = _MockGoogleSignInAccount();
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenAnswer((_) async {});
      when(() => googleSignIn.supportsAuthenticate()).thenReturn(true);
      when(() => googleSignIn.authenticate()).thenAnswer((_) async => account);
      when(() => account.authentication)
          .thenReturn(const GoogleSignInAuthentication(idToken: 'tok'));
      when(() => user.reauthenticateWithCredential(any()))
          .thenAnswer((_) async => _MockUserCredential());

      await AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        googleWebClientId: 'prod-web',
        isWeb: false,
      ).reauthenticate(promptPassword: () async => null);

      verify(() => googleSignIn.initialize(serverClientId: 'prod-web'))
          .called(1);
      verify(() => user.reauthenticateWithCredential(any())).called(1);
      verify(() => user.getIdToken(true)).called(1);
    });

    test('a cancelled Google sheet maps to cancelled', () async {
      stubProviders('google.com');
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenAnswer((_) async {});
      when(() => googleSignIn.supportsAuthenticate()).thenReturn(true);
      when(() => googleSignIn.authenticate()).thenThrow(
        const GoogleSignInException(code: GoogleSignInExceptionCode.canceled),
      );

      await expectLater(
        repo().reauthenticate(promptPassword: () async => null),
        throwsA(const AuthFailure.cancelled()),
      );
    });

    test('a blocked web popup explains how to fix it', () async {
      stubProviders('google.com');
      when(() => user.reauthenticateWithPopup(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'popup-blocked'));

      await expectLater(
        repo(isWeb: true).reauthenticate(promptPassword: () async => null),
        throwsA(
          isA<AuthUnknown>().having(
            (f) => f.message,
            'message',
            contains('pop-ups'),
          ),
        ),
      );
    });

    test('a wrong password maps to invalidCredentials', () async {
      stubProviders('password');
      when(() => user.reauthenticateWithCredential(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'wrong-password'));

      await expectLater(
        repo().reauthenticate(promptPassword: () async => 'bad'),
        throwsA(const AuthFailure.invalidCredentials()),
      );
    });

    test(
      'a PlatformException becomes a friendly AuthFailure.unknown',
      () async {
        stubProviders('google.com');
        when(
          () => googleSignIn.initialize(
            serverClientId: any(named: 'serverClientId'),
          ),
        ).thenThrow(PlatformException(code: 'channel-error', message: 'raw'));

        await expectLater(
          repo().reauthenticate(promptPassword: () async => null),
          throwsA(
            isA<AuthUnknown>().having(
              (f) => f.message,
              'message',
              'Sign-in failed. Please try again.',
            ),
          ),
        );
      },
    );

    test('other errors reach the caller unchanged', () async {
      stubProviders('google.com');
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenThrow(StateError('bug'));

      await expectLater(
        repo().reauthenticate(promptPassword: () async => null),
        throwsStateError,
      );
    });

    test('user-mismatch asks for the signed-in account', () async {
      stubProviders('password');
      when(() => user.reauthenticateWithCredential(any()))
          .thenThrow(fb.FirebaseAuthException(code: 'user-mismatch'));

      await expectLater(
        repo().reauthenticate(promptPassword: () async => 'pw'),
        throwsA(
          isA<AuthUnknown>().having(
            (f) => f.message,
            'message',
            contains('signed in with'),
          ),
        ),
      );
    });

    test('reauthNeedsGesture is true only on web', () {
      expect(repo(isWeb: true).reauthNeedsGesture, isTrue);
      expect(repo().reauthNeedsGesture, isFalse);
    });

    group('canSkipDeleteReauth', () {
      final now = DateTime.now();
      late _MockUserMetadata meta;

      AuthRepository clocked() => AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        clock: () => now,
      );

      void signedIn(String provider, Duration ago) {
        stubProviders(provider);
        meta = _MockUserMetadata();
        when(() => meta.lastSignInTime).thenReturn(now.subtract(ago));
        when(() => user.metadata).thenReturn(meta);
      }

      test('google: true inside the window, false outside it', () {
        signedIn('google.com', const Duration(minutes: 1));
        expect(clocked().canSkipDeleteReauth, isTrue);
        signedIn('google.com', const Duration(minutes: 4));
        expect(clocked().canSkipDeleteReauth, isFalse);
      });

      test('apple and password never skip', () {
        signedIn('apple.com', const Duration(seconds: 5));
        expect(clocked().canSkipDeleteReauth, isFalse);
        signedIn('password', const Duration(seconds: 5));
        expect(clocked().canSkipDeleteReauth, isFalse);
      });

      test('signed out: false', () {
        when(() => firebaseAuth.currentUser).thenReturn(null);
        expect(clocked().canSkipDeleteReauth, isFalse);
      });
    });

    group('Apple code gate', () {
      const channel = MethodChannel(
        'com.aboutyou.dart_packages.sign_in_with_apple',
      );

      setUp(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              return <String, dynamic>{
                'type': 'appleid',
                'authorizationCode': 'apple-code',
                'identityToken': 'id-token',
              };
            });
        stubProviders('apple.com');
        when(() => user.reauthenticateWithCredential(any()))
            .thenAnswer((_) async => _MockUserCredential());
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      Future<ReauthResult> run(TargetPlatform platform) => AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        isWeb: false,
        platform: platform,
      ).reauthenticate(promptPassword: () async => null);

      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        test('$platform returns the code', () async {
          final result = await run(platform);
          expect(result.appleAuthorizationCode, 'apple-code');
        });
      }

      test('android returns no code', () async {
        final result = await run(TargetPlatform.android);
        expect(result.appleAuthorizationCode, isNull);
      });

      test(
        'the Firebase credential never carries the single-use code',
        () async {
          await run(TargetPlatform.iOS);

          final credential =
              verify(() => user.reauthenticateWithCredential(captureAny()))
                      .captured
                      .single
                  as fb.AuthCredential;
          expect(credential.providerId, 'apple.com');
          expect(credential.accessToken, isNull);
        },
      );
    });

    test('revokeAppleToken forwards the authorization code', () async {
      when(() => firebaseAuth.revokeTokenWithAuthorizationCode('c'))
          .thenAnswer((_) async {});

      await repo().revokeAppleToken('c');

      verify(() => firebaseAuth.revokeTokenWithAuthorizationCode('c'))
          .called(1);
    });
  });
}
