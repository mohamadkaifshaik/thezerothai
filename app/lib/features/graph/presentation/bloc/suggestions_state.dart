import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

part 'suggestions_state.freezed.dart';

/// The "Who to follow" rows that may be shown right now: at most 5, best
/// first, already stripped of dismissed and followed accounts. Empty means
/// every surface shows nothing (loading, no suggestions, flag off at the
/// server, a limit, or a failure: the card never explains itself).
@freezed
abstract class SuggestionsState with _$SuggestionsState {
  const factory SuggestionsState({
    @Default(<graph.UserListItem>[]) List<graph.UserListItem> items,
  }) = _SuggestionsState;
}
