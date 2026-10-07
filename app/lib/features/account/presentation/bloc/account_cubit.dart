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

/// Drives DeleteAccount and RequestAccountExport.
///
/// - One idempotency key per intent: generated on the first attempt and
///   reused on every retry (including the one after re-authentication and a
///   user tapping again after a network error); cleared only on success.
/// - On `REAUTH_REQUIRED` it re-authenticates once and retries once with the
///   same key. A second `REAUTH_REQUIRED` is surfaced, never looped.
/// - A cancelled re-authentication sends nothing.
class AccountCubit extends Cubit<AccountState> {
  AccountCubit({
    required AccountRepository accountRepository,
    required AuthRepository authRepository,
    required Future<String?> Function() promptPassword,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Uuid? uuid,
  }) : _accounts = accountRepository,
       _auth = authRepository,
       _promptPassword = promptPassword,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       super(const AccountState());

  final AccountRepository _accounts;
  final AuthRepository _auth;
  final Future<String?> Function() _promptPassword;

  /// Crashlytics non-fatal hook for unexpected errors (never pass URLs).
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Uuid _uuid;

  String? _deleteKey;
  String? _exportKey;

  Future<void> deleteAccount() async {
    if (state.status == AccountStatus.working) return;
    final key = _deleteKey ??= _uuid.v4();
    emit(const AccountState(status: AccountStatus.working));
    try {
      await _withReauth(() => _accounts.deleteAccount(idempotencyKey: key));
      _deleteKey = null;
      emit(const AccountState(status: AccountStatus.deleted));
    } on _Cancelled {
      emit(const AccountState(status: AccountStatus.cancelled));
    } on AuthFailure catch (failure) {
      emit(AccountState(status: AccountStatus.failed, authFailure: failure));
    } on AppException catch (error, stack) {
      _report(error, stack);
      emit(AccountState(status: AccountStatus.failed, error: error));
    }
  }

  Future<void> requestExport() async {
    if (state.status == AccountStatus.working) return;
    final key = _exportKey ??= _uuid.v4();
    emit(const AccountState(status: AccountStatus.working));
    try {
      final export = await _withReauth(
        () => _accounts.requestExport(idempotencyKey: key),
      );
      _exportKey = null;
      emit(AccountState(status: AccountStatus.exportRequested, export: export));
    } on _Cancelled {
      emit(const AccountState(status: AccountStatus.cancelled));
    } on AuthFailure catch (failure) {
      emit(AccountState(status: AccountStatus.failed, authFailure: failure));
    } on AppException catch (error, stack) {
      _report(error, stack);
      emit(AccountState(status: AccountStatus.failed, error: error));
    }
  }

  /// Runs [call]; on [ReauthRequiredException] re-authenticates once and
  /// retries once.
  Future<T> _withReauth<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ReauthRequiredException {
      await _reauthenticate();
      return call();
    }
  }

  Future<void> _reauthenticate() async {
    final ReauthResult result;
    try {
      result = await _auth.reauthenticate(promptPassword: _promptPassword);
    } on AuthCancelled {
      throw const _Cancelled();
    }
    final code = result.appleAuthorizationCode;
    if (code != null && code.isNotEmpty) {
      try {
        await _auth.revokeAppleToken(code);
      } on AuthFailure catch (failure, stack) {
        // Best effort: the deletion itself must not be blocked by Apple.
        _onUnexpectedError?.call(failure, stack);
      }
    }
  }

  void _report(AppException error, StackTrace stack) {
    if (error is UnknownApiException) _onUnexpectedError?.call(error, stack);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
