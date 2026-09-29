import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

part 'relationship_state.freezed.dart';

/// The caller's relationship to one user, plus the in-flight/optimistic
/// status of the last action taken on it. Drives [FollowButton] and the
/// profile header's block/mute menu.
@freezed
abstract class RelationshipState with _$RelationshipState {
  const factory RelationshipState({
    required graph.Relationship relationship,
    @Default(false) bool isUpdating,
    AppException? error,
  }) = _RelationshipState;
}
