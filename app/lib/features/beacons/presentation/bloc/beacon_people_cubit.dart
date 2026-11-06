import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../graph/data/graph_repository.dart';
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';
import 'beacon_people_state.dart';

/// One tab of `/plans/:id/people` (R38): ListParticipants of one filter, 20
/// per page, and the organiser's accept, decline, decline-and-block and
/// remove, each with one key per target user (R36) and a reload after (R35).
///
/// "Decline and block" is two writes: the decline, then `GraphRepository.block`
/// with its own key. A block that fails after a successful decline reports the
/// failure (the generic copy, the rate-limit copy when it is one) and still
/// reloads: the request is gone either way, and a retry would decline a row
/// that is no longer there.
class BeaconPeopleCubit extends Cubit<BeaconPeopleState> {
  BeaconPeopleCubit({
    required BeaconsRepository repository,
    required String beaconId,
    required pb.ParticipantFilter filter,
    GraphRepository? graph,
  }) : _repository = repository,
       _beaconId = beaconId,
       _filter = filter,
       _graph = graph,
       super(const BeaconPeopleState());

  static const _uuid = Uuid();
  static const _pageSize = 20;

  final BeaconsRepository _repository;
  final String _beaconId;
  final pb.ParticipantFilter _filter;
  final GraphRepository? _graph;
  final Map<String, String> _keys = {};
  int _generation = 0;

  bool _stale(int generation) => isClosed || generation != _generation;

  Future<void> load() async {
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: state.rows.isEmpty ? PeopleLoad.loading : null,
        clearError: true,
      ),
    );
    try {
      final page = await _repository.listParticipants(
        beaconId: _beaconId,
        filter: _filter,
        limit: _pageSize,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          status: PeopleLoad.ready,
          rows: page.participants,
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          status: PeopleLoad.error,
          rows: const [],
          nextPageToken: '',
          loadingMore: false,
          error: error,
        ),
      );
    }
  }

  Future<void> loadMore() async {
    if (!state.hasMore ||
        state.loadingMore ||
        state.status != PeopleLoad.ready) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await _repository.listParticipants(
        beaconId: _beaconId,
        filter: _filter,
        limit: _pageSize,
        pageToken: state.nextPageToken,
      );
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          rows: [...state.rows, ...page.participants],
          nextPageToken: page.nextPageToken,
          loadingMore: false,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(state.copyWith(loadingMore: false, error: error));
    }
  }

  Future<bool> accept(String userId) => _act('accept', userId, (key) async {
    await _repository.respondToJoinRequest(
      idempotencyKey: key,
      beaconId: _beaconId,
      userId: userId,
      accept: true,
    );
  });

  Future<bool> decline(String userId) => _act('decline', userId, (key) async {
    await _repository.respondToJoinRequest(
      idempotencyKey: key,
      beaconId: _beaconId,
      userId: userId,
      accept: false,
    );
  });

  Future<bool> remove(String userId) => _act('remove', userId, (key) async {
    await _repository.removeParticipant(
      idempotencyKey: key,
      beaconId: _beaconId,
      userId: userId,
    );
  });

  /// Declines, then blocks. False when either write was refused; the decline
  /// is never retried once it succeeded (its key is dropped before the block).
  Future<bool> declineAndBlock(String userId) async {
    final graph = _graph;
    if (graph == null) return decline(userId);
    return _act('decline', userId, (key) async {
      await _repository.respondToJoinRequest(
        idempotencyKey: key,
        beaconId: _beaconId,
        userId: userId,
        accept: false,
      );
      _keys.remove('decline|$userId');
      final blockKey = _keys.putIfAbsent('block|$userId', _uuid.v4);
      await graph.block(userId: userId, idempotencyKey: blockKey);
      _keys.remove('block|$userId');
    }, copy: _blockCopy);
  }

  static String _blockCopy(AppException error) => switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    _ => beaconsErrorMessage(error),
  };

  Future<bool> _act(
    String kind,
    String userId,
    Future<void> Function(String key) write, {
    String Function(AppException) copy = beaconsErrorMessage,
  }) async {
    if (state.busyUserId != null) return false;
    final key = _keys.putIfAbsent('$kind|$userId', _uuid.v4);
    emit(state.copyWith(busyUserId: userId, clearActionError: true));
    var ok = false;
    try {
      await write(key);
      _keys.remove('$kind|$userId');
      ok = true;
    } on AppException catch (error) {
      if (isClosed) return false;
      emit(state.copyWith(actionError: copy(error)));
    }
    if (isClosed) return ok;
    emit(state.copyWith(clearBusy: true));
    await load();
    return ok;
  }
}
