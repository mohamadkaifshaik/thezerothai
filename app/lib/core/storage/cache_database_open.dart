import 'package:drift/drift.dart';

import 'app_database.dart';
import 'memory_executor.dart';

/// Reported once when the on-disk cache could not be used at start-up and the
/// app runs on an in-memory one (or, when that fails too, on the pure-Dart
/// session cache). Carries no message on purpose: the original
/// error can name the database file's path. Only the cause's type is kept, for
/// debug logs.
class CacheDatabaseUnavailable implements Exception {
  const CacheDatabaseUnavailable(this.causeType);

  final String causeType;

  @override
  String toString() => 'CacheDatabaseUnavailable($causeType)';
}

/// The cache database start-up settled on.
class OpenedCacheDatabase {
  OpenedCacheDatabase(this.database, {this.failure, this.failureStack});

  final AppDatabase database;

  /// Set when the on-disk database failed and [database] is in memory
  /// (sqlite, or the pure-Dart session cache: [AppDatabase.keepsNothing]).
  final CacheDatabaseUnavailable? failure;
  final StackTrace? failureStack;

  /// True for both fallbacks: nothing stored this launch outlives it, and
  /// what the last launch stored is absent.
  bool get inMemory => failure != null;

  bool _reported = false;

  /// Hands [failure] to [report] at most once; nothing when on disk. Bootstrap
  /// passes `TelemetryController.recordWhenCollecting`, which holds it until
  /// crash collecting turns on this session.
  void reportFallback(void Function(Object error, StackTrace stack) report) {
    final failure = this.failure;
    if (failure == null || _reported) return;
    _reported = true;
    report(failure, failureStack ?? StackTrace.empty);
  }
}

/// Opens the cache and claims it for [restoredUid] (L-4), the first use of the
/// database at start-up: the open, any migration, a read and, when the owner
/// changed, a write transaction.
///
/// When any of that throws (a corrupt file, a full disk, no permission), drift
/// keeps the failed open, so the database is closed and a fresh one is built
/// on [inMemoryExecutor] and claimed the same way. The app then runs with a
/// cache that is not kept across restarts; no copy changes. The file is never
/// deleted or renamed, so the next launch tries the disk again. The caller
/// hands the failure on once ([OpenedCacheDatabase.reportFallback]).
///
/// When the in-memory database fails too (on the web it needs `sqlite3.wasm`,
/// which a failed fetch, a blocked request or a missing file keeps away), it
/// is closed the same way and the app starts on [AppDatabase.keepingNothing]:
/// a pure-Dart cache that holds rows in memory for this run only, so fetched
/// pages still render. Still one report, of the first failure.
Future<OpenedCacheDatabase> openCacheDatabase({
  required String? restoredUid,
  AppDatabase Function() openOnDisk = AppDatabase.new,
  QueryExecutor Function() inMemoryExecutor = inMemoryCacheExecutor,
}) async {
  AppDatabase? onDisk;
  try {
    final database = onDisk = openOnDisk();
    await database.claimCacheFor(restoredUid);
    return OpenedCacheDatabase(database);
  } catch (error, stack) {
    final failure = CacheDatabaseUnavailable(error.runtimeType.toString());
    await _closeFailed(onDisk);
    AppDatabase? inMemory;
    try {
      final database = inMemory = AppDatabase(inMemoryExecutor());
      await database.claimCacheFor(restoredUid);
      return OpenedCacheDatabase(
        database,
        failure: failure,
        failureStack: stack,
      );
    } catch (_) {
      await _closeFailed(inMemory);
    }
    final nothing = AppDatabase.keepingNothing();
    await nothing.claimCacheFor(restoredUid);
    return OpenedCacheDatabase(nothing, failure: failure, failureStack: stack);
  }
}

/// Closing a failed open can throw the open's error again; the database is
/// unusable either way.
Future<void> _closeFailed(AppDatabase? database) async {
  try {
    await database?.close();
  } catch (_) {
    // Nothing to do: it is dropped either way.
  }
}
