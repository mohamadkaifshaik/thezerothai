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
/// Keys (R36): one idempotency key per action and payload (the server hashes
/// the note into the request), reused only when exactly the same action is
/// retried after a failure. Every successful write drops all keys, so
/// request, withdraw, request again is a new request. A successful cancel is
/// answered locally (CANCELLED) as well, so the pill never flickers.
class BeaconDetailCubit extends Cubit<BeaconDetailState> {
  BeaconDetailCubit({
    required BeaconsRepository repository,
    required String beaconId,
    pb.BeaconView? initialView,
  }) : _repository = repository,
       _beaconId = beaconId,
       super(
         initialView == null
             ? const BeaconDetailState()
             : BeaconDetailState(
                 status: BeaconDetailStatus.ready,
                 view: initialView,
               ),
       );

  static const _uuid = Uuid();

  final BeaconsRepository _repository;
  final String _beaconId;
  final Map<String, String> _keys = {};
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
      await _loadFaces(view, generation);
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(status: BeaconDetailStatus.error, error: error));
    }
  }

  /// The first 3 people going, only for a viewer who may list participants
  /// (the organiser, or accepted); anyone else keeps the count alone with no
  /// read. A refusal (NOT_FOUND, FORBIDDEN, a paused service, anything else)
  /// leaves the card on the count: the faces are decoration, never an error.
  Future<void> _loadFaces(pb.BeaconView view, int generation) async {
    if (!(view.viewer.canManage || view.viewer.canLeave)) {
      if (state.faces.isNotEmpty) emit(state.copyWith(faces: const []));
      return;
    }
    try {
      final page = await _repository.listParticipants(
        beaconId: _beaconId,
        filter: pb.ParticipantFilter.PARTICIPANT_FILTER_ACCEPTED,
        limit: 3,
      );
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(faces: page.participants));
    } on AppException {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(faces: const []));
    }
  }

  Future<void> cancel() async {
    final ok = await _run(BeaconAction.cancel, '', (key) async {
      await _repository.cancelBeacon(idempotencyKey: key, beaconId: _beaconId);
      if (isClosed) return;
      final view = state.view!.deepCopy()
        ..beacon.status = pb.BeaconStatus.BEACON_STATUS_CANCELLED;
      emit(state.copyWith(view: view));
    });
    if (!ok) return;
  }

  /// Asks to join with [note] (0-140); an empty note is the one-tap "I'm in".
  /// True on success. A `note_required` refusal sets
  /// [BeaconDetailState.noteRequired] (and no [BeaconDetailState.actionError]).
  Future<bool> request(String note) {
    final normalized = note.trim();
    return _run(
      BeaconAction.request,
      normalized,
      (key) => _repository.requestToJoin(
        idempotencyKey: key,
        beaconId: _beaconId,
        note: normalized,
      ),
    );
  }

  Future<bool> withdraw() => _run(
    BeaconAction.withdraw,
    '',
    (key) => _repository.withdrawJoinRequest(
      idempotencyKey: key,
      beaconId: _beaconId,
    ),
    notFoundIsDone: true,
  );

  Future<bool> leave() => _run(
    BeaconAction.leave,
    '',
    (key) => _repository.leaveBeacon(idempotencyKey: key, beaconId: _beaconId),
    notFoundIsDone: true,
  );

  /// Runs one write with its key, then reloads. False when the write was
  /// refused ([BeaconDetailState.actionError] carries the copy).
  Future<bool> _run(
    BeaconAction action,
    String payload,
    Future<void> Function(String key) write, {
    bool notFoundIsDone = false,
  }) async {
    if (state.busy != null || state.view == null) return false;
    final key = _keys.putIfAbsent('${action.name}|$payload', _uuid.v4);
    emit(
      state.copyWith(busy: action, clearActionError: true, noteRequired: false),
    );
    var ok = false;
    try {
      await write(key);
      _keys.clear();
      ok = true;
    } on AppException catch (error) {
      if (isClosed) return false;
      if (notFoundIsDone && error is NotFoundException) {
        // Leave and withdraw answer NOT_FOUND when the caller has no row any
        // more: that is the end state they asked for, so just reload.
        _keys.clear();
        ok = true;
      } else if (action == BeaconAction.request && isNoteRequired(error)) {
        emit(state.copyWith(noteRequired: true));
      } else {
        emit(state.copyWith(actionError: beaconsErrorMessage(error)));
      }
    }
    if (isClosed) return ok;
    emit(state.copyWith(clearBusy: true));
    await load();
    return ok;
  }
}
