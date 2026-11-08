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
/// with its own key. A block that fails after a successful decline says so
/// ([blockFailedCopy]), reloads (the request is gone either way) and offers a
/// retry that only blocks.
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

  /// Declined users still to block (user id to handle), mirrored into
  /// [BeaconPeopleState.pendingBlocks].
  final Map<String, String> _pendingBlock = {};
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

  /// Declines, then blocks. Once the decline went through (or the server says
  /// there is no open request any more) the user is parked in [_pendingBlock]:
  /// a failed block keeps that, says so, and a retry only blocks, with the
  /// same block key.
  Future<bool> declineAndBlock(String userId) async {
    final graph = _graph;
    if (graph == null) return decline(userId);
    return _act(
      'decline',
      userId,
      (key) async {
        if (!_pendingBlock.containsKey(userId)) {
          try {
            await _repository.respondToJoinRequest(
              idempotencyKey: key,
              beaconId: _beaconId,
              userId: userId,
              accept: false,
            );
          } on StateConflictException catch (error) {
            if (error.reason != 'not_requested') rethrow;
          }
          _keys.remove('decline|$userId');
          final handle = state.rows
              .where((p) => p.user.userId == userId)
              .map((p) => p.user.handle)
              .firstOrNull;
          _pendingBlock[userId] = handle ?? '';
          _syncPending();
        }
        final blockKey = _keys.putIfAbsent('block|$userId', _uuid.v4);
        await graph.block(userId: userId, idempotencyKey: blockKey);
        _keys.remove('block|$userId');
        _pendingBlock.remove(userId);
        _syncPending();
      },
      copy: (error) => _pendingBlock.containsKey(userId)
          ? switch (error) {
              final RateLimitedException e =>
                '$blockFailedCopy ${rateLimitedMessage(e)}',
              _ => blockFailedCopy,
            }
          : beaconsErrorMessage(error),
      retryBlock: () => _pendingBlock.containsKey(userId),
    );
  }

  /// Blocks a user whose request was already declined (see [declineAndBlock]).
  Future<bool> retryBlock(String userId) => declineAndBlock(userId);

  void _syncPending() {
    if (!isClosed) {
      emit(state.copyWith(pendingBlocks: Map.of(_pendingBlock)));
    }
  }

  static const blockFailedCopy =
      'Request declined, but blocking failed. Retry block?';

  Future<bool> _act(
    String kind,
    String userId,
    Future<void> Function(String key) write, {
    String Function(AppException) copy = beaconsErrorMessage,
    bool Function()? retryBlock,
  }) async {
    if (state.busyUserId != null) return false;
    final key = _keys.putIfAbsent('$kind|$userId', _uuid.v4);
    emit(
      state.copyWith(
        busyUserId: userId,
        clearActionError: true,
        clearRetryBlock: true,
      ),
    );
    var ok = false;
    try {
      await write(key);
      _keys.remove('$kind|$userId');
      ok = true;
    } on AppException catch (error) {
      if (isClosed) return false;
      emit(
        state.copyWith(
          actionError: copy(error),
          retryBlockUserId: retryBlock != null && retryBlock() ? userId : null,
          clearRetryBlock: retryBlock == null || !retryBlock(),
        ),
      );
    }
    if (isClosed) return ok;
    emit(state.copyWith(clearBusy: true));
    await load();
    return ok;
  }
}
