import 'package:drift/native.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sealed values are bound to their table, column and row key names, so a
/// rename orphans data. These names are pinned on purpose: change them only
/// with a migration that re-seals (see `VaultDatabase.migration`).
const Map<String, Map<String, String>> _schema = {
  'vault_meta': {
    'meta_key': 'TEXT',
    'owner_uid': 'TEXT',
    'schema_version': 'INTEGER',
    'sentinel': 'BLOB',
  },
  'vault_device': {'slot': 'TEXT', 'device_id': 'BLOB', 'device_state': 'BLOB'},
  'vault_groups': {
    'conversation_id': 'TEXT',
    'generation': 'INTEGER',
    'epoch': 'INTEGER',
    'state': 'BLOB',
    'pending_commit': 'BLOB',
  },
  'vault_messages': {
    'conversation_id': 'TEXT',
    'message_id': 'TEXT',
    'sort_key': 'TEXT',
    'state': 'TEXT',
    'generation': 'INTEGER',
    'epoch': 'INTEGER',
    'from_self': 'BLOB',
    'content': 'BLOB',
  },
  'vault_outbox': {
    'idempotency_key': 'TEXT',
    'conversation_id': 'TEXT',
    'sort_key': 'TEXT',
    'generation': 'INTEGER',
    'epoch': 'INTEGER',
    'recipient_user_id': 'BLOB',
    'ciphertext': 'BLOB',
    'report_commitment': 'BLOB',
    'content': 'BLOB',
    'attempts': 'BLOB',
    'last_error': 'BLOB',
  },
  'vault_settings': {'setting_key': 'TEXT', 'value': 'BLOB'},
};

const Map<String, List<String>> _primaryKeys = {
  'vault_meta': ['meta_key'],
  'vault_device': ['slot'],
  'vault_groups': ['conversation_id'],
  'vault_messages': ['conversation_id', 'message_id'],
  'vault_outbox': ['idempotency_key'],
  'vault_settings': ['setting_key'],
};

void main() {
  test('a fresh database is at version 1', () async {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 1);
    expect(kVaultSchemaVersion, 1);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 1);
  });

  test('tables, columns, types and primary keys are pinned', () async {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .get();
    expect(
      tables.map((r) => r.read<String>('name')).toSet(),
      _schema.keys.toSet(),
    );
    for (final table in _schema.keys) {
      final info = await db.customSelect('PRAGMA table_info($table)').get();
      expect(
        {for (final c in info) c.read<String>('name'): c.read<String>('type')},
        _schema[table],
        reason: table,
      );
      final pk = [
        for (final c
            in info.where((c) => c.read<int>('pk') > 0).toList()
              ..sort((a, b) => a.read<int>('pk').compareTo(b.read<int>('pk'))))
          c.read<String>('name'),
      ];
      expect(pk, _primaryKeys[table], reason: table);
    }
    // Only the content of a tombstone and the optional outbox fields are
    // nullable.
    final nullable = <String>{};
    for (final table in _schema.keys) {
      final info = await db.customSelect('PRAGMA table_info($table)').get();
      for (final c in info) {
        if (c.read<int>('notnull') == 0 && c.read<int>('pk') == 0) {
          nullable.add('$table.${c.read<String>('name')}');
        }
      }
    }
    expect(nullable, {
      'vault_messages.content',
      'vault_outbox.conversation_id',
      'vault_outbox.recipient_user_id',
      'vault_outbox.last_error',
    });
  });

  test('messages are indexed by conversation and sort key', () async {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final columns = await db
        .customSelect("PRAGMA index_info('vault_messages_by_sort')")
        .get();
    expect(columns.map((c) => c.read<String>('name')), [
      'conversation_id',
      'sort_key',
    ]);
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT * FROM vault_messages '
          "WHERE conversation_id = 'c' AND sort_key < 'x' "
          'ORDER BY sort_key DESC LIMIT 50',
        )
        .get();
    expect(
      plan.map((r) => r.read<String>('detail')).join(' '),
      contains('vault_messages_by_sort'),
    );
  });
}
