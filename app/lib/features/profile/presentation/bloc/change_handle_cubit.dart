import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';
import '../../../onboarding/domain/handle_rules.dart';

const kSameHandleMessage = 'This is already your handle.';

/// `metadata["quota"]` the server names on the 7-day handle cooldown.
const kHandleChangeQuota = 'handle_change';

/// The server's cooldown; the lockout used when its answer did not say how
/// much is left.
const kHandleCooldown = Duration(days: 7);

/// Lockout after a daily-quota answer that carried no `retryAfter` (quotas
/// reset at IST midnight, so a day is the upper bound).
const kDailyQuotaLockout = Duration(days: 1);

enum ChangeHandleStatus { editing, saving, saved }

@immutable
class ChangeHandleState {
  const ChangeHandleState({
    this.handle = '',
    this.checkStatus = HandleCheckStatus.idle,
    this.checkMessage = '',
    this.status = ChangeHandleStatus.editing,
    this.error,
    this.saved,
    this.cooldownUntil,
  });

  /// What the user typed, trimmed and lowercased.
  final String handle;
  final HandleCheckStatus checkStatus;

  /// Why the handle cannot be used (or "could not check"); empty otherwise.
  final String checkMessage;
  final ChangeHandleStatus status;

  /// The last failed save, shown once (snackbar) and cleared by the next
  /// edit or save.
  final AppException? error;

  /// The server's profile after a successful change.
  final identity.Profile? saved;

  /// When the server said the handle change (or its daily quota) is locked
  /// until. Save stays disabled while this is set; the cubit clears it on the
  /// first edit after it passed.
  final DateTime? cooldownUntil;

  bool get isSaving => status == ChangeHandleStatus.saving;

  /// `unknown` = the availability probe was rate limited: ChangeHandle
  /// validates again, so saving stays possible.
  bool get canSave =>
      !isSaving &&
      status != ChangeHandleStatus.saved &&
      cooldownUntil == null &&
      (checkStatus == HandleCheckStatus.available ||
          checkStatus == HandleCheckStatus.unknown);

  ChangeHandleState copyWith({
    String? handle,
    HandleCheckStatus? checkStatus,
    String? checkMessage,
    ChangeHandleStatus? status,
    AppException? error,
    bool clearError = false,
    identity.Profile? saved,
    DateTime? cooldownUntil,
    bool clearCooldown = false,
  }) => ChangeHandleState(
    handle: handle ?? this.handle,
    checkStatus: checkStatus ?? this.checkStatus,
    checkMessage: checkMessage ?? this.checkMessage,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
    cooldownUntil: clearCooldown ? null : (cooldownUntil ?? this.cooldownUntil),
  );
}

/// Drives Change handle (P2-T5): local format/reserved checks first, then a
/// debounced `CheckHandleAvailability`, then `ChangeHandle` with one
/// idempotency key per distinct handle. The 7-day cooldown is enforced by the
/// server; its answer carries the time left, which is kept in state so Save
/// stays disabled until then. The check rules and answer mapping are the
/// shared ones in `handle_rules.dart` (same as create-profile).
class ChangeHandleCubit extends Cubit<ChangeHandleState> {
  ChangeHandleCubit({
    required IdentityRepository identityRepository,
    required String currentHandle,
    Uuid? uuid,
    Duration debounce = kHandleCheckDebounce,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = identityRepository,
       _current = currentHandle.toLowerCase(),
       _uuid = uuid ?? const Uuid(),
       _debounce = debounce,
       _clock = clock ?? DateTime.now,
       _onUnexpectedError = onUnexpectedError,
       super(const ChangeHandleState());

  final IdentityRepository _repository;
  final String _current;
  final Uuid _uuid;
  final Duration _debounce;
  final DateTime Function() _clock;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Map<String, String> _keys = {};
  Timer? _timer;

  /// Fires when the lockout ends so Save re-enables without another edit.
  Timer? _cooldownTimer;

  /// After one RATE_LIMITED probe answer the probe is not asked again until
  /// its `retryAfter` passed (the rest of the screen when the server gave
  /// none): each further keystroke would only be refused. Saving validates
  /// the handle anyway.
  DateTime? _probesPausedUntil;
  String _pausedMessage = '';

  bool get _probesPaused {
    final until = _probesPausedUntil;
    return until != null && _clock().isBefore(until);
  }

  /// The lockout still in force, or null once it passed (or was never set).
  DateTime? get _activeCooldown {
    final until = state.cooldownUntil;
    return until != null && _clock().isBefore(until) ? until : null;
  }

  /// Time left of the lockout, for the inline note; null when there is none.
  Duration? get cooldownLeft => _activeCooldown?.difference(_clock());

  void handleChanged(String raw) {
    if (state.isSaving) return;
    _timer?.cancel();
    final handle = raw.trim().toLowerCase().replaceFirst(RegExp('^@'), '');
    final cooldown = _activeCooldown;
    ChangeHandleState next(HandleCheckStatus status, [String message = '']) =>
        ChangeHandleState(
          handle: handle,
          checkStatus: status,
          checkMessage: message,
          cooldownUntil: cooldown,
        );
    if (handle.isEmpty) {
      emit(next(HandleCheckStatus.idle));
      return;
    }
    if (handle == _current) {
      emit(next(HandleCheckStatus.unavailable, kSameHandleMessage));
      return;
    }
    final issue = localHandleIssue(handle);
    if (issue != null) {
      emit(next(HandleCheckStatus.unavailable, issue));
      return;
    }
    if (cooldown != null) {
      // Save cannot succeed until the lockout ends, so asking the server
      // whether the handle is free would only spend a read.
      emit(next(HandleCheckStatus.idle));
      return;
    }
    if (_probesPaused) {
      emit(next(HandleCheckStatus.unknown, _pausedMessage));
      return;
    }
    emit(next(HandleCheckStatus.checking));
    _timer = Timer(_debounce, () => _check(handle));
  }

  Future<void> _check(String handle) async {
    try {
      final response = await _repository.checkHandleAvailability(handle);
      if (isClosed || state.handle != handle) return;
      _emitCheck(handleCheckFromAnswer(response));
    } on AppException catch (e, stack) {
      final check = handleCheckFromError(e);
      if (e is RateLimitedException) {
        // A rate-limited probe says nothing about the handle: let the user
        // submit (ChangeHandle validates again) and stop probing.
        _pausedMessage = check.message;
        final wait = e.retryAfter;
        _probesPausedUntil = wait == null
            ? DateTime.utc(9999)
            : _clock().add(wait);
      }
      if (e is UnknownApiException) _onUnexpectedError?.call(e, stack);
      if (isClosed || state.handle != handle) return;
      _emitCheck(check);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed || state.handle != handle) return;
      _emitCheck(
        handleCheckFromError(
          const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  void _emitCheck(HandleCheck check) {
    emit(
      state.copyWith(checkStatus: check.status, checkMessage: check.message),
    );
  }

  Future<void> save() async {
    if (_activeCooldown != null || !state.canSave) return;
    final handle = state.handle;
    final key = _keys.putIfAbsent(handle, _uuid.v4);
    emit(state.copyWith(status: ChangeHandleStatus.saving, clearError: true));
    try {
      final profile = await _repository.changeHandle(
        idempotencyKey: key,
        newHandle: handle,
      );
      _keys.remove(handle);
      if (isClosed) return;
      emit(state.copyWith(status: ChangeHandleStatus.saved, saved: profile));
    } on HandleTakenException {
      // Taken between the check and the save: say so on the field.
      if (isClosed) return;
      emit(
        state.copyWith(
          status: ChangeHandleStatus.editing,
          checkStatus: HandleCheckStatus.unavailable,
          checkMessage: kHandleTakenMessage,
        ),
      );
    } on AppException catch (e, stack) {
      if (e is UnknownApiException) _onUnexpectedError?.call(e, stack);
      if (isClosed) return;
      final lockout = _lockoutFor(e);
      emit(
        state.copyWith(
          status: ChangeHandleStatus.editing,
          error: e,
          cooldownUntil: lockout,
        ),
      );
      if (lockout != null) _scheduleCooldownEnd(lockout);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed) return;
      emit(
        state.copyWith(
          status: ChangeHandleStatus.editing,
          error: const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  /// When a cooldown / quota answer says Save cannot succeed until, or null
  /// for every other failure (which stays retryable).
  DateTime? _lockoutFor(AppException e) {
    final Duration wait;
    if (e is LimitReachedException && e.quota == kHandleChangeQuota) {
      wait = e.retryAfter ?? kHandleCooldown;
    } else if (e is QuotaExceededException &&
        (e.quota != null || e.retryAfter != null)) {
      // A bare RESOURCE_EXHAUSTED (no ErrorDetail: an infrastructure
      // throttle) names no quota and says nothing about a day: retryable.
      wait = e.retryAfter ?? kDailyQuotaLockout;
    } else {
      return null;
    }
    return _clock().add(wait);
  }

  void _scheduleCooldownEnd(DateTime until) {
    _cooldownTimer?.cancel();
    final wait = until.difference(_clock());
    _cooldownTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (isClosed || state.cooldownUntil == null) return;
      emit(state.copyWith(clearCooldown: true));
      // Edits made during the lockout were not probed: check the handle now.
      final handle = state.handle;
      if (handle.isNotEmpty && !state.isSaving) handleChanged(handle);
    });
  }

  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    _cooldownTimer?.cancel();
    return super.close();
  }
}
