/// Supplies the two tokens every API call must carry (ADR-0006 §2):
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
}

/// Supplies a fresh App Check token for each request.
abstract interface class AppCheckTokenProvider {
  Future<String?> getAppCheckToken();
}
