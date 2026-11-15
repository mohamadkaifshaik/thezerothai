import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/location_repository.dart';
import '../../domain/location_copy.dart';
import '../../domain/location_models.dart';
import '../location_error_messages.dart';

part 'location_settings_cubit.freezed.dart';

enum LocationLoad { initial, loading, ready, failed }

/// A one-off message for a snackbar; [LocationSettingsState.serial] makes each
/// one a new event.
enum LocationNotice { cleared, areaSet }

/// How a [LocationSettingsCubit.setArea] ended.
enum SetAreaResult {
  ok,

  /// The server wants a consent: run the rationale and try again.
  consentRequired,

  /// The server's required text is newer than this app's: nothing was sent.
  updateRequired,
  failed,
}

@freezed
abstract class LocationSettingsState with _$LocationSettingsState {
  const factory LocationSettingsState({
    @Default(LocationLoad.initial) LocationLoad load,
    LocationSettingsData? data,
    @Default(false) bool busy,
    AppException? error,
    LocationNotice? notice,
    @Default(0) int serial,
  }) = _LocationSettingsState;

  const LocationSettingsState._();

  AreaRef? get area => data?.area;

  /// SetArea may go without a new consent.
  bool get consentValid => data?.consentValid ?? false;
}

/// The caller's chosen area: load (memoised by the repository), set, clear.
/// Follows the repository's changes, so two open screens agree.
class LocationSettingsCubit extends Cubit<LocationSettingsState> {
  LocationSettingsCubit({required LocationRepository repository})
    : _repository = repository,
      super(const LocationSettingsState()) {
    _sub = repository.changes.listen((data) {
      if (!isClosed) emit(state.copyWith(data: data, load: LocationLoad.ready));
    });
  }

  final LocationRepository _repository;
  late final StreamSubscription<LocationSettingsData> _sub;

  /// Reads the settings. Nothing is sent while a value is shown, unless
  /// [refresh].
  Future<void> load({bool refresh = false}) async {
    if (!refresh && state.load == LocationLoad.ready) return;
    emit(state.copyWith(load: LocationLoad.loading, error: null));
    try {
      final data = await _repository.getSettings(refresh: refresh);
      if (isClosed) return;
      emit(state.copyWith(load: LocationLoad.ready, data: data));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          load: state.data == null ? LocationLoad.failed : LocationLoad.ready,
          error: error,
        ),
      );
    }
  }

  /// Stores [area]. [consent] comes from the rationale screen; null relies on
  /// the stored consent (a fresh one is asked for by [SetAreaResult.consentRequired]).
  Future<SetAreaResult> setArea(
    AreaRef area, {
    ConsentGrantData? consent,
  }) async {
    if (state.busy) return SetAreaResult.failed;
    final required = state.data?.requiredCopyVersion ?? 1;
    final current = state.data?.currentCopyVersion ?? 0;
    // The server's text is newer than this build's: never send a grant this
    // app cannot honour.
    if (required > kLocationConsentCopyVersion ||
        current > kLocationConsentCopyVersion) {
      emit(state.copyWith(error: locationUpdateRequired));
      return SetAreaResult.updateRequired;
    }
    emit(state.copyWith(busy: true, error: null));
    try {
      // The grant carries the server's current copy version (the one place
      // the version is chosen); 0 = not reported, use this build's.
      final data = await _repository.setArea(
        area.id,
        consent: consent == null
            ? null
            : ConsentGrantData(
                copyVersion: current > 0
                    ? current
                    : kLocationConsentCopyVersion,
                adultConfirmed: consent.adultConfirmed,
              ),
      );
      if (isClosed) return SetAreaResult.ok;
      emit(
        state.copyWith(
          busy: false,
          data: data,
          load: LocationLoad.ready,
          notice: LocationNotice.areaSet,
          serial: state.serial + 1,
        ),
      );
      return SetAreaResult.ok;
    } on AppException catch (error) {
      if (isClosed) return SetAreaResult.failed;
      if (isConsentRequired(error)) {
        emit(state.copyWith(busy: false));
        return SetAreaResult.consentRequired;
      }
      emit(state.copyWith(busy: false, error: error, serial: state.serial + 1));
      return SetAreaResult.failed;
    }
  }

  /// One tap, no confirmation: withdraws the consent and clears the area.
  Future<bool> clear() async {
    if (state.busy) return false;
    emit(state.copyWith(busy: true, error: null));
    try {
      final data = await _repository.clearArea();
      if (isClosed) return true;
      emit(
        state.copyWith(
          busy: false,
          data: data,
          load: LocationLoad.ready,
          notice: LocationNotice.cleared,
          serial: state.serial + 1,
        ),
      );
      return true;
    } on AppException catch (error) {
      if (isClosed) return false;
      emit(state.copyWith(busy: false, error: error, serial: state.serial + 1));
      return false;
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
