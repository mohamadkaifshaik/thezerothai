import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart'
    show
        driftDatabase,
        ExistingDatabase,
        MissingBrowserFeature,
        WasmStorageImplementation,
        WebStorageApi;
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart' show vaultKeyAlias;
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_open_io.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_cipher.dart';

/// Fails `VACUUM` only.
class _FailVacuum extends QueryInterceptor {
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.trim().toUpperCase() == 'VACUUM') {
      throw StateError('vacuum refused');
    }
    return super.runCustom(executor, statement, args);
  }
}

/// Holds `VACUUM` until [gate] completes; completes [reached] when it is hit.
class _StallVacuum extends QueryInterceptor {
  _StallVacuum(this.gate, this.reached);

  final Future<void> gate;
  final Completer<void> reached;

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.trim().toUpperCase() == 'VACUUM') {
      if (!reached.isCompleted) reached.complete();
      await gate;
    }
    return super.runCustom(executor, statement, args);
  }
}

Matcher _throwsStatus(VaultStatus status) => throwsA(
  isA<VaultOpenException>().having((e) => e.status, 'status', status),
);

void main() {
  test('the web storage decision, for every storage drift can choose', () {
    const expected = {
      WasmStorageImplementation.opfsShared: true,
      WasmStorageImplementation.opfsLocks: true,
      WasmStorageImplementation.sharedIndexedDb: true,
      WasmStorageImplementation.unsafeIndexedDb: false,
      WasmStorageImplementation.inMemory: false,
    };
    // A new drift storage fails here until it is classified.
    expect(expected.keys.toSet(), WasmStorageImplementation.values.toSet());
    for (final entry in expected.entries) {
      expect(
        isAcceptedVaultWebStorage(entry.key),
        entry.value,
        reason: '${entry.key}',
      );
    }
    expect(kVaultAcceptedWebStorages, {
      WasmStorageImplementation.opfsShared,
      WasmStorageImplementation.opfsLocks,
      WasmStorageImplementation.sharedIndexedDb,
    });
  });

  group('chooseVaultWebStorage', () {
    const name = 'dzeroth_vault_x';
    const opfsShared = WasmStorageImplementation.opfsShared;
    const opfsLocks = WasmStorageImplementation.opfsLocks;
    const sharedIdb = WasmStorageImplementation.sharedIndexedDb;
    const unsafeIdb = WasmStorageImplementation.unsafeIndexedDb;
    const inMemory = WasmStorageImplementation.inMemory;
    const opfs = WebStorageApi.opfs;
    const idb = WebStorageApi.indexedDb;

    WasmStorageImplementation choose(
      List<WasmStorageImplementation> available,
      List<ExistingDatabase> existing, {
      Set<MissingBrowserFeature> missing = const {},
    }) => chooseVaultWebStorage(
      available: available,
      existing: existing,
      missingFeatures: missing,
      name: name,
    );

    test('an untrusted probe (a worker failed) is refused, whatever it '
        'listed', () {
      const workerError = {MissingBrowserFeature.workerError};
      for (final existing in <List<ExistingDatabase>>[
        [],
        [(idb, name)],
        [(opfs, name)],
      ]) {
        expect(
          () => choose(
            [inMemory, opfsLocks, sharedIdb],
            existing,
            missing: workerError,
          ),
          _throwsStatus(VaultStatus.unavailable),
          reason: '$existing',
        );
      }
      for (final feature in MissingBrowserFeature.values) {
        expect(
          isTrustedVaultWebProbe({feature}),
          feature != MissingBrowserFeature.workerError,
          reason: '$feature',
        );
      }
      expect(isTrustedVaultWebProbe({}), isTrue);
      // Only workerError is refused. Other missing features are not
      // refused here, but they can still hide an existing copy (see
      // isTrustedVaultWebProbe); the storage-marker task covers them.
      expect(
        choose(
          [inMemory, sharedIdb],
          [],
          missing: {
            MissingBrowserFeature.sharedArrayBuffers,
            MissingBrowserFeature.dedicatedWorkersInSharedWorkers,
          },
        ),
        sharedIdb,
      );
    });

    test('explicit cases', () {
      // Nothing stored yet: the best accepted storage.
      expect(
        choose([inMemory, opfsShared, opfsLocks, sharedIdb], []),
        opfsShared,
      );
      expect(choose([inMemory, sharedIdb, unsafeIdb], []), sharedIdb);
      expect(choose([unsafeIdb, inMemory, opfsLocks], []), opfsLocks);
      expect(
        () => choose([inMemory, unsafeIdb], []),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(
        () => choose([inMemory], []),
        _throwsStatus(VaultStatus.unavailable),
      );
      // Stored where it is still reachable: stay there (as drift does).
      expect(
        choose([inMemory, opfsLocks, sharedIdb], [(idb, name)]),
        sharedIdb,
      );
      expect(
        choose([inMemory, opfsLocks, sharedIdb], [(opfs, name)]),
        opfsLocks,
      );
      // Stored in IndexedDB, only the unsafe one reachable: refused, and
      // never moved to OPFS (that would show an empty vault).
      expect(
        () => choose([inMemory, opfsLocks, unsafeIdb], [(idb, name)]),
        _throwsStatus(VaultStatus.unavailable),
      );
      // Stored in OPFS, OPFS gone (e.g. no cross-origin isolation now).
      expect(
        () => choose([inMemory, sharedIdb, unsafeIdb], [(opfs, name)]),
        _throwsStatus(VaultStatus.storageChanged),
      );
      expect(
        () => choose([inMemory], [(opfs, name)]),
        _throwsStatus(VaultStatus.storageChanged),
      );
      // Copies in both storages: whichever is chosen hides the other.
      expect(
        () => choose(
          [inMemory, opfsLocks, sharedIdb],
          [(opfs, name), (idb, name)],
        ),
        _throwsStatus(VaultStatus.storageChanged),
      );
      // Other databases (the cache, other users) do not matter.
      expect(
        choose([inMemory, sharedIdb], [(opfs, 'dzeroth'), (opfs, 'other')]),
        sharedIdb,
      );
    });

    test('every combination of available storages and existing databases', () {
      const optional = [opfsShared, opfsLocks, sharedIdb, unsafeIdb];
      const candidates = <ExistingDatabase>[
        (opfs, name),
        (idb, name),
        (opfs, 'other'),
        (idb, 'other'),
      ];
      List<List<T>> subsets<T>(List<T> items) => [
        for (var mask = 0; mask < 1 << items.length; mask++)
          [
            for (var i = 0; i < items.length; i++)
              if (mask & (1 << i) != 0) items[i],
          ],
      ];
      var cases = 0;
      for (final extra in subsets(optional)) {
        // drift always lists inMemory; order must not matter.
        final available = [...extra.reversed, inMemory];
        final best = ([...available]..sort((a, b) => a.index - b.index)).first;
        for (final existing in subsets(candidates)) {
          cases++;
          final mine = {
            for (final e in existing)
              if (e.$2 == name) e.$1,
          };
          final reason = '$available / $existing';
          WasmStorageImplementation? chosen;
          VaultStatus? refused;
          try {
            chosen = choose(available, existing);
          } on VaultOpenException catch (e) {
            refused = e.status;
          }
          // The same inputs from a probe with a failed worker: refused.
          expect(
            () => choose(
              available,
              existing,
              missing: {MissingBrowserFeature.workerError},
            ),
            _throwsStatus(VaultStatus.unavailable),
            reason: reason,
          );
          if (chosen != null) {
            expect(isAcceptedVaultWebStorage(chosen), isTrue, reason: reason);
            expect(available, contains(chosen), reason: reason);
            expect(
              mine.every((api) => api == chosen!.storageApi),
              isTrue,
              reason: reason,
            );
            if (mine.isEmpty) {
              expect(chosen, best, reason: reason);
            } else {
              // The best available storage of the existing database's API.
              final sameApi = [
                for (final s in available)
                  if (s.storageApi == mine.single) s,
              ]..sort((a, b) => a.index - b.index);
              expect(chosen, sameApi.first, reason: reason);
            }
          } else {
            expect(refused, isNot(VaultStatus.keyLost), reason: reason);
            expect(
              refused,
              anyOf(VaultStatus.unavailable, VaultStatus.storageChanged),
              reason: reason,
            );
            if (mine.isEmpty) {
              expect(refused, VaultStatus.unavailable, reason: reason);
              expect(isAcceptedVaultWebStorage(best), isFalse, reason: reason);
            }
            if (refused == VaultStatus.storageChanged) {
              expect(mine, isNotEmpty, reason: reason);
            }
          }
        }
      }
      expect(cases, 256);
    });

    test('with a storage marker: refused (storageChanged) before anything '
        'is created when the marked copy is not listed or would not be '
        'chosen', () {
      WasmStorageImplementation chooseMarked(
        List<WasmStorageImplementation> available,
        List<ExistingDatabase> existing,
        String expected, {
        Set<MissingBrowserFeature> missing = const {},
      }) => chooseVaultWebStorage(
        available: available,
        existing: existing,
        missingFeatures: missing,
        name: name,
        expectedStorage: expected,
      );
      // Marked and listed where it would be chosen: opens as before.
      expect(
        chooseMarked([inMemory, sharedIdb], [(idb, name)], 'sharedIndexedDb'),
        sharedIdb,
      );
      // Same OPFS file, another access method: same API, accepted.
      expect(
        chooseMarked([inMemory, opfsLocks], [(opfs, name)], 'opfsShared'),
        opfsLocks,
      );
      // Marked in OPFS, the probe lists nothing (a hidden copy): without
      // the marker a new vault would be created; with it, refused.
      expect(
        choose([inMemory, sharedIdb], []),
        sharedIdb,
        reason: 'the gap the marker closes',
      );
      expect(
        () => chooseMarked([inMemory, sharedIdb], [], 'opfsLocks'),
        _throwsStatus(VaultStatus.storageChanged),
      );
      expect(
        () => chooseMarked([inMemory, opfsLocks, sharedIdb], [], 'opfsLocks'),
        _throwsStatus(VaultStatus.storageChanged),
      );
      // Marked in IndexedDB, listed only in OPFS (a stray copy).
      expect(
        () => chooseMarked(
          [inMemory, opfsLocks, sharedIdb],
          [(opfs, name)],
          'sharedIndexedDb',
        ),
        _throwsStatus(VaultStatus.storageChanged),
      );
      // Not a web storage name: fail closed.
      for (final bad in ['native', 'inMemory', 'unsafeIndexedDb', '']) {
        expect(
          () => chooseMarked([inMemory, sharedIdb], [(idb, name)], bad),
          _throwsStatus(VaultStatus.unavailable),
          reason: bad,
        );
      }
      // The trust check still comes first.
      expect(
        () => chooseMarked(
          [inMemory, sharedIdb],
          [],
          'opfsLocks',
          missing: {MissingBrowserFeature.workerError},
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
    });

    test('with a storage marker, every combination: a choice is always of '
        'the marked API and of a listed copy; null keeps the plain '
        'decision', () {
      const optional = [opfsShared, opfsLocks, sharedIdb, unsafeIdb];
      const candidates = <ExistingDatabase>[
        (opfs, name),
        (idb, name),
        (opfs, 'other'),
      ];
      const markers = <String?>[
        null,
        'opfsShared',
        'opfsLocks',
        'sharedIndexedDb',
        'native',
      ];
      List<List<T>> subsets<T>(List<T> items) => [
        for (var mask = 0; mask < 1 << items.length; mask++)
          [
            for (var i = 0; i < items.length; i++)
              if (mask & (1 << i) != 0) items[i],
          ],
      ];
      var cases = 0;
      for (final extra in subsets(optional)) {
        final available = [...extra, inMemory];
        for (final existing in subsets(candidates)) {
          WasmStorageImplementation? plain;
          VaultStatus? plainRefused;
          try {
            plain = choose(available, existing);
          } on VaultOpenException catch (e) {
            plainRefused = e.status;
          }
          for (final marker in markers) {
            cases++;
            final reason = '$available / $existing / $marker';
            WasmStorageImplementation? chosen;
            VaultStatus? refused;
            try {
              chosen = chooseVaultWebStorage(
                available: available,
                existing: existing,
                missingFeatures: const {},
                name: name,
                expectedStorage: marker,
              );
            } on VaultOpenException catch (e) {
              refused = e.status;
            }
            expect(refused, isNot(VaultStatus.keyLost), reason: reason);
            if (marker == null) {
              expect(chosen, plain, reason: reason);
              expect(refused, plainRefused, reason: reason);
              continue;
            }
            final api = vaultWebStorageApi(marker);
            if (api == null) {
              expect(refused, VaultStatus.unavailable, reason: reason);
              continue;
            }
            if (chosen != null) {
              // Never a new vault next to a marked one: the marked copy is
              // listed and is the one opened, exactly as without a marker.
              expect(chosen.storageApi, api, reason: reason);
              expect(existing, contains((api, name)), reason: reason);
              expect(chosen, plain, reason: reason);
            } else if (!existing.contains((api, name))) {
              expect(refused, VaultStatus.storageChanged, reason: reason);
            }
          }
        }
      }
      expect(cases, 16 * 8 * markers.length);
    });

    test('the web wipe marker check', () {
      void check(List<ExistingDatabase> existing, String? expected) =>
          checkVaultWipeListed(
            existing: existing,
            name: name,
            expectedStorage: expected,
          );
      // No marker: whatever is listed (or nothing) is fine.
      check([], null);
      check([(opfs, name)], null);
      // Marker and a listed copy under its API: fine.
      check([(opfs, name)], 'opfsLocks');
      check([(opfs, name), (idb, name)], 'sharedIndexedDb');
      // Marker, copy not listed under it: refused, nothing deleted.
      for (final (existing, marker) in <(List<ExistingDatabase>, String)>[
        ([], 'opfsLocks'),
        ([(idb, name)], 'opfsShared'),
        ([(opfs, 'other')], 'opfsShared'),
        ([(opfs, name)], 'native'),
      ]) {
        expect(
          () => check(existing, marker),
          _throwsStatus(VaultStatus.unavailable),
          reason: '$existing / $marker',
        );
      }
    });
  });

  test(
    'anything but Android (native) is unsupported, before drift starts',
    () async {
      expect(
        () => openIoVaultConnection('dzeroth_vault_x', isAndroid: false),
        _throwsStatus(VaultStatus.unsupported),
      );
      // The VM host is not Android.
      await expectLater(
        openVault(uid: 'u1', cipher: FakeVaultCipher()),
        _throwsStatus(VaultStatus.unsupported),
      );
      await expectLater(
        wipeVaultFile(uid: 'u1'),
        _throwsStatus(VaultStatus.unsupported),
      );
    },
  );

  test('alias entry points: the same database name and wipe, by alias '
      'only; a string that is not an alias is refused', () async {
    final alias = vaultKeyAlias('u1');
    expect(vaultDatabaseNameForAlias(alias), vaultDatabaseName('u1'));
    expect(() => vaultDatabaseNameForAlias('u1'), throwsArgumentError);
    await expectLater(wipeVaultFileForAlias(alias: 'u1'), throwsArgumentError);
    // The VM host is not Android.
    await expectLater(
      wipeVaultFileForAlias(alias: alias),
      _throwsStatus(VaultStatus.unsupported),
    );
  });

  group('create false', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vault_nocreate');
      file = File('${dir.path}${Platform.pathSeparator}v.sqlite');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('create false on an empty database writes nothing and is '
        'unavailable', () async {
      final cipher = FakeVaultCipher();
      await expectLater(
        openVaultOnDatabase(
          VaultDatabase.forTesting(NativeDatabase(file)),
          uid: 'u1',
          cipher: cipher,
          create: false,
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(cipher.sealCalls, 0, reason: 'no sentinel sealed');
      final check = VaultDatabase.forTesting(NativeDatabase(file));
      expect(await check.select(check.vaultMeta).get(), isEmpty);
      await check.close();
    });

    test('create false on an existing vault opens it', () async {
      final cipher = FakeVaultCipher();
      final made = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase(file)),
        uid: 'u1',
        cipher: cipher,
      );
      await made.close();
      // Closing the vault closed its cipher: the same key opens again.
      final again = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase(file)),
        uid: 'u1',
        cipher: FakeVaultCipher(),
        create: false,
      );
      expect(again.createdThisOpen, isFalse);
      await again.close();
    });

    test('create false on Android writes nothing and is unavailable; a '
        'zero-byte file is the only trace', () async {
      const name = 'dzeroth_vault_nocreate';
      final db = VaultDatabase(
        driftDatabase(
          name: name,
          native: vaultNativeOptions(
            directory: () async => dir.path,
            tempDirectory: () async => null,
            create: false,
          ),
        ),
      );
      await expectLater(
        openVaultOnDatabase(
          db,
          uid: 'u1',
          cipher: FakeVaultCipher(),
          create: false,
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      // sqlite itself makes the zero-byte file when it opens a missing path
      // (drift_flutter has no open mode that refuses to): the brief's "no
      // file" is NOT met on Android, only "nothing written". No schema, no
      // stamp, no sentinel, no sidecar.
      final left = {
        for (final e in dir.listSync())
          e.uri.pathSegments.last: e is File ? e.lengthSync() : -1,
      };
      expect(left, {'$name.sqlite': 0});
      // The leftover is harmless: a normal (create true) open still starts a
      // vault in it.
      final later = await openVaultOnDatabase(
        VaultDatabase(
          driftDatabase(
            name: name,
            native: vaultNativeOptions(
              directory: () async => dir.path,
              tempDirectory: () async => null,
            ),
          ),
        ),
        uid: 'u1',
        cipher: FakeVaultCipher(),
      );
      expect(later.createdThisOpen, isTrue);
      await later.close();
    });

    test('the web chooser: create false with no listed copy is unavailable; '
        'a copy under another storage than expected stays storageChanged', () {
      WasmStorageImplementation pick({
        required bool create,
        Iterable<ExistingDatabase> existing = const [],
        String? expected,
      }) => chooseVaultWebStorage(
        available: const [
          WasmStorageImplementation.opfsLocks,
          WasmStorageImplementation.sharedIndexedDb,
        ],
        existing: existing,
        missingFeatures: const {},
        name: 'n',
        expectedStorage: expected,
        create: create,
      );
      expect(() => pick(create: false), _throwsStatus(VaultStatus.unavailable));
      expect(
        () => pick(create: false, expected: 'opfsLocks'),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(
        () => pick(
          create: false,
          expected: 'opfsLocks',
          existing: [(WebStorageApi.indexedDb, 'n')],
        ),
        _throwsStatus(VaultStatus.storageChanged),
      );
      expect(
        pick(create: false, existing: [(WebStorageApi.opfs, 'n')]),
        WasmStorageImplementation.opfsLocks,
      );
      // create true is as before: no listed copy picks the best storage.
      expect(pick(create: true), WasmStorageImplementation.opfsLocks);
    });
  });

  test('an empty uid is refused', () async {
    await expectLater(
      openVault(uid: '', cipher: FakeVaultCipher()),
      throwsArgumentError,
    );
    await expectLater(wipeVaultFile(uid: ''), throwsArgumentError);
  });

  test('wipeVaultDatabase deletes every row with a cipher that throws, and '
      'closes the database', () async {
    final dir = Directory.systemTemp.createTempSync('vault_wipe');
    final file = File('${dir.path}${Platform.pathSeparator}v.sqlite');
    final cipher = FakeVaultCipher();
    final vault = await openVaultOnDatabase(
      VaultDatabase.forTesting(NativeDatabase(file)),
      uid: 'u1',
      cipher: cipher,
    );
    await vault.transaction((tx) async {
      await tx.putDevice(Uint8List(3), Uint8List(4));
      await tx.putMessage(
        StoredMessage(
          conversationId: 'c1',
          messageId: 'm1',
          createdAtMicros: 1,
          mine: true,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: Uint8List(5),
        ),
      );
      await tx.putSetting('a', Uint8List(1));
    });
    await vault.close();
    cipher.throwsEverything = true;

    final wiped = VaultDatabase.forTesting(NativeDatabase(file));
    final reportedPath = await wipeVaultDatabase(wiped);
    await expectLater(wiped.customSelect('SELECT 1').get(), throwsA(anything));
    expect(
      File(reportedPath!).absolute.path.toLowerCase(),
      file.absolute.path.toLowerCase(),
    );

    final check = VaultDatabase.forTesting(NativeDatabase(file));
    for (final table in check.vaultTables) {
      expect(
        await check.select(table).get(),
        isEmpty,
        reason: table.actualTableName,
      );
    }
    final free = await check.customSelect('PRAGMA freelist_count').getSingle();
    expect(free.data.values.single, 0);
    await check.close();
    final bytes = String.fromCharCodes(file.readAsBytesSync());
    expect(bytes, isNot(contains('m1')));

    // Then the file itself and its sidecars go.
    for (final suffix in ['-journal', '-wal', '-shm']) {
      File('${file.path}$suffix').writeAsStringSync('x');
    }
    await deleteVaultFilesAt(file.path);
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      expect(File('${file.path}$suffix').existsSync(), isFalse, reason: suffix);
    }
    // Idempotent.
    await deleteVaultFilesAt(file.path);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('wipeVaultDatabase: a failed VACUUM after the rows are gone still '
      'succeeds and reports the file path', () async {
    final dir = Directory.systemTemp.createTempSync('vault_vacuum');
    final file = File('${dir.path}${Platform.pathSeparator}v.sqlite');
    final vault = await openVaultOnDatabase(
      VaultDatabase.forTesting(NativeDatabase(file)),
      uid: 'u1',
      cipher: FakeVaultCipher(),
    );
    await vault.transaction((tx) => tx.putSetting('a', Uint8List(1)));
    await vault.close();

    final noVacuum = VaultDatabase.forTesting(
      NativeDatabase(file).interceptWith(_FailVacuum()),
    );
    final path = await wipeVaultDatabase(noVacuum);
    expect(path, isNotNull);
    final check = VaultDatabase.forTesting(NativeDatabase(file));
    expect(await check.select(check.vaultSettings).get(), isEmpty);
    expect(await check.select(check.vaultMeta).get(), isEmpty);
    await check.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('open-vault registry', () {
    test('wipeVaultFile refuses while that uid\'s vault is open in this '
        'process, and passes once it is closed or wiped', () async {
      final name = vaultDatabaseName('u1');
      final first = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase.memory()),
        uid: 'u1',
        cipher: FakeVaultCipher(),
        registerAs: name,
      );
      // A failure below must not leave the name registered for later tests.
      addTearDown(first.close);
      final second = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase.memory()),
        uid: 'u1',
        cipher: FakeVaultCipher(),
        registerAs: name,
      );
      addTearDown(second.close);
      expect(isVaultOpenInProcess(name), isTrue);
      await expectLater(wipeVaultFile(uid: 'u1'), throwsStateError);
      // Another uid is not affected (on the VM it then reaches the
      // platform, which is unsupported).
      await expectLater(
        wipeVaultFile(uid: 'u2'),
        _throwsStatus(VaultStatus.unsupported),
      );
      await first.close();
      await first.close(); // idempotent: counts once
      expect(isVaultOpenInProcess(name), isTrue);
      await expectLater(wipeVaultFile(uid: 'u1'), throwsStateError);
      await second.wipe();
      expect(isVaultOpenInProcess(name), isFalse);
      await expectLater(
        wipeVaultFile(uid: 'u1'),
        _throwsStatus(VaultStatus.unsupported),
      );
    });

    test('the name stays registered until close() and wipe() have finished: '
        'a wipeVaultFile started without awaiting them is refused', () async {
      final name = vaultDatabaseName('u4');
      final vault = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase.memory()),
        uid: 'u4',
        cipher: FakeVaultCipher(),
        registerAs: name,
      );
      addTearDown(vault.close);
      final closing = vault.close();
      await expectLater(wipeVaultFile(uid: 'u4'), throwsStateError);
      await closing;
      expect(isVaultOpenInProcess(name), isFalse);
      // Past the guard (the VM platform itself is unsupported).
      await expectLater(
        wipeVaultFile(uid: 'u4'),
        _throwsStatus(VaultStatus.unsupported),
      );

      final cipher = FakeVaultCipher();
      final wiped = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase.memory()),
        uid: 'u4',
        cipher: cipher,
        registerAs: name,
      );
      addTearDown(wiped.close);
      var destroyed = false;
      cipher.onDestroy = () async {
        // Still registered while the key is being destroyed.
        expect(isVaultOpenInProcess(name), isTrue);
        destroyed = true;
      };
      final wiping = wiped.wipe();
      await expectLater(wipeVaultFile(uid: 'u4'), throwsStateError);
      await wiping;
      expect(destroyed, isTrue);
      expect(isVaultOpenInProcess(name), isFalse);
    });

    test('a failed open registers nothing', () async {
      final name = vaultDatabaseName('u3');
      await expectLater(
        openVaultOnDatabase(
          VaultDatabase.forTesting(NativeDatabase.memory()),
          uid: 'u3',
          cipher: FakeVaultCipher()..unavailable = true,
          registerAs: name,
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(isVaultOpenInProcess(name), isFalse);
    });
  });

  group('A-I1: an abandoned wipe never resumes into a live vault', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vault_abandon');
      file = File('${dir.path}${Platform.pathSeparator}v.sqlite');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> seed(String uid) async {
      final v = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase(file)),
        uid: uid,
        cipher: FakeVaultCipher(),
      );
      await v.transaction((tx) => tx.putSetting('kept', Uint8List(1)));
      await v.close();
    }

    Future<int> settingsRows() async {
      final check = VaultDatabase.forTesting(NativeDatabase(file));
      final n = (await check.select(check.vaultSettings).get()).length;
      await check.close();
      return n;
    }

    test('stalled in the lazy open: times out, a vault is opened, the wipe '
        'resumes and deletes nothing', () async {
      const uid = 'abandon-open';
      final name = vaultDatabaseName(uid);
      await seed(uid);
      final gate = Completer<void>();
      late Future<String?> inner;
      await expectLater(
        runAbandonableVaultWipe(
          name,
          (stop) => inner = wipeVaultDatabase(
            VaultDatabase.forTesting(
              LazyDatabase(() async {
                await gate.future;
                return NativeDatabase(file);
              }),
            ),
            stop: stop,
            timeout: const Duration(minutes: 5),
          ),
          timeout: const Duration(milliseconds: 50),
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      // The session retries and opens a fresh vault meanwhile.
      final live = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase(file)),
        uid: uid,
        cipher: FakeVaultCipher(),
        registerAs: name,
      );
      addTearDown(live.close);
      gate.complete();
      await expectLater(inner, _throwsStatus(VaultStatus.unavailable));
      expect(await live.setting('kept'), isNotNull);
      await live.close();
      expect(await settingsRows(), 1);
    });

    test('abandoned with NO vault open: the resumed wipe still deletes '
        'nothing (the flag alone stops it)', () async {
      const uid = 'abandon-closed';
      await seed(uid);
      final gate = Completer<void>();
      late Future<String?> inner;
      await expectLater(
        runAbandonableVaultWipe(
          vaultDatabaseName(uid),
          (stop) => inner = wipeVaultDatabase(
            VaultDatabase.forTesting(
              LazyDatabase(() async {
                await gate.future;
                return NativeDatabase(file);
              }),
            ),
            stop: stop,
            timeout: const Duration(minutes: 5),
          ),
          timeout: const Duration(milliseconds: 50),
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      gate.complete();
      await expectLater(inner, _throwsStatus(VaultStatus.unavailable));
      expect(await settingsRows(), 1);
    });

    test('Android path stalled in VACUUM: times out, a vault is opened, the '
        'resumed wipe deletes no file', () async {
      const uid = 'abandon-vacuum';
      final name = vaultDatabaseName(uid);
      await seed(uid);
      final gate = Completer<void>();
      final reached = Completer<void>();
      late Future<void> inner;
      await expectLater(
        runAbandonableVaultWipe(
          name,
          (stop) => inner = wipeIoVaultFile(
            VaultDatabase.forTesting(
              NativeDatabase(file)
                  .interceptWith(_StallVacuum(gate.future, reached)),
            ),
            reportedPath: Future.value(file.path),
            stop: stop,
          ),
          // Long enough to reach VACUUM (where it then stalls).
          timeout: const Duration(seconds: 2),
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(reached.isCompleted, isTrue);
      final live = await openVaultOnDatabase(
        VaultDatabase.forTesting(NativeDatabase(file)),
        uid: uid,
        cipher: FakeVaultCipher(),
        registerAs: name,
      );
      addTearDown(live.close);
      gate.complete();
      await expectLater(inner, _throwsStatus(VaultStatus.unavailable));
      expect(file.existsSync(), isTrue);
      await live.close();
    });

    test('a wipe that finished normally is not affected', () async {
      const uid = 'abandon-none';
      await seed(uid);
      await runAbandonableVaultWipe(
        vaultDatabaseName(uid),
        (stop) => wipeIoVaultFile(
          VaultDatabase.forTesting(NativeDatabase(file)),
          reportedPath: Future.value(null),
          stop: stop,
        ),
      );
      expect(file.existsSync(), isFalse);
    });
  });

  group('A-M1: the Android wipe of a file that is not a database', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('vault_garbage'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<(VaultDatabase, Future<String?>, ReceivePort)> openGarbage(
      String name,
    ) async {
      final file = File('${dir.path}${Platform.pathSeparator}$name.sqlite')
        ..writeAsStringSync('not a database, ' * 400);
      for (final s in ['-journal', '-wal']) {
        File('${file.path}$s').writeAsStringSync('x');
      }
      final port = ReceivePort();
      final reported = port.first.then<String?>(
        (p) => p is String ? p : null,
        onError: (Object _) => null,
      );
      // drift_flutter's real native path, on a test directory.
      final db = VaultDatabase(
        driftDatabase(
          name: name,
          native: vaultNativeOptions(
            reportPath: port.sendPort,
            directory: () async => dir.path,
            tempDirectory: () async => null,
          ),
        ),
      );
      return (db, reported, port);
    }

    test('the rows cannot be deleted, so the reported file is deleted and '
        'the wipe succeeds', () async {
      const name = 'dzeroth_vault_garbage1';
      final (db, reported, port) = await openGarbage(name);
      addTearDown(port.close);
      await wipeIoVaultFile(db, reportedPath: reported, stop: () => false);
      for (final s in ['', '-journal', '-wal', '-shm']) {
        expect(
          File('${dir.path}${Platform.pathSeparator}$name.sqlite$s')
              .existsSync(),
          isFalse,
          reason: s,
        );
      }
    });

    test('stopped (abandoned, or the vault is open again): no file is '
        'deleted', () async {
      const name = 'dzeroth_vault_garbage2';
      final (db, reported, port) = await openGarbage(name);
      addTearDown(port.close);
      await expectLater(
        wipeIoVaultFile(db, reportedPath: reported, stop: () => true),
        _throwsStatus(VaultStatus.unavailable),
      );
      expect(
        File('${dir.path}${Platform.pathSeparator}$name.sqlite').existsSync(),
        isTrue,
      );
    });

    test('no path reported (the open failed before sqlite opened a file): '
        'unavailable', () async {
      final db = VaultDatabase.forTesting(
        LazyDatabase(() async => throw StateError('no storage')),
      );
      await expectLater(
        wipeIoVaultFile(
          db,
          reportedPath: Future.value(null),
          stop: () => false,
        ),
        _throwsStatus(VaultStatus.unavailable),
      );
    });
  });

  test('wipeVaultDatabase on a failing storage is unavailable', () async {
    final db = VaultDatabase.forTesting(
      LazyDatabase(() async => throw StateError('no storage')),
    );
    await expectLater(
      wipeVaultDatabase(db),
      _throwsStatus(VaultStatus.unavailable),
    );
  });
}
