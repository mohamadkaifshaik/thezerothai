import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../domain/bookmark_history_feature_flag.dart';

/// The posts the caller opened on this device, newest first (the History tab
/// of `/bookmarks`). Device-only: no RPC, nothing leaves the device.
///
/// - [recordOpen] moves a post to the top (re-opening does not duplicate) and
///   keeps at most [kBookmarkHistoryCap] rows per uid.
/// - Writes check the [SessionEpoch] inside their transaction, so an open that
///   finishes after sign-out is dropped and never leaves a row behind.
/// - [clearSession] (sign-out, [AppDatabase.clearAll]) wipes everything; [clear]
///   removes one account's rows when the user asks.
class PostHistoryRepository {
  PostHistoryRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Records that [uid] opened [postId] now. Returns without writing when the
  /// session ended since the caller read [epoch] (default: the current one).
  Future<void> recordOpen({
    required String uid,
    required String postId,
    int? epoch,
  }) {
    final guard = epoch ?? _db.sessionEpoch.value;
    final openedAtMs = _clock().toUtc().millisecondsSinceEpoch;
    return _db.transaction(() async {
      if (!_db.sessionEpoch.allows(guard)) return;
      final table = _db.postHistoryEntries;
      // Delete first, then insert: a plain upsert is not needed and keeps
      // the statement set to what the in-memory store understands.
      await (_db.delete(
        table,
      )..where((t) => t.uid.equals(uid) & t.postId.equals(postId))).go();
      await _db
          .into(table)
          .insert(
            PostHistoryEntriesCompanion.insert(
              uid: uid,
              postId: postId,
              openedAtMs: openedAtMs,
            ),
          );
      final rows =
          await (_db.select(table)
                ..where((t) => t.uid.equals(uid))
                ..orderBy([(t) => OrderingTerm.desc(t.openedAtMs)]))
              .get();
      for (final row in rows.skip(kBookmarkHistoryCap)) {
        await (_db.delete(
          table,
        )..where((t) => t.uid.equals(uid) & t.postId.equals(row.postId))).go();
      }
    });
  }

  /// The post ids [uid] opened, newest first, at most [kBookmarkHistoryCap].
  Future<List<String>> recentPostIds(String uid) async {
    final rows =
        await (_db.select(_db.postHistoryEntries)
              ..where((t) => t.uid.equals(uid))
              ..orderBy([(t) => OrderingTerm.desc(t.openedAtMs)]))
            .get();
    return [for (final row in rows.take(kBookmarkHistoryCap)) row.postId];
  }

  /// Removes [postId] from [uid]'s history (a post that no longer loads).
  Future<void> remove({required String uid, required String postId}) async {
    await (_db.delete(
      _db.postHistoryEntries,
    )..where((t) => t.uid.equals(uid) & t.postId.equals(postId))).go();
  }

  /// Clears [uid]'s history ("Clear history").
  Future<void> clear(String uid) async {
    await (_db.delete(
      _db.postHistoryEntries,
    )..where((t) => t.uid.equals(uid))).go();
  }

  /// Sign-out: every account's rows go. Called from the session reset.
  Future<void> clearSession() async {
    await _db.delete(_db.postHistoryEntries).go();
  }
}
