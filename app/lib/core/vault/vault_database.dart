import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'vault_cipher.dart' show requireVaultKeyAlias, vaultKeyAlias;

part 'vault_database.g.dart';

// The vault's on-disk schema. It is NOT a cache: nothing here is trimmed,
// dropped on error or kept in memory. Renaming a table or a column, or
// changing a row key, orphans every value sealed under the old name (see
// [vaultSealLabel] and [vaultRowKey]); `vault_schema_test.dart` pins them.
//
// Clear columns are only: ids (conversation, message, idempotency key,
// setting key, the fixed meta/device slot, the device id as hex, the expected
// message id, the local id), sort keys, message state, check and kind, the
// outbox stage, `mine`, generation, epoch (and the other pair columns: marks,
// member `since`, sent digests), the provisional flag and time, the member
// side, the owner uid and the schema version. Every other
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

/// MLS group state per conversation and generation (schema version 2).
@DataClassName('VaultGroupStateRow')
class VaultGroupStates extends Table {
  @override
  String get tableName => 'vault_group_states';

  TextColumn get conversationId => text()();
  IntColumn get generation => integer()();
  IntColumn get epoch => integer()();

  /// Clear: 1 while the group was created locally and the server has not
  /// accepted it yet.
  IntColumn get provisional => integer().withDefault(const Constant(0))();

  /// Clear: when a provisional group was created (microseconds).
  IntColumn get provisionalCreatedAt => integer().nullable()();

  /// Sealed.
  BlobColumn get state => blob()();

  /// Sealed: an encoded `PendingCommit`; NULL when there is none.
  BlobColumn get pending => blob().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId, generation};
}

/// The marks and the sync record of one conversation (schema version 2).
@DataClassName('VaultConversationRow')
class VaultConversations extends Table {
  @override
  String get tableName => 'vault_conversations';

  TextColumn get conversationId => text()();

  /// Clear: the after-pair mark (both columns, or neither).
  IntColumn get afterGeneration => integer().nullable()();
  IntColumn get afterEpoch => integer().nullable()();

  /// Clear: the join high-water mark (both columns, or neither).
  IntColumn get joinGeneration => integer().nullable()();
  IntColumn get joinEpoch => integer().nullable()();

  /// Sealed: an encoded `ConversationSync`; NULL before the first write.
  BlobColumn get sync => blob().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

/// The devices pinned in a conversation (schema version 2).
@DataClassName('VaultMemberRow')
class VaultMembers extends Table {
  @override
  String get tableName => 'vault_members';

  TextColumn get conversationId => text()();

  /// Clear: lower-case hex of the device id bytes.
  TextColumn get deviceId => text()();

  /// Clear: one of `MemberSide`.
  TextColumn get side => text()();
  IntColumn get sinceGeneration => integer()();
  IntColumn get sinceEpoch => integer()();

  /// Sealed.
  BlobColumn get signatureKey => blob()();

  @override
  Set<Column> get primaryKey => {conversationId, deviceId};
}

/// Digests of the commits this device sent, per pair (schema version 2).
@DataClassName('VaultSentRow')
class VaultSent extends Table {
  @override
  String get tableName => 'vault_sent';

  TextColumn get conversationId => text()();
  IntColumn get generation => integer()();
  IntColumn get epoch => integer()();

  /// Clear: 64 hex.
  TextColumn get digest => text()();

  @override
  Set<Column> get primaryKey => {conversationId, generation, epoch, digest};
}

/// Version 1 MLS group state, one row per conversation. Never written by
/// version 2 (its rows are copied to `vault_group_states` and left in place,
/// sealed and unread); kept in the schema, in [VaultDatabase.vaultTables] and
/// so covered by the wipe.
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

  /// Sealed: one byte, 1 for a message this user sent. Legacy (version 1):
  /// version 2 always writes it equal to [mine].
  BlobColumn get fromSelf => blob()();

  /// Sealed; NULL for a tombstone (never a sealed empty value).
  BlobColumn get content => blob().nullable()();

  /// Clear (version 2): one of `StoredMessageCheck`.
  TextColumn get checkState => text().withDefault(const Constant('ok'))();

  /// Clear (version 2): one of `StoredMessageKind`.
  TextColumn get kind => text().withDefault(const Constant('message'))();

  /// Clear (version 2): 1 for a message from this user's own devices; NULL
  /// for a version 1 row whose sealed [fromSelf] did not authenticate.
  IntColumn get mine => integer().nullable()();

  /// Sealed (version 2): the sender's device id; NULL when not known.
  BlobColumn get senderDeviceId => blob().nullable()();

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

  /// Clear (version 2): one of `OutboxStage`.
  TextColumn get stage => text().withDefault(const Constant('encrypted'))();

  /// Clear (version 2): the message id the server will give this send.
  TextColumn get expectedMessageId => text().nullable()();

  /// Clear (version 2): stable across re-keying; the first idempotency key.
  TextColumn get localId => text().nullable()();

  /// Sealed (version 2): the serialized `MlsInit`, exact bytes.
  BlobColumn get init => blob().nullable()();

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
const int kVaultSchemaVersion = 2;

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
/// - `vault_groups` (legacy, version 1): `[conversationId]`
/// - `vault_group_states`: `[conversationId, '$generation']`
/// - `vault_conversations`: `[conversationId]`
/// - `vault_members`: `[conversationId, deviceIdHex]`
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

/// [vaultSortKeyMicros], or null when the stored key is damaged (too short,
/// not 20 digits followed by `|`, or out of range).
int? vaultSortKeyMicrosOrNull(String sortKey) {
  if (sortKey.length < 21 || sortKey[20] != '|') return null;
  final digits = sortKey.substring(0, 20);
  if (!RegExp(r'^[0-9]{20}$').hasMatch(digits)) return null;
  final value = int.tryParse(digits);
  return value == null || value < 0 ? null : value;
}

/// The database name of [uid]'s vault: `dzeroth_vault_` and the same 32 hex
/// digits as the uid's [vaultKeyAlias], so one vault file per user and the
/// name does not reveal the uid. On native the file is `<name>.sqlite`.
String vaultDatabaseName(String uid) =>
    vaultDatabaseNameForAlias(vaultKeyAlias(uid));

/// [vaultDatabaseName] from the key [alias] ([ArgumentError] for a value that
/// is not an alias).
String vaultDatabaseNameForAlias(String alias) =>
    'dzeroth_vault_${requireVaultKeyAlias(alias).substring('dzeroth.vault.'.length)}';

/// The encrypted, durable vault database of one user. Only `secure_vault.dart`
/// reads and writes it; this class holds the schema and whole-file helpers.
@DriftDatabase(
  tables: [
    VaultMeta,
    VaultDevice,
    VaultGroups,
    VaultGroupStates,
    VaultConversations,
    VaultMembers,
    VaultSent,
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
      // Additive SQL only: steps ADD tables and columns (never rename, drop
      // or rewrite: sealed values are bound to table, column and row key
      // names), run when drift opens the file, before the sentinel is
      // checked, and change no existing row, so a file whose key is lost
      // keeps every sealed byte. The part that needs the key (re-sealing)
      // is `_migrateSealedV1` in secure_vault.dart. Drift does not run this
      // in one transaction and sets `user_version` only afterwards, so every
      // step is safe to run again after a crash halfway.
      if (from < 2) {
        await m.createTable(vaultGroupStates);
        await m.createTable(vaultConversations);
        await m.createTable(vaultMembers);
        await m.createTable(vaultSent);
        await _addColumn(m, vaultMessages, vaultMessages.checkState);
        await _addColumn(m, vaultMessages, vaultMessages.kind);
        await _addColumn(m, vaultMessages, vaultMessages.mine);
        await _addColumn(m, vaultMessages, vaultMessages.senderDeviceId);
        await _addColumn(m, vaultOutbox, vaultOutbox.stage);
        await _addColumn(m, vaultOutbox, vaultOutbox.expectedMessageId);
        await _addColumn(m, vaultOutbox, vaultOutbox.localId);
        await _addColumn(m, vaultOutbox, vaultOutbox.init);
      }
    },
    // Deleted rows are overwritten with zeros instead of lingering in free
    // pages (on Android it is also set by the connection's setup callback,
    // before the schema is created). Per connection, so set on every open.
    beforeOpen: (_) => customStatement('PRAGMA secure_delete = ON'),
  );

  /// `ALTER TABLE ... ADD COLUMN`, unless [column] is already there (a
  /// previous attempt added it and stopped before `user_version` moved).
  Future<void> _addColumn(
    Migrator m,
    TableInfo<Table, Object?> table,
    GeneratedColumn<Object> column,
  ) async {
    final info = await customSelect(
      'PRAGMA table_info(${table.actualTableName})',
    ).get();
    if (info.any((row) => row.read<String>('name') == column.$name)) return;
    await m.addColumn(table, column);
  }

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

  /// Every vault table, the legacy `vault_groups` included (there are no
  /// foreign keys, so any order deletes).
  List<TableInfo<Table, Object?>> get vaultTables => [
    vaultMessages,
    vaultOutbox,
    vaultGroups,
    vaultGroupStates,
    vaultConversations,
    vaultMembers,
    vaultSent,
    vaultDevice,
    vaultSettings,
    vaultMeta,
  ];

  /// Deletes every row of every table in one transaction. Needs no key, so
  /// it works when the cipher is lost or unavailable. Follow with [vacuum].
  ///
  /// [halt] is asked INSIDE the transaction, after the (lazy) connection has
  /// opened, immediately before each table's delete: true throws
  /// [StateError] and the transaction rolls back, so a wipe its caller has
  /// abandoned deletes nothing even when it was stalled in the open.
  Future<void> deleteAllRows({bool Function()? halt}) => transaction(() async {
    for (final table in vaultTables) {
      if (halt?.call() ?? false) throw StateError('vault wipe stopped');
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
