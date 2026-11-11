import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../communities/data/communities_repository.dart';
import '../../data/beacons_repository.dart';
import 'beacons_state.dart';

/// `/plans`: audience chips and one ListBeacons per selected chip (R30).
///
/// - **Chips.** Public first, then one per joined community from the
///   communities session cache (0 calls once the Communities screen or a
///   compose loaded it; one ListMyCommunities otherwise). With `communities`
///   off for the caller, or when that lookup fails, the chips are Public only
///   and the list still loads.
/// - **Pages.** `limit` 20, `from` unset (the server's now); [loadMore]
///   appends with the token; a chip switch starts a fresh page. A generation
///   counter drops a stale answer (a load that finished after a later select).
class BeaconsCubit extends Cubit<BeaconsState> {
  BeaconsCubit({
    required BeaconsRepository repository,
    CommunitiesRepository? communities,
    bool communitiesEnabled = false,
  }) : _repository = repository,
       _communities = communitiesEnabled ? communities : null,
       super(const BeaconsState());

  static const _pageSize = 20;

  final BeaconsRepository _repository;
  final CommunitiesRepository? _communities;
  int _generation = 0;

  /// First-page loads ([load], [select]) still running.
  int _inFlight = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  /// Whether a first page was ever asked for (tablet T5: the hoisted list
  /// is shared by two placements, see [ensureLoaded]).
  bool get started => _generation > 0;

  /// [load] unless one was already started: the band B list pane, which
  /// shows the list the route already opened.
  Future<void> ensureLoaded() => started ? Future.value() : load();

  /// [load] unless a first page is already on its way (the list pane and the
  /// route open together in band B: one ListBeacons, not two).
  Future<void> refresh() => _inFlight > 0 ? Future.value() : load();

  /// Loads the chips (once per [load]) and the selected audience's first page.
  Future<void> load() async {
    final generation = ++_generation;
    _inFlight++;
    try {
      emit(
        state.copyWith(
          status: state.views.isEmpty ? BeaconsLoad.loading : null,
          clearError: true,
        ),
      );
      final audiences = await _audiences();
      if (_stale(generation)) return;
      final selected = audiences.contains(state.selected)
          ? state.selected
          : const BeaconsAudience.public();
      emit(state.copyWith(audiences: audiences, selected: selected));
      await _loadFirstPage(generation);
    } finally {
      _inFlight--;
    }
  }

  /// Switches the audience and loads its first page.
  Future<void> select(BeaconsAudience audience) async {
    if (audience == state.selected && state.status == BeaconsLoad.ready) {
      return;
    }
    final generation = ++_generation;
    _inFlight++;
    try {
      emit(
        state.copyWith(
          selected: audience,
          status: BeaconsLoad.loading,
          views: const [],
          nextPageToken: '',
          loadingMore: false,
          clearError: true,
        ),
      );
      await _loadFirstPage(generation);
    } finally {
      _inFlight--;
    }
  }

  /// Appends the next page; nothing when there is none or one is in flight.
  Future<void> loadMore() async {
    if (!state.hasMore ||
        state.loadingMore ||
        state.status != BeaconsLoad.ready) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await _repository.listBeacons(
        communityId: state.selected.id,
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

  Future<List<BeaconsAudience>> _audiences() async {
    final communities = _communities;
    if (communities == null) return const [BeaconsAudience.public()];
    try {
      final mine = await communities.myCommunities();
      return [
        const BeaconsAudience.public(),
        for (final c in mine.communities)
          BeaconsAudience.community(c.communityId, c.name),
      ];
    } on AppException {
      return const [BeaconsAudience.public()];
    }
  }

  Future<void> _loadFirstPage(int generation) async {
    try {
      final page = await _repository.listBeacons(
        communityId: state.selected.id,
        limit: _pageSize,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          status: BeaconsLoad.ready,
          views: page.views,
          nextPageToken: page.nextPageToken,
          loadingMore: false,
          clearError: true,
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
