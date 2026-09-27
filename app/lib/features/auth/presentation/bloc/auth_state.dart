import 'package:freezed_annotation/freezed_annotation.dart';

import '../../domain/app_user.dart';
import '../../domain/auth_failure.dart';

part 'auth_state.freezed.dart';

enum AuthStatus {
  /// Firebase hasn't reported the initial auth state yet. Show a splash.
  unknown,
  unauthenticated,

  /// Signed in with email/password but the address hasn't been confirmed.
  needsEmailVerification,
  authenticated,
}

@freezed
abstract class AuthState with _$AuthState {
  const factory AuthState({
    @Default(AuthStatus.unknown) AuthStatus status,
    AppUser? user,
    @Default(false) bool isSubmitting,
    AuthFailure? failure,
  }) = _AuthState;

  const AuthState._();

  bool get isAuthenticated => status == AuthStatus.authenticated;
}
