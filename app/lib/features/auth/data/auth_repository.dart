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

/// Outcome of [AuthRepository.reauthenticate].
class ReauthResult {
  const ReauthResult({this.appleAuthorizationCode});

  /// Set after a native Apple re-auth; hand it to
  /// [AuthRepository.revokeAppleToken].
  final String? appleAuthorizationCode;
}

/// Wraps Firebase Auth + Google Sign-In + Sign in with Apple behind one
/// interface. No phone/SMS auth (CLAUDE.md, ADR-0006): the sign-in surface is
/// intentionally limited to email/password, Google and Apple.
///
/// Also implements [AuthTokenProvider] so `core/network/api_client.dart` can
/// attach a fresh Firebase ID token to every API call without depending on
/// this feature package for anything but that one method.
class AuthRepository implements AuthTokenProvider {
  AuthRepository({
    fb.FirebaseAuth? firebaseAuth,
    GoogleSignIn? googleSignIn,
    this.googleWebClientId,
    this.appleServiceId,
    this.appleRedirectUri,
    @visibleForTesting bool isWeb = kIsWeb,
    @visibleForTesting TargetPlatform? platform,
  }) : _firebaseAuth = firebaseAuth ?? fb.FirebaseAuth.instance,
       _googleSignIn = googleSignIn ?? GoogleSignIn.instance,
       _isWeb = isWeb,
       _platform = platform ?? defaultTargetPlatform;

  /// Provider configuration of this build (from `AppConfig`): the one source
  /// for sign-in and re-authentication. [googleWebClientId] is the Web OAuth
  /// client of the build's Firebase project; [appleServiceId] and
  /// [appleRedirectUri] drive Apple's web flow (web and Android).
  final String? googleWebClientId;
  final String? appleServiceId;
  final String? appleRedirectUri;
  final TargetPlatform _platform;

  String? get _googleClientId =>
      (googleWebClientId == null || googleWebClientId!.isEmpty)
      ? null
      : googleWebClientId;

  WebAuthenticationOptions? get _appleWebOptions {
    final id = appleServiceId;
    final uri = appleRedirectUri;
    if (id == null || id.isEmpty || uri == null || uri.isEmpty) return null;
    return WebAuthenticationOptions(clientId: id, redirectUri: Uri.parse(uri));
  }

  final fb.FirebaseAuth _firebaseAuth;
  final GoogleSignIn _googleSignIn;
  final bool _isWeb;
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

  Future<void> _ensureGoogleInitialized({String? serverClientId}) async {
    if (_googleInitialized) return;
    await _googleSignIn.initialize(
      serverClientId: (serverClientId == null || serverClientId.isEmpty)
          ? null
          : serverClientId,
    );
    _googleInitialized = true;
  }

  /// Web: Firebase Auth's own popup. google_sign_in 7 can't sign in
  /// programmatically on web (`supportsAuthenticate()` is false there; it only
  /// supports Google's rendered button).
  ///
  /// Mobile: google_sign_in, then a Firebase credential from its ID token.
  /// [webClientId] (this build's Firebase project's Web OAuth client) is passed
  /// as `serverClientId`, so the ID token is issued for the project the build
  /// targets. Without it, Android falls back to the checked-in (dev)
  /// google-services.json, and prod Firebase would reject the token.
  Future<void> signInWithGoogle({String? webClientId}) async {
    if (_isWeb) {
      try {
        await _firebaseAuth.signInWithPopup(fb.GoogleAuthProvider());
      } on fb.FirebaseAuthException catch (e) {
        throw _mapFirebaseAuthException(e);
      }
      return;
    }
    try {
      await _ensureGoogleInitialized(
        serverClientId: webClientId ?? _googleClientId,
      );
      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthFailure.unknown(
          'Google sign-in is not supported on this platform.',
        );
      }
      final account = await _googleSignIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthFailure.unknown(
          'Google sign-in did not return a token.',
        );
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
        webAuthenticationOptions: webOptions ?? _appleWebOptions,
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

  /// Re-authenticates the signed-in user with the provider they signed in
  /// with, then forces an ID-token refresh so the next API call carries a
  /// fresh `auth_time` (needed by sensitive RPCs such as DeleteAccount).
  ///
  /// - Google / Apple: provider flow (web: popup).
  /// - Password: [promptPassword] asks the user; null or empty means they
  ///   cancelled.
  ///
  /// Throws [AuthFailure.cancelled] when the user backs out; nothing is sent
  /// to the API in that case. Returns the Apple authorization code (native
  /// Apple flow only) so the caller can revoke it, see [revokeAppleToken].
  Future<ReauthResult> reauthenticate({
    required Future<String?> Function() promptPassword,
  }) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw const AuthFailure.unknown('You are signed out.');
    }
    final providers = user.providerData.map((p) => p.providerId).toSet();
    String? appleCode;
    try {
      if (providers.contains('google.com')) {
        if (_isWeb) {
          await user.reauthenticateWithPopup(fb.GoogleAuthProvider());
        } else {
          await _ensureGoogleInitialized(serverClientId: _googleClientId);
          if (!_googleSignIn.supportsAuthenticate()) {
            throw const AuthFailure.unknown(
              'Google sign-in is not supported on this platform.',
            );
          }
          final account = await _googleSignIn.authenticate();
          final idToken = account.authentication.idToken;
          if (idToken == null) {
            throw const AuthFailure.unknown(
              'Google sign-in did not return a token.',
            );
          }
          await user.reauthenticateWithCredential(
            fb.GoogleAuthProvider.credential(idToken: idToken),
          );
        }
      } else if (providers.contains('apple.com')) {
        if (_isWeb) {
          await user.reauthenticateWithPopup(fb.OAuthProvider('apple.com'));
        } else {
          final rawNonce = _generateNonce();
          final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
          final apple = await SignInWithApple.getAppleIDCredential(
            scopes: const [AppleIDAuthorizationScopes.email],
            nonce: hashedNonce,
            webAuthenticationOptions: _appleWebOptions,
          );
          // Only the native iOS/macOS code can be revoked (the Android/web
          // service-id flow belongs to another client). It is single use, so
          // it is deliberately NOT passed as `accessToken` to Firebase here.
          if (_platform == TargetPlatform.iOS ||
              _platform == TargetPlatform.macOS) {
            appleCode = apple.authorizationCode;
          }
          await user.reauthenticateWithCredential(
            fb.OAuthProvider('apple.com')
                .credential(idToken: apple.identityToken, rawNonce: rawNonce),
          );
        }
      } else if (providers.contains('password')) {
        final email = user.email;
        if (email == null) {
          throw const AuthFailure.unknown('This account has no email.');
        }
        final password = await promptPassword();
        if (password == null || password.isEmpty) {
          throw const AuthFailure.cancelled();
        }
        await user.reauthenticateWithCredential(
          fb.EmailAuthProvider.credential(email: email, password: password),
        );
      } else {
        throw const AuthFailure.unknown(
          'This sign-in method cannot be re-confirmed.',
        );
      }
      await user.getIdToken(true);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthFailure.cancelled();
      }
      throw AuthFailure.unknown(e.description ?? e.code.toString());
    } on AuthFailure {
      rethrow;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AuthFailure.cancelled();
      }
      throw AuthFailure.unknown(e.message);
    } on SignInWithAppleException catch (e) {
      // Includes SignInWithAppleNotSupportedException (e.g. no web options).
      throw AuthFailure.unknown(e.toString());
    } on fb.FirebaseAuthException catch (e) {
      throw _mapFirebaseAuthException(e);
    } catch (e) {
      // Platform channel / plugin errors: never leave the caller hanging.
      throw AuthFailure.unknown(e.toString());
    }
    return ReauthResult(appleAuthorizationCode: appleCode);
  }

  /// Revokes the Sign in with Apple token (Apple's account-deletion rule,
  /// plan Q7). Call after an Apple [reauthenticate], before DeleteAccount.
  Future<void> revokeAppleToken(String authorizationCode) async {
    try {
      await _firebaseAuth.revokeTokenWithAuthorizationCode(authorizationCode);
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
      // Web popup sign-in (signInWithPopup).
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
      case 'user-cancelled':
        return const AuthFailure.cancelled();
      case 'popup-blocked':
        return const AuthFailure.unknown(
          'Your browser blocked the sign-in window. Allow pop-ups for '
          'this site and try again.',
        );
      case 'account-exists-with-different-credential':
        return const AuthFailure.unknown(
          'An account with this email already exists. Sign in with your '
          'email and password instead.',
        );
      default:
        return AuthFailure.unknown(e.message ?? e.code);
    }
  }
}
