import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../domain/composer_draft.dart';
import '../domain/reply_audience.dart';

/// What [DraftsRepository.upsert] did.
enum DraftSaveResult {
  /// Saved; nothing else changed.
  saved,

  /// Saved, and the account's oldest draft was removed to stay within
  /// [kMaxDrafts]; the UI says so.
  savedDroppedOldest,

  /// Not written: the session ended since the write started. (An empty draft
  /// removes its row and also answers this.)
  skipped,
}

/// The only reader and writer of unsent posts on this device (ADR-0029, W6-14).
/// Drafts live in `ComposerDraftEntries`: every query is filtered by uid, the
/// table survives sign-out (F7) and is wiped for one uid by [deleteAll] when
/// that account is deleted. 0 RPCs, 0 server bytes.
///
/// Nothing here logs: a draft's text never reaches a logger or Crashlytics, and
/// a storage failure in the debounced autosave is reported by
/// [onAutosaveFailed] without its message (a database error can carry bound
/// values).
class DraftsRepository {
  DraftsRepository(
    this._database, {
    this.autosaveDelay = const Duration(seconds: 2),
    DateTime Function()? now,
    this.onAutosaveFailed,
  }) : _now = now ?? DateTime.now;

  final AppDatabase _database;

  /// The quiet time before [autosave] writes.
  final Duration autosaveDelay;
  final DateTime Function() _now;

  /// Called with no details when a debounced write failed.
  final void Function()? onAutosaveFailed;

  final Map<String, Timer> _pending = {};

  /// A fresh draft id (random, 16 hex characters). Opaque.
  static String newId() {
    final r = Random.secure();
    return List.generate(
      8,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// [uid]'s drafts, newest edit first. Emits again on every change.
  Stream<List<ComposerDraft>> watch(String uid) {
    final query = _database.select(_database.composerDraftEntries)
      ..where((t) => t.uid.equals(uid))
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.draftId),
      ]);
    return query.watch().map((rows) => rows.map(_fromRow).toList());
  }

  /// One draft of [uid], or null (also null for another account's id).
  Future<ComposerDraft?> read(String uid, String draftId) async {
    final row =
        await (_database.select(_database.composerDraftEntries)
              ..where((t) => t.uid.equals(uid) & t.draftId.equals(draftId)))
            .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// Writes after [autosaveDelay] of quiet for this draft id; a newer call
  /// replaces the pending one. The epoch is read now, so a sign-out between
  /// the call and the write drops it. Failures never throw.
  void autosave(ComposerDraft draft) {
    final epoch = _database.sessionEpoch.value;
    _pending[draft.id]?.cancel();
    _pending[draft.id] = Timer(autosaveDelay, () async {
      _pending.remove(draft.id);
      try {
        await _write(draft, epoch);
      } catch (_) {
        onAutosaveFailed?.call();
      }
    });
  }

  /// Saves now (the "Save" button, leaving the composer) and cancels a pending
  /// autosave of the same draft. An empty draft deletes its row.
  Future<DraftSaveResult> upsert(ComposerDraft draft) {
    _pending.remove(draft.id)?.cancel();
    return _write(draft, _database.sessionEpoch.value);
  }

  /// Cancels every pending autosave. Nothing is written.
  void cancelPending() {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }

  /// Removes [ids] of [uid] (a posted or discarded draft, edit mode). Pending
  /// autosaves of them are cancelled first. Unguarded: removing never leaks.
  Future<void> delete(String uid, Iterable<String> ids) {
    final list = ids.toList();
    for (final id in list) {
      _pending.remove(id)?.cancel();
    }
    return (_database.delete(
      _database.composerDraftEntries,
    )..where((t) => t.uid.equals(uid) & t.draftId.isIn(list))).go();
  }

  /// Removes every draft of [uid]: "Delete all", and a successful
  /// DeleteAccount on this device.
  Future<void> deleteAll(String uid) {
    cancelPending();
    return (_database.delete(
      _database.composerDraftEntries,
    )..where((t) => t.uid.equals(uid))).go();
  }

  Future<DraftSaveResult> _write(ComposerDraft draft, int epoch) {
    final db = _database;
    final table = db.composerDraftEntries;
    return db.transaction(() async {
      if (!db.sessionEpoch.allows(epoch)) return DraftSaveResult.skipped;
      if (draft.isEmpty) {
        await (db.delete(table)..where(
              (t) => t.uid.equals(draft.uid) & t.draftId.equals(draft.id),
            ))
            .go();
        return DraftSaveResult.skipped;
      }
      final existing =
          await (db.select(table)..where(
                (t) => t.uid.equals(draft.uid) & t.draftId.equals(draft.id),
              ))
              .getSingleOrNull();
      await db
          .into(table)
          .insertOnConflictUpdate(
            ComposerDraftEntriesCompanion.insert(
              draftId: draft.id,
              uid: draft.uid,
              draftText: _clamp(draft.text),
              pollJson: Value(
                draft.poll == null ? '' : jsonEncode(draft.poll!.toJson()),
              ),
              replyPolicy: Value(draft.replyAudience.name),
              paidPartnership: Value(draft.paidPartnership),
              madeWithAi: Value(draft.madeWithAi),
              createdAt: existing?.createdAt ?? draft.createdAt,
              updatedAt: _now(),
            ),
          );
      final mine =
          await (db.select(table)
                ..where((t) => t.uid.equals(draft.uid))
                ..orderBy([
                  (t) => OrderingTerm.asc(t.updatedAt),
                  (t) => OrderingTerm.asc(t.draftId),
                ]))
              .get();
      final excess = mine.length - kMaxDrafts;
      if (excess <= 0) return DraftSaveResult.saved;
      final drop = mine
          .where((r) => r.draftId != draft.id)
          .take(excess)
          .map((r) => r.draftId)
          .toList();
      await (db.delete(
        table,
      )..where((t) => t.uid.equals(draft.uid) & t.draftId.isIn(drop))).go();
      return DraftSaveResult.savedDroppedOldest;
    });
  }

  static String _clamp(String text) {
    final runes = text.runes;
    if (runes.length <= kMaxDraftCodePoints) return text;
    return String.fromCharCodes(runes.take(kMaxDraftCodePoints));
  }

  static ComposerDraft _fromRow(ComposerDraftRow row) {
    Object? poll;
    if (row.pollJson.isNotEmpty) {
      try {
        poll = jsonDecode(row.pollJson);
      } on FormatException {
        poll = null;
      }
    }
    return ComposerDraft(
      id: row.draftId,
      uid: row.uid,
      text: row.draftText,
      poll: DraftPoll.fromJson(poll),
      replyAudience: ReplyAudience.values.firstWhere(
        (a) => a.name == row.replyPolicy,
        orElse: () => ReplyAudience.everyone,
      ),
      paidPartnership: row.paidPartnership,
      madeWithAi: row.madeWithAi,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}
