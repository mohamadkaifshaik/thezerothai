import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'vault_cipher.dart' show vaultKeyAlias;

part 'vault_database.g.dart';

// The vault's on-disk schema. It is NOT a cache: nothing here is trimmed,
// dropped on error or kept in memory. Renaming a table or a column, or
// changing a row key, orphans every value sealed under the old name (see
// [vaultSealLabel] and [vaultRowKey]); `vault_schema_test.dart` pins them.
//
// Clear columns are only: ids (conversation, message, idempotency key,
// setting key, the fixed meta/device slot), sort keys, message state,
// generation, epoch, the owner uid and the schema version. Every other
// column holds `VaultCipher.seal(vaultSealLabel(table, column),
// vaultRowKey(parts), bytes)`.

/// The vault's own bookkeeping: one row (`meta_key = 'vault'`) holding the
/// owner stamp, the schema version and the sealed sentinel that proves the
/// current key opens this file. Stamp and sentinel share the row, so one
/// cannot exist without the other.
@DataClassName('VaultMetaRow')
class VaultMeta extends Table {
  @override
  String get tableName => 'vault_meta';

  TextColumn get metaKey => text()();

  /// Clear: the uid that owns this file.
  TextColumn get ownerUid => text()();

  /// Clear: the schema version the vault was stamped with.
  IntColumn get schemaVersion => integer()();

  /// Sealed: [kVaultSentinel].
  BlobColumn get sentinel => blob()();

  @override
  Set<Column> get primaryKey => {metaKey};
}

/// This device's MLS identity: one row (`slot = 'device'`).
@DataClassName('VaultDeviceRow')
class VaultDevice extends Table {
  @override
  String get tableName => 'vault_device';

  TextColumn get slot => text()();

  /// Sealed.
  BlobColumn get deviceId => blob()();

  /// Sealed.
  BlobColumn get deviceState => blob()();

  @override
  Set<Column> get primaryKey => {slot};
}

/// MLS group state per conversation.
@DataClassName('VaultGroupRow')
class VaultGroups extends Table {
  @override
  String get tableName => 'vault_groups';

  TextColumn get conversationId => text()();
  IntColumn get generation => integer()();
  IntColumn get epoch => integer()();

  /// Sealed.
  BlobColumn get state => blob()();

  /// Sealed: one byte, 1 when a commit is pending.
  BlobColumn get pendingCommit => blob()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

/// Decrypted message history. Never trimmed.
@DataClassName('VaultMessageRow')
@TableIndex(
  name: 'vault_messages_by_sort',
  columns: {#conversationId, #sortKey},
)
class VaultMessages extends Table {
  @override
  String get tableName => 'vault_messages';

  TextColumn get conversationId => text()();
  TextColumn get messageId => text()();

  /// Clear: [vaultSortKey] of the message's creation time and id. The
  /// creation time is read back from it, so it has no column of its own.
  TextColumn get sortKey => text()();

  /// Clear: one of [StoredMessageState].
  TextColumn get state => text()();
  IntColumn get generation => integer()();
  IntColumn get epoch => integer()();

  /// Sealed: one byte, 1 for a message this user sent.
  BlobColumn get fromSelf => blob()();

  /// Sealed; NULL for a tombstone (never a sealed empty value).
  BlobColumn get content => blob().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId, messageId};
}

/// Messages encrypted but not yet accepted by the server.
@DataClassName('VaultOutboxRow')
class VaultOutbox extends Table {
  @override
  String get tableName => 'vault_outbox';

  TextColumn get idempotencyKey => text()();

  /// Clear; NULL for a first message to [recipientUserId].
  TextColumn get conversationId => text().nullable()();

  /// Clear: [vaultSortKey] of the item's creation time and idempotency key.
  TextColumn get sortKey => text()();
  IntColumn get generation => integer()();
  IntColumn get epoch => integer()();

  /// Sealed (utf8); NULL when [conversationId] is set.
  BlobColumn get recipientUserId => blob().nullable()();

  /// Sealed.
  BlobColumn get ciphertext => blob()();

  /// Sealed.
  BlobColumn get reportCommitment => blob()();

  /// Sealed.
  BlobColumn get content => blob()();

  /// Sealed (utf8 decimal).
  BlobColumn get attempts => blob()();

  /// Sealed (utf8); NULL when there was no error.
  BlobColumn get lastError => blob().nullable()();

  @override
  Set<Column> get primaryKey => {idempotencyKey};
}

/// Vault-scoped settings.
@DataClassName('VaultSettingRow')
class VaultSettings extends Table {
  @override
  String get tableName => 'vault_settings';

  TextColumn get settingKey => text()();

  /// Sealed.
  BlobColumn get value => blob()();

  @override
  Set<Column> get primaryKey => {settingKey};
}

/// The schema version this build writes and stamps into `vault_meta`.
const int kVaultSchemaVersion = 1;

/// The fixed primary key of the one `vault_meta` row.
const String kVaultMetaKey = 'vault';

/// The fixed primary key of the one `vault_device` row.
const String kVaultDeviceSlot = 'device';

/// The plaintext sealed into the sentinel.
const String kVaultSentinel = 'dzeroth.vault.sentinel.v1';

/// THE row key formula, the only place it is defined. Each part is written
/// as its length in UTF-16 code units, `:`, then the part, and the results
/// are concatenated: `vaultRowKey(['c1', 'm1']) == '2:c12:m1'`. The length
/// prefix makes the encoding unambiguous for any part content (`|`, `:`
/// and digits included), so no two keys collide. Row keys used:
///
/// - `vault_meta`: `[kVaultMetaKey]`
/// - `vault_device`: `[kVaultDeviceSlot]`
/// - `vault_groups`: `[conversationId]`
/// - `vault_messages`: `[conversationId, messageId]`
/// - `vault_outbox`: `[idempotencyKey]`
/// - `vault_settings`: `[settingKey]`
///
/// Changing it, or a table's key parts, orphans every sealed value.
String vaultRowKey(List<String> parts) =>
    parts.map((p) => '${p.length}:$p').join();

/// The `table` argument passed to `VaultCipher.seal`/`open` for [column] of
/// [table]: `'$table.$column'`. Binding the column (not only the table)
/// means two sealed values of one row cannot be swapped and still open.
String vaultSealLabel(String table, String column) => '$table.$column';

/// The sort key of a message or outbox item: [createdAtMicros] zero-padded
/// to 20 digits, `|`, then [id]. Sorts by time, then id, as text.
String vaultSortKey(int createdAtMicros, String id) {
  if (createdAtMicros < 0) {
    throw ArgumentError.value(createdAtMicros, 'createdAtMicros', 'negative');
  }
  return '${createdAtMicros.toString().padLeft(20, '0')}|$id';
}

/// The creation time inside a [vaultSortKey].
int vaultSortKeyMicros(String sortKey) => int.parse(sortKey.substring(0, 20));

/// The database name of [uid]'s vault: `dzeroth_vault_` and the same 32 hex
/// digits as the uid's [vaultKeyAlias], so one vault file per user and the
/// name does not reveal the uid. On native the file is `<name>.sqlite`.
String vaultDatabaseName(String uid) =>
    'dzeroth_vault_${vaultKeyAlias(uid).substring('dzeroth.vault.'.length)}';

/// The encrypted, durable vault database of one user. Only `secure_vault.dart`
/// reads and writes it; this class holds the schema and whole-file helpers.
@DriftDatabase(
  tables: [
    VaultMeta,
    VaultDevice,
    VaultGroups,
    VaultMessages,
    VaultOutbox,
    VaultSettings,
  ],
)
class VaultDatabase extends _$VaultDatabase {
  /// On a platform connection from `vault_open.dart` (never in memory).
  VaultDatabase(super.connection);

  /// Test-only: any executor, e.g. `NativeDatabase.memory()`.
  @visibleForTesting
  VaultDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => kVaultSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // No upgrades yet (version 1). To add one: bump [kVaultSchemaVersion],
      // add `if (from < N) { ... }` steps here that only ADD tables, columns
      // or indexes (never rename or drop: sealed values are bound to table,
      // column and row key names), and add a hand-written migration test
      // from version N-1 in `vault_schema_test.dart`.
    },
    // Deleted rows are overwritten with zeros instead of lingering in free
    // pages (on Android it is also set by the connection's setup callback,
    // before the schema is created). Per connection, so set on every open.
    beforeOpen: (_) => customStatement('PRAGMA secure_delete = ON'),
  );

  /// Rebuilds the file without free pages. Must run outside a transaction.
  Future<void> vacuum() => customStatement('VACUUM');

  /// The main database file path as sqlite reports it; empty or null for a
  /// database with no file (in memory, or a web storage).
  Future<String?> mainFilePath() async {
    final rows = await customSelect('PRAGMA database_list').get();
    for (final row in rows) {
      if (row.data['name'] == 'main') return row.data['file'] as String?;
    }
    return null;
  }

  /// Every vault table (there are no foreign keys, so any order deletes).
  List<TableInfo<Table, Object?>> get vaultTables => [
    vaultMessages,
    vaultOutbox,
    vaultGroups,
    vaultDevice,
    vaultSettings,
    vaultMeta,
  ];

  /// Deletes every row of every table in one transaction. Needs no key, so
  /// it works when the cipher is lost or unavailable. Follow with [vacuum].
  Future<void> deleteAllRows() => transaction(() async {
    for (final table in vaultTables) {
      await delete(table).go();
    }
  });

  /// Closes without throwing and without waiting more than 5 s: a failed or
  /// hung open can throw again, or never finish, on close.
  Future<void> closeQuietly() async {
    try {
      await close().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Dropped either way.
    }
  }

  /// Whether any table other than `vault_meta` holds a row.
  Future<bool> hasDataRows() async {
    for (final table in vaultTables) {
      if (table == vaultMeta) continue;
      final row = await customSelect(
        'SELECT 1 FROM ${table.actualTableName} LIMIT 1',
        readsFrom: {table},
      ).getSingleOrNull();
      if (row != null) return true;
    }
    return false;
  }
}
