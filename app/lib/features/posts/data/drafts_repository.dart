import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;

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

/// Which RPC a draft send goes to. `CreatePost` and `SchedulePost` keep
/// separate idempotency key spaces on the server, so a pending key belongs to
/// exactly one of them (W6-39).
enum SendKind { post, schedule }

/// Why a send was refused before any RPC (W6-39).
enum SendBlock {
  /// The draft row is gone although this process knew it: another composer
  /// sent it (or it was deleted). G5: never mint a key for it.
  rowGone,

  /// A key of the OTHER kind is pending (a post may exist where the user now
  /// asks to schedule, or the reverse). G6.
  otherKind,

  /// The pending key is older than its window, so the server may no longer
  /// recognise it: we cannot tell whether the earlier send landed.
  unconfirmed,
}

/// The answer of [DraftsRepository.claimSend].
@immutable
class SendClaim {
  const SendClaim.key(String this.key, {required this.reused})
    : block = null,
      pendingKind = null;
  const SendClaim.blocked(SendBlock this.block, {this.pendingKind})
    : key = null,
      reused = false;

  /// The idempotency key to send under; null when [block] is set.
  final String? key;

  /// The key was already stored by an earlier send of this draft (so that
  /// send may have landed), as opposed to freshly minted now.
  final bool reused;
  final SendBlock? block;

  /// For [SendBlock.otherKind]: the kind that is pending.
  final SendKind? pendingKind;

  bool get isBlocked => block != null;
}

/// How long a stored `post` key is reused: CreatePost's idempotency record
/// lives 24 h, so the client stops an hour early (ADR-0029 A4).
const kPostSendKeyWindow = Duration(hours: 23);

/// A scheduled item keeps its key for 7 days after it reaches a terminal
/// state (ADR-0029 A4); the window ends that long after its publish time.
const kScheduleSendKeyAfterPublish = Duration(days: 7);

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

  /// The oldest `updatedAt` a draft may have and still be shown or loaded
  /// (W6-45): a draft at or before this instant is 30 days or more past its
  /// last user edit.
  DateTime get _cutoff => _now().subtract(kDraftExpiry);

  /// Deletes [uid]'s drafts whose last user edit is [kDraftExpiry] or more
  /// ago (W6-45, L-5). Only that uid's rows; runs whatever the `drafts` flag
  /// says. Returns how many were removed. 0 RPCs.
  Future<int> purgeExpired(String uid) {
    final cutoff = _cutoff;
    return (_database.delete(_database.composerDraftEntries)..where(
          (t) => t.uid.equals(uid) & t.updatedAt.isSmallerOrEqualValue(cutoff),
        ))
        .go();
  }

  /// [uid]'s drafts, newest edit first, expired ones left out (filtered when
  /// this is subscribed; Drafts also purges on open). Emits again on every
  /// change.
  Stream<List<ComposerDraft>> watch(String uid) {
    final cutoff = _cutoff;
    final query = _database.select(_database.composerDraftEntries)
      ..where((t) => t.uid.equals(uid) & t.updatedAt.isBiggerThanValue(cutoff))
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.draftId),
      ]);
    return query.watch().map((rows) {
      _seen.addAll(rows.map((r) => r.draftId));
      return rows.map(_fromRow).toList();
    });
  }

  /// One draft of [uid], or null (also null for another account's id).
  Future<ComposerDraft?> read(String uid, String draftId) async {
    final cutoff = _cutoff;
    final row =
        await (_database.select(_database.composerDraftEntries)..where(
              (t) =>
                  t.uid.equals(uid) &
                  t.draftId.equals(draftId) &
                  t.updatedAt.isBiggerThanValue(cutoff),
            ))
            .getSingleOrNull();
    if (row != null) _seen.add(draftId);
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

  /// Ids this instance has read, listed or written. A missing row whose id is
  /// in here was removed by someone else (another composer sent it, or it was
  /// deleted); a missing row never seen is a draft that was not autosaved yet.
  /// An id leaves the set only when its own empty content removes the row.
  final Set<String> _seen = {};

  /// Claims the idempotency key for one send of [draft] (W6-39, ADR-0029
  /// Amendment 1 A4), in one local transaction, before the RPC leaves. 0 RPCs.
  /// `updatedAt` is never touched (W6-45): a claim is not an edit.
  ///
  /// - Row present with a key of the same [kind] inside its window: that key
  ///   comes back with `reused: true`, whatever the content now is. The
  ///   server then replays (same body) or answers IDEMPOTENCY_KEY_REUSED
  ///   (another body): either way it cannot create a second post. The start
  ///   time is not refreshed, so the window runs from the first mint.
  /// - Row present with no key (or [forceNew]): a fresh key is stored.
  /// - Row present with a key of the other kind: [SendBlock.otherKind].
  /// - Row present with an expired key: [SendBlock.unconfirmed].
  /// - Row missing and its id seen by this instance: [SendBlock.rowGone]. A
  ///   draft nobody has stored yet (a Post inside the autosave delay) is
  ///   stored by the claim itself, with its key.
  ///
  /// [draft] must not be empty (an image-only post has no row to keep a key
  /// on). [forceNew] mints a new key over a pending one: the user's explicit
  /// "post this version too" / "send anyway".
  Future<SendClaim> claimSend({
    required ComposerDraft draft,
    required SendKind kind,
    required String Function() newKey,
    DateTime? publishAt,
    bool forceNew = false,
  }) {
    assert(!draft.isEmpty, 'an empty draft has no row to claim');
    final db = _database;
    final table = db.composerDraftEntries;
    final epoch = db.sessionEpoch.value;
    return db.transaction(() async {
      Future<ComposerDraftRow?> lookup() =>
          (db.select(table)..where(
                (t) => t.uid.equals(draft.uid) & t.draftId.equals(draft.id),
              ))
              .getSingleOrNull();
      var row = await lookup();
      if (row == null) {
        if (_seen.contains(draft.id)) {
          return const SendClaim.blocked(SendBlock.rowGone);
        }
        await _write(draft, epoch);
        row = await lookup();
      }
      final stored = row?.sendKey;
      if (row != null && stored != null && !forceNew) {
        final pending = row.sendKind == SendKind.schedule.name
            ? SendKind.schedule
            : SendKind.post;
        if (pending != kind) {
          return SendClaim.blocked(SendBlock.otherKind, pendingKind: pending);
        }
        if (_expired(row, pending)) {
          return const SendClaim.blocked(SendBlock.unconfirmed);
        }
        _seen.add(draft.id);
        return SendClaim.key(stored, reused: true);
      }
      final key = newKey();
      if (row != null) {
        _seen.add(draft.id);
        await (db.update(table)..where(
              (t) => t.uid.equals(draft.uid) & t.draftId.equals(draft.id),
            ))
            .write(
              ComposerDraftEntriesCompanion(
                sendKey: Value(key),
                sendKind: Value(kind.name),
                sendPublishAt: Value(publishAt?.toUtc()),
                sendStartedAt: Value(_now()),
              ),
            );
      }
      return SendClaim.key(key, reused: false);
    });
  }

  bool _expired(ComposerDraftRow row, SendKind kind) {
    final now = _now();
    final publishAt = row.sendPublishAt;
    if (kind == SendKind.schedule && publishAt != null) {
      return now.isAfter(publishAt.add(kScheduleSendKeyAfterPublish));
    }
    final started = row.sendStartedAt;
    return started == null || now.difference(started) >= kPostSendKeyWindow;
  }

  /// Forgets the pending key [key] of a draft after an answer that proves no
  /// post was created. Only a row still holding exactly [key] is changed, and
  /// `updatedAt` is left alone. Safe to call for a row that is gone.
  Future<void> clearSend(String uid, String draftId, String key) {
    final table = _database.composerDraftEntries;
    return (_database.update(table)..where(
          (t) =>
              t.uid.equals(uid) &
              t.draftId.equals(draftId) &
              t.sendKey.equals(key),
        ))
        .write(
          const ComposerDraftEntriesCompanion(
            sendKey: Value(null),
            sendKind: Value(null),
            sendPublishAt: Value(null),
            sendStartedAt: Value(null),
          ),
        );
  }

  Future<DraftSaveResult> _write(ComposerDraft draft, int epoch) {
    final db = _database;
    final table = db.composerDraftEntries;
    return db.transaction(() async {
      if (!db.sessionEpoch.allows(epoch)) return DraftSaveResult.skipped;
      if (draft.isEmpty) {
        _seen.remove(draft.id);
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
      // updatedAt is the last USER edit (W6-45): saving content identical to
      // the stored row keeps the old stamp, so an autosave never extends the
      // draft's 30 days. (Media and a schedule are never part of a draft.)
      final clamped = _clamp(draft.text);
      final pollJson = draft.poll == null
          ? ''
          : jsonEncode(draft.poll!.toJson());
      if (existing != null &&
          existing.draftText == clamped &&
          existing.pollJson == pollJson &&
          existing.replyPolicy == draft.replyAudience.name &&
          existing.paidPartnership == draft.paidPartnership &&
          existing.madeWithAi == draft.madeWithAi) {
        return DraftSaveResult.saved;
      }
      _seen.add(draft.id);
      await db
          .into(table)
          .insertOnConflictUpdate(
            ComposerDraftEntriesCompanion.insert(
              draftId: draft.id,
              uid: draft.uid,
              draftText: clamped,
              pollJson: Value(pollJson),
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
