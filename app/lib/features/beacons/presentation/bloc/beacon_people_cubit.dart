import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/format/rate_limited_message.dart';
import '../../../graph/data/graph_repository.dart';
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';
import 'beacon_people_state.dart';
import 'pending_beacon_blocks.dart';

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
    PendingBeaconBlocks? pendingBlocks,
  }) : _repository = repository,
       _beaconId = beaconId,
       _filter = filter,
       _graph = graph,
       _pending = pendingBlocks ?? PendingBeaconBlocks(),
       _ownsPending = pendingBlocks == null,
       super(
         BeaconPeopleState(
           pendingBlocks: pendingBlocks?.handles(beaconId) ?? const {},
         ),
       ) {
    _pending.addListener(_syncPending);
  }

  static const _uuid = Uuid();
  static const _pageSize = 20;

  final BeaconsRepository _repository;
  final String _beaconId;
  final pb.ParticipantFilter _filter;
  final GraphRepository? _graph;
  final Map<String, String> _keys = {};

  final PendingBeaconBlocks _pending;
  final bool _ownsPending;

  @override
  Future<void> close() {
    _pending.removeListener(_syncPending);
    if (_ownsPending) _pending.dispose();
    return super.close();
  }

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
  /// there is no open request any more) the user is parked in the account session:
  /// a failed block keeps that, says so, and a retry only blocks, with the
  /// same block key.
  ///
  /// Without a graph repository (blocking unavailable in this scope) this
  /// deliberately degrades to a plain [decline]: the request is still
  /// answered, only the block is skipped.
  Future<bool> declineAndBlock(String userId) async {
    if (!_pending.active) return false;
    final graph = _graph;
    if (graph == null) return decline(userId);
    return _act(
      'decline',
      userId,
      (key) async {
        if (_pending.keyFor(_beaconId, userId) == null) {
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
          _pending.record(_beaconId, userId, handle ?? '', _uuid.v4());
        }
        final blockKey = _pending.keyFor(_beaconId, userId);
        if (blockKey == null) return;
        await graph.block(userId: userId, idempotencyKey: blockKey);
        _pending.complete(_beaconId, userId, blockKey);
      },
      copy: (error) => _pending.keyFor(_beaconId, userId) != null
          ? switch (error) {
              final RateLimitedException e =>
                '$blockFailedCopy ${rateLimitedMessage(e)}',
              _ => blockFailedCopy,
            }
          : beaconsErrorMessage(error),
      retryBlock: () => _pending.keyFor(_beaconId, userId) != null,
    );
  }

  /// Blocks a user whose request was already declined (see [declineAndBlock]).
  Future<bool> retryBlock(String userId) async {
    if (_pending.keyFor(_beaconId, userId) == null) return false;
    return declineAndBlock(userId);
  }

  void _syncPending() {
    if (!isClosed) {
      emit(state.copyWith(pendingBlocks: _pending.handles(_beaconId)));
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
    if (isClosed || state.busyUserId != null) return false;
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
