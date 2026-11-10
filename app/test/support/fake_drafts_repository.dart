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

  /// The send key held per `uid/draftId` (what the real store keeps in the
  /// row's `send*` columns).
  final Map<String, ({String key, SendKind kind, DateTime? publishAt})> sends =
      {};

  @override
  Future<void> deleteAll(String uid) async {
    wiped.add(uid);
    rows.removeWhere((d) => d.uid == uid);
    sends.removeWhere((k, _) => k.startsWith('$uid/'));
    _changes.add(null);
  }

  /// The uids [purgeExpired] was called with, in order.
  final List<String> purged = [];

  @override
  Future<int> purgeExpired(String uid) async {
    purged.add(uid);
    final cutoff = DateTime.now().subtract(kDraftExpiry);
    final before = rows.length;
    rows.removeWhere((d) => d.uid == uid && !d.updatedAt.isAfter(cutoff));
    if (rows.length != before) _changes.add(null);
    return before - rows.length;
  }

  @override
  Future<int> count(String uid) async => rows.where((d) => d.uid == uid).length;

  @override
  Stream<int> watchCount(String uid) {
    // A controller, not async*: cancelling an async* generator that is parked
    // on an await waits for its next event.
    late StreamController<int> out;
    StreamSubscription<void>? sub;
    out = StreamController<int>(
      onListen: () {
        void emit() => out.add(rows.where((d) => d.uid == uid).length);
        emit();
        sub = _changes.stream.listen((_) => emit());
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<void> delete(String uid, Iterable<String> ids) async {
    final set = ids.toSet();
    rows.removeWhere((d) => d.uid == uid && set.contains(d.id));
    for (final id in set) {
      sends.remove('$uid/$id');
    }
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

  /// Like the real store, minus the windows and the "row gone" memory: the
  /// row is stored if missing, a key of the same kind is reused, a key of the
  /// other kind blocks, and [forceNew] mints over it. It never returns a
  /// [SendClaim.startedAt] and never expires a key (no
  /// [SendBlock.unconfirmed]): window tests use the real store.
  @override
  Future<SendClaim> claimSend({
    required ComposerDraft draft,
    required SendKind kind,
    required String Function() newKey,
    DateTime? publishAt,
    bool forceNew = false,
  }) async {
    if (!rows.any((d) => d.uid == draft.uid && d.id == draft.id)) {
      await upsert(draft);
    }
    final id = '${draft.uid}/${draft.id}';
    final held = sends[id];
    if (held != null && !forceNew) {
      if (held.kind != kind) {
        return SendClaim.blocked(SendBlock.otherKind, pendingKind: held.kind);
      }
      return SendClaim.key(held.key, reused: true);
    }
    final key = newKey();
    sends[id] = (key: key, kind: kind, publishAt: publishAt);
    return SendClaim.key(key, reused: false);
  }

  @override
  Future<void> clearSend(String uid, String draftId, String key) async {
    final id = '$uid/$draftId';
    if (sends[id]?.key == key) sends.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
