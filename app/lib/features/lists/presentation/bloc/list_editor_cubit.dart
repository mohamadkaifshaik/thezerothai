import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../data/lists_repository.dart';
import '../lists_error_messages.dart';

/// How the editor ended: [list] is the saved list, null after a delete.
@immutable
class ListEditorOutcome {
  const ListEditorOutcome.saved(pb.ListInfo this.list) : deletedId = null;
  const ListEditorOutcome.deleted(String this.deletedId) : list = null;

  final pb.ListInfo? list;
  final String? deletedId;
}

@immutable
class ListEditorState {
  const ListEditorState({this.busy = false, this.error, this.outcome});

  /// A save or delete is in flight (inputs and buttons are disabled).
  final bool busy;

  /// Friendly text of the last failure; the form stays open for a retry.
  final String? error;

  /// Set once when the call succeeded: the sheet pops with it.
  final ListEditorOutcome? outcome;
}

/// Create / edit / delete of one List (W5-11).
///
/// One idempotency key per user action, reused when the same action is
/// retried after a failure (rule 4). A key is tied to the exact payload it was
/// first sent with: if the user edits the fields after a failure the payload
/// differs, so the next attempt is a new action with a new key.
class ListEditorCubit extends Cubit<ListEditorState> {
  ListEditorCubit({required ListsRepository repository, this.existing})
    : _repository = repository,
      super(const ListEditorState());

  static const _uuid = Uuid();

  final ListsRepository _repository;

  /// The list being edited; null = create.
  final pb.ListInfo? existing;

  String? _saveKey;
  String? _savePayload;
  String? _deleteKey;

  Future<void> save({
    required String name,
    required String description,
    required bool isPrivate,
  }) async {
    if (state.busy) return;
    final payload = '$name\u0000$description\u0000$isPrivate';
    if (_savePayload != payload) {
      _saveKey = _uuid.v4();
      _savePayload = payload;
    }
    final key = _saveKey!;
    emit(const ListEditorState(busy: true));
    try {
      final before = existing;
      final pb.ListInfo saved;
      if (before == null) {
        saved = await _repository.createList(
          idempotencyKey: key,
          name: name,
          description: description,
          isPrivate: isPrivate,
        );
      } else {
        saved = await _repository.updateList(
          idempotencyKey: key,
          listId: before.listId,
          name: name == before.name ? null : name,
          description: description == before.description ? null : description,
          isPrivate: isPrivate == before.isPrivate ? null : isPrivate,
        );
      }
      if (isClosed) return;
      emit(ListEditorState(outcome: ListEditorOutcome.saved(saved)));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(ListEditorState(error: listsErrorMessage(error)));
    }
  }

  Future<void> delete() async {
    final before = existing;
    if (before == null || state.busy) return;
    final key = _deleteKey ??= _uuid.v4();
    emit(const ListEditorState(busy: true));
    try {
      await _repository.deleteList(idempotencyKey: key, listId: before.listId);
      if (isClosed) return;
      emit(ListEditorState(outcome: ListEditorOutcome.deleted(before.listId)));
    } on AppException catch (error) {
      if (isClosed) return;
      // A list that is already gone counts as deleted.
      if (error is NotFoundException) {
        emit(
          ListEditorState(outcome: ListEditorOutcome.deleted(before.listId)),
        );
        return;
      }
      emit(ListEditorState(error: listsErrorMessage(error)));
    }
  }
}
