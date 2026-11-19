import '../../../../core/session/session_end.dart';
import '../../domain/app_user.dart';

export '../../../../core/session/session_end.dart' show SessionEnd;

sealed class AuthEvent {
  const AuthEvent();
}

/// Starts listening to Firebase's auth state. Dispatched once at app start.
final class AuthSubscriptionRequested extends AuthEvent {
  const AuthSubscriptionRequested();
}

/// Internal: the Firebase auth state changed (sign-in, sign-out, reload).
final class AuthUserChanged extends AuthEvent {
  const AuthUserChanged(this.user, {this.fromStreamError = false});
  final AppUser? user;

  /// The auth stream failed (the user is then null): always a lost session,
  /// never an explicit sign-out.
  final bool fromStreamError;
}

final class AuthEmailSignUpRequested extends AuthEvent {
  const AuthEmailSignUpRequested({required this.email, required this.password});
  final String email;
  final String password;
}

final class AuthEmailSignInRequested extends AuthEvent {
  const AuthEmailSignInRequested({required this.email, required this.password});
  final String email;
  final String password;
}

final class AuthGoogleSignInRequested extends AuthEvent {
  const AuthGoogleSignInRequested();
}

final class AuthAppleSignInRequested extends AuthEvent {
  const AuthAppleSignInRequested();
}

final class AuthEmailVerificationResendRequested extends AuthEvent {
  const AuthEmailVerificationResendRequested();
}

/// The user tapped "I've verified my email" on the verification prompt.
final class AuthEmailVerificationCheckRequested extends AuthEvent {
  const AuthEmailVerificationCheckRequested();
}

/// The explicit intent to leave the account. [reason] is
/// [SessionEnd.userSignedOut] for "Sign out" and [SessionEnd.accountDeleted]
/// for the sign-out the account-deletion flow does; either wipes the
/// encrypted vault.
///
/// [uid] is the account the request was EXPRESSED for (captured where the
/// person tapped). When another account is signed in by the time the event
/// is handled, the request is dropped: nobody is signed out and nothing is
/// armed, so a tab that switched users never turns another account's end
/// into a wipe. When NOBODY is signed in it still runs the sign-out (push
/// unregister, provider sign-out) and arms nothing. Without a [uid] the intent binds to whoever is signed in at
/// handling time; every arming caller in the app passes one. Value
/// equality, so tests can verify the uid.
final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested({
    this.reason = SessionEnd.userSignedOut,
    this.uid,
    this.arm = true,
  }) : assert(reason != SessionEnd.sessionLost);
  final SessionEnd reason;
  final String? uid;

  /// False for a sign-out that must NOT be treated as an explicit end (the
  /// account-deleted page reached without knowing which account was
  /// deleted): the user is signed out, but no intent is armed and no
  /// explicit hook runs, so the vault treats it as a lost session (kept).
  final bool arm;

  @override
  bool operator ==(Object other) =>
      other is AuthSignOutRequested &&
      other.reason == reason &&
      other.uid == uid &&
      other.arm == arm;

  @override
  int get hashCode => Object.hash(reason, uid, arm);
}

/// Clears a transient [AuthState.failure] after the UI has shown it.
final class AuthFailureDismissed extends AuthEvent {
  const AuthFailureDismissed();
}
