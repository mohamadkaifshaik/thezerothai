import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import 'beacons_state.dart' show BeaconsLoad;
import 'my_beacons_state.dart';

/// `/plans/mine` (R39): one ListMyBeacons of 20 per selection; a window or
/// role change starts a fresh page; load-more appends; a stale answer is
/// dropped.
class MyBeaconsCubit extends Cubit<MyBeaconsState> {
  MyBeaconsCubit({required BeaconsRepository repository})
    : _repository = repository,
      super(const MyBeaconsState());

  static const _pageSize = 20;

  final BeaconsRepository _repository;
  int _generation = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  Future<void> load() {
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: state.views.isEmpty ? BeaconsLoad.loading : null,
        clearError: true,
      ),
    );
    return _loadFirstPage(generation);
  }

  Future<void> select({pb.MyBeaconsWindow? window, pb.MyBeaconsRole? role}) {
    final generation = ++_generation;
    emit(
      state.copyWith(
        window: window,
        role: role,
        status: BeaconsLoad.loading,
        views: const [],
        nextPageToken: '',
        loadingMore: false,
        clearError: true,
      ),
    );
    return _loadFirstPage(generation);
  }

  Future<void> loadMore() async {
    if (!state.hasMore ||
        state.loadingMore ||
        state.status != BeaconsLoad.ready) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await _repository.listMyBeacons(
        role: state.role,
        window: state.window,
        limit: _pageSize,
        pageToken: state.nextPageToken,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          views: [...state.views, ...page.views],
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(state.copyWith(loadingMore: false, error: error));
    }
  }

  Future<void> _loadFirstPage(int generation) async {
    try {
      final page = await _repository.listMyBeacons(
        role: state.role,
        window: state.window,
        limit: _pageSize,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          status: BeaconsLoad.ready,
          views: page.views,
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          status: BeaconsLoad.error,
          views: const [],
          nextPageToken: '',
          loadingMore: false,
          error: error,
        ),
      );
    }
  }
}
