import '../../domain/app_user.dart';

sealed class AuthEvent {
  const AuthEvent();
}

/// Starts listening to Firebase's auth state. Dispatched once at app start.
final class AuthSubscriptionRequested extends AuthEvent {
  const AuthSubscriptionRequested();
}

/// Internal: the Firebase auth state changed (sign-in, sign-out, reload).
final class AuthUserChanged extends AuthEvent {
  const AuthUserChanged(this.user);
  final AppUser? user;
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

final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

/// Clears a transient [AuthState.failure] after the UI has shown it.
final class AuthFailureDismissed extends AuthEvent {
  const AuthFailureDismissed();
}
