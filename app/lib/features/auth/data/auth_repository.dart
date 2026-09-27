import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/network/auth_token_provider.dart';
import '../domain/app_user.dart';
import '../domain/auth_failure.dart';

/// Wraps Firebase Auth + Google Sign-In + Sign in with Apple behind one
/// interface. No phone/SMS auth (CLAUDE.md, ADR-0006): the sign-in surface is
/// intentionally limited to email/password, Google and Apple.
///
/// Also implements [AuthTokenProvider] so `core/network/api_client.dart` can
/// attach a fresh Firebase ID token to every API call without depending on
/// this feature package for anything but that one method.
class AuthRepository implements AuthTokenProvider {
  AuthRepository({fb.FirebaseAuth? firebaseAuth, GoogleSignIn? googleSignIn})
    : _firebaseAuth = firebaseAuth ?? fb.FirebaseAuth.instance,
      _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  final fb.FirebaseAuth _firebaseAuth;
  final GoogleSignIn _googleSignIn;
  bool _googleInitialized = false;

  /// Emits the current [AppUser], or null when signed out. Uses
  /// `userChanges()` (not `authStateChanges()`) so profile reloads —
  /// e.g. after the user confirms email verification — are reflected too.
  Stream<AppUser?> authStateChanges() {
    return _firebaseAuth.userChanges().map(_toAppUser);
  }

  AppUser? get currentUser => _toAppUser(_firebaseAuth.currentUser);

  AppUser? _toAppUser(fb.User? user) {
    if (user == null) return null;
    final isPasswordProvider = user.providerData.any(
      (p) => p.providerId == 'password',
    );
    return AppUser(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
      emailVerified: user.emailVerified,
      isPasswordProvider: isPasswordProvider,
    );
  }

  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      await credential.user?.sendEmailVerification();
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      await _firebaseAuth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  Future<void> sendEmailVerification() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    try {
      await user.sendEmailVerification();
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  /// Re-fetches the user from Firebase so `emailVerified` reflects a recent
  /// confirmation. Call after the user taps "I've verified my email".
  Future<void> reloadUser() async {
    try {
      await _firebaseAuth.currentUser?.reload();
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  Future<void> _ensureGoogleInitialized({String? clientId}) async {
    if (_googleInitialized) return;
    await _googleSignIn.initialize(clientId: clientId);
    _googleInitialized = true;
  }

  /// [webClientId] is required on Flutter Web (the OAuth client id for this
  /// site); ignored on mobile, where native config drives sign-in.
  Future<void> signInWithGoogle({String? webClientId}) async {
    try {
      await _ensureGoogleInitialized(clientId: kIsWeb ? webClientId : null);
      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthFailure.unknown(
          'Google sign-in is not supported on this platform.',
        );
      }
      final account = await _googleSignIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthFailure.unknown('Google sign-in did not return a token.');
      }
      final credential = fb.GoogleAuthProvider.credential(idToken: idToken);
      await _firebaseAuth.signInWithCredential(credential);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthFailure.cancelled();
      }
      throw AuthFailure.unknown(e.description ?? e.code.toString());
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  /// [webOptions] must be provided on web and Android (Apple's REST-based
  /// flow), and are ignored on iOS/macOS where the native Apple ID sheet is
  /// used instead.
  Future<void> signInWithApple({WebAuthenticationOptions? webOptions}) async {
    final rawNonce = _generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    try {
      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
        webAuthenticationOptions: webOptions,
      );
      final oauthCredential = fb.OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        rawNonce: rawNonce,
        accessToken: appleCredential.authorizationCode,
      );
      await _firebaseAuth.signInWithCredential(oauthCredential);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AuthFailure.cancelled();
      }
      throw AuthFailure.unknown(e.message);
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    }
  }

  Future<void> signOut() async {
    await Future.wait([
      _firebaseAuth.signOut(),
      if (_googleInitialized) _googleSignIn.signOut(),
    ]);
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) {
    return _firebaseAuth.currentUser?.getIdToken(forceRefresh) ??
        Future.value();
  }

  static String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  AuthFailure _mapFirebaseAuthException(fb.FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-email':
        return const AuthFailure.invalidCredentials();
      case 'email-already-in-use':
        return const AuthFailure.emailAlreadyInUse();
      case 'weak-password':
        return const AuthFailure.weakPassword();
      case 'user-disabled':
        return const AuthFailure.userDisabled();
      case 'too-many-requests':
        return const AuthFailure.tooManyRequests();
      case 'requires-recent-login':
        return const AuthFailure.requiresRecentLogin();
      case 'network-request-failed':
        return const AuthFailure.network();
      default:
        return AuthFailure.unknown(e.message ?? e.code);
    }
  }
}
