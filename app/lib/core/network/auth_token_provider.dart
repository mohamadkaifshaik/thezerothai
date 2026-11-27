/// Supplies the two tokens every API call must carry:
/// the Firebase ID token (`Authorization: Bearer`) and the Firebase App
/// Check token (`X-Firebase-AppCheck`).
///
/// Implemented by `features/auth`'s `AuthRepository` and by App Check setup
/// in `app/bootstrap.dart`; injected into [ApiClient] so `core/network` never
/// depends on a feature package.
abstract interface class AuthTokenProvider {
  /// The current user's Firebase ID token, refreshing it if it is close to
  /// expiry. Returns null when signed out.
  Future<String?> getIdToken();

  /// Forces a new ID token from the auth SDK (`getIdToken(true)`), so the
  /// next [getIdToken] answers it. Used once per burst of SESSION_ENDED
  /// answers (`SessionEndedInterceptor`, removal design SA L1).
  ///
  /// Remover copy fix round 1 (R1): never signs out. A refresh the SDK
  /// refuses because the sign-in is dead (revoked, disabled or deleted)
  /// throws [DeadSignInException], so the caller can tell it from a network
  /// failure.
  Future<String?> refreshIdToken();

  /// The server refused [uid]'s session with SESSION_ENDED, and again after a
  /// forced refresh: a device was removed from the account on another
  /// device. The implementation signs [uid] out as a lost session (the vault
  /// is kept). Called at most once per burst.
  void reportSessionEnded(String uid);
}

/// What [AuthTokenProvider.refreshIdToken] throws when the auth SDK says the
/// sign-in can never be refreshed again (its refresh token was revoked, or
/// the user was disabled or deleted). Carries no detail on purpose.
final class DeadSignInException implements Exception {
  const DeadSignInException();
}

/// Supplies a fresh App Check token for each request.
abstract interface class AppCheckTokenProvider {
  Future<String?> getAppCheckToken();
}
