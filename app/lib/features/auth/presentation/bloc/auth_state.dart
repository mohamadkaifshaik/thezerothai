import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/session/session_end.dart';
import '../../domain/app_user.dart';

export '../../../../core/session/session_end.dart' show SessionEnd;
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

    /// How the last signed-in session ended: [SessionEnd.userSignedOut]
    /// after an `AuthSignOutRequested`, [SessionEnd.accountDeleted] after the
    /// account-deletion flow, [SessionEnd.sessionLost] for every other
    /// transition to no user (an auth stream error included). Set in the
    /// same state that drops the user; null until a session has ended.
    SessionEnd? lastSessionEnd,
  }) = _AuthState;

  const AuthState._();

  bool get isAuthenticated => status == AuthStatus.authenticated;
}
