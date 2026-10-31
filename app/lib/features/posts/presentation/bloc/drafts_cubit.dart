import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/drafts_repository.dart';
import '../../domain/composer_draft.dart';

enum DraftsStatus { loading, ready, error }

@immutable
class DraftsViewState {
  const DraftsViewState({
    this.status = DraftsStatus.loading,
    this.drafts = const [],
    this.editing = false,
    this.selected = const {},
  });

  final DraftsStatus status;

  /// The account's unsent posts, newest edit first.
  final List<ComposerDraft> drafts;

  /// Edit mode (checkboxes, Select all, Delete).
  final bool editing;
  final Set<String> selected;

  bool get allSelected =>
      drafts.isNotEmpty && drafts.every((d) => selected.contains(d.id));

  DraftsViewState copyWith({
    DraftsStatus? status,
    List<ComposerDraft>? drafts,
    bool? editing,
    Set<String>? selected,
  }) => DraftsViewState(
    status: status ?? this.status,
    drafts: drafts ?? this.drafts,
    editing: editing ?? this.editing,
    selected: selected ?? this.selected,
  );
}

/// The Unsent posts tab (W6-15): the device's drafts of one account from
/// [DraftsRepository.watch] (local, 0 RPCs), Edit mode and bulk delete. The
/// list updates by itself when a draft is saved or removed.
class DraftsCubit extends Cubit<DraftsViewState> {
  DraftsCubit({
    required DraftsRepository repository,
    required String? uid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _onUnexpectedError = onUnexpectedError,
       super(const DraftsViewState()) {
    watchUid(uid);
  }

  final DraftsRepository _repository;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  StreamSubscription<List<ComposerDraft>>? _sub;
  String? _uid;

  /// (Re)subscribes for [uid]: another account never sees these rows.
  void watchUid(String? uid) {
    if (uid == _uid && _sub != null) return;
    _uid = uid;
    unawaited(_sub?.cancel());
    emit(const DraftsViewState());
    if (uid == null || uid.isEmpty) {
      _sub = null;
      emit(const DraftsViewState(status: DraftsStatus.ready));
      return;
    }
    _sub = _repository
        .watch(uid)
        .listen(
          _onDrafts,
          onError: (Object error, StackTrace stack) {
            // Without details: a storage error can carry a draft's text.
            _onUnexpectedError?.call(
              StateError('Drafts could not be read.'),
              stack,
            );
            if (!isClosed) emit(state.copyWith(status: DraftsStatus.error));
          },
        );
  }

  /// "Try again" after a read failure.
  void retry() {
    final uid = _uid;
    _uid = null;
    watchUid(uid);
  }

  void _onDrafts(List<ComposerDraft> drafts) {
    if (isClosed) return;
    final ids = {for (final d in drafts) d.id};
    emit(
      state.copyWith(
        status: DraftsStatus.ready,
        drafts: drafts,
        selected: state.selected.where(ids.contains).toSet(),
        // Nothing left to edit.
        editing: drafts.isEmpty ? false : state.editing,
      ),
    );
  }

  void editStarted() {
    if (state.drafts.isEmpty) return;
    emit(state.copyWith(editing: true, selected: const {}));
  }

  void editFinished() =>
      emit(state.copyWith(editing: false, selected: const {}));

  void toggled(String draftId) {
    final next = {...state.selected};
    if (!next.remove(draftId)) next.add(draftId);
    emit(state.copyWith(selected: next));
  }

  void selectAll() =>
      emit(state.copyWith(selected: {for (final d in state.drafts) d.id}));

  void clearSelection() => emit(state.copyWith(selected: const {}));

  /// Deletes the selected drafts (the screen asked first). Returns how many
  /// were removed; a storage failure answers 0 and is reported without
  /// details.
  Future<int> deleteSelected() async {
    final uid = _uid;
    final ids = state.selected.toList();
    if (uid == null || ids.isEmpty) return 0;
    try {
      await _repository.delete(uid, ids);
    } catch (_, stack) {
      _onUnexpectedError?.call(
        StateError('Drafts could not be deleted.'),
        stack,
      );
      return 0;
    }
    if (!isClosed) emit(state.copyWith(editing: false, selected: const {}));
    return ids.length;
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
