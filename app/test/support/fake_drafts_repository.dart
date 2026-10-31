import 'dart:async';

import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';

/// An in-memory [DraftsRepository] for widget tests (a real drift database
/// does not complete inside the fake-async zone of `testWidgets`).
class FakeDraftsRepository implements DraftsRepository {
  FakeDraftsRepository({List<ComposerDraft>? drafts}) : rows = drafts ?? [];

  final List<ComposerDraft> rows;
  final _changes = StreamController<void>.broadcast();

  /// Drafts passed to [autosave] (the debounce is not simulated).
  int autosaves = 0;

  /// The uids [deleteAll] was called with, in order.
  final List<String> wiped = [];

  @override
  Future<void> deleteAll(String uid) async {
    wiped.add(uid);
    rows.removeWhere((d) => d.uid == uid);
    _changes.add(null);
  }

  @override
  Future<void> delete(String uid, Iterable<String> ids) async {
    final set = ids.toSet();
    rows.removeWhere((d) => d.uid == uid && set.contains(d.id));
    _changes.add(null);
  }

  @override
  Stream<List<ComposerDraft>> watch(String uid) async* {
    List<ComposerDraft> mine() => [
      for (final d in rows)
        if (d.uid == uid) d,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Future<ComposerDraft?> read(String uid, String draftId) async {
    for (final d in rows) {
      if (d.uid == uid && d.id == draftId) return d;
    }
    return null;
  }

  @override
  Future<DraftSaveResult> upsert(ComposerDraft draft) async {
    rows.removeWhere((d) => d.uid == draft.uid && d.id == draft.id);
    // Like the real store: an empty draft only removes its row.
    if (draft.isEmpty) {
      _changes.add(null);
      return DraftSaveResult.skipped;
    }
    rows.add(draft);
    _changes.add(null);
    return DraftSaveResult.saved;
  }

  @override
  void autosave(ComposerDraft draft) {
    autosaves++;
    unawaited(upsert(draft));
  }

  @override
  void cancelPending() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
