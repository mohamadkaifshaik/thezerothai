import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_failure.freezed.dart';

/// Typed failures from Firebase Auth / the platform sign-in SDKs. Kept
/// separate from `core/network/app_exception.dart`'s [AppException] hierarchy
/// because these never come from our API — they come from Firebase Auth,
/// Google Sign-In or Sign in with Apple, each with their own error codes.
@freezed
sealed class AuthFailure with _$AuthFailure {
  const factory AuthFailure.invalidCredentials() = AuthInvalidCredentials;
  const factory AuthFailure.emailAlreadyInUse() = AuthEmailAlreadyInUse;
  const factory AuthFailure.weakPassword() = AuthWeakPassword;
  const factory AuthFailure.userDisabled() = AuthUserDisabled;
  const factory AuthFailure.tooManyRequests() = AuthTooManyRequests;
  const factory AuthFailure.requiresRecentLogin() = AuthRequiresRecentLogin;
  const factory AuthFailure.network() = AuthNetworkFailure;

  /// The user closed the provider's sign-in sheet/popup. Not an error worth
  /// showing.
  const factory AuthFailure.cancelled() = AuthCancelled;
  const factory AuthFailure.unknown(String message) = AuthUnknown;
}

extension AuthFailureMessage on AuthFailure {
  /// A friendly, user-facing message. Never surfaces raw SDK text except for
  /// [AuthFailure.unknown], which is best-effort.
  String get message => switch (this) {
    AuthInvalidCredentials() => 'Incorrect email or password.',
    AuthEmailAlreadyInUse() => 'An account with this email already exists.',
    AuthWeakPassword() => 'Choose a stronger password (at least 8 characters).',
    AuthUserDisabled() => 'This account has been disabled.',
    AuthTooManyRequests() => 'Too many attempts. Please wait and try again.',
    AuthRequiresRecentLogin() =>
      'Please sign in again to confirm it is you before doing this.',
    AuthNetworkFailure() => 'No connection. Check your network and try again.',
    AuthCancelled() => '',
    AuthUnknown(:final message) =>
      message.isEmpty ? 'Something went wrong. Please try again.' : message,
  };
}
