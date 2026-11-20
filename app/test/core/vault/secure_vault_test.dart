import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart'
    show MessageCheck;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_cipher.dart';

const _uid = 'user-1';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(Uint8List? b) => b == null ? '<null>' : utf8.decode(b);

PendingCommit _pending() => PendingCommit(
  kind: PendingKind.change,
  builtOn: const MlsPair(5, 8),
  commit: _b('commit bytes'),
);

StoredMessage _msg(
  String id, {
  String conversation = 'c1',
  int at = 1000,
  String? text,
  String state = StoredMessageState.visible,
  bool mine = false,
}) => StoredMessage(
  conversationId: conversation,
  messageId: id,
  createdAtMicros: at,
  mine: mine,
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
      localId: key,
      expectedMessageId: expectedMessageId(_uid, key),
      conversationId: conversation,
      recipientUserId: conversation == null ? 'recipient-user-9' : null,
      generation: 3,
      epoch: 4,
      ciphertext: _b('wire ciphertext $key'),
      reportCommitment: Uint8List.fromList(List.filled(32, 7)),
      content: _b('outbox plaintext $key'),
      createdAtMicros: at,
      attempts: 2,
      lastError: 'network down $key',
    );

/// A pair that skips [MlsPair]'s asserts (they are off in release builds),
/// to prove the vault's own range checks.
class _RawPair implements MlsPair {
  _RawPair(this.generation, this.epoch);

  @override
  final int generation;
  @override
  final int epoch;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _count(VaultDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

/// Every table `seed` writes holds exactly one row. The legacy v1
/// `vault_groups` is never written by version 2, so it holds none.
bool _seededOnce(Map<String, int> counts) => counts.entries.every(
  (e) => e.key == 'vault_groups' ? e.value == 0 : e.value == 1,
);

Future<Map<String, int>> _counts(VaultDatabase db) async => {
  for (final t in [
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
        ),
      );
      await tx.putMessage(_msg('m1'));
      await tx.putOutbox(_outbox('k1'));
      await tx.putSetting('s', _b('setting'));
      await tx.setAfterPair('c1', const MlsPair(1, 1));
      await tx.putMember(
        MemberRecord(
          conversationId: 'c1',
          deviceId: _b('dev'),
          signatureKey: _b('sig'),
          side: MemberSide.theirs,
          since: const MlsPair(1, 1),
        ),
      );
      await tx.addSent('c1', const MlsPair(1, 1), 'a' * 64);
    });
    await vault.close();
  }

  test('close() closes the cipher and does not destroy it', () async {
    final cipher = FakeVaultCipher();
    final vault = await open(fileDb(newPath()), cipher);
    await vault.close();
    expect(cipher.closeCalls, 1);
    expect(cipher.closed, isTrue);
    expect(cipher.destroyCalls, 0);
    await vault.close(); // idempotent
    expect(cipher.closeCalls, 1);
    await expectLater(
      cipher.seal('t', 'r', _b('x')),
      throwsStateError,
      reason: 'the closed cipher refuses new calls',
    );
  });

  group('open and the sentinel', () {
    test('createdThisOpen is true only for the open that wrote the '
        'sentinel; storageName is what the opener passed', () async {
      final path = newPath();
      final cipher = FakeVaultCipher();
      final first = await openVaultOnDatabase(
        fileDb(path),
        uid: _uid,
        cipher: cipher,
        storageName: 'opfsLocks',
      );
      expect(first.createdThisOpen, isTrue);
      expect(first.storageName, 'opfsLocks');
      await first.close();
      // A closed cipher refuses new calls: each open gets a new one on the
      // same key, as a restart does.
      final again = await open(fileDb(path), FakeVaultCipher());
      expect(again.createdThisOpen, isFalse);
      expect(again.storageName, 'native', reason: 'the default');
      await again.close();
      // A vault with rows, reopened: not created either.
      final seeded = newPath();
      await seed(seeded, FakeVaultCipher());
      final reopened = await open(fileDb(seeded), FakeVaultCipher());
      expect(reopened.createdThisOpen, isFalse);
      await reopened.close();
    });

    test('a new vault stamps the owner and writes a sealed sentinel', () async {
      final db = fileDb(newPath());
      final cipher = FakeVaultCipher(freshlyCreated: true);
      final vault = await open(db, cipher);
      addTearDown(vault.close);

      final rows = await db.select(db.vaultMeta).get();
      expect(rows, hasLength(1));
      expect(rows.single.metaKey, 'vault');
      expect(rows.single.ownerUid, _uid);
      expect(rows.single.schemaVersion, 2, reason: 'a new vault is stamped 2');
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
      expect(_seededOnce(countsBefore), isTrue);
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
      await seed(path, FakeVaultCipher());
      final raw = fileDb(path);
      final other = await FakeVaultCipher().seal(
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
      expect(_seededOnce(await _counts(after)), isTrue);
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
      expect(_seededOnce(await _counts(db)), isTrue);
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
      expect(_seededOnce(await _counts(after)), isTrue);
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
      expect(_seededOnce(await _counts(after)), isTrue);
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
      await raw.customStatement('UPDATE vault_meta SET schema_version = 3');
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
            pending: _pending(),
          ),
        );
        await tx.putMessage(_msg('m1', at: 42, mine: true));
        await tx.putMessage(
          _msg('m2', at: 43, state: StoredMessageState.removed),
        );
        await tx.putOutbox(_outbox('k1', at: 7));
        await tx.putOutbox(_outbox('k2', conversation: null, at: 8));
        await tx.putSetting('pref', _b('value'));
      });

      expect(_s(await vault.deviceId()), 'dev-id');
      expect(_s(await vault.deviceState()), 'dev-state-2');
      final g = (await vault.group('c1', 5))!;
      expect(
        [g.generation, g.epoch, g.hasPending, g.provisional],
        [5, 9007199254740991, true, false],
      );
      expect(_s(g.state), 'mls group state');
      expect(_s(g.pending!.commit), 'commit bytes');
      expect(await vault.group('c2', 5), isNull);
      expect(await vault.group('c1', 6), isNull);

      final m1 = (await vault.message('c1', 'm1'))!;
      expect(m1.createdAtMicros, 42);
      expect(m1.mine, isTrue);
      expect(m1.state, StoredMessageState.visible);
      expect([m1.generation, m1.epoch], [1, 2]);
      expect(_s(m1.content), 'secret text of m1');
      final m2 = (await vault.message('c1', 'm2'))!;
      expect(m2.state, StoredMessageState.removed);
      expect(m2.content, isNull);
      expect(m2.mine, isFalse);

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
      expect(k1.reportCommitment, List.filled(32, 7));
      expect(k1.localId, 'k1');
      expect(k1.expectedMessageId, expectedMessageId(_uid, 'k1'));
      expect(k1.stage, OutboxStage.encrypted);
      expect(k1.init, isNull);
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
        await tx.deleteGroup('c1', 5);
        await tx.deleteOutbox('k1');
      });
      expect(await vault.group('c1', 5), isNull);
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
              pending: _pending(),
            ),
          );
          await tx.putMessage(_msg('m-new'));
          // The writes are visible inside the transaction...
          expect(_s((await vault.group('c1', 1))!.state), 'new state');
          expect(await vault.hasMessage('c1', 'm-new'), isTrue);
          throw StateError('engine failed');
        }),
        throwsStateError,
      );
      // ...and gone after it.
      final g = (await vault.group('c1', 1))!;
      expect(_s(g.state), 'old state');
      expect(g.epoch, 1);
      expect(g.hasPending, isFalse);
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
              pending: PendingCommit(
                kind: PendingKind.change,
                builtOn: const MlsPair(1, 1),
                commit: _b('PLAIN-commit'),
              ),
            ),
          );
          await tx.putMessage(
            StoredMessage(
              conversationId: 'c1',
              messageId: 'm1',
              createdAtMicros: 1000,
              mine: true,
              state: StoredMessageState.visible,
              generation: 1,
              epoch: 2,
              content: _b('PLAIN-message'),
              check: StoredMessageCheck.unverified,
              senderDeviceId: _b('PLAIN-sender'),
            ),
          );
          await tx.putOutbox(
            OutboxItem(
              idempotencyKey: 'k1',
              localId: 'k1',
              expectedMessageId: expectedMessageId(_uid, 'k1'),
              recipientUserId: 'PLAIN-recipient',
              generation: 1,
              epoch: 1,
              ciphertext: _b('PLAIN-ciphertext'),
              reportCommitment: Uint8List(32),
              content: _b('PLAIN-outbox'),
              init: _b('PLAIN-init'),
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
          'vault_group_states': {
            'conversation_id',
            'generation',
            'epoch',
            'provisional',
            'provisional_created_at',
          },
          'vault_messages': {
            'conversation_id',
            'message_id',
            'sort_key',
            'state',
            'generation',
            'epoch',
            'check_state',
            'kind',
            'mine',
          },
          'vault_outbox': {
            'idempotency_key',
            'conversation_id',
            'sort_key',
            'generation',
            'epoch',
            'stage',
            'expected_message_id',
            'local_id',
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
              pending: _pending(),
            ),
          );
          cipher.unavailable = true;
          await tx.putMessage(_msg('m1'));
        }),
        throwsA(isA<VaultKeyException>()),
      );
      cipher.unavailable = false;
      final g = (await vault.group('c1', 1))!;
      expect([_s(g.state), g.epoch, g.hasPending], ['old', 1, false]);
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
            ),
          );
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c2',
              generation: 1,
              epoch: 1,
              state: _b('g2'),
            ),
          );
          await tx.putSetting('a', _b('1'));
          await tx.putSetting('b', _b('2'));
        });
        await db.customStatement(
          'UPDATE vault_device SET device_state = device_id',
        );
        await db.customStatement(
          "UPDATE vault_group_states SET state = (SELECT state FROM vault_group_states WHERE conversation_id = 'c2') "
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
        await expectLater(vault.group('c1', 1), corrupt('vault_group_states'));
        expect(_s((await vault.group('c2', 1))!.state), 'g2');
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
          mine: false,
          state: StoredMessageState.removed,
          generation: 1,
          epoch: 1,
          content: _b('nope'),
        );
        const visibleWithout = StoredMessage(
          conversationId: 'c1',
          messageId: 'y',
          createdAtMicros: 1,
          mine: false,
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
      expect(await vault.group('c1', 1), isNotNull);
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

    test('a transaction in flight when wipe() starts never commits after the '
        'delete', () async {
      final path = newPath();
      final fileDatabase = fileDb(path);
      final fileCipher = FakeVaultCipher();
      final fileVault = await open(fileDatabase, fileCipher);
      await fileVault.transaction((tx) => tx.putSetting('a', _b('1')));

      // Case 1: the body is waiting when wipe() starts; its next write is
      // refused and the transaction rolls back.
      final gate = Completer<void>();
      final entered = Completer<void>();
      final inFlight = fileVault.transaction((tx) async {
        entered.complete();
        await gate.future;
        await tx.putSetting('late', _b('2'));
      });
      await entered.future;
      Map<String, int>? atDestroy;
      fileCipher.onDestroy = () async =>
          atDestroy = await _counts(fileDatabase);
      final wiping = fileVault.wipe();
      gate.complete();
      await expectLater(inFlight, throwsStateError);
      await wiping;
      expect(
        atDestroy!.values.every((c) => c == 0),
        isTrue,
        reason: '$atDestroy',
      );
      final after = fileDb(path);
      addTearDown(after.close);
      expect((await _counts(after)).values.every((c) => c == 0), isTrue);
    });

    test('a transaction that already finished its writes when wipe() starts '
        'commits first, and the wipe then deletes it', () async {
      final path = newPath();
      final fileDatabase = fileDb(path);
      final fileCipher = FakeVaultCipher();
      final fileVault = await open(fileDatabase, fileCipher);
      final wrote = Completer<void>();
      final release = Completer<void>();
      final inFlight = fileVault.transaction((tx) async {
        await tx.putSetting('early', _b('1'));
        wrote.complete();
        await release.future;
      });
      await wrote.future;
      final wiping = fileVault.wipe();
      release.complete();
      await inFlight; // committed before the delete could run
      await wiping;
      final after = fileDb(path);
      addTearDown(after.close);
      expect((await _counts(after)).values.every((c) => c == 0), isTrue);
    });

    test('a corrupt clear sort key: the outbox row is unreadable by key, the '
        'message comes back undecryptable with its stored sort key', () async {
      await vault.transaction((tx) async {
        await tx.putOutbox(_outbox('k1', at: 1));
        await tx.putOutbox(_outbox('k2', at: 2));
        await tx.putMessage(_msg('m1', at: 1));
        await tx.putMessage(_msg('m2', at: 2));
      });
      await db.customStatement(
        "UPDATE vault_outbox SET sort_key = 'garbage' "
        "WHERE idempotency_key = 'k1'",
      );
      await db.customStatement(
        "UPDATE vault_messages SET sort_key = '0000000000000000000x|m1' "
        "WHERE message_id = 'm1'",
      );
      final read = await vault.outbox();
      expect(read.items.map((o) => o.idempotencyKey), ['k2']);
      expect(read.unreadableKeys, ['k1']);
      final page = await vault.messages('c1');
      expect(page.map((m) => m.messageId), ['m1', 'm2']);
      final m1 = page.first;
      expect(m1.state, StoredMessageState.undecryptable);
      expect(m1.content, isNull);
      expect(m1.sortKey, '0000000000000000000x|m1');
      // Paging past it uses the stored key, so nothing after it is skipped.
      final next = await vault.messages(
        'c1',
        limit: 1,
        beforeSortKey: m1.sortKey,
      );
      expect(next.map((m) => m.messageId), ['m2']);
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
        () => vault.group('c1', 1),
        () => vault.groups('c1'),
        vault.groupConversationIds,
        () => vault.conversation('c1'),
        () => vault.members('c1'),
        () => vault.hasOutboxExpecting('x'),
        () => vault.hasSent('c1', const MlsPair(1, 1), 'a' * 64),
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

  group('schema v2: groups, marks, members, sync and system rows', () {
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

    GroupRecord group(
      int generation, {
      int epoch = 1,
      bool provisional = false,
      String conversation = 'c1',
    }) => GroupRecord(
      conversationId: conversation,
      generation: generation,
      epoch: epoch,
      state: _b('state g$generation e$epoch'),
      provisional: provisional,
      provisionalCreatedAtMicros: provisional ? 555 : null,
    );

    Future<Map<String, Object?>> markRow([String conversation = 'c1']) async =>
        (await db
                .customSelect(
                  'SELECT after_generation, after_epoch, join_generation, '
                  'join_epoch FROM vault_conversations '
                  'WHERE conversation_id = ?',
                  variables: [Variable.withString(conversation)],
                )
                .getSingleOrNull())
            ?.data ??
        {};

    test('two generations of one conversation coexist', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1, epoch: 4));
        await tx.putGroup(group(2, epoch: 0));
        await tx.putGroup(group(1, conversation: 'c0'));
      });
      expect(_s((await vault.group('c1', 1))!.state), 'state g1 e4');
      expect(_s((await vault.group('c1', 2))!.state), 'state g2 e0');
      final all = await vault.groups('c1');
      expect(all.map((g) => g.generation), [1, 2]);
      expect(await vault.groupConversationIds(), ['c0', 'c1']);
      // A second write of one generation replaces it.
      await vault.transaction((tx) => tx.putGroup(group(1, epoch: 5)));
      expect((await vault.groups('c1')).map((g) => g.epoch), [5, 0]);
      expect(await _count(db, 'vault_group_states'), 3);
    });

    test('deleteGroup removes one generation only', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.putGroup(group(2));
        await tx.putGroup(group(1, conversation: 'c2'));
      });
      await vault.transaction((tx) => tx.deleteGroup('c1', 1));
      expect(await vault.group('c1', 1), isNull);
      expect(await vault.group('c1', 2), isNotNull);
      expect(await vault.group('c2', 1), isNotNull);
      expect(await vault.groupConversationIds(), ['c1', 'c2']);
    });

    test('putGroup refuses to make a provisional group final', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.putGroup(group(2, provisional: true));
      });
      await expectLater(
        vault.transaction((tx) => tx.putGroup(group(2, epoch: 4))),
        throwsStateError,
      );
      final stored = (await vault.group('c1', 2))!;
      expect(stored.provisional, isTrue);
      expect(stored.epoch, 1);
      // No mark can be written for it by that route.
      await expectLater(
        vault.transaction((tx) => tx.setAfterPair('c1', const MlsPair(2, 0))),
        throwsStateError,
      );
    });

    test('putGroup refuses to make a final group provisional', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.setAfterPair('c1', const MlsPair(1, 1));
      });
      await expectLater(
        vault.transaction((tx) => tx.putGroup(group(1, provisional: true))),
        throwsStateError,
      );
      expect((await vault.group('c1', 1))!.provisional, isFalse);
      // A final group can be re-saved as final.
      await vault.transaction((tx) => tx.putGroup(group(1, epoch: 3)));
      expect((await vault.group('c1', 1))!.epoch, 3);
    });

    test('a provisional group can be re-saved as provisional', () async {
      await vault.transaction((tx) => tx.putGroup(group(2, provisional: true)));
      await vault.transaction(
        (tx) => tx.putGroup(group(2, epoch: 6, provisional: true)),
      );
      final stored = (await vault.group('c1', 2))!;
      expect(stored.provisional, isTrue);
      expect(stored.epoch, 6);
      expect(stored.provisionalCreatedAtMicros, 555);
      // Still provisional: no mark is accepted.
      await expectLater(
        vault.transaction(
          (tx) => tx.setJoinHighWater('c1', const MlsPair(2, 0)),
        ),
        throwsStateError,
      );
    });

    test('putGroup refuses a pending commit outside the limits', () async {
      PendingCommit pending({int commit = 10, int? welcome, int ids = 0}) =>
          PendingCommit(
            kind: PendingKind.change,
            builtOn: const MlsPair(1, 1),
            commit: Uint8List(commit),
            welcome: welcome == null ? null : Uint8List(welcome),
            welcomeDeviceIds: [for (var i = 0; i < ids; i++) 'd$i'],
          );
      final refused = <String, PendingCommit>{
        'empty commit': pending(commit: 0),
        'commit over 16384': pending(commit: 16385),
        'empty welcome': pending(welcome: 0, ids: 1),
        'welcome over 65536': pending(welcome: 65537, ids: 1),
        'welcome without ids': pending(welcome: 5),
        'more than 10 ids': pending(welcome: 5, ids: 11),
        'ids without a welcome': pending(ids: 1),
      };
      for (final e in refused.entries) {
        await expectLater(
          vault.transaction(
            (tx) => tx.putGroup(
              GroupRecord(
                conversationId: 'c1',
                generation: 1,
                epoch: 1,
                state: _b('x'),
                pending: e.value,
              ),
            ),
          ),
          throwsArgumentError,
          reason: e.key,
        );
      }
      expect(await _count(db, 'vault_group_states'), 0);
      // The edges are accepted.
      final accepted = [
        pending(commit: 1),
        pending(commit: 16384),
        pending(welcome: 1, ids: 1),
        pending(welcome: 65536, ids: 10),
      ];
      for (var i = 0; i < accepted.length; i++) {
        await vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: i,
              epoch: 1,
              state: _b('x'),
              pending: accepted[i],
            ),
          ),
        );
      }
      final big = (await vault.group('c1', 3))!.pending!;
      expect(big.welcome!.length, 65536);
      expect(big.welcomeDeviceIds, hasLength(10));
    });

    test('putGroup refuses a pending builtOn out of range and '
        'putConversationSync refuses integers the decoder would refuse; '
        'nothing is stored', () async {
      await expectLater(
        vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 1,
              state: _b('x'),
              pending: PendingCommit(
                kind: PendingKind.change,
                builtOn: _RawPair(-1, 0),
                commit: Uint8List(1),
              ),
            ),
          ),
        ),
        throwsArgumentError,
      );
      expect(await _count(db, 'vault_group_states'), 0);
      final refused = <String, ConversationSync>{
        'negative commitCallsToday': const ConversationSync(
          commitCallsToday: -1,
        ),
        'micros above 2^53 - 1': const ConversationSync(
          lastSelfUpdateAtMicros: kMaxPairComponent + 1,
        ),
        'a completed epoch out of range': ConversationSync(
          completedEpochs: [_RawPair(0, kMaxPairComponent + 1)],
        ),
      };
      for (final e in refused.entries) {
        await expectLater(
          vault.transaction((tx) => tx.putConversationSync('c1', e.value)),
          throwsArgumentError,
          reason: e.key,
        );
      }
      expect(await vault.conversation('c1'), isNull);
      expect(await _count(db, 'vault_conversations'), 0);
    });

    test('a provisional group writes no mark, and deleting it leaves the '
        'earlier marks', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.setAfterPair('c1', const MlsPair(1, 3));
        await tx.setJoinHighWater('c1', const MlsPair(1, 2));
      });
      final marksBefore = await markRow();
      await vault.transaction((tx) => tx.putGroup(group(2, provisional: true)));
      final provisional = (await vault.group('c1', 2))!;
      expect(provisional.provisional, isTrue);
      expect(provisional.provisionalCreatedAtMicros, 555);
      expect(await markRow(), marksBefore, reason: 'no mark for a provisional');
      await vault.transaction((tx) => tx.deleteGroup('c1', 2));
      expect(await vault.group('c1', 2), isNull);
      expect(await markRow(), marksBefore);
      final record = (await vault.conversation('c1'))!;
      expect(record.afterPair, const MlsPair(1, 3));
      expect(record.joinHighWater, const MlsPair(1, 2));
      // A provisional group needs its creation time.
      await expectLater(
        vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 3,
              epoch: 0,
              state: _b('x'),
              provisional: true,
            ),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('putGroup, deleteGroup and putConversationSync never touch the '
        'marks', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.setAfterPair('c1', const MlsPair(1, 3));
        await tx.setJoinHighWater('c1', const MlsPair(1, 2));
      });
      final before = await markRow();
      await vault.transaction((tx) async {
        await tx.putGroup(group(1, epoch: 9));
        await tx.putConversationSync(
          'c1',
          const ConversationSync(sinceToken: 'abc', commitCallsToday: 2),
        );
        await tx.deleteGroup('c1', 1);
      });
      expect(await markRow(), before);
      final record = (await vault.conversation('c1'))!;
      expect(record.sync.sinceToken, 'abc');
      expect(record.afterPair, const MlsPair(1, 3));
      // The marks do not touch the sync record either.
      await vault.transaction(
        (tx) => tx.setAfterPair('c1', const MlsPair(1, 4)),
      );
      expect((await vault.conversation('c1'))!.sync.sinceToken, 'abc');
    });

    test(
      'clearProvisional writes the marks and clears the flag atomically',
      () async {
        await vault.transaction((tx) async {
          await tx.putGroup(group(1));
          await tx.setAfterPair('c1', const MlsPair(1, 2));
          await tx.putGroup(group(2, provisional: true));
        });
        final marksBefore = await markRow();

        // A throwing transaction leaves both the flag and the marks unchanged.
        await expectLater(
          vault.transaction((tx) async {
            await tx.clearProvisional(
              'c1',
              2,
              afterPair: const MlsPair(2, 0),
              joinHighWater: const MlsPair(2, 0),
            );
            throw StateError('engine failed');
          }),
          throwsStateError,
        );
        expect((await vault.group('c1', 2))!.provisional, isTrue);
        expect(await markRow(), marksBefore);

        await vault.transaction(
          (tx) => tx.clearProvisional(
            'c1',
            2,
            afterPair: const MlsPair(2, 0),
            joinHighWater: const MlsPair(2, 0),
          ),
        );
        final cleared = (await vault.group('c1', 2))!;
        expect(cleared.provisional, isFalse);
        expect(cleared.provisionalCreatedAtMicros, isNull);
        final raw = await db
            .customSelect(
              'SELECT provisional, provisional_created_at FROM '
              "vault_group_states WHERE generation = 2",
            )
            .getSingle();
        expect(raw.data['provisional'], 0);
        expect(raw.data['provisional_created_at'], isNull);
        final record = (await vault.conversation('c1'))!;
        expect(record.afterPair, const MlsPair(2, 0));
        expect(record.joinHighWater, const MlsPair(2, 0));
      },
    );

    test('clearProvisional refuses an absent group, a final group and marks '
        'that would move back, and writes nothing', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.setAfterPair('c1', const MlsPair(1, 5));
        await tx.putGroup(group(2, provisional: true));
      });
      final before = await markRow();
      for (final attempt in <Future<void> Function(VaultTx)>[
        (tx) => tx.clearProvisional('c1', 9, afterPair: const MlsPair(9, 0)),
        (tx) => tx.clearProvisional('c1', 1, afterPair: const MlsPair(9, 0)),
        (tx) => tx.clearProvisional('c1', 2, afterPair: const MlsPair(1, 5)),
        (tx) => tx.clearProvisional('c1', 2, afterPair: const MlsPair(1, 4)),
        (tx) => tx
            .clearProvisional(
              'c1',
              2,
              afterPair: const MlsPair(2, 0),
              joinHighWater: const MlsPair(2, 0),
            )
            .then(
              (_) =>
                  tx.clearProvisional('c1', 2, afterPair: const MlsPair(3, 0)),
            ),
      ]) {
        await expectLater(vault.transaction(attempt), throwsStateError);
      }
      expect((await vault.group('c1', 2))!.provisional, isTrue);
      expect(await markRow(), before);
    });

    test('clearProvisional refuses marks of another generation (ArgumentError) '
        'and writes nothing', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.setAfterPair('c1', const MlsPair(1, 5));
        await tx.putGroup(group(2, provisional: true));
      });
      final before = await markRow();
      for (final attempt in <Future<void> Function(VaultTx)>[
        (tx) => tx.clearProvisional('c1', 2, afterPair: const MlsPair(3, 0)),
        (tx) => tx.clearProvisional(
          'c1',
          2,
          afterPair: const MlsPair(2, 0),
          joinHighWater: const MlsPair(3, 0),
        ),
      ]) {
        await expectLater(vault.transaction(attempt), throwsArgumentError);
      }
      expect((await vault.group('c1', 2))!.provisional, isTrue);
      expect(await markRow(), before);
    });

    test('setAfterPair refuses a provisional generation and a pair not above '
        'the mark', () async {
      await vault.transaction((tx) async {
        await tx.putGroup(group(1));
        await tx.putGroup(group(2, provisional: true));
        await tx.setAfterPair('c1', const MlsPair(1, 3));
        await tx.setJoinHighWater('c1', const MlsPair(1, 3));
      });
      final before = await markRow();
      final refused = <Future<void> Function(VaultTx)>[
        (tx) => tx.setAfterPair('c1', const MlsPair(2, 0)), // provisional
        (tx) => tx.setJoinHighWater('c1', const MlsPair(2, 7)),
        (tx) => tx.setAfterPair('c1', const MlsPair(1, 3)), // not above
        (tx) => tx.setAfterPair('c1', const MlsPair(1, 2)), // back
        (tx) => tx.setAfterPair('c1', const MlsPair(0, 99)),
        (tx) => tx.setJoinHighWater('c1', const MlsPair(1, 3)),
        (tx) => tx.setJoinHighWater('c1', const MlsPair(0, 9)),
      ];
      for (final attempt in refused) {
        await expectLater(vault.transaction(attempt), throwsStateError);
      }
      expect(await markRow(), before);
      // Strictly above is accepted, in either mark.
      await vault.transaction((tx) async {
        await tx.setAfterPair('c1', const MlsPair(1, 4));
        await tx.setJoinHighWater('c1', const MlsPair(1, 9));
      });
      final record = (await vault.conversation('c1'))!;
      expect(record.afterPair, const MlsPair(1, 4));
      expect(record.joinHighWater, const MlsPair(1, 9));
      // The largest component a web number holds exactly is accepted.
      await expectLater(
        vault.transaction(
          (tx) => tx.setAfterPair('c1', const MlsPair(1, kMaxPairComponent)),
        ),
        completes,
      );
    });

    test('MlsPair.above(pair, null) for a conversation with no row', () async {
      expect(await vault.conversation('nope'), isNull);
      expect(MlsPair.above(const MlsPair(0, 0), null), isTrue);
      await vault.transaction((tx) async {
        await tx.putGroup(group(0, conversation: 'fresh', epoch: 0));
        await tx.setAfterPair('fresh', const MlsPair(0, 0));
        await tx.setJoinHighWater('fresh', const MlsPair(0, 0));
      });
      final record = (await vault.conversation('fresh'))!;
      expect(record.afterPair, const MlsPair(0, 0));
      expect(record.joinHighWater, const MlsPair(0, 0));
      expect(record.sync.sinceToken, '');
      // A conversation row made by a sync write has no marks yet.
      await vault.transaction(
        (tx) => tx.putConversationSync('syncOnly', const ConversationSync()),
      );
      final syncOnly = (await vault.conversation('syncOnly'))!;
      expect(syncOnly.afterPair, isNull);
      expect(syncOnly.joinHighWater, isNull);
      expect(MlsPair.above(const MlsPair(0, 0), syncOnly.afterPair), isTrue);
    });

    test('members and conversation sync round-trip and are sealed', () async {
      final deviceA = Uint8List.fromList([0xab, 0x01, 0xff]);
      final deviceB = Uint8List.fromList([0x00, 0x10]);
      final keyA = _b('SIGNATURE-KEY-A');
      const sync = ConversationSync(
        firstSawGeneration: 3,
        sinceToken: 'TOKEN-SECRET',
        commitCallsDay: 'DAY-MARKER',
        commitCallsToday: 4,
        epochMustAdvance: true,
        completedEpochs: [MlsPair(3, 1)],
      );
      await vault.transaction((tx) async {
        await tx.putMember(
          MemberRecord(
            conversationId: 'c1',
            deviceId: deviceA,
            signatureKey: keyA,
            side: MemberSide.mine,
            since: const MlsPair(3, 0),
          ),
        );
        await tx.putMember(
          MemberRecord(
            conversationId: 'c1',
            deviceId: deviceB,
            signatureKey: _b('SIGNATURE-KEY-B'),
            side: MemberSide.unattributed,
            since: const MlsPair(3, 2),
          ),
        );
        await tx.putConversationSync('c1', sync);
      });
      final members = await vault.members('c1');
      expect(members.map((m) => m.deviceId), [
        deviceB,
        deviceA,
      ], reason: 'ascending device id hex: 0010 before ab01ff');
      expect(members.last.signatureKey, keyA);
      expect(members.last.side, MemberSide.mine);
      expect(members.last.since, const MlsPair(3, 0));
      expect(await vault.members('other'), isEmpty);
      final back = (await vault.conversation('c1'))!.sync;
      expect(back.sinceToken, 'TOKEN-SECRET');
      expect(back.commitCallsDay, 'DAY-MARKER');
      expect(back.commitCallsToday, 4);
      expect(back.epochMustAdvance, isTrue);
      expect(back.completedEpochs, [const MlsPair(3, 1)]);

      // Raw rows: the device id is clear lower-case hex, nothing else
      // readable (no key bytes, no token, no day string).
      final raw = await db
          .customSelect('SELECT * FROM vault_members ORDER BY device_id')
          .get();
      expect(raw.map((r) => r.data['device_id']), ['0010', 'ab01ff']);
      final conv = await db
          .customSelect('SELECT * FROM vault_conversations')
          .getSingle();
      for (final row in [...raw, conv]) {
        for (final column in row.data.entries) {
          final value = column.value;
          if (value is Uint8List) {
            final text = latin1.decode(value);
            for (final secret in [
              'SIGNATURE-KEY',
              'TOKEN-SECRET',
              'DAY-MARKER',
              'sinceToken',
            ]) {
              expect(text, isNot(contains(secret)), reason: column.key);
            }
          }
        }
      }
      expect(raw.first.data['signature_key'], isA<Uint8List>());
      expect(conv.data['sync'], isA<Uint8List>());

      await vault.transaction((tx) => tx.deleteMember('c1', deviceA));
      expect((await vault.members('c1')).single.deviceId, deviceB);
      await expectLater(
        vault.transaction(
          (tx) => tx.putMember(
            MemberRecord(
              conversationId: 'c1',
              deviceId: deviceB,
              signatureKey: keyA,
              side: 'bogus',
              since: const MlsPair(1, 1),
            ),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a sync or pending value that does not open or is malformed is '
        'VaultCorruptException', () async {
      await vault.transaction((tx) async {
        await tx.putConversationSync('c1', const ConversationSync());
        await tx.putConversationSync('c2', const ConversationSync());
      });
      await db.customStatement(
        "UPDATE vault_conversations SET sync = (SELECT sync FROM vault_conversations WHERE conversation_id = 'c2') "
        "WHERE conversation_id = 'c1'",
      );
      await expectLater(
        vault.conversation('c1'),
        throwsA(
          isA<VaultCorruptException>().having(
            (e) => e.table,
            'table',
            'vault_conversations',
          ),
        ),
      );
      expect((await vault.conversation('c2'))!.sync.sinceToken, '');
      // Authentic, but not a sync record (another v).
      await vault.transaction((tx) async {
        await tx.putSetting('x', _b('x')); // keep a write path exercised
      });
      final other = await cipher.seal(
        'vault_conversations.sync',
        vaultRowKey(['c3']),
        _b('{"v":2}'),
      );
      await db.customInsert(
        'INSERT INTO vault_conversations (conversation_id, sync) VALUES (?, ?)',
        variables: [Variable.withString('c3'), Variable.withBlob(other)],
      );
      await expectLater(
        vault.conversation('c3'),
        throwsA(isA<VaultCorruptException>()),
      );
    });

    test('an unverified and an undecodable visible message keep their '
        'content', () async {
      StoredMessage message(String id, String check) => StoredMessage(
        conversationId: 'c1',
        messageId: id,
        createdAtMicros: id == 'u' ? 10 : 20,
        mine: false,
        state: StoredMessageState.visible,
        generation: 1,
        epoch: 1,
        content: _b('content of $id'),
        check: check,
        senderDeviceId: _b('sender-$id'),
      );
      await vault.transaction((tx) async {
        await tx.putMessage(message('u', StoredMessageCheck.unverified));
        await tx.putMessage(message('d', StoredMessageCheck.undecodable));
        await tx.putMessage(_msg('ok', at: 30));
      });
      final u = (await vault.message('c1', 'u'))!;
      expect(u.check, StoredMessageCheck.unverified);
      expect(u.state, StoredMessageState.visible);
      expect(_s(u.content), 'content of u');
      expect(_s(u.senderDeviceId), 'sender-u');
      final d = (await vault.message('c1', 'd'))!;
      expect(d.check, StoredMessageCheck.undecodable);
      expect(_s(d.content), 'content of d');
      final ok = (await vault.message('c1', 'ok'))!;
      expect(ok.check, StoredMessageCheck.ok);
      expect(ok.kind, StoredMessageKind.message);
      expect(ok.senderDeviceId, isNull);
      // A non-ok check only on a visible message row.
      for (final bad in [
        StoredMessage(
          conversationId: 'c1',
          messageId: 'b1',
          createdAtMicros: 1,
          mine: false,
          state: StoredMessageState.removed,
          generation: 1,
          epoch: 1,
          content: null,
          check: StoredMessageCheck.unverified,
        ),
        StoredMessage(
          conversationId: 'c1',
          messageId: 'b2',
          createdAtMicros: 1,
          mine: false,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: _b('line'),
          kind: StoredMessageKind.system,
          check: StoredMessageCheck.unverified,
        ),
        StoredMessage(
          conversationId: 'c1',
          messageId: 'b3',
          createdAtMicros: 1,
          mine: false,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: null,
          check: StoredMessageCheck.unverified,
        ),
        StoredMessage(
          conversationId: 'c1',
          messageId: 'b4',
          createdAtMicros: 1,
          mine: false,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: _b('x'),
          check: 'bogus',
        ),
      ]) {
        await expectLater(
          vault.transaction((tx) => tx.putMessage(bad)),
          throwsArgumentError,
          reason: bad.messageId,
        );
      }
      // A tombstone resets the check, so a removed row is never unverified.
      await vault.transaction(
        (tx) => tx.setMessageState('c1', 'u', StoredMessageState.removed),
      );
      final removed = (await vault.message('c1', 'u'))!;
      expect(removed.check, StoredMessageCheck.ok);
      expect(removed.content, isNull);
    });

    test('mine is stored in clear and the legacy sealed from_self always '
        'equals it', () async {
      await vault.transaction((tx) async {
        await tx.putMessage(_msg('a', mine: true));
        await tx.putMessage(_msg('b', at: 2));
      });
      final raw = await db
          .customSelect(
            'SELECT message_id, mine, from_self FROM vault_messages '
            'ORDER BY message_id',
          )
          .get();
      expect(raw.map((r) => r.data['mine']), [1, 0]);
      for (final r in raw) {
        final flag = await cipher.open(
          'vault_messages.from_self',
          vaultRowKey(['c1', r.data['message_id']! as String]),
          r.data['from_self']! as Uint8List,
        );
        expect(flag, [r.data['mine']]);
      }
      expect((await vault.message('c1', 'a'))!.mine, isTrue);
      expect((await vault.message('c1', 'b'))!.mine, isFalse);
    });

    test('a system row round-trips and systemLineId is stable', () async {
      final deviceId = Uint8List.fromList([1, 2, 3, 4]);
      const pair = MlsPair(2, 5);
      final id = systemLineId(
        'c1',
        pair,
        SystemLine.deviceAdded,
        deviceId: deviceId,
      );
      final content = SystemLineContent(
        line: SystemLine.deviceAdded,
        deviceId: deviceId,
        side: MemberSide.theirs,
      );
      StoredMessage row() => StoredMessage(
        conversationId: 'c1',
        messageId: id,
        createdAtMicros: 77,
        mine: false,
        state: StoredMessageState.visible,
        generation: pair.generation,
        epoch: pair.epoch,
        content: content.encode(),
        kind: StoredMessageKind.system,
      );
      await vault.transaction((tx) => tx.putMessage(row()));
      // Re-processing the same event writes the same row.
      expect(
        systemLineId('c1', pair, SystemLine.deviceAdded, deviceId: deviceId),
        id,
      );
      await vault.transaction((tx) => tx.putMessage(row()));
      expect(await _count(db, 'vault_messages'), 1);
      final back = (await vault.message('c1', id))!;
      expect(back.kind, StoredMessageKind.system);
      expect(back.state, StoredMessageState.visible);
      final decoded = SystemLineContent.decode(back.content!)!;
      expect(decoded.line, SystemLine.deviceAdded);
      expect(decoded.deviceId, deviceId);
      expect(decoded.side, MemberSide.theirs);
    });

    test('putOutbox refuses an empty localId or expectedMessageId', () async {
      OutboxItem item({String localId = 'l1', String? expected}) => OutboxItem(
        idempotencyKey: 'k1',
        localId: localId,
        expectedMessageId: expected ?? expectedMessageId(_uid, 'k1'),
        conversationId: 'c1',
        generation: 0,
        epoch: 0,
        ciphertext: Uint8List(0),
        reportCommitment: Uint8List(0),
        content: _b('plain content'),
        createdAtMicros: 5,
        stage: OutboxStage.plain,
      );
      for (final bad in [item(localId: ''), item(expected: '')]) {
        await expectLater(
          vault.transaction((tx) => tx.putOutbox(bad)),
          throwsArgumentError,
        );
      }
      expect(await _count(db, 'vault_outbox'), 0);
    });

    test('putOutbox refuses a plain row with ciphertext and an encrypted row '
        'with a 31-byte commitment', () async {
      OutboxItem item({
        required String stage,
        Uint8List? ciphertext,
        Uint8List? commitment,
        Uint8List? init,
        int generation = 0,
        int epoch = 0,
      }) => OutboxItem(
        idempotencyKey: 'k-$stage',
        localId: 'k-$stage',
        expectedMessageId: expectedMessageId(_uid, 'k-$stage'),
        conversationId: 'c1',
        generation: generation,
        epoch: epoch,
        ciphertext: ciphertext ?? Uint8List(0),
        reportCommitment: commitment ?? Uint8List(0),
        content: _b('plain content'),
        createdAtMicros: 5,
        stage: stage,
        init: init,
      );
      final commitment32 = Uint8List(32);
      final refused = [
        item(stage: OutboxStage.plain, ciphertext: _b('x')),
        item(stage: OutboxStage.plain, commitment: commitment32),
        item(stage: OutboxStage.plain, generation: 1),
        item(stage: OutboxStage.plain, epoch: 1),
        item(stage: OutboxStage.plain, init: _b('init')),
        item(
          stage: OutboxStage.encrypted,
          ciphertext: _b('x'),
          commitment: Uint8List(31),
          generation: 1,
        ),
        item(
          stage: OutboxStage.encrypted,
          commitment: commitment32,
          generation: 1,
        ),
        item(
          stage: OutboxStage.encrypted,
          ciphertext: Uint8List(8193),
          commitment: commitment32,
          generation: 1,
        ),
        item(stage: 'bogus'),
      ];
      for (final bad in refused) {
        await expectLater(
          vault.transaction((tx) => tx.putOutbox(bad)),
          throwsArgumentError,
          reason: '${bad.stage} ${bad.ciphertext.length}',
        );
      }
      expect(await _count(db, 'vault_outbox'), 0);

      // The accepted forms: a plain row, and an encrypted row at both ends
      // of the ciphertext range with an init.
      await vault.transaction((tx) async {
        await tx.putOutbox(item(stage: OutboxStage.plain));
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: 'k-enc',
            localId: 'local-enc',
            expectedMessageId: expectedMessageId(_uid, 'k-enc'),
            recipientUserId: 'ref-as-sent',
            generation: 2,
            epoch: 3,
            ciphertext: Uint8List(8192),
            reportCommitment: commitment32,
            content: _b('c'),
            createdAtMicros: 6,
            init: _b('serialized MlsInit'),
          ),
        );
      });
      final read = await vault.outbox();
      expect(read.unreadableKeys, isEmpty);
      final plain = read.items.first;
      expect(plain.stage, OutboxStage.plain);
      expect(plain.ciphertext, isEmpty);
      expect(plain.reportCommitment, isEmpty);
      expect(plain.init, isNull);
      final enc = read.items.last;
      expect(enc.stage, OutboxStage.encrypted);
      expect(enc.localId, 'local-enc');
      expect(enc.recipientUserId, 'ref-as-sent');
      expect(enc.ciphertext.length, 8192);
      expect(_s(enc.init), 'serialized MlsInit');
    });

    test('hasOutboxExpecting and hasSent read no sealed column', () async {
      final digest = 'ab' * 32;
      await vault.transaction((tx) async {
        await tx.putOutbox(_outbox('k1'));
        await tx.addSent('c1', const MlsPair(1, 2), digest);
      });
      cipher.throwsEverything = true; // any open or seal would throw
      expect(
        await vault.hasOutboxExpecting(expectedMessageId(_uid, 'k1')),
        isTrue,
      );
      expect(
        await vault.hasOutboxExpecting(expectedMessageId(_uid, 'zz')),
        isFalse,
      );
      expect(await vault.hasSent('c1', const MlsPair(1, 2), digest), isTrue);
      expect(await vault.hasSent('c1', const MlsPair(1, 3), digest), isFalse);
      expect(
        await vault.hasSent('c1', const MlsPair(1, 2), 'cd' * 32),
        isFalse,
      );
      expect(await vault.hasSent('c2', const MlsPair(1, 2), digest), isFalse);
      cipher.throwsEverything = false;
      // The digest is 64 lower-case hex.
      for (final bad in ['AB' * 32, 'ab' * 31, 'zz' * 32, '']) {
        await expectLater(
          vault.transaction((tx) => tx.addSent('c1', const MlsPair(1, 2), bad)),
          throwsArgumentError,
        );
      }
    });

    test('clearSentBefore keeps the current pair', () async {
      String d(int i) => i.toRadixString(16).padLeft(64, '0');
      await vault.transaction((tx) async {
        await tx.addSent('c1', const MlsPair(1, 1), d(1));
        await tx.addSent('c1', const MlsPair(1, 2), d(2));
        await tx.addSent('c1', const MlsPair(1, 2), d(3));
        await tx.addSent('c1', const MlsPair(1, 3), d(4));
        await tx.addSent('c1', const MlsPair(2, 0), d(5));
        await tx.addSent('c2', const MlsPair(1, 1), d(6));
      });
      await vault.transaction(
        (tx) => tx.clearSentBefore('c1', const MlsPair(1, 2)),
      );
      expect(await vault.hasSent('c1', const MlsPair(1, 1), d(1)), isFalse);
      expect(await vault.hasSent('c1', const MlsPair(1, 2), d(2)), isTrue);
      expect(await vault.hasSent('c1', const MlsPair(1, 2), d(3)), isTrue);
      expect(await vault.hasSent('c1', const MlsPair(1, 3), d(4)), isTrue);
      expect(await vault.hasSent('c1', const MlsPair(2, 0), d(5)), isTrue);
      expect(await vault.hasSent('c2', const MlsPair(1, 1), d(6)), isTrue);
      await vault.transaction(
        (tx) => tx.clearSentBefore('c1', const MlsPair(2, 0)),
      );
      expect(await vault.hasSent('c1', const MlsPair(1, 3), d(4)), isFalse);
      expect(await vault.hasSent('c1', const MlsPair(2, 0), d(5)), isTrue);
      // The same digest twice is one row.
      await vault.transaction(
        (tx) => tx.addSent('c1', const MlsPair(2, 0), d(5)),
      );
      expect(await _count(db, 'vault_sent'), 2);
    });

    test('a pair above 2^53 - 1 is refused', () async {
      const tooBig = 9007199254740992;
      await expectLater(
        vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: tooBig,
              state: _b('x'),
            ),
          ),
        ),
        throwsArgumentError,
      );
      expect(await _count(db, 'vault_group_states'), 0);
    });

    test('StoredMessageCheck values equal MessageCheck.name', () {
      expect(StoredMessageCheck.ok, MessageCheck.ok.name);
      expect(StoredMessageCheck.unverified, MessageCheck.unverified.name);
      expect(StoredMessageCheck.undecodable, MessageCheck.undecodable.name);
      expect(StoredMessageCheck.all, {
        for (final c in MessageCheck.values) c.name,
      });
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
