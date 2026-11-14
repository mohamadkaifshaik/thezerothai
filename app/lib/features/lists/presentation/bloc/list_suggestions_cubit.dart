import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../data/lists_repository.dart';
import '../../domain/lists_feature_flag.dart';

/// The "Suggested members" card state: [loading] until the first answer;
/// [ready] with [items] (possibly none: the card hides); [failed] on any
/// error (the card hides, nothing is explained).
enum ListSuggestionsStatus { loading, ready, failed }

@immutable
class ListSuggestionsState {
  const ListSuggestionsState({
    this.status = ListSuggestionsStatus.loading,
    this.items = const [],
    this.busyIds = const {},
  });

  final ListSuggestionsStatus status;
  final List<graph.UserListItem> items;

  /// People with an AddListMember in flight.
  final Set<String> busyIds;

  ListSuggestionsState copyWith({
    ListSuggestionsStatus? status,
    List<graph.UserListItem>? items,
    Set<String>? busyIds,
  }) => ListSuggestionsState(
    status: status ?? this.status,
    items: items ?? this.items,
    busyIds: busyIds ?? this.busyIds,
  );
}

/// What [ListSuggestionsCubit.add] did.
class ListSuggestionAdded {
  const ListSuggestionAdded(this.item, this.error);

  /// The row that was added (null when nothing was sent).
  final graph.UserListItem? item;

  /// The failure for the snackbar, else null.
  final AppException? error;

  bool get added => item != null && error == null;
}

/// Up to [kListSuggestionsMax] people who may fit a List the viewer owns
/// (`ListSuggestedMembers`, one call per [load]), each with an Add button.
///
/// - Add sends one `AddListMember` with a fresh idempotency key per person
///   (kept for a retry of that person) and takes the row out on success. A
///   person the server says is gone (NOT_FOUND) or protected leaves too; the
///   other failures keep the row so Add can be tried again.
/// - The owner check and the `list_suggestions` flag are the screen's: this
///   cubit is only created once both hold.
class ListSuggestionsCubit extends Cubit<ListSuggestionsState> {
  ListSuggestionsCubit({
    required ListsRepository repository,
    required this.listId,
  }) : _repository = repository,
       super(const ListSuggestionsState());

  final ListsRepository _repository;
  final String listId;
  final Map<String, String> _keys = {};

  Future<void> load() async {
    try {
      final users = await _repository.listSuggestedMembers(
        listId: listId,
        maxResults: kListSuggestionsMax,
      );
      if (isClosed) return;
      emit(
        ListSuggestionsState(
          status: ListSuggestionsStatus.ready,
          items: users
              .where((u) => u.user.userId.isNotEmpty)
              .take(kListSuggestionsMax)
              .toList(),
        ),
      );
    } on AppException {
      if (isClosed) return;
      emit(const ListSuggestionsState(status: ListSuggestionsStatus.failed));
    }
  }

  Future<ListSuggestionAdded> add(String userId) async {
    final index = state.items.indexWhere((i) => i.user.userId == userId);
    if (index < 0 || state.busyIds.contains(userId)) {
      return const ListSuggestionAdded(null, null);
    }
    final item = state.items[index];
    emit(state.copyWith(busyIds: {...state.busyIds, userId}));
    final key = _keys[userId] ??= ListsRepository.newIdempotencyKey();
    try {
      await _repository.addMember(
        idempotencyKey: key,
        listId: listId,
        userId: userId,
      );
      _keys.remove(userId);
      _drop(userId);
      return ListSuggestionAdded(item, null);
    } on NotFoundException catch (error) {
      _drop(userId);
      return ListSuggestionAdded(null, error);
    } on ProtectedAccountException catch (error) {
      _drop(userId);
      return ListSuggestionAdded(null, error);
    } on AppException catch (error) {
      if (!isClosed) {
        emit(state.copyWith(busyIds: {...state.busyIds}..remove(userId)));
      }
      return ListSuggestionAdded(null, error);
    }
  }

  void _drop(String userId) {
    if (isClosed) return;
    emit(
      state.copyWith(
        items: [
          for (final i in state.items)
            if (i.user.userId != userId) i,
        ],
        busyIds: {...state.busyIds}..remove(userId),
      ),
    );
  }
}
