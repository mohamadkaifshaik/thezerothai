// Web only. Runs through `flutter drive` in Chrome (see app/web/DRIFT_WEB_SETUP.md
// for the commands); `flutter test` does not run integration_test/.
//
// Guards against a drift web worker that keeps transaction writes in memory:
// drift 2.35.0's worker flushed IndexedDB only after statements run outside a
// transaction, so a write made inside one reached IndexedDB at the next such
// statement or a clean close, and a reload, tab close or crash before that
// lost it (drift #3864, fixed in 2.35.1). The check reads IndexedDB directly,
// through its own connection on the page, while the database stays open:
// bytes found there are what a fresh tab would load after a crash.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/drift_storage.dart';

const _databaseFile = '/database';

bool _contains(Uint8List? haystack, String marker) {
  if (haystack == null) return false;
  final needle = utf8.encode(marker);
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Whether [marker] is in the persisted database file, polled for up to two
/// seconds so a flush still in flight is not mistaken for a missing one.
Future<bool> _persisted(String name, String marker) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (true) {
    if (_contains(await readPersistedFile(name, _databaseFile), marker)) {
      return true;
    }
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _insertSetting(AppDatabase db, String key, String value) => db
    .into(db.appSettingEntries)
    .insert(
      AppSettingEntriesCompanion.insert(settingKey: key, settingValue: value),
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{};
  binding.reportData = report;

  /// Opens the cache database under a throwaway [name] through [open] and
  /// checks that a row written inside a transaction is in IndexedDB once the
  /// transaction returns, with the database still open (no close, which is
  /// what used to flush it). Returns the storage drift used.
  Future<OpenedStorage> checkTransactionWritePersists(
    String label,
    QueryExecutor Function(String name, OpenedStorage storage) open, {
    bool requireIndexedDb = true,
  }) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final name = 'dz_durability_${label}_$stamp';
    final storage = OpenedStorage();
    final db = AppDatabase(open(name, storage));
    addTearDown(() async {
      await db.close();
      await deletePersisted(name);
    });

    // Control: a write outside any transaction. Every worker flushes after
    // one, so this proves the IndexedDB reader sees what drift persists.
    final outside = 'dzeroth-outside-transaction-$stamp';
    await _insertSetting(db, 'outside', outside);

    report['$label.storage'] = storage.implementation;
    report['$label.missingFeatures'] = storage.missingFeatures;
    final usesIndexedDb =
        storage.implementation == 'sharedIndexedDb' ||
        storage.implementation == 'unsafeIndexedDb';
    if (!usesIndexedDb) {
      expect(
        requireIndexedDb,
        isFalse,
        reason: '$label opened ${storage.implementation}, not IndexedDB',
      );
      report['$label.result'] = 'not IndexedDB: check skipped';
      return storage;
    }

    expect(
      await _persisted(name, outside),
      isTrue,
      reason: 'control: a write outside a transaction never reached IndexedDB',
    );

    final inside = 'dzeroth-inside-transaction-$stamp';
    expect(await _persisted(name, inside), isFalse);
    await db.transaction(() => _insertSetting(db, 'inside', inside));

    // No statement, close or other write between the commit and this read:
    // with the old worker any of those would flush and hide the bug.
    final persisted = await _persisted(name, inside);
    report['$label.result'] = persisted
        ? 'transaction write persisted'
        : 'transaction write NOT in IndexedDB';
    expect(
      persisted,
      isTrue,
      reason:
          'a row written inside a transaction was not persisted to IndexedDB '
          'with the database open (${storage.implementation}); the drift '
          'worker predates drift 2.35.1, run `make drift-worker`',
    );

    // And drift reads back what it wrote.
    final rows = await db.select(db.appSettingEntries).get();
    expect(rows.map((row) => row.settingValue), containsAll([outside, inside]));
    return storage;
  }

  testWidgets(
    'sharedIndexedDb: a write inside a transaction reaches IndexedDB',
    (tester) async {
      report['crossOriginIsolated'] = crossOriginIsolated;
      await checkTransactionWritePersists('forced', openSharedIndexedDb);
    },
    skip: !kIsWeb,
  );

  testWidgets(
    'production options: the storage drift picks keeps transaction writes',
    (tester) async {
      // Whatever Chrome picks here is reported; on the production site (no
      // cross-origin isolation) it is sharedIndexedDb, the case checked above.
      await checkTransactionWritePersists(
        'production',
        openLikeProduction,
        requireIndexedDb: false,
      );
    },
    skip: !kIsWeb,
  );
}
