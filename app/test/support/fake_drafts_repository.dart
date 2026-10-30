import 'dart:async';

import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';

/// An in-memory [DraftsRepository] for widget tests (a real drift database
/// does not complete inside the fake-async zone of `testWidgets`).
class FakeDraftsRepository implements DraftsRepository {
  FakeDraftsRepository({List<ComposerDraft>? drafts}) : rows = drafts ?? [];

  final List<ComposerDraft> rows;

  /// The uids [deleteAll] was called with, in order.
  final List<String> wiped = [];

  @override
  Future<void> deleteAll(String uid) async {
    wiped.add(uid);
    rows.removeWhere((d) => d.uid == uid);
  }

  @override
  Future<void> delete(String uid, Iterable<String> ids) async {
    final set = ids.toSet();
    rows.removeWhere((d) => d.uid == uid && set.contains(d.id));
  }

  @override
  Stream<List<ComposerDraft>> watch(String uid) =>
      Stream.value(rows.where((d) => d.uid == uid).toList());

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
    rows.add(draft);
    return DraftSaveResult.saved;
  }

  @override
  void autosave(ComposerDraft draft) => unawaited(upsert(draft));

  @override
  void cancelPending() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
