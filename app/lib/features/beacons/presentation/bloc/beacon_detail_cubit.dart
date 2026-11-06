import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';
import 'beacon_detail_state.dart';

/// `/plans/:id`: one GetBeacon per [load], and the organiser's [cancel].
///
/// One idempotency key per cubit for Cancel, reused when the same action is
/// retried after a failure (rule 4). The answer of a successful cancel is the
/// view with its status set to CANCELLED (the server's next read agrees).
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
  String? _cancelKey;
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
    if (state.cancelBusy || state.view == null) return;
    final key = _cancelKey ??= _uuid.v4();
    emit(state.copyWith(cancelBusy: true, clearActionError: true));
    try {
      await _repository.cancelBeacon(idempotencyKey: key, beaconId: _beaconId);
      if (isClosed) return;
      final view = state.view!.deepCopy()
        ..beacon.status = pb.BeaconStatus.BEACON_STATUS_CANCELLED;
      emit(state.copyWith(cancelBusy: false, view: view));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          cancelBusy: false,
          actionError: beaconsErrorMessage(error),
        ),
      );
    }
  }
}
