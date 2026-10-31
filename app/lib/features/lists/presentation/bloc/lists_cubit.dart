import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../data/lists_repository.dart';
import 'lists_state.dart';

/// The caller's own Lists (W5-11): 1 `ListUserLists` per [load]. The owner has
/// at most 20 lists, so one page of 50 holds them all; the token is still
/// followed (a short page can carry one) up to [_maxPages] pages.
class ListsCubit extends Cubit<ListsState> {
  ListsCubit({required ListsRepository repository, this.ownerId = ''})
    : _repository = repository,
      super(const ListsState());

  /// Whose lists: empty = the caller's own; a user id = that user's public
  /// lists (W5-13, `/u/:id/lists`).
  final String ownerId;

  static const _pageSize = 50;
  static const _maxPages = 3;

  final ListsRepository _repository;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    emit(state.copyWith(status: ListsStatus.loading, clearError: true));
    try {
      final out = <pb.ListInfo>[];
      var token = '';
      for (var page = 0; page < _maxPages; page++) {
        final r = await _repository.listUserLists(
          ownerId: ownerId,
          pageSize: _pageSize,
          pageToken: token,
        );
        out.addAll(r.lists);
        token = r.nextPageToken;
        if (token.isEmpty) break;
      }
      if (isClosed || generation != _generation) return;
      emit(ListsState(status: ListsStatus.ready, lists: out));
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(ListsState(status: ListsStatus.error, error: error));
    }
  }

  /// A list the editor created: appended (the server order is oldest first).
  void created(pb.ListInfo list) {
    if (state.lists.any((l) => l.listId == list.listId)) return;
    emit(state.copyWith(lists: [...state.lists, list]));
  }

  /// A list the editor changed: replaced in place.
  void updated(pb.ListInfo list) {
    emit(
      state.copyWith(
        lists: [
          for (final l in state.lists) l.listId == list.listId ? list : l,
        ],
      ),
    );
  }

  void deleted(String listId) {
    emit(
      state.copyWith(
        lists: [
          for (final l in state.lists)
            if (l.listId != listId) l,
        ],
      ),
    );
  }
}
