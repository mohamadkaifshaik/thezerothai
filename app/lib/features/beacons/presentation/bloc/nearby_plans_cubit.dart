import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../location/domain/location_models.dart';
import '../../data/beacons_repository.dart';

part 'nearby_plans_cubit.freezed.dart';

/// The server's `metadata["reason"]` of ListNearbyBeacons when the caller has
/// no stored area.
const kAreaNotSetReason = 'area_not_set';

/// [loading] first page on its way, [ready] items (or the empty state),
/// [noArea] the caller has no area (the prompt), [error] the first page
/// failed, [disabled] the server says Nearby is off (the tab goes away).
enum NearbyLoad { loading, ready, noArea, error, disabled }

@freezed
abstract class NearbyPlansState with _$NearbyPlansState {
  const factory NearbyPlansState({
    @Default(NearbyLoad.loading) NearbyLoad load,
    @Default(<pb.NearbyBeacon>[]) List<pb.NearbyBeacon> items,
    @Default('') String nextPageToken,
    @Default(false) bool loadingMore,
    AreaRef? area,
    pb.NearbyCount? count,
    @Default(pb.NearbyScope.NEARBY_SCOPE_AREA) pb.NearbyScope scope,
    AppException? error,
  }) = _NearbyPlansState;

  const NearbyPlansState._();

  bool get hasMore => nextPageToken.isNotEmpty;

  /// The scope switch shows for a neighbourhood only: a city area always
  /// reads at city scope on the server.
  bool get canSwitchScope => area != null && area!.type != AreaType.city;
}

/// Explore's Nearby tab: public plans in the caller's stored area (area_id
/// empty), 20 per page with the cursor, an Area / City scope, and the count
/// of the first page. A generation counter drops a stale answer (a load that
/// finished after a scope switch).
class NearbyPlansCubit extends Cubit<NearbyPlansState> {
  NearbyPlansCubit({required BeaconsRepository repository})
    : _repository = repository,
      super(const NearbyPlansState());

  static const pageSize = 20;

  final BeaconsRepository _repository;
  int _generation = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  /// First page of the current scope. Keeps the rows on screen while a
  /// refresh runs.
  Future<void> load() async {
    final generation = ++_generation;
    if (state.items.isEmpty || state.load != NearbyLoad.ready) {
      emit(state.copyWith(load: NearbyLoad.loading, error: null));
    }
    await _first(generation);
  }

  /// Switches the scope and loads its first page.
  Future<void> setScope(pb.NearbyScope scope) async {
    if (scope == state.scope && state.load == NearbyLoad.ready) return;
    final generation = ++_generation;
    emit(
      state.copyWith(
        scope: scope,
        load: NearbyLoad.loading,
        items: const [],
        nextPageToken: '',
        loadingMore: false,
        count: null,
        error: null,
      ),
    );
    await _first(generation);
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.loadingMore || state.load != NearbyLoad.ready) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, error: null));
    try {
      final page = await _repository.listNearby(
        scope: state.scope,
        limit: pageSize,
        pageToken: state.nextPageToken,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          items: [...state.items, ...page.items],
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(state.copyWith(loadingMore: false, error: error));
    }
  }

  Future<void> _first(int generation) async {
    try {
      final page = await _repository.listNearby(
        scope: state.scope,
        limit: pageSize,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          load: NearbyLoad.ready,
          items: page.items,
          nextPageToken: page.nextPageToken,
          loadingMore: false,
          area: page.area ?? state.area,
          count: page.count,
          error: null,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      if (error is StateConflictException &&
          error.reason == kAreaNotSetReason) {
        emit(
          state.copyWith(
            load: NearbyLoad.noArea,
            items: const [],
            nextPageToken: '',
            loadingMore: false,
            area: null,
            count: null,
            error: null,
          ),
        );
      } else if (error is FeatureDisabledException) {
        emit(state.copyWith(load: NearbyLoad.disabled, error: error));
      } else {
        emit(
          state.copyWith(
            load: NearbyLoad.error,
            items: const [],
            nextPageToken: '',
            loadingMore: false,
            error: error,
          ),
        );
      }
    }
  }
}
