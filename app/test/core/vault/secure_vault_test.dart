import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_cipher.dart';

const _uid = 'user-1';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(Uint8List? b) => b == null ? '<null>' : utf8.decode(b);

StoredMessage _msg(
  String id, {
  String conversation = 'c1',
  int at = 1000,
  String? text,
  String state = StoredMessageState.visible,
  bool fromSelf = false,
}) => StoredMessage(
  conversationId: conversation,
  messageId: id,
  createdAtMicros: at,
  fromSelf: fromSelf,
  state: state,
  generation: 1,
  epoch: 2,
  content: state == StoredMessageState.visible
      ? _b(text ?? 'secret text of $id')
      : null,
);

OutboxItem _outbox(String key, {String? conversation = 'c1', int at = 10}) =>
    OutboxItem(
      idempotencyKey: key,
      conversationId: conversation,
      recipientUserId: conversation == null ? 'recipient-user-9' : null,
      generation: 3,
      epoch: 4,
      ciphertext: _b('wire ciphertext $key'),
      reportCommitment: _b('commitment $key'),
      content: _b('outbox plaintext $key'),
      createdAtMicros: at,
      attempts: 2,
      lastError: 'network down $key',
    );

Future<int> _count(VaultDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<Map<String, int>> _counts(VaultDatabase db) async => {
  for (final t in [
    'vault_meta',
    'vault_device',
    'vault_groups',
    'vault_messages',
    'vault_outbox',
    'vault_settings',
  ])
    t: await _count(db, t),
};

void main() {
  // Each test opens its own file or memory database on purpose.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dir;
  var n = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vault_test');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows can hold the file briefly; the OS temp dir is cleaned anyway.
    }
  });

  /// A file-backed database, so a test can reopen it after a failed open
  /// (which closes the database).
  String newPath() => '${dir.path}${Platform.pathSeparator}v${n++}.sqlite';
  VaultDatabase fileDb(String path) =>
      VaultDatabase.forTesting(NativeDatabase(File(path)));

  Future<SecureVault> open(
    VaultDatabase db,
    VaultCipher cipher, {
    String uid = _uid,
  }) => openVaultOnDatabase(db, uid: uid, cipher: cipher);

  Matcher throwsStatus(VaultStatus status) => throwsA(
    isA<VaultOpenException>().having((e) => e.status, 'status', status),
  );

  /// A vault with some rows of every kind, closed again.
  Future<void> seed(String path, VaultCipher cipher) async {
    final vault = await open(fileDb(path), cipher);
    await vault.transaction((tx) async {
      await tx.putDevice(_b('device-id'), _b('device-state'));
      await tx.putGroup(
        GroupRecord(
          conversationId: 'c1',
          generation: 1,
          epoch: 1,
          state: _b('group-state'),
          pendingCommit: false,
        ),
      );
      await tx.putMessage(_msg('m1'));
      await tx.putOutbox(_outbox('k1'));
      await tx.putSetting('s', _b('setting'));
    });
    await vault.close();
  }

  group('open and the sentinel', () {
    test('a new vault stamps the owner and writes a sealed sentinel', () async {
      final db = fileDb(newPath());
      final cipher = FakeVaultCipher(freshlyCreated: true);
      final vault = await open(db, cipher);
      addTearDown(vault.close);

      final rows = await db.select(db.vaultMeta).get();
      expect(rows, hasLength(1));
      expect(rows.single.metaKey, 'vault');
      expect(rows.single.ownerUid, _uid);
      expect(rows.single.schemaVersion, 1);
      expect(latin1.decode(rows.single.sentinel), isNot(contains('sentinel')));
      final opened = await cipher.open(
        'vault_meta.sentinel',
        vaultRowKey(['vault']),
        rows.single.sentinel,
      );
      expect(_s(opened), kVaultSentinel);
      expect(vault.uid, _uid);
    });

    test('a reopen with the same key is ready and reads the rows', () async {
      final path = newPath();
      final cipher = FakeVaultCipher();
      await seed(path, cipher);
      final vault = await open(fileDb(path), FakeVaultCipher());
      addTearDown(vault.close);
      expect(_s(await vault.deviceState()), 'device-state');
      expect(
        _s((await vault.message('c1', 'm1'))!.content),
        'secret text of m1',
      );
    });

    test('a lost key is keyLost and the file is left untouched', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final checkBefore = fileDb(path);
      final countsBefore = await _counts(checkBefore);
      final sentinelBefore =
          (await checkBefore.select(checkBefore.vaultMeta).getSingle())
              .sentinel;
      await checkBefore.close();

      final wrong = FakeVaultCipher(freshlyCreated: true)..switchToWrongKey();
      await expectLater(
        open(fileDb(path), wrong),
        throwsStatus(VaultStatus.keyLost),
      );
      // Twice: a lost key never turns into a new vault.
      await expectLater(
        open(fileDb(path), wrong),
        throwsStatus(VaultStatus.keyLost),
      );

      final after = fileDb(path);
      addTearDown(after.close);
      expect(await _counts(after), countsBefore);
      expect(countsBefore.values.every((c) => c == 1), isTrue);
      expect(
        (await after.select(after.vaultMeta).getSingle()).sentinel,
        sentinelBefore,
      );
      expect(wrong.sealCalls, 0);
    });

    test('rows without a sentinel are keyLost and left untouched', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final raw = fileDb(path);
      await raw.customStatement('DELETE FROM vault_meta');
      final before = await _counts(raw);
      await raw.close();

      await expectLater(
        open(fileDb(path), FakeVaultCipher()),
        throwsStatus(VaultStatus.keyLost),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect(await _counts(after), before);
      expect(before['vault_messages'], 1);
    });

    test('a sentinel holding another value is keyLost', () async {
      final path = newPath();
      final cipher = FakeVaultCipher();
      await seed(path, cipher);
      final raw = fileDb(path);
      final other = await cipher.seal(
        'vault_meta.sentinel',
        vaultRowKey(['vault']),
        _b('not the sentinel'),
      );
      await raw.customUpdate(
        'UPDATE vault_meta SET sentinel = ?',
        variables: [Variable.withBlob(other)],
      );
      await raw.close();
      await expectLater(
        open(fileDb(path), FakeVaultCipher()),
        throwsStatus(VaultStatus.keyLost),
      );
    });

    test('an unavailable cipher is unavailable and changes nothing', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final unavailable = FakeVaultCipher()..unavailable = true;
      await expectLater(
        open(fileDb(path), unavailable),
        throwsStatus(VaultStatus.unavailable),
      );
      final broken = FakeVaultCipher()..throwsEverything = true;
      await expectLater(
        open(fileDb(path), broken),
        throwsStatus(VaultStatus.unavailable),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect((await _counts(after)).values.every((c) => c == 1), isTrue);
    });

    test('an unavailable cipher on a new vault writes nothing', () async {
      final path = newPath();
      await expectLater(
        open(fileDb(path), FakeVaultCipher()..unavailable = true),
        throwsStatus(VaultStatus.unavailable),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect(await _count(after, 'vault_meta'), 0);
    });

    test('another owner\'s stamp never wipes: a sentinel that opens under '
        'this cipher is re-stamped and ready, rows kept', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final db = fileDb(path);
      // Same key material (the stamp alone is wrong, e.g. corrupted).
      final vault = await open(db, FakeVaultCipher(), uid: 'user-2');
      addTearDown(vault.close);
      expect((await _counts(db)).values.every((c) => c == 1), isTrue);
      expect((await db.select(db.vaultMeta).getSingle()).ownerUid, 'user-2');
      expect(
        _s((await vault.message('c1', 'm1'))!.content),
        'secret text of m1',
      );
    });

    test('another owner\'s stamp whose sentinel does not open is keyLost, '
        'file untouched', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      await expectLater(
        open(fileDb(path), FakeVaultCipher(key: 'key-2'), uid: 'user-2'),
        throwsStatus(VaultStatus.keyLost),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect((await _counts(after)).values.every((c) => c == 1), isTrue);
      expect((await after.select(after.vaultMeta).getSingle()).ownerUid, _uid);
    });

    test('another owner\'s stamp with an unavailable cipher is unavailable, '
        'file untouched', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      await expectLater(
        open(fileDb(path), FakeVaultCipher()..unavailable = true, uid: 'u2'),
        throwsStatus(VaultStatus.unavailable),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect((await _counts(after)).values.every((c) => c == 1), isTrue);
      expect((await after.select(after.vaultMeta).getSingle()).ownerUid, _uid);
    });

    test('opening turns on secure_delete', () async {
      final db = VaultDatabase.forTesting(NativeDatabase.memory());
      final vault = await open(db, FakeVaultCipher());
      addTearDown(vault.close);
      final row = await db.customSelect('PRAGMA secure_delete').getSingle();
      expect(row.data.values.single, 1);
    });

    test('a stamp from a newer schema is unavailable and untouched', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final raw = fileDb(path);
      await raw.customStatement('UPDATE vault_meta SET schema_version = 2');
      await raw.close();
      await expectLater(
        open(fileDb(path), FakeVaultCipher()),
        throwsStatus(VaultStatus.unavailable),
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect(await _count(after, 'vault_messages'), 1);
    });

    test(
      'a storage that fails to open is unavailable, nothing escapes',
      () async {
        final escaped = <Object>[];
        await runZonedGuarded(() async {
          // A file that cannot be opened fails the first query (what
          // drift's native background connection does).
          final db = VaultDatabase.forTesting(
            LazyDatabase(() async => throw const FileSystemException('gone')),
          );
          await expectLater(
            open(db, FakeVaultCipher()),
            throwsStatus(VaultStatus.unavailable),
          );
        }, (error, _) => escaped.add(error));
        await pumpEventQueue();
        expect(escaped, isEmpty);
      },
    );

    test('an open that never completes times out as unavailable', () async {
      final never = Completer<QueryExecutor>();
      final db = VaultDatabase.forTesting(LazyDatabase(() => never.future));
      await expectLater(
        openVaultOnDatabase(
          db,
          uid: _uid,
          cipher: FakeVaultCipher(),
          openTimeout: const Duration(milliseconds: 50),
        ),
        throwsStatus(VaultStatus.unavailable),
      );
    });

    test('after key loss, wipeVaultFile then a fresh key opens a new vault '
        '(the recovery path), with no working cipher needed to wipe', () async {
      final path = newPath();
      await seed(path, FakeVaultCipher());
      final lost = FakeVaultCipher()..throwsEverything = true;
      await expectLater(
        open(fileDb(path), lost),
        throwsStatus(VaultStatus.unavailable),
      );

      await wipeVaultDatabase(fileDb(path));

      final fresh = FakeVaultCipher(freshlyCreated: true, key: 'key-new');
      final db = fileDb(path);
      final vault = await open(db, fresh);
      addTearDown(vault.close);
      expect(await vault.deviceId(), isNull);
      expect(await _count(db, 'vault_meta'), 1);
      expect(lost.openCalls + lost.sealCalls, 0);
    });
  });

  group('writes and reads', () {
    late VaultDatabase db;
    late FakeVaultCipher cipher;
    late SecureVault vault;

    setUp(() async {
      db = VaultDatabase.forTesting(NativeDatabase.memory());
      cipher = FakeVaultCipher();
      vault = await open(db, cipher);
    });

    tearDown(() async {
      try {
        await vault.close();
      } catch (_) {}
    });

    test('every VaultTx write round-trips', () async {
      await vault.transaction((tx) async {
        await tx.putDevice(_b('dev-id'), _b('dev-state-1'));
        await tx.putDeviceState(_b('dev-state-2'));
        await tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 5,
            epoch: 9007199254740991,
            state: _b('mls group state'),
            pendingCommit: true,
          ),
        );
        await tx.putMessage(_msg('m1', at: 42, fromSelf: true));
        await tx.putMessage(
          _msg('m2', at: 43, state: StoredMessageState.removed),
        );
        await tx.putOutbox(_outbox('k1', at: 7));
        await tx.putOutbox(_outbox('k2', conversation: null, at: 8));
        await tx.putSetting('pref', _b('value'));
      });

      expect(_s(await vault.deviceId()), 'dev-id');
      expect(_s(await vault.deviceState()), 'dev-state-2');
      final g = (await vault.group('c1'))!;
      expect(
        [g.generation, g.epoch, g.pendingCommit],
        [5, 9007199254740991, true],
      );
      expect(_s(g.state), 'mls group state');
      expect(await vault.group('c2'), isNull);

      final m1 = (await vault.message('c1', 'm1'))!;
      expect(m1.createdAtMicros, 42);
      expect(m1.fromSelf, isTrue);
      expect(m1.state, StoredMessageState.visible);
      expect([m1.generation, m1.epoch], [1, 2]);
      expect(_s(m1.content), 'secret text of m1');
      final m2 = (await vault.message('c1', 'm2'))!;
      expect(m2.state, StoredMessageState.removed);
      expect(m2.content, isNull);
      expect(m2.fromSelf, isFalse);

      final read = await vault.outbox();
      expect(read.unreadableKeys, isEmpty);
      final out = read.items;
      expect(out.map((o) => o.idempotencyKey), ['k1', 'k2']);
      final k1 = out.first;
      expect(k1.conversationId, 'c1');
      expect(k1.recipientUserId, isNull);
      expect(
        [k1.generation, k1.epoch, k1.createdAtMicros, k1.attempts],
        [3, 4, 7, 2],
      );
      expect(_s(k1.ciphertext), 'wire ciphertext k1');
      expect(_s(k1.reportCommitment), 'commitment k1');
      expect(_s(k1.content), 'outbox plaintext k1');
      expect(k1.lastError, 'network down k1');
      expect(out.last.conversationId, isNull);
      expect(out.last.recipientUserId, 'recipient-user-9');
      expect(
        (await vault.outbox(conversationId: 'c1')).items
            .map((o) => o.idempotencyKey),
        ['k1'],
      );
      expect(_s(await vault.setting('pref')), 'value');
      expect(await vault.setting('none'), isNull);

      await vault.transaction((tx) async {
        await tx.deleteGroup('c1');
        await tx.deleteOutbox('k1');
      });
      expect(await vault.group('c1'), isNull);
      expect((await vault.outbox()).items.map((o) => o.idempotencyKey), ['k2']);
    });

    test('a device and its state are null before putDevice; putDeviceState '
        'first is refused', () async {
      expect(await vault.deviceId(), isNull);
      expect(await vault.deviceState(), isNull);
      await expectLater(
        vault.transaction((tx) => tx.putDeviceState(_b('x'))),
        throwsStateError,
      );
    });

    test('a throwing transaction leaves no trace (old group state, no new '
        'message)', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 1,
            epoch: 1,
            state: _b('old state'),
            pendingCommit: false,
          ),
        );
      });
      await expectLater(
        vault.transaction((tx) async {
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 2,
              state: _b('new state'),
              pendingCommit: true,
            ),
          );
          await tx.putMessage(_msg('m-new'));
          // The writes are visible inside the transaction...
          expect(_s((await vault.group('c1'))!.state), 'new state');
          expect(await vault.hasMessage('c1', 'm-new'), isTrue);
          throw StateError('engine failed');
        }),
        throwsStateError,
      );
      // ...and gone after it.
      final g = (await vault.group('c1'))!;
      expect(_s(g.state), 'old state');
      expect(g.epoch, 1);
      expect(g.pendingCommit, isFalse);
      expect(await vault.hasMessage('c1', 'm-new'), isFalse);
      expect(await vault.message('c1', 'm-new'), isNull);
      expect(await _count(db, 'vault_messages'), 0);
    });

    test(
      'transactions do not nest, and a VaultTx is dead outside its body',
      () async {
        await expectLater(
          vault.transaction((tx) => vault.transaction((_) async => 1)),
          throwsStateError,
        );
        await expectLater(
          vault.transaction((tx) => vault.wipe()),
          throwsStateError,
        );
        late VaultTx leaked;
        await vault.transaction((tx) async => leaked = tx);
        await expectLater(leaked.putSetting('k', _b('v')), throwsStateError);
        expect(await vault.setting('k'), isNull);
        // Two transactions at once from separate callers are fine.
        await Future.wait([
          vault.transaction((tx) => tx.putSetting('a', _b('1'))),
          vault.transaction((tx) => tx.putSetting('b', _b('2'))),
        ]);
        expect(_s(await vault.setting('a')), '1');
        expect(_s(await vault.setting('b')), '2');
      },
    );

    test(
      'raw rows hold no plaintext and only the allowed clear columns',
      () async {
        await vault.transaction((tx) async {
          await tx.putDevice(_b('PLAIN-device-id'), _b('PLAIN-device-state'));
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 1,
              state: _b('PLAIN-group'),
              pendingCommit: true,
            ),
          );
          await tx.putMessage(_msg('m1', text: 'PLAIN-message'));
          await tx.putOutbox(
            OutboxItem(
              idempotencyKey: 'k1',
              recipientUserId: 'PLAIN-recipient',
              generation: 1,
              epoch: 1,
              ciphertext: _b('PLAIN-ciphertext'),
              reportCommitment: _b('PLAIN-commitment'),
              content: _b('PLAIN-outbox'),
              createdAtMicros: 1,
              attempts: 12345,
              lastError: 'PLAIN-error',
            ),
          );
          await tx.putSetting('pref', _b('PLAIN-setting'));
        });

        const clear = {
          'vault_meta': {'meta_key', 'owner_uid', 'schema_version'},
          'vault_device': {'slot'},
          'vault_groups': {'conversation_id', 'generation', 'epoch'},
          'vault_messages': {
            'conversation_id',
            'message_id',
            'sort_key',
            'state',
            'generation',
            'epoch',
          },
          'vault_outbox': {
            'idempotency_key',
            'conversation_id',
            'sort_key',
            'generation',
            'epoch',
          },
          'vault_settings': {'setting_key'},
        };
        for (final entry in clear.entries) {
          final rows = await db
              .customSelect('SELECT * FROM ${entry.key}')
              .get();
          expect(rows, isNotEmpty, reason: entry.key);
          for (final row in rows) {
            for (final column in row.data.entries) {
              final value = column.value;
              if (entry.value.contains(column.key)) {
                expect(value, isNot(isA<Uint8List>()), reason: column.key);
                continue;
              }
              // Every other column is sealed: a blob of nonce + tag at least.
              expect(
                value,
                isA<Uint8List>(),
                reason: '${entry.key}.${column.key}',
              );
              final bytes = value as Uint8List;
              expect(bytes.length, greaterThanOrEqualTo(28));
              final text = latin1.decode(bytes);
              expect(text, isNot(contains('PLAIN')), reason: column.key);
              expect(text, isNot(contains('12345')), reason: column.key);
            }
          }
        }
        // The column lists of the schema match: no unexpected clear column.
        for (final entry in clear.entries) {
          final info = await db
              .customSelect('PRAGMA table_info(${entry.key})')
              .get();
          final nonBlob = {
            for (final c in info)
              if (c.read<String>('type') != 'BLOB') c.read<String>('name'),
          };
          expect(nonBlob, entry.value, reason: entry.key);
        }
      },
    );

    test('a value copied to another row fails to open: the message is '
        'returned undecryptable and kept', () async {
      await vault.transaction((tx) async {
        await tx.putMessage(_msg('m1', at: 1));
        await tx.putMessage(_msg('m2', at: 2));
      });
      await db.customStatement(
        'UPDATE vault_messages SET content = '
        "(SELECT content FROM vault_messages WHERE message_id = 'm1') "
        "WHERE message_id = 'm2'",
      );
      final m2 = (await vault.message('c1', 'm2'))!;
      expect(m2.state, StoredMessageState.undecryptable);
      expect(m2.content, isNull);
      expect(m2.createdAtMicros, 2);
      final page = await vault.messages('c1');
      expect(page.map((m) => m.messageId), ['m2', 'm1']);
      expect(page.map((m) => m.state), [
        StoredMessageState.undecryptable,
        StoredMessageState.visible,
      ]);
      expect(await vault.hasMessage('c1', 'm2'), isTrue);
      expect(await _count(db, 'vault_messages'), 2);
      // Reading did not write the undecryptable state back.
      final raw = await db
          .customSelect(
            "SELECT state FROM vault_messages WHERE message_id = 'm2'",
          )
          .getSingle();
      expect(raw.read<String>('state'), StoredMessageState.visible);
    });

    test('two sealed columns of one row cannot be swapped', () async {
      await vault.transaction((tx) => tx.putOutbox(_outbox('k1')));
      await db.customStatement(
        'UPDATE vault_outbox SET content = ciphertext, ciphertext = content',
      );
      final read = await vault.outbox();
      expect(read.items, isEmpty);
      expect(read.unreadableKeys, ['k1']);
      expect(await _count(db, 'vault_outbox'), 1);
    });

    test('one unreadable outbox row does not block the others, and is '
        'reported by key, never deleted', () async {
      await vault.transaction((tx) async {
        await tx.putOutbox(_outbox('k1', at: 1));
        await tx.putOutbox(_outbox('k2', at: 2));
        await tx.putOutbox(_outbox('k3', at: 3));
      });
      // k2: a value copied from another row. k3: attempts is not a number.
      await db.customStatement(
        'UPDATE vault_outbox SET content = '
        "(SELECT content FROM vault_outbox WHERE idempotency_key = 'k1') "
        "WHERE idempotency_key = 'k2'",
      );
      final notANumber = await cipher.seal(
        'vault_outbox.attempts',
        vaultRowKey(['k3']),
        _b('SECRET-not-a-number'),
      );
      await db.customUpdate(
        "UPDATE vault_outbox SET attempts = ? WHERE idempotency_key = 'k3'",
        variables: [Variable.withBlob(notANumber)],
      );
      final read = await vault.outbox();
      expect(read.items.map((o) => o.idempotencyKey), ['k1']);
      expect(read.unreadableKeys, ['k2', 'k3']);
      expect(read.toString(), isNot(contains('SECRET')));
      expect(await _count(db, 'vault_outbox'), 3);
      // The caller removes them by key.
      await vault.transaction((tx) async {
        for (final key in read.unreadableKeys) {
          await tx.deleteOutbox(key);
        }
      });
      final again = await vault.outbox();
      expect(again.items.map((o) => o.idempotencyKey), ['k1']);
      expect(again.unreadableKeys, isEmpty);
    });

    test('a cipher that becomes unavailable mid-transaction fails it and the '
        'group is unchanged', () async {
      await vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 1,
            epoch: 1,
            state: _b('old'),
            pendingCommit: false,
          ),
        ),
      );
      await expectLater(
        vault.transaction((tx) async {
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 2,
              state: _b('new'),
              pendingCommit: true,
            ),
          );
          cipher.unavailable = true;
          await tx.putMessage(_msg('m1'));
        }),
        throwsA(isA<VaultKeyException>()),
      );
      cipher.unavailable = false;
      final g = (await vault.group('c1'))!;
      expect([_s(g.state), g.epoch, g.pendingCommit], ['old', 1, false]);
      expect(await vault.hasMessage('c1', 'm1'), isFalse);
    });

    test(
      'a device or group row that fails to open is VaultCorruptException',
      () async {
        await vault.transaction((tx) async {
          await tx.putDevice(_b('id'), _b('state'));
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 1,
              state: _b('g1'),
              pendingCommit: false,
            ),
          );
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c2',
              generation: 1,
              epoch: 1,
              state: _b('g2'),
              pendingCommit: false,
            ),
          );
          await tx.putSetting('a', _b('1'));
          await tx.putSetting('b', _b('2'));
        });
        await db.customStatement(
          'UPDATE vault_device SET device_state = device_id',
        );
        await db.customStatement(
          "UPDATE vault_groups SET state = (SELECT state FROM vault_groups WHERE conversation_id = 'c2') "
          "WHERE conversation_id = 'c1'",
        );
        await db.customStatement(
          "UPDATE vault_settings SET value = (SELECT value FROM vault_settings WHERE setting_key = 'b') "
          "WHERE setting_key = 'a'",
        );
        Matcher corrupt(String table) => throwsA(
          isA<VaultCorruptException>().having((e) => e.table, 'table', table),
        );
        await expectLater(vault.deviceState(), corrupt('vault_device'));
        expect(_s(await vault.deviceId()), 'id');
        await expectLater(vault.group('c1'), corrupt('vault_groups'));
        expect(_s((await vault.group('c2'))!.state), 'g2');
        await expectLater(vault.setting('a'), corrupt('vault_settings'));
      },
    );

    test(
      'an unavailable cipher propagates from reads (never "undecryptable")',
      () async {
        await vault.transaction((tx) => tx.putMessage(_msg('m1')));
        cipher.unavailable = true;
        await expectLater(
          vault.messages('c1'),
          throwsA(isA<VaultKeyException>()),
        );
        await expectLater(
          vault.message('c1', 'm1'),
          throwsA(isA<VaultKeyException>()),
        );
        await expectLater(
          vault.transaction((tx) => tx.putMessage(_msg('m2'))),
          throwsA(isA<VaultKeyException>()),
        );
        cipher.unavailable = false;
        expect(await vault.hasMessage('c1', 'm2'), isFalse);
      },
    );

    test('messages page newest first through 1,000 messages, no cap', () async {
      // Two conversations interleaved, ids that sort differently from time.
      await vault.transaction((tx) async {
        for (var i = 0; i < 1000; i++) {
          await tx.putMessage(_msg('id-${999 - i}', at: 1000000 + i));
          if (i % 100 == 0) {
            await tx.putMessage(_msg('other-$i', conversation: 'c2', at: i));
          }
        }
      });
      final seen = <StoredMessage>[];
      String? before;
      var pages = 0;
      while (true) {
        final page = await vault.messages(
          'c1',
          limit: 37,
          beforeSortKey: before,
        );
        pages++;
        seen.addAll(page);
        if (page.length < 37) break;
        before = page.last.sortKey;
      }
      expect(seen, hasLength(1000));
      expect(pages, 28);
      expect(seen.first.createdAtMicros, 1000999);
      expect(seen.last.createdAtMicros, 1000000);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].createdAtMicros, lessThan(seen[i - 1].createdAtMicros));
      }
      expect(seen.map((m) => m.messageId).toSet(), hasLength(1000));
      expect(seen.every((m) => m.conversationId == 'c1'), isTrue);
      expect(_s(seen[500].content), 'secret text of ${seen[500].messageId}');
      expect(await _count(db, 'vault_messages'), 1010);
      expect(await vault.messages('c1', limit: 5000), hasLength(1000));
      expect(() => vault.messages('c1', limit: 0), throwsArgumentError);
    });

    test('same time: ties sort by message id', () async {
      await vault.transaction((tx) async {
        await tx.putMessage(_msg('a', at: 5));
        await tx.putMessage(_msg('b', at: 5));
        await tx.putMessage(_msg('c', at: 4));
      });
      expect((await vault.messages('c1')).map((m) => m.messageId), [
        'b',
        'a',
        'c',
      ]);
      final afterB = await vault.messages(
        'c1',
        beforeSortKey: vaultSortKey(5, 'b'),
      );
      expect(afterB.map((m) => m.messageId), ['a', 'c']);
    });

    test('hasMessage reads no sealed column', () async {
      await vault.transaction((tx) => tx.putMessage(_msg('m1')));
      final opens = cipher.openCalls;
      expect(await vault.hasMessage('c1', 'm1'), isTrue);
      expect(await vault.hasMessage('c1', 'm2'), isFalse);
      expect(await vault.hasMessage('c2', 'm1'), isFalse);
      expect(cipher.openCalls, opens);
    });

    test(
      'setMessageState clears content (NULL, not a sealed empty value)',
      () async {
        await vault.transaction((tx) async {
          await tx.putMessage(_msg('m1'));
          await tx.putMessage(_msg('m2'));
        });
        for (final state in [
          StoredMessageState.removed,
          StoredMessageState.deletedAccount,
        ]) {
          await vault.transaction(
            (tx) => tx.setMessageState('c1', 'm1', state),
          );
          final m = (await vault.message('c1', 'm1'))!;
          expect(m.state, state);
          expect(m.content, isNull);
        }
        final raw = await db
            .customSelect(
              "SELECT content FROM vault_messages WHERE message_id = 'm1'",
            )
            .getSingle();
        expect(raw.data['content'], isNull);
        expect(
          _s((await vault.message('c1', 'm2'))!.content),
          'secret text of m2',
        );
        // Unknown message: nothing is created.
        await vault.transaction(
          (tx) => tx.setMessageState('c1', 'nope', StoredMessageState.removed),
        );
        expect(await vault.hasMessage('c1', 'nope'), isFalse);
        await expectLater(
          vault.transaction(
            (tx) => tx.setMessageState('c1', 'm2', StoredMessageState.visible),
          ),
          throwsArgumentError,
        );
        await expectLater(
          vault.transaction((tx) => tx.setMessageState('c1', 'm2', 'bogus')),
          throwsArgumentError,
        );
      },
    );

    test(
      'putMessage refuses content on a tombstone and none on a visible',
      () async {
        final tombstoneWithContent = StoredMessage(
          conversationId: 'c1',
          messageId: 'x',
          createdAtMicros: 1,
          fromSelf: false,
          state: StoredMessageState.removed,
          generation: 1,
          epoch: 1,
          content: _b('nope'),
        );
        const visibleWithout = StoredMessage(
          conversationId: 'c1',
          messageId: 'y',
          createdAtMicros: 1,
          fromSelf: false,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: null,
        );
        for (final m in [tombstoneWithContent, visibleWithout]) {
          await expectLater(
            vault.transaction((tx) => tx.putMessage(m)),
            throwsArgumentError,
          );
        }
        await vault.transaction(
          (tx) =>
              tx.putMessage(_msg('t', state: StoredMessageState.undecryptable)),
        );
        final raw = await db
            .customSelect(
              "SELECT content FROM vault_messages WHERE message_id = 't'",
            )
            .getSingle();
        expect(raw.data['content'], isNull);
      },
    );

    test('deleteConversation, with and without a time bound', () async {
      await vault.transaction((tx) async {
        for (var i = 1; i <= 5; i++) {
          await tx.putMessage(_msg('m$i', at: i * 10));
        }
        await tx.putMessage(_msg('other', conversation: 'c2', at: 10));
        await tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 1,
            epoch: 1,
            state: _b('g'),
            pendingCommit: false,
          ),
        );
      });
      await vault.transaction(
        (tx) => tx.deleteConversation('c1', upToCreatedAtMicros: 30),
      );
      expect((await vault.messages('c1')).map((m) => m.messageId), [
        'm5',
        'm4',
      ]);
      await vault.transaction((tx) => tx.deleteConversation('c1'));
      expect(await vault.messages('c1'), isEmpty);
      expect(await vault.hasMessage('c2', 'other'), isTrue);
      expect(await vault.group('c1'), isNotNull);
    });

    test('deleteConversation bounds: inclusive, below zero deletes nothing, '
        'the largest int deletes everything', () async {
      // Web numbers stop at 2^53; the VM goes to 2^63 - 1.
      const big = 9007199254740991;
      await vault.transaction((tx) async {
        await tx.putMessage(_msg('zero', at: 0));
        await tx.putMessage(_msg('a', at: 29));
        await tx.putMessage(_msg('b', at: 30));
        await tx.putMessage(_msg('c', at: 31));
        await tx.putMessage(_msg('big', at: big));
      });
      Future<List<String>> ids() async =>
          (await vault.messages('c1')).map((m) => m.messageId).toList();
      await vault.transaction(
        (tx) => tx.deleteConversation('c1', upToCreatedAtMicros: -1),
      );
      expect(await ids(), ['big', 'c', 'b', 'a', 'zero']);
      await vault.transaction(
        (tx) => tx.deleteConversation('c1', upToCreatedAtMicros: 30),
      );
      expect(await ids(), ['big', 'c']);
      await vault.transaction(
        (tx) => tx.deleteConversation('c1', upToCreatedAtMicros: big - 1),
      );
      expect(await ids(), ['big']);
      // The VM's int max (2^63 - 1); adding 1 would wrap negative.
      await vault.transaction(
        (tx) => tx.deleteConversation(
          'c1',
          upToCreatedAtMicros: 9223372036854775807,
        ),
      );
      expect(await ids(), isEmpty);
    });

    test('wipe scrubs the file: no id, uid or sealed byte survives in it, '
        'and no free pages remain', () async {
      final path = newPath();
      final fileDatabase = fileDb(path);
      final fileCipher = FakeVaultCipher();
      final fileVault = await open(fileDatabase, fileCipher, uid: 'OWNERUID');
      await fileVault.transaction((tx) async {
        for (var i = 0; i < 200; i++) {
          await tx.putMessage(_msg('CLEARID$i', conversation: 'CONVID', at: i));
        }
        await tx.putSetting('SETTINGKEY', _b('v'));
      });
      await fileVault.wipe();
      expect(fileCipher.destroyCalls, 1);
      final bytes = latin1.decode(File(path).readAsBytesSync());
      for (final marker in ['CLEARID', 'CONVID', 'OWNERUID', 'SETTINGKEY']) {
        expect(bytes, isNot(contains(marker)), reason: marker);
      }
      final check = fileDb(path);
      addTearDown(check.close);
      final free = await check
          .customSelect('PRAGMA freelist_count')
          .getSingle();
      expect(free.data.values.single, 0);
    });

    test('a wipe in progress refuses new calls and transactions; a failed '
        'wipe lets them through again', () async {
      await vault.transaction((tx) => tx.putSetting('a', _b('1')));
      final wiping = vault.wipe();
      await expectLater(
        vault.transaction((tx) => tx.putSetting('b', _b('2'))),
        throwsStateError,
      );
      await expectLater(vault.setting('a'), throwsStateError);
      await wiping;
      expect(cipher.destroyCalls, 1);
    });

    test('wipe empties the database, then destroys the cipher', () async {
      await vault.transaction((tx) async {
        await tx.putDevice(_b('id'), _b('state'));
        await tx.putMessage(_msg('m1'));
        await tx.putOutbox(_outbox('k1'));
        await tx.putSetting('a', _b('1'));
      });
      Map<String, int>? atDestroy;
      cipher.onDestroy = () async => atDestroy = await _counts(db);
      await vault.wipe();
      expect(cipher.destroyCalls, 1);
      expect(
        atDestroy!.values.every((c) => c == 0),
        isTrue,
        reason: '$atDestroy',
      );
      expect(() => vault.messages('c1'), throwsStateError);
    });

    test(
      'wipe does not destroy the cipher when the rows cannot be deleted',
      () async {
        await vault.transaction((tx) async {
          await tx.putMessage(_msg('m1'));
          await tx.putSetting('a', _b('1'));
        });
        await db.customStatement(
          'CREATE TRIGGER no_delete BEFORE DELETE ON vault_messages '
          "BEGIN SELECT RAISE(ABORT, 'refused'); END",
        );
        await expectLater(vault.wipe(), throwsA(anything));
        expect(cipher.destroyCalls, 0);
        // One transaction: the setting deleted before the failure is back.
        expect(_s(await vault.setting('a')), '1');
        expect(await vault.hasMessage('c1', 'm1'), isTrue);
        // The wiping flag was cleared: writes work again.
        await vault.transaction((tx) => tx.putSetting('b', _b('2')));
        expect(_s(await vault.setting('b')), '2');
      },
    );

    test('after close every call is a StateError', () async {
      late VaultTx leaked;
      await vault.transaction((tx) async => leaked = tx);
      await vault.close();
      final calls = <Future<Object?> Function()>[
        () => vault.transaction((tx) async => null),
        vault.deviceId,
        vault.deviceState,
        () => vault.group('c1'),
        () => vault.messages('c1'),
        () => vault.message('c1', 'm1'),
        () => vault.hasMessage('c1', 'm1'),
        () => vault.outbox(),
        () => vault.setting('a'),
        vault.wipe,
        () => leaked.putSetting('a', _b('1')),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsStateError);
      }
      expect(cipher.destroyCalls, 0);
      await vault.close();
    });
  });

  group('formulas and printing', () {
    test('row key, seal label, sort key and database name are pinned', () {
      expect(vaultRowKey(['c1', 'm1']), '2:c12:m1');
      expect(vaultRowKey(['vault']), '5:vault');
      expect(vaultRowKey(['a|b', ':']), '3:a|b1::');
      expect(vaultRowKey(['ab', 'c']), isNot(vaultRowKey(['a', 'bc'])));
      expect(
        vaultSealLabel('vault_messages', 'content'),
        'vault_messages.content',
      );
      expect(vaultSortKey(42, 'm1'), '00000000000000000042|m1');
      expect(vaultSortKeyMicros('00000000000000000042|m1'), 42);
      expect(() => vaultSortKey(-1, 'm'), throwsArgumentError);
      expect(vaultDatabaseName('user-1'), startsWith('dzeroth_vault_'));
      expect(
        vaultDatabaseName('user-1'),
        'dzeroth_vault_${vaultKeyAlias('user-1').substring(14)}',
      );
      expect(vaultDatabaseName('user-1'), hasLength(14 + 32));
      expect(vaultDatabaseName('user-1'), isNot(contains('user')));
      expect(vaultDatabaseName('user-1'), isNot(vaultDatabaseName('user-2')));
    });

    test('records and errors print ids only', () {
      final printed = [
        _msg('m1', text: 'SECRET'),
        _outbox('k1'),
        GroupRecord(
          conversationId: 'c1',
          generation: 1,
          epoch: 1,
          state: _b('SECRET'),
          pendingCommit: false,
        ),
        const VaultOpenException(VaultStatus.keyLost),
        const VaultCorruptException('vault_groups'),
      ].map((o) => o.toString()).toList();
      expect(printed, [
        'StoredMessage(c1, m1)',
        'OutboxItem(k1)',
        'GroupRecord(c1)',
        'VaultOpenException(keyLost)',
        'VaultCorruptException(vault_groups)',
      ]);
    });
  });
}
