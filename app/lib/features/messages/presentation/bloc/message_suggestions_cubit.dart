import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../data/messaging_repository.dart';
import '../../domain/message_suggestions.dart';

/// [idle] before [load], [loading], [ready] (rows, possibly none) or [failed]
/// (the picker draws nothing for it).
enum MessageSuggestionsStatus { idle, loading, ready, failed }

@immutable
class MessageSuggestionsState {
  const MessageSuggestionsState({
    this.status = MessageSuggestionsStatus.idle,
    this.suggestions = const [],
  });

  final MessageSuggestionsStatus status;
  final List<pb.MessageSuggestion> suggestions;
}

/// One `ListMessageSuggestions` when the picker opens (no paging, no polling).
/// Every failure is quiet: the picker keeps its Following list, nothing is
/// shown or retried. The caller checks `messaging` and `dm_suggestions`.
class MessageSuggestionsCubit extends Cubit<MessageSuggestionsState> {
  MessageSuggestionsCubit({
    required MessagingRepository repository,
    this.ownUserId,
  }) : _repository = repository,
       super(const MessageSuggestionsState());

  final MessagingRepository _repository;
  final String? ownUserId;

  Future<void> load() async {
    if (state.status == MessageSuggestionsStatus.loading) return;
    emit(
      const MessageSuggestionsState(status: MessageSuggestionsStatus.loading),
    );
    try {
      final rows = await _repository.listMessageSuggestions(
        limit: kMessageSuggestionsLimit,
      );
      if (isClosed) return;
      final seen = <String>{};
      emit(
        MessageSuggestionsState(
          status: MessageSuggestionsStatus.ready,
          suggestions: [
            for (final s in rows)
              if (s.user.userId.isNotEmpty &&
                  s.user.userId != ownUserId &&
                  seen.add(s.user.userId))
                s,
          ],
        ),
      );
    } on Object {
      // Quiet: the existing picker stands.
      if (!isClosed) {
        emit(
          const MessageSuggestionsState(
            status: MessageSuggestionsStatus.failed,
          ),
        );
      }
    }
  }
}
