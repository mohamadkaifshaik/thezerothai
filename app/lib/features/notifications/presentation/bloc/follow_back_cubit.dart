import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/notifications/v1/notifications.pb.dart' as pb;
import '../../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../../../graph/data/graph_repository.dart';
import '../../data/notifications_store.dart';

/// The actor a follow row can offer "Follow back" to, or null: a FOLLOW
/// notification from one person (a collapsed "Alice and 2 others followed
/// you" names no single account to follow back), with a known id.
String? followBackActorOf(pb.Notification n) {
  if (n.type != NotificationType.NOTIFICATION_TYPE_FOLLOW) return null;
  if (n.actorCount > 1) return null;
  final id = n.actor.userId;
  return id.isEmpty ? null : id;
}

/// What the follow rows know about the viewer and each follow actor.
@immutable
class FollowBackState {
  const FollowBackState({
    this.relationships = const {},
    this.failed = const {},
  });

  /// The relationship to each actor already answered (seeds the row's
  /// `RelationshipCubit`).
  final Map<String, graph.Relationship> relationships;

  /// Actors whose last ask failed: their row draws no control. Every other
  /// unknown actor is still to be answered, and its row keeps the control's
  /// line so it does not jump when the button arrives.
  final Set<String> failed;

  @override
  bool operator ==(Object other) =>
      other is FollowBackState &&
      mapEquals(other.relationships, relationships) &&
      setEquals(other.failed, failed);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(relationships.keys),
    Object.hashAllUnordered(failed),
  );
}

/// F14, "Follow back" on a follow notification: the viewer's relationship to
/// the actor of every follow row, asked **once per page** in one batched
/// `GetRelationships` ([GraphRepository.relationshipsFor], which sends only
/// the ids it has not cached this session). Never one call per row.
///
/// The screen calls [resolve] with the rows it has whenever a page lands;
/// ids already asked (answered or in flight) are skipped, so a page that
/// adds no new follow actor costs nothing. A failed answer drops the
/// control from those rows (no banner; the row still opens the profile) and
/// lets the next page ask for them again.
class FollowBackCubit extends Cubit<FollowBackState> {
  FollowBackCubit({required GraphRepository graph})
    : _graph = graph,
      super(const FollowBackState());

  final GraphRepository _graph;
  final Set<String> _asked = {};

  /// Asks for the actors of the follow rows in [entries] not asked yet.
  Future<void> resolve(Iterable<NotificationEntry> entries) async {
    final ids = <String>{
      for (final e in entries)
        if (!e.isGap) ?followBackActorOf(e.value!),
    }.where((id) => !_asked.contains(id)).toList();
    if (ids.isEmpty) return;
    _asked.addAll(ids);
    if (ids.any(state.failed.contains)) {
      emit(
        FollowBackState(
          relationships: state.relationships,
          failed: {...state.failed}..removeAll(ids),
        ),
      );
    }
    try {
      final answers = await _graph.relationshipsFor(ids);
      if (isClosed) return;
      emit(
        FollowBackState(
          relationships: {...state.relationships, ...answers},
          failed: state.failed,
        ),
      );
    } on AppException {
      if (isClosed) return;
      _asked.removeAll(ids);
      emit(
        FollowBackState(
          relationships: state.relationships,
          failed: {...state.failed, ...ids},
        ),
      );
    }
  }
}
