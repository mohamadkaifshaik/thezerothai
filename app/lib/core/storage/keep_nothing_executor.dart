import 'package:drift/backends.dart';

/// A drift executor with no database behind it: every select finds no rows,
/// every insert, update, delete and schema statement succeeds and changes
/// nothing, and transactions always commit. Pure Dart, so it needs neither
/// sqlite3 (native) nor `sqlite3.wasm` (web).
///
/// Start-up's last resort (see `openCacheDatabase`): when neither the on-disk
/// nor the in-memory sqlite database can be used, the app still starts, as if
/// every cache were empty and nothing were kept. Reads that expect exactly
/// one row (`getSingle`) would fail on it, so the cache uses the `OrNull`
/// forms.
QueryExecutor keepNothingExecutor() => DelegatedDatabase(_KeepNothing());

class _KeepNothing extends DatabaseDelegate {
  bool _open = false;

  // No schema version is kept, so drift runs no migration.
  @override
  DbVersionDelegate get versionDelegate => const NoVersionDelegate();

  @override
  TransactionDelegate get transactionDelegate => const NoTransactionDelegate();

  @override
  bool get isOpen => _open;

  @override
  Future<void> open(QueryExecutorUser db) async {
    _open = true;
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<QueryResult> runSelect(String statement, List<Object?> args) async =>
      QueryResult(const [], const []);

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 0;

  @override
  Future<void> runCustom(String statement, List<Object?> args) async {}

  @override
  Future<void> runBatched(BatchedStatements statements) async {}
}
