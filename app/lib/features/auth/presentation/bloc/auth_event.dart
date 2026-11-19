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
/// [uid] is the account the intent was EXPRESSED for (captured where the
/// person tapped). The intent is armed only when that account is still the
/// one signed in when the event is handled: a tab that switched users in the
/// meantime never turns another account's end into a wipe. Without a [uid]
/// the intent binds to whoever is signed in at handling time; every caller
/// in the app passes one. Value equality, so tests can verify the uid.
final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested({this.reason = SessionEnd.userSignedOut, this.uid})
    : assert(reason != SessionEnd.sessionLost);
  final SessionEnd reason;
  final String? uid;

  @override
  bool operator ==(Object other) =>
      other is AuthSignOutRequested &&
      other.reason == reason &&
      other.uid == uid;

  @override
  int get hashCode => Object.hash(reason, uid);
}

/// Clears a transient [AuthState.failure] after the UI has shown it.
final class AuthFailureDismissed extends AuthEvent {
  const AuthFailureDismissed();
}
