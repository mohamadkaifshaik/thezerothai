import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';
import '../../../onboarding/domain/handle_rules.dart';
import '../../../onboarding/presentation/bloc/onboarding_state.dart'
    show HandleCheckStatus;

/// Wait after the last keystroke before asking the server whether a handle
/// is free (CLAUDE.md: debounce 300 ms; `check_handle_daily` is a real cap).
const kHandleCheckDebounce = Duration(milliseconds: 300);

const kSameHandleMessage = 'This is already your handle.';

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

  bool get isSaving => status == ChangeHandleStatus.saving;

  /// `unknown` = the availability probe was rate limited: ChangeHandle
  /// validates again, so saving stays possible.
  bool get canSave =>
      !isSaving &&
      status != ChangeHandleStatus.saved &&
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
  }) => ChangeHandleState(
    handle: handle ?? this.handle,
    checkStatus: checkStatus ?? this.checkStatus,
    checkMessage: checkMessage ?? this.checkMessage,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
  );
}

/// Drives Change handle (P2-T5): local format/reserved checks first, then a
/// debounced `CheckHandleAvailability`, then `ChangeHandle` with one
/// idempotency key per distinct handle. The 7-day cooldown is enforced by the
/// server; its answer carries the time left.
class ChangeHandleCubit extends Cubit<ChangeHandleState> {
  ChangeHandleCubit({
    required IdentityRepository identityRepository,
    required String currentHandle,
    Uuid? uuid,
    Duration debounce = kHandleCheckDebounce,
  }) : _repository = identityRepository,
       _current = currentHandle.toLowerCase(),
       _uuid = uuid ?? const Uuid(),
       _debounce = debounce,
       super(const ChangeHandleState());

  final IdentityRepository _repository;
  final String _current;
  final Uuid _uuid;
  final Duration _debounce;
  final Map<String, String> _keys = {};
  Timer? _timer;

  void handleChanged(String raw) {
    if (state.isSaving) return;
    _timer?.cancel();
    final handle = raw.trim().toLowerCase().replaceFirst(RegExp('^@'), '');
    if (handle.isEmpty) {
      emit(
        ChangeHandleState(
          checkStatus: HandleCheckStatus.idle,
          status: ChangeHandleStatus.editing,
        ),
      );
      return;
    }
    ChangeHandleState unavailable(String message) => ChangeHandleState(
      handle: handle,
      checkStatus: HandleCheckStatus.unavailable,
      checkMessage: message,
    );
    if (handle == _current) {
      emit(unavailable(kSameHandleMessage));
      return;
    }
    if (!kHandlePattern.hasMatch(handle)) {
      emit(unavailable(kHandleFormatMessage));
      return;
    }
    if (kReservedHandles.contains(handle)) {
      emit(unavailable(kHandleReservedMessage));
      return;
    }
    emit(
      ChangeHandleState(
        handle: handle,
        checkStatus: HandleCheckStatus.checking,
      ),
    );
    _timer = Timer(_debounce, () => _check(handle));
  }

  Future<void> _check(String handle) async {
    try {
      final response = await _repository.checkHandleAvailability(handle);
      if (isClosed || state.handle != handle) return;
      emit(
        state.copyWith(
          checkStatus: response.available
              ? HandleCheckStatus.available
              : HandleCheckStatus.unavailable,
          checkMessage: response.available
              ? ''
              : handleUnavailableMessage(response.reason),
        ),
      );
    } on RateLimitedException {
      // A rate-limited probe says nothing about the handle: let the user
      // submit; ChangeHandle validates again.
      if (isClosed || state.handle != handle) return;
      emit(
        state.copyWith(
          checkStatus: HandleCheckStatus.unknown,
          checkMessage:
              "Couldn't check this handle right now. We'll confirm it when "
              'you save.',
        ),
      );
    } on AppException catch (e) {
      if (isClosed || state.handle != handle) return;
      emit(
        state.copyWith(
          checkStatus: HandleCheckStatus.unknown,
          checkMessage: e is NetworkException
              ? "Couldn't check this handle. We'll confirm it when you save."
              : "Couldn't check this handle right now.",
        ),
      );
    }
  }

  Future<void> save() async {
    if (!state.canSave) return;
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
    } on AppException catch (e) {
      if (isClosed) return;
      emit(state.copyWith(status: ChangeHandleStatus.editing, error: e));
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: ChangeHandleStatus.editing,
          error: const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
