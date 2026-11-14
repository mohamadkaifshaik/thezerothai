import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../domain/message_search.dart';

part 'message_search_state.freezed.dart';

enum MessageSearchStatus {
  /// No query typed (or a blank one).
  idle,

  /// The cached rows are being read.
  searching,

  /// [MessageSearchState.groups] is the answer to [MessageSearchState.query].
  ready,
}

/// What the message search shows: the query and its hits, grouped by
/// conversation. Lives only as long as the search UI (never persisted).
@freezed
abstract class MessageSearchState with _$MessageSearchState {
  const factory MessageSearchState({
    @Default('') String query,
    @Default(MessageSearchStatus.idle) MessageSearchStatus status,
    @Default(<ConversationHits>[]) List<ConversationHits> groups,

    /// True when older pages of the one searched conversation can be fetched.
    @Default(false) bool canLoadOlder,
    @Default(false) bool loadingOlder,

    /// Older pages fetched so far in this search (held in memory only).
    @Default(0) int olderPages,
    AppException? olderError,
  }) = _MessageSearchState;
}

extension MessageSearchStateX on MessageSearchState {
  int get hitCount => groups.fold(0, (sum, g) => sum + g.hits.length);

  bool get hasQuery => query.trim().isNotEmpty;
}
