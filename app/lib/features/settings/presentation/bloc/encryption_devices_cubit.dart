import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../messages/domain/e2ee/encrypted_messaging.dart';

enum EncryptionDevicesStatus { loading, ready, failed }

/// What [EncryptionDevicesCubit.remove] did: the directory removal answered, it failed, or nothing was attempted
/// (the cubit is closed or another removal is running).
enum RemoveOutcome { removed, failed, notAttempted }

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
  });

  final EncryptionDevicesStatus status;
  final OwnDeviceList? list;

  /// The ref being removed.
  final String? removing;
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
        ),
      );
    }
  }

  /// [RemoveOutcome.removed] when the directory removal answered (whatever the reload or the device setup does
  /// after it); [RemoveOutcome.failed] when it did not (the list stays and [EncryptionDevicesState.error] carries
  /// the typed error); [RemoveOutcome.notAttempted] when the cubit is closed or another removal is running.
  ///
  /// [retrySetup] (the screen sets it only at the 5-device limit) asks the port to register this device again after
  /// the removal. Order: remove, retry (when asked), reload.
  Future<RemoveOutcome> remove(String ref, {bool retrySetup = false}) async {
    if (isClosed || state.removing != null) return RemoveOutcome.notAttempted;
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

  @override
  Future<void> close() {
    _messaging.removalsPending.removeListener(_pendingChanged);
    return super.close();
  }
}
