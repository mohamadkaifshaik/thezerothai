import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../data/lists_repository.dart';
import '../lists_error_messages.dart';

/// [loading] the first fetch, [ready] the checkboxes, [error] the fetch failed.
enum AddToListsStatus { loading, ready, error }

@immutable
class AddToListsState {
  const AddToListsState({
    this.status = AddToListsStatus.loading,
    this.lists = const [],
    this.memberOf = const {},
    this.pending = const {},
    this.error,
    this.notice,
  });

  final AddToListsStatus status;

  /// The caller's own lists (private ones too), oldest first.
  final List<pb.ListInfo> lists;

  /// Ids of [lists] that hold the person (optimistic while a toggle is in flight).
  final Set<String> memberOf;

  /// Ids with an Add or Remove in flight (their checkbox is busy).
  final Set<String> pending;

  /// Why the list could not load.
  final AppException? error;

  /// Friendly reason the last toggle was rolled back; cleared by the next one.
  final String? notice;

  AddToListsState copyWith({
    AddToListsStatus? status,
    List<pb.ListInfo>? lists,
    Set<String>? memberOf,
    Set<String>? pending,
    AppException? error,
    String? notice,
    bool clearNotice = false,
  }) => AddToListsState(
    status: status ?? this.status,
    lists: lists ?? this.lists,
    memberOf: memberOf ?? this.memberOf,
    pending: pending ?? this.pending,
    error: error ?? this.error,
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// The "Add to Lists" sheet of one person (W5-13): 1 `ListUserLists` with
/// `contains_user_id` per [load], then one Add or Remove per toggle.
///
/// A toggle is optimistic and rolls back on any error with the reason in
/// [AddToListsState.notice]. One idempotency key per user action, reused when
/// the same action (same list, same direction) is tried again after a failure,
/// and dropped once it succeeded (rule 4).
class AddToListsCubit extends Cubit<AddToListsState> {
  AddToListsCubit({required ListsRepository repository, required this.userId})
    : _repository = repository,
      super(const AddToListsState());

  static const _uuid = Uuid();
  static const _pageSize = 50;
  static const _maxPages = 3;

  final ListsRepository _repository;

  /// The person being added to or removed from lists.
  final String userId;

  final Map<String, String> _keys = {};

  Future<void> load() async {
    emit(const AddToListsState());
    try {
      final lists = <pb.ListInfo>[];
      final containing = <String>{};
      var token = '';
      for (var page = 0; page < _maxPages; page++) {
        final r = await _repository.listUserLists(
          containsUserId: userId,
          pageSize: _pageSize,
          pageToken: token,
        );
        lists.addAll(r.lists);
        containing.addAll(r.containingListIds);
        token = r.nextPageToken;
        if (token.isEmpty) break;
      }
      if (isClosed) return;
      emit(
        AddToListsState(
          status: AddToListsStatus.ready,
          lists: lists,
          memberOf: containing,
        ),
      );
    } on AppException catch (error) {
      if (isClosed) return;
      emit(AddToListsState(status: AddToListsStatus.error, error: error));
    }
  }

  /// Flips the person's membership of [listId]. Ignored while that list's
  /// previous toggle is still in flight.
  Future<void> toggle(String listId) async {
    if (state.status != AddToListsStatus.ready ||
        state.pending.contains(listId) ||
        !state.lists.any((l) => l.listId == listId)) {
      return;
    }
    final add = !state.memberOf.contains(listId);
    final keyName = '$listId:${add ? 'add' : 'remove'}';
    final key = _keys[keyName] ??= _uuid.v4();
    emit(
      state.copyWith(
        memberOf: add
            ? {...state.memberOf, listId}
            : ({...state.memberOf}..remove(listId)),
        pending: {...state.pending, listId},
        clearNotice: true,
      ),
    );
    try {
      final updated = add
          ? await _repository.addMember(
              idempotencyKey: key,
              listId: listId,
              userId: userId,
            )
          : await _repository.removeMember(
              idempotencyKey: key,
              listId: listId,
              userId: userId,
            );
      _keys.remove(keyName);
      if (isClosed) return;
      emit(
        state.copyWith(
          // The reply carries the new member count.
          lists: [
            for (final l in state.lists)
              l.listId == listId && updated.listId == listId ? updated : l,
          ],
          pending: {...state.pending}..remove(listId),
        ),
      );
    } on AppException catch (error) {
      if (isClosed) return;
      // Rolled back to what the server last confirmed.
      emit(
        state.copyWith(
          memberOf: add
              ? ({...state.memberOf}..remove(listId))
              : {...state.memberOf, listId},
          pending: {...state.pending}..remove(listId),
          notice: listsErrorMessage(error),
        ),
      );
    }
  }
}
