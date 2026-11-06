import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
/// changed means no call.
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

  Future<void> save({
    required String title,
    required String details,
    required String venue,
    required int openSpots,
  }) async {
    final view = state.view;
    if (state.busy || view == null) return;
    final b = view.beacon;
    final request = pb.UpdateBeaconRequest(beaconId: _beaconId);
    if (title != b.title) request.title = title;
    if (details != b.details) request.details = details;
    if (venue != b.venue) request.venue = venue;
    if (openSpots != b.openSpots) request.openSpots = openSpots;
    if (!request.hasTitle() &&
        !request.hasDetails() &&
        !request.hasVenue() &&
        !request.hasOpenSpots()) {
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
      emit(state.copyWith(busy: false, view: saved, saved: saved));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, saveError: beaconsErrorMessage(error)));
    }
  }
}
