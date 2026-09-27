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
}
