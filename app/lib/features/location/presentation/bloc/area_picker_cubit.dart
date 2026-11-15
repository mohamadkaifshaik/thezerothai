import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/location_repository.dart';
import '../../domain/area_search.dart';
import '../../domain/location_models.dart';

part 'area_picker_cubit.freezed.dart';

enum AreaPickerLoad { loading, ready, failed }

@freezed
abstract class AreaPickerState with _$AreaPickerState {
  const factory AreaPickerState({
    @Default(AreaPickerLoad.loading) AreaPickerLoad load,
    @Default(<AreaEntry>[]) List<AreaEntry> areas,
    @Default('') String query,
    AppException? error,
  }) = _AreaPickerState;

  const AreaPickerState._();

  /// The matches of [query], best first.
  List<AreaEntry> get results => searchAreas(areas, query);
}

/// The catalogue behind the picker, searched on the device.
class AreaPickerCubit extends Cubit<AreaPickerState> {
  AreaPickerCubit({required LocationRepository repository})
    : _repository = repository,
      super(const AreaPickerState());

  final LocationRepository _repository;

  Future<void> load() async {
    emit(state.copyWith(load: AreaPickerLoad.loading, error: null));
    try {
      final catalog = await _repository.catalog();
      if (isClosed) return;
      emit(state.copyWith(load: AreaPickerLoad.ready, areas: catalog.areas));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(state.copyWith(load: AreaPickerLoad.failed, error: error));
    }
  }

  void search(String query) => emit(state.copyWith(query: query));
}
