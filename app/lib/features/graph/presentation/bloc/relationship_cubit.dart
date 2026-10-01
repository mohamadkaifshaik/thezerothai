import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../data/graph_repository.dart';
import 'relationship_state.dart';

/// Local, non-deprecated alternative to the protobuf-generated `copyWith`
/// (deprecated, see https://github.com/google/protobuf.dart/issues/998),
/// used for the optimistic-update/rollback dance below.
extension RelationshipUpdate on graph.Relationship {
  graph.Relationship updated({
    graph.FollowState? followState,
    bool? blocking,
    bool? muting,
  }) {
    return graph.Relationship(
      userId: userId,
      followState: followState ?? this.followState,
      blocking: blocking ?? this.blocking,
      muting: muting ?? this.muting,
    );
  }
}

/// Drives one user's relationship: optimistic follow/unfollow/block/
/// unblock/mute/unmute, with rollback on failure (CLAUDE.md: "Optimistic
/// updates with rollback"). One instance per (viewer, target) pair — created
/// fresh for every profile header and every list row.
class RelationshipCubit extends Cubit<RelationshipState> {
  RelationshipCubit({
    required GraphRepository graphRepository,
    required this.userId,
    required graph.Relationship initial,
    Uuid? uuid,
  }) : _graphRepository = graphRepository,
       _uuid = uuid ?? const Uuid(),
       super(RelationshipState(relationship: initial));

  final GraphRepository _graphRepository;
  final String userId;
  final Uuid _uuid;

  // One idempotency key per user "intent" (CLAUDE.md rule 4 / ADR-0003):
  // generated on the first attempt, reused on every retry of that same
  // intent (including a user tapping the button again after a failed
  // attempt), and cleared only once the server confirms it — so a dropped
  // response can never double the mutation.
  String? _followKey;
  String? _blockKey;
  String? _muteKey;

  Future<void> follow() => _mutate(
    keyOf: () => _followKey ??= _uuid.v4(),
    onSuccess: () => _followKey = null,
    optimistic: (r) =>
        r.updated(followState: graph.FollowState.FOLLOW_STATE_FOLLOWING),
    call: (key) => _graphRepository.follow(userId: userId, idempotencyKey: key),
  );

  Future<void> unfollow() => _mutate(
    keyOf: () => _followKey ??= _uuid.v4(),
    onSuccess: () => _followKey = null,
    optimistic: (r) =>
        r.updated(followState: graph.FollowState.FOLLOW_STATE_NONE),
    call: (key) =>
        _graphRepository.unfollow(userId: userId, idempotencyKey: key),
  );

  Future<void> block() => _mutate(
    keyOf: () => _blockKey ??= _uuid.v4(),
    onSuccess: () => _blockKey = null,
    optimistic: (r) => r.updated(
      blocking: true,
      followState: graph.FollowState.FOLLOW_STATE_NONE,
    ),
    call: (key) => _graphRepository.block(userId: userId, idempotencyKey: key),
  );

  Future<void> unblock() => _mutate(
    keyOf: () => _blockKey ??= _uuid.v4(),
    onSuccess: () => _blockKey = null,
    optimistic: (r) => r.updated(blocking: false),
    call: (key) =>
        _graphRepository.unblock(userId: userId, idempotencyKey: key),
  );

  Future<void> mute() => _mutate(
    keyOf: () => _muteKey ??= _uuid.v4(),
    onSuccess: () => _muteKey = null,
    optimistic: (r) => r.updated(muting: true),
    call: (key) => _graphRepository.mute(userId: userId, idempotencyKey: key),
  );

  Future<void> unmute() => _mutate(
    keyOf: () => _muteKey ??= _uuid.v4(),
    onSuccess: () => _muteKey = null,
    optimistic: (r) => r.updated(muting: false),
    call: (key) => _graphRepository.unmute(userId: userId, idempotencyKey: key),
  );

  Future<void> _mutate({
    required String Function() keyOf,
    required void Function() onSuccess,
    required graph.Relationship Function(graph.Relationship current) optimistic,
    required Future<graph.Relationship> Function(String key) call,
  }) async {
    if (state.isUpdating) return;
    final previous = state.relationship;
    final key = keyOf();
    emit(
      state.copyWith(
        relationship: optimistic(previous),
        isUpdating: true,
        error: null,
      ),
    );
    try {
      final updated = await call(key);
      onSuccess();
      if (isClosed) return;
      emit(RelationshipState(relationship: updated));
    } on AppException catch (e) {
      // Roll back to the pre-optimistic relationship. Never auto-retry
      // DegradedModeException (CLAUDE.md); the caller decides whether to
      // offer a manual retry, which reuses the same key via [keyOf].
      if (isClosed) return;
      emit(state.copyWith(relationship: previous, isUpdating: false, error: e));
    }
  }
}
