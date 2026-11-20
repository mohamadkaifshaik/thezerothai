import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sealed values are bound to their table, column and row key names, so a
/// rename orphans data. These names are pinned on purpose: change them only
/// with a migration that re-seals (see `VaultDatabase.migration`).
const Map<String, Map<String, String>> _schemaV1 = {
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

const Map<String, List<String>> _primaryKeysV1 = {
  'vault_meta': ['meta_key'],
  'vault_device': ['slot'],
  'vault_groups': ['conversation_id'],
  'vault_messages': ['conversation_id', 'message_id'],
  'vault_outbox': ['idempotency_key'],
  'vault_settings': ['setting_key'],
};

/// Version 2: everything of version 1, unchanged, plus the new tables and the
/// eight new columns. Nothing is renamed or dropped.
final Map<String, Map<String, String>> _schema = {
  ..._schemaV1,
  'vault_group_states': {
    'conversation_id': 'TEXT',
    'generation': 'INTEGER',
    'epoch': 'INTEGER',
    'provisional': 'INTEGER',
    'provisional_created_at': 'INTEGER',
    'state': 'BLOB',
    'pending': 'BLOB',
  },
  'vault_conversations': {
    'conversation_id': 'TEXT',
    'after_generation': 'INTEGER',
    'after_epoch': 'INTEGER',
    'join_generation': 'INTEGER',
    'join_epoch': 'INTEGER',
    'sync': 'BLOB',
  },
  'vault_members': {
    'conversation_id': 'TEXT',
    'device_id': 'TEXT',
    'side': 'TEXT',
    'since_generation': 'INTEGER',
    'since_epoch': 'INTEGER',
    'signature_key': 'BLOB',
  },
  'vault_sent': {
    'conversation_id': 'TEXT',
    'generation': 'INTEGER',
    'epoch': 'INTEGER',
    'digest': 'TEXT',
  },
  'vault_messages': {
    ..._schemaV1['vault_messages']!,
    'check_state': 'TEXT',
    'kind': 'TEXT',
    'mine': 'INTEGER',
    'sender_device_id': 'BLOB',
  },
  'vault_outbox': {
    ..._schemaV1['vault_outbox']!,
    'stage': 'TEXT',
    'expected_message_id': 'TEXT',
    'local_id': 'TEXT',
    'init': 'BLOB',
  },
};

const Map<String, List<String>> _primaryKeys = {
  ..._primaryKeysV1,
  'vault_group_states': ['conversation_id', 'generation'],
  'vault_conversations': ['conversation_id'],
  'vault_members': ['conversation_id', 'device_id'],
  'vault_sent': ['conversation_id', 'generation', 'epoch', 'digest'],
};

/// Opens [executor] only to read it (version 1, no migration).
class _ReadOnlyUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  test('a fresh database is at version 2', () async {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 2);
    expect(kVaultSchemaVersion, 2);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 2);
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
    expect(_schema.keys, hasLength(10));
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
    // Only these are nullable: a tombstone's content, the optional outbox
    // fields, and the optional columns of version 2.
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
      'vault_messages.mine',
      'vault_messages.sender_device_id',
      'vault_outbox.conversation_id',
      'vault_outbox.recipient_user_id',
      'vault_outbox.last_error',
      'vault_outbox.expected_message_id',
      'vault_outbox.local_id',
      'vault_outbox.init',
      'vault_group_states.provisional_created_at',
      'vault_group_states.pending',
      'vault_conversations.after_generation',
      'vault_conversations.after_epoch',
      'vault_conversations.join_generation',
      'vault_conversations.join_epoch',
      'vault_conversations.sync',
    });
  });

  test('the defaults of the version 2 columns', () async {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    Future<Map<String, String?>> defaults(String table) async => {
      for (final c in await db.customSelect('PRAGMA table_info($table)').get())
        c.read<String>('name'): c.read<String?>('dflt_value'),
    };
    final group = await defaults('vault_group_states');
    expect(group['provisional'], '0');
    final messages = await defaults('vault_messages');
    expect(messages['check_state'], "'ok'");
    expect(messages['kind'], "'message'");
    final outbox = await defaults('vault_outbox');
    expect(outbox['stage'], "'encrypted'");
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

  test('every vault table is in vaultTables and so covered by the wipe', () {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      db.vaultTables.map((t) => t.actualTableName).toSet(),
      _schema.keys.toSet(),
    );
    expect(db.vaultTables, hasLength(10));
  });

  group('the version 1 fixture', () {
    test(
      'is the version 1 file, ends at user_version 1 and matches the v1 maps',
      () async {
        final file = File('test/core/vault/fixtures/vault_schema_v1.sql');
        final script = file.readAsStringSync();
        // The committed bytes are LF; a Windows checkout may turn them into
        // CRLF, which the script does not care about.
        expect(
          script.replaceAll('\r\n', '\n'),
          endsWith('PRAGMA user_version = 1;\n'),
        );

        final executor = NativeDatabase.memory(
          setup: (raw) => raw.execute(script),
        );
        addTearDown(executor.close);
        await executor.ensureOpen(_ReadOnlyUser());
        final tables = await executor.runSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
          const [],
        );
        expect({
          for (final t in tables) t['name']! as String,
        }, _schemaV1.keys.toSet());
        for (final table in _schemaV1.keys) {
          final info = await executor.runSelect(
            'PRAGMA table_info($table)',
            const [],
          );
          expect(
            {for (final c in info) c['name']! as String: c['type']! as String},
            _schemaV1[table],
            reason: table,
          );
          final pk = [
            for (final c
                in info.where((c) => (c['pk']! as int) > 0).toList()..sort(
                  (a, b) => (a['pk']! as int).compareTo(b['pk']! as int),
                ))
              c['name']! as String,
          ];
          expect(pk, _primaryKeysV1[table], reason: table);
        }
        final version = await executor.runSelect(
          'PRAGMA user_version',
          const [],
        );
        expect(version.single['user_version'], 1);
      },
    );
  });
}
