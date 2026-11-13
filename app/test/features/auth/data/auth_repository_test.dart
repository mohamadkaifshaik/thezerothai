import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';

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
