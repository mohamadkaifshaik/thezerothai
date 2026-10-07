import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseAuth extends Mock implements fb.FirebaseAuth {}

class _MockGoogleSignIn extends Mock implements GoogleSignIn {}

class _MockGoogleSignInAccount extends Mock implements GoogleSignInAccount {}

class _MockUserCredential extends Mock implements fb.UserCredential {}

class _MockUser extends Mock implements fb.User {}

class _MockUserInfo extends Mock implements fb.UserInfo {}

void main() {
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
      when(
        () => account.authentication,
      ).thenReturn(const GoogleSignInAuthentication(idToken: 'tok'));
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenAnswer((_) async => _MockUserCredential());

      await AuthRepository(
        firebaseAuth: firebaseAuth,
        googleSignIn: googleSignIn,
        googleWebClientId: 'prod-web',
        isWeb: false,
      ).reauthenticate(promptPassword: () async => null);

      verify(
        () => googleSignIn.initialize(serverClientId: 'prod-web'),
      ).called(1);
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

    test('a generic platform error becomes AuthFailure.unknown', () async {
      stubProviders('google.com');
      when(
        () => googleSignIn.initialize(
          serverClientId: any(named: 'serverClientId'),
        ),
      ).thenThrow(Exception('channel error'));

      await expectLater(
        repo().reauthenticate(promptPassword: () async => null),
        throwsA(isA<AuthUnknown>()),
      );
    });

    test('a blocked web popup explains how to fix it', () async {
      stubProviders('google.com');
      when(
        () => user.reauthenticateWithPopup(any()),
      ).thenThrow(fb.FirebaseAuthException(code: 'popup-blocked'));

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
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenThrow(fb.FirebaseAuthException(code: 'wrong-password'));

      await expectLater(
        repo().reauthenticate(promptPassword: () async => 'bad'),
        throwsA(const AuthFailure.invalidCredentials()),
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
