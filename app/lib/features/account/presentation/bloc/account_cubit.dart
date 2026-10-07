import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../auth/data/auth_repository.dart';
import '../../../auth/domain/auth_failure.dart';
import '../../data/account_repository.dart';

enum AccountStatus {
  idle,

  /// A call (or the re-authentication in front of it) is in flight.
  working,

  /// DeleteAccount was accepted.
  deleted,

  /// The user backed out of re-authentication. Nothing was sent.
  cancelled,

  /// Failed; see [AccountState.error] / [AccountState.authFailure].
  failed,

  /// An export was requested; see [AccountState.export].
  exportRequested,
}

@immutable
class AccountState {
  const AccountState({
    this.status = AccountStatus.idle,
    this.error,
    this.authFailure,
    this.export,
  });

  final AccountStatus status;
  final AppException? error;
  final AuthFailure? authFailure;
  final AccountExport? export;

  @override
  bool operator ==(Object other) =>
      other is AccountState &&
      other.status == status &&
      other.error == error &&
      other.authFailure == authFailure &&
      other.export == export;

  @override
  int get hashCode => Object.hash(status, error, authFailure, export);
}

/// Asks the user for their password (password accounts only); null means
/// they dismissed the prompt.
typedef PasswordPrompt = Future<String?> Function();

/// Drives DeleteAccount and RequestAccountExport.
///
/// - One idempotency key per intent: generated on the first attempt and
///   reused on every retry; cleared only on success.
/// - [deleteAccount] re-authenticates UP FRONT (re-auth, then Apple token
///   revoke on iOS/macOS, then DeleteAccount), starting synchronously so a
///   web popup opens inside the tap's user gesture. Normal path: exactly one
///   DeleteAccount. A `REAUTH_REQUIRED` anyway (clock skew) gets one
///   re-auth + one retry with the same key, never a loop.
/// - [requestExport] only re-authenticates on `REAUTH_REQUIRED`, never
///   revokes the Apple token (that is delete-only).
/// - A cancelled re-authentication sends no RPC.
/// - The cubit never stays in `working`: every path ends in a terminal
///   state, and [reset] frees a flow stuck behind a provider UI that never
///   returned.
class AccountCubit extends Cubit<AccountState> {
  AccountCubit({
    required AccountRepository accountRepository,
    required AuthRepository authRepository,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Uuid? uuid,
  }) : _accounts = accountRepository,
       _auth = authRepository,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       super(const AccountState());

  final AccountRepository _accounts;
  final AuthRepository _auth;

  /// Crashlytics non-fatal hook for unexpected errors (never pass URLs).
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Uuid _uuid;

  String? _deleteKey;
  String? _exportKey;

  /// Bumped by [reset]; results of an abandoned flow are dropped.
  int _generation = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  /// True while a DeleteAccount RPC is on the wire: its result must not be
  /// dropped (an accepted deletion has to be recorded), so [reset] waits.
  bool _rpcInFlight = false;

  /// Abandons an in-flight flow (e.g. the user left the screen or a provider
  /// UI never returned) and returns to idle. The idempotency keys are kept.
  /// A no-op while the DeleteAccount RPC is in flight.
  void reset() {
    if (isClosed || _rpcInFlight) return;
    _generation++;
    emit(const AccountState());
  }

  /// Call straight from the tap handler: no `await` runs before the
  /// re-authentication starts.
  Future<void> deleteAccount({required PasswordPrompt promptPassword}) async {
    if (isClosed || state.status == AccountStatus.working) return;
    final generation = ++_generation;
    final key = _deleteKey ??= _uuid.v4();
    emit(const AccountState(status: AccountStatus.working));
    try {
      await _reauthenticate(promptPassword, revokeApple: true);
      if (_stale(generation)) return;
      await _withReauth(
        () async {
          _rpcInFlight = true;
          try {
            return await _accounts.deleteAccount(idempotencyKey: key);
          } finally {
            _rpcInFlight = false;
          }
        },
        promptPassword,
        generation,
        revokeApple: true,
      );
      if (_stale(generation)) return;
      _deleteKey = null;
      emit(const AccountState(status: AccountStatus.deleted));
    } catch (error, stack) {
      _fail(generation, error, stack);
    }
  }

  Future<void> requestExport({required PasswordPrompt promptPassword}) async {
    if (isClosed || state.status == AccountStatus.working) return;
    final generation = ++_generation;
    final key = _exportKey ??= _uuid.v4();
    emit(const AccountState(status: AccountStatus.working));
    try {
      final export = await _withReauth(
        () => _accounts.requestExport(idempotencyKey: key),
        promptPassword,
        generation,
        revokeApple: false,
      );
      if (_stale(generation)) return;
      _exportKey = null;
      emit(AccountState(status: AccountStatus.exportRequested, export: export));
    } catch (error, stack) {
      _fail(generation, error, stack);
    }
  }

  /// Runs [call]; on [ReauthRequiredException] re-authenticates once and
  /// retries once.
  Future<T> _withReauth<T>(
    Future<T> Function() call,
    PasswordPrompt promptPassword,
    int generation, {
    required bool revokeApple,
  }) async {
    try {
      return await call();
    } on ReauthRequiredException {
      // A web popup opened from this continuation is outside the tap's user
      // gesture and would be blocked: surface the error instead; the next
      // tap re-authenticates up front and reuses the same key.
      if (_stale(generation) || _auth.reauthNeedsGesture) rethrow;
      // Revoking again here is harmless: the earlier attempt was best-effort
      // and a fresh Apple code is issued by this second re-auth.
      await _reauthenticate(promptPassword, revokeApple: revokeApple);
      if (_stale(generation)) rethrow;
      return call();
    }
  }

  /// Re-authenticates; a cancel becomes [_Cancelled]. The Apple token is
  /// revoked (delete flow only) best-effort: a revoke failure is reported
  /// and never blocks the deletion.
  Future<void> _reauthenticate(
    PasswordPrompt promptPassword, {
    required bool revokeApple,
  }) async {
    final ReauthResult result;
    try {
      result = await _auth.reauthenticate(promptPassword: promptPassword);
    } on AuthCancelled {
      throw const _Cancelled();
    }
    final code = result.appleAuthorizationCode;
    if (revokeApple && code != null && code.isNotEmpty) {
      try {
        await _auth.revokeAppleToken(code);
      } catch (error, stack) {
        _onUnexpectedError?.call(error, stack);
      }
    }
  }

  void _fail(int generation, Object error, StackTrace stack) {
    if (_stale(generation)) return;
    if (error is _Cancelled) {
      emit(const AccountState(status: AccountStatus.cancelled));
    } else if (error is AuthFailure) {
      emit(AccountState(status: AccountStatus.failed, authFailure: error));
    } else if (error is AppException) {
      if (error is UnknownApiException) _onUnexpectedError?.call(error, stack);
      emit(AccountState(status: AccountStatus.failed, error: error));
    } else {
      _onUnexpectedError?.call(error, stack);
      emit(
        const AccountState(
          status: AccountStatus.failed,
          error: UnknownApiException('Something went wrong. Please try again.'),
        ),
      );
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
