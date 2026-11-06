import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';
import 'beacon_detail_state.dart';

/// `/plans/:id`: one GetBeacon per [load]; the organiser's [cancel]; the
/// viewer's [request], [withdraw] and [leave].
///
/// After a write, read (R35): every action, refused or not, ends with one
/// GetBeacon so the pill, seats and buttons show what the server computed.
/// Keys (R36): one idempotency key per action kind, reused when the same
/// action is retried after a failure and dropped after a success, so the next
/// action of that kind is a new one. A successful cancel is answered locally
/// (CANCELLED) as well, so the pill never flickers.
class BeaconDetailCubit extends Cubit<BeaconDetailState> {
  BeaconDetailCubit({
    required BeaconsRepository repository,
    required String beaconId,
  }) : _repository = repository,
       _beaconId = beaconId,
       super(const BeaconDetailState());

  static const _uuid = Uuid();

  final BeaconsRepository _repository;
  final String _beaconId;
  final Map<BeaconAction, String> _keys = {};
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: state.view == null ? BeaconDetailStatus.loading : null,
        clearError: true,
      ),
    );
    try {
      final view = await _repository.getBeacon(_beaconId);
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(status: BeaconDetailStatus.ready, view: view));
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(status: BeaconDetailStatus.error, error: error));
    }
  }

  Future<void> cancel() async {
    final ok = await _run(BeaconAction.cancel, (key) async {
      await _repository.cancelBeacon(idempotencyKey: key, beaconId: _beaconId);
      if (isClosed) return;
      final view = state.view!.deepCopy()
        ..beacon.status = pb.BeaconStatus.BEACON_STATUS_CANCELLED;
      emit(state.copyWith(view: view));
    });
    if (!ok) return;
  }

  /// Asks to join with [note] (0-140). True on success.
  Future<bool> request(String note) => _run(
    BeaconAction.request,
    (key) => _repository.requestToJoin(
      idempotencyKey: key,
      beaconId: _beaconId,
      note: note,
    ),
  );

  Future<bool> withdraw() => _run(
    BeaconAction.withdraw,
    (key) => _repository.withdrawJoinRequest(
      idempotencyKey: key,
      beaconId: _beaconId,
    ),
  );

  Future<bool> leave() => _run(
    BeaconAction.leave,
    (key) => _repository.leaveBeacon(idempotencyKey: key, beaconId: _beaconId),
  );

  /// Runs one write with its key, then reloads. False when the write was
  /// refused ([BeaconDetailState.actionError] carries the copy).
  Future<bool> _run(
    BeaconAction action,
    Future<void> Function(String key) write,
  ) async {
    if (state.busy != null || state.view == null) return false;
    final key = _keys.putIfAbsent(action, _uuid.v4);
    emit(state.copyWith(busy: action, clearActionError: true));
    var ok = false;
    try {
      await write(key);
      _keys.remove(action);
      ok = true;
    } on AppException catch (error) {
      if (isClosed) return false;
      emit(state.copyWith(actionError: beaconsErrorMessage(error)));
    }
    if (isClosed) return ok;
    emit(state.copyWith(clearBusy: true));
    await load();
    return ok;
  }
}
