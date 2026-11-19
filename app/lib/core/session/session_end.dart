/// Why a signed-in session ended. Decides whether the encrypted vault is
/// wiped (`VaultSession.onSessionEnded`); the disposable cache is wiped the
/// same way for every reason.
enum SessionEnd {
  /// The person chose "Sign out" (an explicit `AuthSignOutRequested`). The
  /// vault and its key are wiped.
  userSignedOut,

  /// The account was deleted on this device (the account-deletion flow).
  /// The vault and its key are wiped.
  accountDeleted,

  /// Every other way to lose the user: a revoked or expired token, an auth
  /// stream error, a start-up without a restored user. The vault is kept, so
  /// the same user signing back in finds it intact.
  sessionLost,
}
