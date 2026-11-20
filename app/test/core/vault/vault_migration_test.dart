import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_cipher.dart';

// The schema version 1 -> 2 migration, on a file made by the version 1 code:
// `fixtures/vault_schema_v1.sql` is the version 1 DDL, captured by running the
// unmodified version 1 database class (never written by hand). Rows are
// inserted by raw SQL and sealed under the version 1 labels and row keys, then
// the file is opened with the version 2 code.

const _uid = 'user-1';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

/// The version 1 columns of each table, in the fixture's order: what a dump
/// compares, so the columns version 2 added do not show up in it.
const Map<String, List<String>> _v1Columns = {
  'vault_meta': ['meta_key', 'owner_uid', 'schema_version', 'sentinel'],
  'vault_device': ['slot', 'device_id', 'device_state'],
  'vault_groups': [
    'conversation_id',
    'generation',
    'epoch',
    'state',
    'pending_commit',
  ],
  'vault_messages': [
    'conversation_id',
    'message_id',
    'sort_key',
    'state',
    'generation',
    'epoch',
    'from_self',
    'content',
  ],
  'vault_outbox': [
    'idempotency_key',
    'conversation_id',
    'sort_key',
    'generation',
    'epoch',
    'recipient_user_id',
    'ciphertext',
    'report_commitment',
    'content',
    'attempts',
    'last_error',
  ],
  'vault_settings': ['setting_key', 'value'],
};

const List<String> _allTables = [
  'vault_meta',
  'vault_device',
  'vault_groups',
  'vault_group_states',
  'vault_conversations',
  'vault_members',
  'vault_sent',
  'vault_messages',
  'vault_outbox',
  'vault_settings',
];

typedef _Dump = Map<String, List<Map<String, Object?>>>;

/// Opens an executor only to read it, at [version] so nothing is migrated or
/// re-stamped.
class _ReadOnlyUser implements QueryExecutorUser {
  _ReadOnlyUser(this.schemaVersion);

  @override
  final int schemaVersion;

  /// The version the file had when it was opened.
  int? versionBefore;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    versionBefore = details.versionBefore;
  }
}

/// A cipher whose engine goes away after [okOpens] successful opens.
class _OutageCipher extends FakeVaultCipher {
  _OutageCipher(this.okOpens);

  final int okOpens;

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) {
    if (openCalls >= okOpens) unavailable = true;
    return super.open(table, rowKey, sealed);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dir;
  var n = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vault_migration');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows can hold the file briefly; the OS temp dir is cleaned anyway.
    }
  });

  String newPath() => '${dir.path}${Platform.pathSeparator}v${n++}.sqlite';

  final fixture = File('test/core/vault/fixtures/vault_schema_v1.sql')
      .readAsStringSync();

  Future<Uint8List> seal(
    FakeVaultCipher cipher,
    String table,
    String column,
    List<String> key,
    Uint8List plaintext,
  ) => cipher.seal(vaultSealLabel(table, column), vaultRowKey(key), plaintext);

  /// Creates a version 1 file: the fixture, then rows sealed as version 1
  /// sealed them. [other] seals the values named in [badValues] under another
  /// key, so they do not authenticate under the real one.
  Future<String> v1File({
    Set<String> badValues = const {},
    List<String> extraSql = const [],
  }) async {
    final path = newPath();
    final cipher = FakeVaultCipher();
    final other = FakeVaultCipher(key: 'another-key');
    FakeVaultCipher by(String name) =>
        badValues.contains(name) ? other : cipher;

    final sentinel = await seal(cipher, 'vault_meta', 'sentinel', [
      kVaultMetaKey,
    ], _b(kVaultSentinel));
    final deviceId = await seal(cipher, 'vault_device', 'device_id', [
      kVaultDeviceSlot,
    ], _b('device-id-v1'));
    final deviceState = await seal(cipher, 'vault_device', 'device_state', [
      kVaultDeviceSlot,
    ], _b('device-state-v1'));
    final inserts = <(String, List<Object?>)>[
      (
        'INSERT INTO vault_meta VALUES (?, ?, ?, ?)',
        [kVaultMetaKey, _uid, 1, sentinel],
      ),
      (
        'INSERT INTO vault_device VALUES (?, ?, ?)',
        [kVaultDeviceSlot, deviceId, deviceState],
      ),
    ];
    for (final (conv, generation, epoch, flag) in [
      ('c1', 1, 3, 0),
      ('c2', 2, 5, 1),
    ]) {
      inserts.add((
        'INSERT INTO vault_groups VALUES (?, ?, ?, ?, ?)',
        [
          conv,
          generation,
          epoch,
          await seal(by('group-$conv'), 'vault_groups', 'state', [
            conv,
          ], _b('group state of $conv')),
          await seal(cipher, 'vault_groups', 'pending_commit', [
            conv,
          ], Uint8List.fromList([flag])),
        ],
      ));
    }
    for (final (id, at, state, fromSelf, hasContent) in [
      ('m1', 10, 'visible', true, true),
      ('m2', 20, 'visible', false, true),
      ('m3', 30, 'removed', true, false),
    ]) {
      inserts.add((
        'INSERT INTO vault_messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'c1',
          id,
          vaultSortKey(at, id),
          state,
          1,
          2,
          await seal(by('from-self-$id'), 'vault_messages', 'from_self', [
            'c1',
            id,
          ], Uint8List.fromList([fromSelf ? 1 : 0])),
          hasContent
              ? await seal(cipher, 'vault_messages', 'content', [
                  'c1',
                  id,
                ], _b('content of $id'))
              : null,
        ],
      ));
    }
    for (final (key, at) in [('k1', 5), ('k2', 6)]) {
      Future<Uint8List> o(String column, Uint8List v) =>
          seal(by('outbox-$key'), 'vault_outbox', column, [key], v);
      inserts.add((
        'INSERT INTO vault_outbox VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          key,
          'c1',
          vaultSortKey(at, key),
          3,
          4,
          null,
          await o('ciphertext', _b('wire $key')),
          await o('report_commitment', Uint8List(32)),
          await o('content', _b('outbox content $key')),
          await o('attempts', _b('2')),
          null,
        ],
      ));
    }
    inserts.add((
      'INSERT INTO vault_settings VALUES (?, ?)',
      [
        'pref',
        await seal(cipher, 'vault_settings', 'value', ['pref'], _b('v1 pref')),
      ],
    ));

    final executor = NativeDatabase(
      File(path),
      setup: (raw) {
        raw.execute(fixture);
        for (final (sql, params) in inserts) {
          raw.execute(sql, params);
        }
        // After the rows: a crash that left some version 2 structure behind.
        for (final sql in extraSql) {
          raw.execute(sql);
        }
      },
    );
    await executor.ensureOpen(_ReadOnlyUser(1));
    await executor.close();
    return path;
  }

  Future<_Dump> dump(
    String path,
    int version, {
    Map<String, List<String>> columns = _v1Columns,
  }) async {
    final executor = NativeDatabase(File(path));
    await executor.ensureOpen(_ReadOnlyUser(version));
    try {
      return {
        for (final e in columns.entries)
          e.key: await executor.runSelect(
            'SELECT ${e.value.join(', ')} FROM ${e.key} ORDER BY rowid',
            const [],
          ),
      };
    } finally {
      await executor.close();
    }
  }

  Future<Map<String, int>> counts(String path, int version) async {
    final executor = NativeDatabase(File(path));
    await executor.ensureOpen(_ReadOnlyUser(version));
    try {
      return {
        for (final t in _allTables)
          t:
              (await executor.runSelect(
                    'SELECT COUNT(*) AS n FROM $t',
                    const [],
                  )).single['n']!
                  as int,
      };
    } finally {
      await executor.close();
    }
  }

  VaultDatabase fileDb(String path) =>
      VaultDatabase.forTesting(NativeDatabase(File(path)));

  Future<SecureVault> open(String path, [FakeVaultCipher? cipher]) =>
      openVaultOnDatabase(
        fileDb(path),
        uid: _uid,
        cipher: cipher ?? FakeVaultCipher(),
      );

  Matcher throwsStatus(VaultStatus status) => throwsA(
    isA<VaultOpenException>().having((e) => e.status, 'status', status),
  );

  /// The `user_version` the file had when it was opened (the user's
  /// `beforeOpen` sees it before drift would move it to [assume]).
  Future<int?> userVersion(String path, int assume) async {
    final executor = NativeDatabase(File(path));
    final user = _ReadOnlyUser(assume);
    try {
      await executor.ensureOpen(user);
      return user.versionBefore;
    } finally {
      await executor.close();
    }
  }

  Future<int> stamp(String path, int version) async {
    final rows = (await dump(path, version))['vault_meta']!;
    return rows.single['schema_version']! as int;
  }

  test('the fixture is a version 1 file', () async {
    final path = await v1File();
    expect(await stamp(path, 1), 1);
    expect(await userVersion(path, 1), 1);
    final before = await dump(path, 1);
    expect(before['vault_groups'], hasLength(2));
    expect(before['vault_messages'], hasLength(3));
    expect(before['vault_outbox'], hasLength(2));
  });

  test(
    'a v1 vault with a device, settings, two groups, messages and an '
    'outbox row opens ready at version 2 with every value readable',
    () async {
      final path = await v1File();
      final vault = await open(path);
      addTearDown(vault.close);

      expect(vault.createdThisOpen, isFalse);
      expect(String.fromCharCodes((await vault.deviceId())!), 'device-id-v1');
      expect(
        String.fromCharCodes((await vault.deviceState())!),
        'device-state-v1',
      );
      expect(String.fromCharCodes((await vault.setting('pref'))!), 'v1 pref');
      expect((await vault.group('c1', 1))!.epoch, 3);
      expect((await vault.group('c2', 2))!.epoch, 5);
      final messages = await vault.messages('c1');
      expect(messages.map((m) => m.messageId), ['m3', 'm2', 'm1']);
      expect(String.fromCharCodes(messages.last.content!), 'content of m1');
      final outbox = await vault.outbox();
      expect(outbox.unreadableKeys, isEmpty);
      expect(outbox.items.map((o) => o.idempotencyKey), ['k1', 'k2']);
      expect(
        String.fromCharCodes(outbox.items.first.content),
        'outbox content k1',
      );
      expect(outbox.items.first.attempts, 2);

      await vault.close();
      expect(await stamp(path, 2), 2);
      expect(await userVersion(path, 2), 2);
    },
  );

  test('a v1 group is readable as group(conv, generation) with no pending '
      'and not provisional, and the vault_groups rows are byte-identical to '
      'before', () async {
    final path = await v1File();
    final before = await dump(path, 1);
    final vault = await open(path);
    final c1 = (await vault.group('c1', 1))!;
    expect(String.fromCharCodes(c1.state), 'group state of c1');
    expect([c1.generation, c1.epoch], [1, 3]);
    expect(c1.pending, isNull);
    expect(c1.hasPending, isFalse);
    expect(c1.provisional, isFalse);
    expect(c1.provisionalCreatedAtMicros, isNull);
    final c2 = (await vault.group('c2', 2))!;
    expect(c2.hasPending, isFalse, reason: 'a v1 pending flag is not carried');
    expect(await vault.group('c1', 2), isNull);
    expect(await vault.groupConversationIds(), ['c1', 'c2']);
    // No marks were invented.
    expect(await vault.conversation('c1'), isNull);
    await vault.close();

    final after = await dump(path, 2);
    expect(after['vault_groups'], before['vault_groups']);
    expect(after['vault_groups'], hasLength(2));
  });

  test('the open deletes no row of any table', () async {
    final path = await v1File();
    // Rows that do not authenticate are kept too.
    final bad = await v1File(
      badValues: {'group-c2', 'from-self-m2', 'outbox-k2'},
    );
    for (final file in [path, bad]) {
      final before = await dump(file, 1);
      final vault = await open(file);
      await vault.close();
      final after = await counts(file, 2);
      for (final e in before.entries) {
        expect(after[e.key], e.value.length, reason: '${e.key} in $file');
      }
      expect(after['vault_group_states'], file == path ? 2 : 1);
      expect(after['vault_conversations'], 0);
      expect(after['vault_members'], 0);
      expect(after['vault_sent'], 0);
    }
  });

  test('v1 messages keep content and have mine == fromSelf, check ok, kind '
      'message', () async {
    final path = await v1File();
    final vault = await open(path);
    final byId = {for (final m in await vault.messages('c1')) m.messageId: m};
    expect(byId['m1']!.mine, isTrue);
    expect(byId['m2']!.mine, isFalse);
    expect(byId['m3']!.mine, isTrue);
    expect(String.fromCharCodes(byId['m1']!.content!), 'content of m1');
    expect(String.fromCharCodes(byId['m2']!.content!), 'content of m2');
    expect(byId['m3']!.content, isNull);
    expect(byId['m3']!.state, StoredMessageState.removed);
    for (final m in byId.values) {
      expect(m.check, StoredMessageCheck.ok);
      expect(m.kind, StoredMessageKind.message);
      expect(m.senderDeviceId, isNull);
    }
    await vault.close();

    // The clear column was derived from the sealed legacy flag, which was
    // left as it was (so the two still agree).
    final rows = await dump(
      path,
      2,
      columns: {
        'vault_messages': [
          'message_id',
          'mine',
          'check_state',
          'kind',
          'sender_device_id',
        ],
      },
    );
    expect(
      [
        for (final r in rows['vault_messages']!)
          [r['message_id'], r['mine'], r['check_state'], r['kind']],
      ],
      [
        ['m1', 1, 'ok', 'message'],
        ['m2', 0, 'ok', 'message'],
        ['m3', 1, 'ok', 'message'],
      ],
    );
  });

  test('a v1 outbox row has stage encrypted, localId == idempotencyKey and '
      'the K3 expected id', () async {
    final path = await v1File();
    final vault = await open(path);
    final items = (await vault.outbox()).items;
    expect(items.map((o) => o.stage), everyElement(OutboxStage.encrypted));
    for (final item in items) {
      expect(item.localId, item.idempotencyKey);
      expect(
        item.expectedMessageId,
        expectedMessageId(_uid, item.idempotencyKey),
      );
      expect(item.init, isNull);
      expect(await vault.hasOutboxExpecting(item.expectedMessageId), isTrue);
    }
    await vault.close();
    final raw = await dump(
      path,
      2,
      columns: {
        'vault_outbox': ['idempotency_key', 'local_id', 'expected_message_id'],
      },
    );
    for (final r in raw['vault_outbox']!) {
      expect(r['local_id'], r['idempotency_key']);
      expect(
        r['expected_message_id'],
        expectedMessageId(_uid, r['idempotency_key']! as String),
      );
    }
  });

  test('a v1 vault opened with another key is keyLost and every sealed blob '
      'is byte-identical to the fixture rows', () async {
    final path = await v1File();
    final before = await dump(path, 1);
    final wrong = FakeVaultCipher(freshlyCreated: true)..switchToWrongKey();
    for (var i = 0; i < 2; i++) {
      await expectLater(
        openVaultOnDatabase(fileDb(path), uid: _uid, cipher: wrong),
        throwsStatus(VaultStatus.keyLost),
      );
    }
    // Drift added the version 2 tables and columns when it opened the file
    // (additive SQL, before the sentinel is checked); no existing row moved.
    expect(await dump(path, 2), before);
    expect(await stamp(path, 2), 1, reason: 'the stamp is still 1');
    final after = await counts(path, 2);
    expect(after['vault_group_states'], 0);
    expect(after['vault_conversations'], 0);
    expect(after['vault_members'], 0);
    expect(after['vault_sent'], 0);
    final clear = await dump(
      path,
      2,
      columns: {
        'vault_messages': ['mine', 'check_state', 'kind', 'sender_device_id'],
        'vault_outbox': ['stage', 'local_id', 'expected_message_id', 'init'],
      },
    );
    for (final r in clear['vault_messages']!) {
      expect(r['mine'], isNull);
      expect(r['check_state'], 'ok');
      expect(r['kind'], 'message');
      expect(r['sender_device_id'], isNull);
    }
    for (final r in clear['vault_outbox']!) {
      expect(r['stage'], 'encrypted');
      expect(r['local_id'], isNull);
      expect(r['expected_message_id'], isNull);
      expect(r['init'], isNull);
    }

    // The right key still opens it afterwards.
    final vault = await open(path);
    addTearDown(vault.close);
    expect((await vault.group('c1', 1))!.epoch, 3);
  });

  test('a v1 group row that does not authenticate stays in vault_groups '
      'untouched while the rest migrates', () async {
    final path = await v1File(
      badValues: {'group-c2', 'from-self-m2', 'outbox-k2'},
    );
    final before = await dump(path, 1);
    final vault = await open(path);
    addTearDown(vault.close);
    // The open is ready (a row that does not authenticate is not key loss).
    expect(vault.createdThisOpen, isFalse);

    expect((await vault.group('c1', 1))!.epoch, 3);
    expect(await vault.group('c2', 2), isNull);
    expect(await vault.groupConversationIds(), ['c1']);

    final byId = {for (final m in await vault.messages('c1')) m.messageId: m};
    expect(byId['m1']!.mine, isTrue);
    expect(byId['m2']!.state, StoredMessageState.undecryptable);
    expect(byId['m3']!.mine, isTrue);
    final outbox = await vault.outbox();
    expect(outbox.items.map((o) => o.idempotencyKey), ['k1']);
    expect(outbox.unreadableKeys, ['k2']);
    await vault.close();

    // Nothing that did not authenticate was changed, and the stamp moved.
    final after = await dump(path, 2);
    for (final table in _v1Columns.keys.where((t) => t != 'vault_meta')) {
      expect(after[table], before[table], reason: table);
    }
    expect(
      after['vault_meta']!.single['sentinel'],
      before['vault_meta']!.single['sentinel'],
    );
    expect(await stamp(path, 2), 2);
    final marks = await dump(
      path,
      2,
      columns: {
        'vault_messages': ['message_id', 'mine'],
        'vault_outbox': ['idempotency_key', 'local_id'],
      },
    );
    expect(
      {for (final r in marks['vault_messages']!) r['message_id']: r['mine']},
      {'m1': 1, 'm2': null, 'm3': 1},
    );
    expect(
      {
        for (final r in marks['vault_outbox']!)
          r['idempotency_key']: r['local_id'],
      },
      {'k1': 'k1', 'k2': 'k2'},
    );
  });

  test('a v1 outbox row that does not authenticate still gets localId and '
      'the expected id, with its sealed bytes unchanged', () async {
    final path = await v1File(badValues: {'outbox-k2'});
    final before = await dump(path, 1);
    final vault = await open(path);
    addTearDown(vault.close);
    // The row is unreadable, but the clear id lookup agrees with the
    // migrated clear columns.
    final read = await vault.outbox();
    expect(read.unreadableKeys, ['k2']);
    expect(read.items.map((o) => o.idempotencyKey), ['k1']);
    expect(
      await vault.hasOutboxExpecting(expectedMessageId(_uid, 'k2')),
      isTrue,
    );
    expect(
      await vault.hasOutboxExpecting(expectedMessageId(_uid, 'k1')),
      isTrue,
    );
    await vault.close();

    final after = await dump(path, 2);
    for (final table in _v1Columns.keys.where((t) => t != 'vault_meta')) {
      expect(after[table], before[table], reason: '$table sealed bytes');
    }
    final raw = await dump(
      path,
      2,
      columns: {
        'vault_outbox': ['idempotency_key', 'local_id', 'expected_message_id'],
      },
    );
    for (final r in raw['vault_outbox']!) {
      expect(r['local_id'], r['idempotency_key']);
      expect(
        r['expected_message_id'],
        expectedMessageId(_uid, r['idempotency_key']! as String),
      );
    }
  });

  test('a cipher outage during the sealed step leaves the stamp at 1 and a '
      'second open completes it', () async {
    final path = await v1File();
    final before = await dump(path, 1);
    // The sentinel opens (1), then both groups (2, 3); the next open throws:
    // the group_states rows the step wrote are rolled back with the rest.
    await expectLater(
      openVaultOnDatabase(fileDb(path), uid: _uid, cipher: _OutageCipher(3)),
      throwsStatus(VaultStatus.unavailable),
    );
    expect(await stamp(path, 2), 1);
    final mid = await counts(path, 2);
    expect(
      mid['vault_group_states'],
      0,
      reason: 'one transaction, rolled back',
    );
    expect(await dump(path, 2), before);
    final marks = await dump(
      path,
      2,
      columns: {
        'vault_messages': ['mine'],
        'vault_outbox': ['local_id', 'expected_message_id'],
      },
    );
    expect(
      marks['vault_messages']!.map((r) => r['mine']),
      everyElement(isNull),
    );
    expect(
      marks['vault_outbox']!.map((r) => r['local_id']),
      everyElement(isNull),
    );

    // Outages at other points of the step roll back the same way.
    // The step opens six values now (the sentinel, 2 groups, 3 messages; the
    // outbox ids need no open), so these cut it at the start, between the
    // messages and at the last one.
    for (final okOpens in [1, 4, 5]) {
      await expectLater(
        openVaultOnDatabase(
          fileDb(path),
          uid: _uid,
          cipher: _OutageCipher(okOpens),
        ),
        throwsStatus(VaultStatus.unavailable),
        reason: 'after $okOpens opens',
      );
      expect(await stamp(path, 2), 1, reason: 'after $okOpens opens');
      expect((await counts(path, 2))['vault_group_states'], 0);
      expect(await dump(path, 2), before);
    }

    final vault = await open(path);
    addTearDown(vault.close);
    expect((await vault.group('c1', 1))!.epoch, 3);
    expect((await vault.group('c2', 2))!.epoch, 5);
    expect((await vault.message('c1', 'm1'))!.mine, isTrue);
    expect((await vault.outbox()).items.first.localId, 'k1');
    await vault.close();
    expect(await stamp(path, 2), 2);
  });

  test('opening twice migrates once', () async {
    final path = await v1File();
    final first = await open(path);
    await first.close();
    final afterFirst = await dump(path, 2);
    final groupStates = await dump(
      path,
      2,
      columns: {
        'vault_group_states': ['conversation_id', 'generation', 'state'],
      },
    );

    final cipher = FakeVaultCipher();
    final second = await open(path, cipher);
    addTearDown(second.close);
    // Only the sentinel was opened: the sealed step did not run again.
    expect(cipher.openCalls, 1);
    expect(cipher.sealCalls, 0);
    await second.close();
    expect(await dump(path, 2), afterFirst);
    expect(
      await dump(
        path,
        2,
        columns: {
          'vault_group_states': ['conversation_id', 'generation', 'state'],
        },
      ),
      groupStates,
      reason: 'the migrated rows were not re-sealed',
    );
    expect((await counts(path, 2))['vault_group_states'], 2);
  });

  test('a file where the additive step stopped halfway opens and completes '
      'it', () async {
    // A crash between two statements of the additive step: drift sets
    // user_version only afterwards, so the file is still version 1 with some
    // of the version 2 structure already there.
    final path = await v1File(
      extraSql: [
        'CREATE TABLE "vault_sent" ("conversation_id" TEXT NOT NULL, '
            '"generation" INTEGER NOT NULL, "epoch" INTEGER NOT NULL, '
            '"digest" TEXT NOT NULL, '
            'PRIMARY KEY ("conversation_id", "generation", "epoch", "digest"));',
        "ALTER TABLE vault_messages ADD COLUMN check_state TEXT NOT NULL DEFAULT 'ok';",
        'ALTER TABLE vault_outbox ADD COLUMN init BLOB NULL;',
      ],
    );
    final vault = await open(path);
    addTearDown(vault.close);
    expect((await vault.group('c1', 1))!.epoch, 3);
    expect((await vault.message('c1', 'm1'))!.mine, isTrue);
    expect((await vault.outbox()).items, hasLength(2));
    await vault.close();
    expect(await stamp(path, 2), 2);
  });

  test('an upgraded v1 file has the same schema as a fresh v2 database, '
      'across all ten tables', () async {
    Future<Map<String, Object?>> shape(String path) async {
      final executor = NativeDatabase(File(path));
      await executor.ensureOpen(_ReadOnlyUser(2));
      try {
        final tables = await executor.runSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name",
          const [],
        );
        final out = <String, Object?>{};
        for (final t in tables) {
          final table = t['name']! as String;
          final info = await executor.runSelect(
            'PRAGMA table_info($table)',
            const [],
          );
          final indexes = await executor.runSelect(
            'PRAGMA index_list($table)',
            const [],
          );
          out[table] = {
            'columns': {
              for (final c in info)
                c['name']! as String: [
                  c['type'],
                  c['notnull'],
                  c['dflt_value'],
                  c['pk'],
                ],
            },
            'indexes': {
              for (final i in indexes)
                i['name']! as String: [i['unique'], i['origin'], i['partial']],
            },
          };
        }
        return out;
      } finally {
        await executor.close();
      }
    }

    final upgraded = await v1File();
    final vault = await open(upgraded);
    await vault.close();
    final fresh = newPath();
    final created = await open(fresh);
    await created.close();

    final a = await shape(upgraded);
    final b = await shape(fresh);
    expect(a.keys.toSet(), _allTables.toSet());
    expect(a.keys, b.keys);
    for (final table in _allTables) {
      expect(a[table], b[table], reason: table);
    }
  });

  test('a new vault is stamped 2 directly and runs no sealed step', () async {
    final path = newPath();
    final cipher = FakeVaultCipher(freshlyCreated: true);
    final vault = await open(path, cipher);
    expect(vault.createdThisOpen, isTrue);
    await vault.close();
    expect(await stamp(path, 2), 2);
    expect(cipher.openCalls, 0);
  });

  test('wipe empties all ten tables', () async {
    final path = await v1File();
    final vault = await open(path);
    await vault.transaction((tx) async {
      await tx.putGroup(
        GroupRecord(
          conversationId: 'c9',
          generation: 1,
          epoch: 1,
          state: _b('s'),
          provisional: true,
          provisionalCreatedAtMicros: 1,
        ),
      );
      await tx.putGroup(
        GroupRecord(
          conversationId: 'c1',
          generation: 5,
          epoch: 1,
          state: _b('s'),
        ),
      );
      await tx.setAfterPair('c1', const MlsPair(5, 0));
      await tx.putConversationSync('c1', const ConversationSync());
      await tx.putMember(
        MemberRecord(
          conversationId: 'c1',
          deviceId: _b('dev'),
          signatureKey: _b('sig'),
          side: MemberSide.theirs,
          since: const MlsPair(5, 0),
        ),
      );
      await tx.addSent('c1', const MlsPair(5, 0), 'ab' * 32);
    });
    await vault.close();
    final reopened = await open(path);
    final seen = await counts(path, 2);
    expect(seen.keys.toSet(), _allTables.toSet());
    expect(
      seen.values.where((c) => c == 0),
      isEmpty,
      reason: 'all ten hold rows',
    );

    await reopened.wipe();
    final after = await counts(path, 2);
    expect(after.keys, hasLength(10));
    expect(after.values, everyElement(0));
  });
}
