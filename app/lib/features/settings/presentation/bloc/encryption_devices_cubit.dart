import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../messages/domain/e2ee/encrypted_messaging.dart';

enum EncryptionDevicesStatus { loading, ready, failed }

/// What [EncryptionDevicesCubit.remove] did: the directory removal answered, it failed, or nothing was attempted
/// (the cubit is closed or another removal is running).
///
/// With a re-sign-in asked for (`confirmItsYou`, every REMOTE removal; lane D
/// PR 4 ruling 3): [cancelled] when the user did not confirm it was them
/// (nothing was sent), [needsReauth] when the removal answered
/// REAUTH_REQUIRED (the call missed the recent-sign-in window; the removal
/// waits, parked, for the user to confirm again).
enum RemoveOutcome { removed, failed, notAttempted, cancelled, needsReauth }

/// The device list of Settings > Encrypted messages. A plain class on purpose: it holds device refs, so it has no
/// `toString` (R14), no `==` and no generated code.
@immutable
class EncryptionDevicesState {
  const EncryptionDevicesState({
    this.status = EncryptionDevicesStatus.loading,
    this.list,
    this.removing,
    this.removalsPending = 0,
    this.error,
    this.confirming = false,
  });

  final EncryptionDevicesStatus status;
  final OwnDeviceList? list;

  /// The ref being removed.
  final String? removing;

  /// A removal's "Confirm it's you" is open (fix round ruling 5, N7): no
  /// removal can start, so the screen disables every Remove.
  final bool confirming;
  final int removalsPending;
  final AppException? error;
}

/// Loads the own-device list and removes a device. Makes no call until [load]; the screen creates it only while the
/// vault on this device is ready. Nothing caught here is forwarded: an error that is not an [AppException] is reported
/// as a fixed `StateError('<step>')` (a removal's `ArgumentError` carries the ref).
class EncryptionDevicesCubit extends Cubit<EncryptionDevicesState> {
  EncryptionDevicesCubit({
    required EncryptedMessaging messaging,
    this.onUnexpectedError,
  }) : _messaging = messaging,
       super(
         EncryptionDevicesState(
           removalsPending: messaging.removalsPending.value,
         ),
       ) {
    messaging.removalsPending.addListener(_pendingChanged);
  }

  final EncryptedMessaging _messaging;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  /// A re-sign-in for a removal is open: no second removal starts.
  bool _confirming = false;

  /// Sets [_confirming] and shows it ([EncryptionDevicesState.confirming]).
  void _setConfirming(bool value) {
    _confirming = value;
    if (isClosed) return;
    final s = state;
    emit(
      EncryptionDevicesState(
        status: s.status,
        list: s.list,
        removing: s.removing,
        removalsPending: s.removalsPending,
        error: s.error,
        confirming: value,
      ),
    );
  }

  void _pendingChanged() {
    if (isClosed) return;
    final s = state;
    emit(
      EncryptionDevicesState(
        status: s.status,
        list: s.list,
        removing: s.removing,
        removalsPending: _messaging.removalsPending.value,
        error: s.error,
        confirming: _confirming,
      ),
    );
  }

  void _report(String step, StackTrace stack) =>
      onUnexpectedError?.call(StateError(step), stack);

  Future<void> load() async {
    if (isClosed) return;
    final before = state;
    emit(
      EncryptionDevicesState(
        status: EncryptionDevicesStatus.loading,
        list: before.list,
        removing: before.removing,
        removalsPending: before.removalsPending,
        confirming: _confirming,
      ),
    );
    try {
      final list = await _messaging.ownDevices();
      if (isClosed) return;
      emit(
        EncryptionDevicesState(
          status: EncryptionDevicesStatus.ready,
          list: list,
          removing: state.removing,
          removalsPending: state.removalsPending,
          confirming: _confirming,
        ),
      );
    } catch (e, stack) {
      if (isClosed) return;
      if (e is! AppException) _report('ownDevices', stack);
      emit(
        EncryptionDevicesState(
          status: EncryptionDevicesStatus.failed,
          removing: state.removing,
          removalsPending: state.removalsPending,
          error: e is AppException ? e : null,
          confirming: _confirming,
        ),
      );
    }
  }

  /// [RemoveOutcome.removed] when the directory removal answered (whatever the reload or the device setup does
  /// after it); [RemoveOutcome.failed] when it did not (the list stays and [EncryptionDevicesState.error] carries
  /// the typed error); [RemoveOutcome.notAttempted] when the cubit is closed or another removal is running.
  ///
  /// [retrySetup] (the screen sets it only at the 5-device limit) asks the port to register this device again after
  /// the removal. Order: [confirmItsYou] (when given), remove, retry (when asked), reload.
  ///
  /// [confirmItsYou] (the screen passes it on every Remove tap; lane D PR 4, ruling 3 and fix round ruling 1) is the
  /// re-sign-in. It runs FIRST, before anything is sent or queued and before the row shows its spinner, so the
  /// REMOTE call that follows at once is inside the server's recent-sign-in window (`ACCOUNT_DELETE_REAUTH_MAX_AGE`).
  /// While it runs, [EncryptionDevicesState.confirming] is true. False or a throw: [RemoveOutcome.cancelled], nothing
  /// sent. A REAUTH_REQUIRED answer anyway: [RemoveOutcome.needsReauth], the list kept and no error (the
  /// queue parked the removal; calling this again for the same ref sends it at once).
  Future<RemoveOutcome> remove(
    String ref, {
    bool retrySetup = false,
    Future<bool> Function()? confirmItsYou,
  }) async {
    if (isClosed || state.removing != null || _confirming) {
      return RemoveOutcome.notAttempted;
    }
    if (confirmItsYou != null) {
      var confirmed = false;
      _setConfirming(true);
      try {
        confirmed = await confirmItsYou();
      } catch (_, stack) {
        _report('confirmItsYou', stack);
      } finally {
        _setConfirming(false);
      }
      if (!confirmed) return RemoveOutcome.cancelled;
      if (isClosed || state.removing != null) return RemoveOutcome.notAttempted;
    }
    final before = state;
    emit(
      EncryptionDevicesState(
        status: before.status,
        list: before.list,
        removing: ref,
        removalsPending: before.removalsPending,
      ),
    );
    try {
      await _messaging.removeDevice(ref);
    } on ReauthRequiredException {
      // The call missed the window: the queue parked the removal (never
      // dropped). The screen asks the user to confirm again and calls this
      // again for the same ref, which sends it at once.
      _restore(before);
      return RemoveOutcome.needsReauth;
    } catch (e, stack) {
      if (e is! AppException) _report('removeDevice', stack);
      if (!isClosed) {
        emit(
          EncryptionDevicesState(
            status: before.status,
            list: before.list,
            removalsPending: state.removalsPending,
            error: e is AppException ? e : null,
          ),
        );
      }
      return RemoveOutcome.failed;
    }
    // The 5-device latch: registering again is only a request, never part of the removal's answer.
    if (retrySetup) {
      try {
        await _messaging.retryDeviceSetup();
      } catch (_, stack) {
        _report('retryDeviceSetup', stack);
      }
    }
    OwnDeviceList? list = before.list;
    try {
      list = await _messaging.ownDevices();
    } catch (e, stack) {
      if (e is! AppException) _report('ownDevicesAfterRemove', stack);
    }
    if (!isClosed) {
      emit(
        EncryptionDevicesState(
          status: EncryptionDevicesStatus.ready,
          list: list,
          removalsPending: state.removalsPending,
        ),
      );
    }
    return RemoveOutcome.removed;
  }

  /// Back to [before]'s list and status, with nothing being removed and no
  /// error (the pending count stays live).
  void _restore(EncryptionDevicesState before) {
    if (isClosed) return;
    emit(
      EncryptionDevicesState(
        status: before.status,
        list: before.list,
        removalsPending: state.removalsPending,
      ),
    );
  }

  @override
  Future<void> close() {
    _messaging.removalsPending.removeListener(_pendingChanged);
    return super.close();
  }
}
