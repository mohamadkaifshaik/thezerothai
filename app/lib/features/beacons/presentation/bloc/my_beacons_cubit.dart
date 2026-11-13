import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import 'beacons_state.dart' show BeaconsLoad;
import 'my_beacons_state.dart';

/// `/plans/mine` (R39): one ListMyBeacons of 20 per selection; a window or
/// role change starts a fresh page; load-more appends; a stale answer is
/// dropped.
///
/// With [pageSize] 2 it is the "Your plans" section of `/plans` on the
/// tablet layout (tablet plan section 4.1: the caller's next plans, every
/// role, upcoming; one extra list call, limit 2).
class MyBeaconsCubit extends Cubit<MyBeaconsState> {
  MyBeaconsCubit({required BeaconsRepository repository, int pageSize = 20})
    : _repository = repository,
      _pageSize = pageSize,
      super(const MyBeaconsState());

  final int _pageSize;

  final BeaconsRepository _repository;
  int _generation = 0;

  /// First-page loads ([load], [select]) still running.
  int _inFlight = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  /// Whether a first page was ever asked for.
  bool get started => _generation > 0;

  /// [load] unless one was already started (a second placement of the same
  /// hoisted cubit).
  Future<void> ensureLoaded() => started ? Future.value() : load();

  /// [load] unless a first page is already on its way.
  Future<void> refresh() => _inFlight > 0 ? Future.value() : load();

  Future<void> load() {
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: state.views.isEmpty ? BeaconsLoad.loading : null,
        clearError: true,
      ),
    );
    return _tracked(_loadFirstPage(generation));
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
    return _tracked(_loadFirstPage(generation));
  }

  Future<void> _tracked(Future<void> load) async {
    _inFlight++;
    try {
      await load;
    } finally {
      _inFlight--;
    }
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
