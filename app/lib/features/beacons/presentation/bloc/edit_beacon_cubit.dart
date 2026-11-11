import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';

@immutable
class EditBeaconState {
  const EditBeaconState({
    this.loading = true,
    this.view,
    this.error,
    this.busy = false,
    this.saveError,
    this.saved,
  });

  /// The plan is being read for the form.
  final bool loading;

  /// The plan as loaded (the form's starting values).
  final pb.BeaconView? view;

  /// The failure of the load (nothing to edit).
  final AppException? error;

  /// A save is in flight.
  final bool busy;

  /// Friendly text of the last failed save; the form stays open.
  final String? saveError;

  /// Set once when the save succeeded (or nothing had changed): the screen
  /// goes back.
  final pb.BeaconView? saved;

  EditBeaconState copyWith({
    bool? loading,
    pb.BeaconView? view,
    AppException? error,
    bool clearError = false,
    bool? busy,
    String? saveError,
    bool clearSaveError = false,
    pb.BeaconView? saved,
  }) => EditBeaconState(
    loading: loading ?? this.loading,
    view: view ?? this.view,
    error: clearError ? null : (error ?? this.error),
    busy: busy ?? this.busy,
    saveError: clearSaveError ? null : (saveError ?? this.saveError),
    saved: saved ?? this.saved,
  );
}

/// `/plans/:id/edit`: one GetBeacon for the starting values, then one
/// UpdateBeacon carrying only the fields that differ (presence is the server's
/// diff). One key per distinct payload, reused on a retry (R36). Nothing
/// changed means no call. F28 adds the start, duration and cost; an answer
/// without them (an older server) keeps the form open with
/// [kPlanScheduleNotSaved].
class EditBeaconCubit extends Cubit<EditBeaconState> {
  EditBeaconCubit({
    required BeaconsRepository repository,
    required String beaconId,
  }) : _repository = repository,
       _beaconId = beaconId,
       super(const EditBeaconState());

  static const _uuid = Uuid();

  final BeaconsRepository _repository;
  final String _beaconId;
  String? _key;
  List<int>? _payload;

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final view = await _repository.getBeacon(_beaconId);
      if (isClosed) return;
      emit(state.copyWith(loading: false, view: view));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(state.copyWith(loading: false, error: error));
    }
  }

  /// Saves the form. [startAt], [durationMinutes] and [cost] (F28) are sent
  /// only when given and different from the loaded plan; the screen gives
  /// none once the plan has started (the server refuses them then).
  Future<void> save({
    required String title,
    required String details,
    required String venue,
    required int openSpots,
    DateTime? startAt,
    int? durationMinutes,
    pb.BeaconCost? cost,
  }) async {
    final view = state.view;
    if (state.busy || view == null) return;
    final b = view.beacon;
    final request = pb.UpdateBeaconRequest(beaconId: _beaconId);
    if (title != b.title) request.title = title;
    if (details != b.details) request.details = details;
    if (venue != b.venue) request.venue = venue;
    if (openSpots != b.openSpots) request.openSpots = openSpots;
    if (startAt != null && !startAt.isAtSameMomentAs(b.startAt.toDateTime())) {
      request.startAt = ts.Timestamp.fromDateTime(startAt.toUtc());
    }
    if (durationMinutes != null && durationMinutes != b.durationMinutes) {
      request.durationMinutes = durationMinutes;
    }
    if (cost != null && cost != b.cost) request.cost = cost;
    if (!request.hasTitle() &&
        !request.hasDetails() &&
        !request.hasVenue() &&
        !request.hasOpenSpots() &&
        !_movesSchedule(request)) {
      emit(state.copyWith(saved: view, clearSaveError: true));
      return;
    }
    final payload = request.writeToBuffer();
    if (_payload == null || !listEquals(_payload, payload)) {
      _key = _uuid.v4();
      _payload = payload;
    }
    emit(state.copyWith(busy: true, clearSaveError: true));
    try {
      final saved = await _repository.updateBeacon(
        idempotencyKey: _key!,
        request: request,
      );
      if (isClosed) return;
      if (!_scheduleApplied(request, saved.beacon)) {
        // A server from before F28 answers OK and ignores the new fields:
        // not "saved". The view is its answer, so a retry sends only what
        // is still different.
        emit(
          state.copyWith(
            busy: false,
            view: saved,
            saveError: kPlanScheduleNotSaved,
          ),
        );
        return;
      }
      emit(state.copyWith(busy: false, view: saved, saved: saved));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, saveError: beaconsErrorMessage(error)));
    }
  }

  static bool _movesSchedule(pb.UpdateBeaconRequest r) =>
      r.hasStartAt() || r.hasDurationMinutes() || r.hasCost();

  /// Whether [saved] carries the start, duration and cost [sent] asked for.
  static bool _scheduleApplied(pb.UpdateBeaconRequest sent, pb.Beacon saved) =>
      (!sent.hasStartAt() ||
          saved.startAt.toDateTime().isAtSameMomentAs(
            sent.startAt.toDateTime(),
          )) &&
      (!sent.hasDurationMinutes() ||
          saved.durationMinutes == sent.durationMinutes) &&
      (!sent.hasCost() || saved.cost == sent.cost);
}

/// The save error when the server kept the old start, duration or cost
/// (F28 not deployed there yet).
const kPlanScheduleNotSaved =
    "The new time or cost wasn't saved. Try again later.";
