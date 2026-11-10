import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/cache_database_open.dart';
import 'package:dzeroth/core/telemetry/crash_payload.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:flutter_test/flutter_test.dart';

/// A path shaped like an Android app directory, with a long digit run: it
/// must never reach a report.
const _diskPath = '/data/user/0/app_12345678/app_flutter/dzeroth.sqlite';

/// Wraps an in-memory "disk" database: fails the open or every write on
/// demand and records whether the database was closed.
class _Disk extends QueryInterceptor {
  _Disk({this.failOpen = false, this.failWrites = false});

  final bool failOpen;
  final bool failWrites;
  bool closed = false;
  int opens = 0;

  Never _fail(String what) =>
      throw FileSystemException('cannot $what', _diskPath);

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    opens++;
    if (failOpen) _fail('open');
    return super.ensureOpen(executor, user);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failWrites) _fail('write');
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failWrites) _fail('write');
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> close(QueryExecutor inner) {
    closed = true;
    return super.close(inner);
  }

  AppDatabase open() =>
      AppDatabase(NativeDatabase.memory().interceptWith(this));
}

void main() {
  final opened = <AppDatabase>[];

  tearDown(() async {
    for (final db in opened) {
      try {
        await db.close();
      } catch (_) {
        // The broken "disk" may fail to close again; nothing to do.
      }
    }
    opened.clear();
  });

  Future<OpenedCacheDatabase> open(_Disk disk, String? uid) async {
    final result = await openCacheDatabase(
      restoredUid: uid,
      openOnDisk: () {
        final db = disk.open();
        opened.add(db);
        return db;
      },
    );
    opened.add(result.database);
    return result;
  }

  List<(Object, StackTrace)> reportsOf(OpenedCacheDatabase result) {
    final reports = <(Object, StackTrace)>[];
    result.reportFallback((e, s) => reports.add((e, s)));
    // Bootstrap calls it once; a second call must still not report again.
    result.reportFallback((e, s) => reports.add((e, s)));
    return reports;
  }

  test(
    'a healthy disk database is used as before: claimed, no report',
    () async {
      final disk = _Disk();
      final result = await open(disk, 'a');

      expect(result.inMemory, isFalse);
      expect(result.failure, isNull);
      expect(await result.database.readSetting(kCacheOwnerKey), 'a');
      expect(disk.closed, isFalse);
      expect(reportsOf(result), isEmpty);
    },
  );

  test('an open that throws: start-up goes on in memory, reported once, '
      'with no path', () async {
    final disk = _Disk(failOpen: true);
    final result = await open(disk, 'a');

    expect(result.inMemory, isTrue);
    expect(disk.closed, isTrue, reason: 'the broken database is closed');
    // The fallback is claimed for the restored uid like the disk would be.
    expect(await result.database.readSetting(kCacheOwnerKey), 'a');

    final reports = reportsOf(result);
    expect(reports, hasLength(1));
    final (error, stack) = reports.single;
    expect(error, isA<CacheDatabaseUnavailable>());
    expect(error.toString(), isNot(contains('/data/')));
    expect(error.toString(), isNot(matches(RegExp(r'\d{6,}'))));
    // What would leave the device: the type only.
    expect(crashPayloadFor(error).toString(), 'CacheDatabaseUnavailable');
    expect(stack, isNot(StackTrace.empty));
  });

  test('a failure inside claimCacheFor (the write) falls back too', () async {
    final disk = _Disk(failWrites: true);
    final result = await open(disk, 'a');

    expect(disk.opens, greaterThan(0), reason: 'the open itself worked');
    expect(result.inMemory, isTrue);
    expect(disk.closed, isTrue);
    expect(await result.database.readSetting(kCacheOwnerKey), 'a');
    expect(reportsOf(result), hasLength(1));
  });

  test(
    'signed out (null uid) on a broken disk: in memory, nothing claimed',
    () async {
      final result = await open(_Disk(failOpen: true), null);

      expect(result.inMemory, isTrue);
      expect(await result.database.readSetting(kCacheOwnerKey), isNull);
    },
  );

  test('a later launch tries the disk again', () async {
    final broken = await open(_Disk(failOpen: true), 'a');
    expect(broken.inMemory, isTrue);

    final next = _Disk();
    final healthy = await open(next, 'a');
    expect(healthy.inMemory, isFalse);
    expect(next.opens, greaterThan(0));
  });

  test(
    'a corrupt file on disk: fallback, and the file is left as it was',
    () async {
      final dir = await Directory.systemTemp.createTemp('dbfallback');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // Windows may still hold the handle for a moment; temp is fine.
        }
      });
      final file = File('${dir.path}${Platform.pathSeparator}dzeroth.sqlite');
      final garbage = List<int>.filled(4096, 0x78);
      await file.writeAsBytes(garbage, flush: true);

      final result = await openCacheDatabase(
        restoredUid: 'a',
        openOnDisk: () => AppDatabase(NativeDatabase(file)),
      );
      opened.add(result.database);

      expect(result.inMemory, isTrue);
      expect(file.existsSync(), isTrue, reason: 'never deleted or renamed');
      expect(await file.readAsBytes(), garbage);
      expect(reportsOf(result), hasLength(1));
    },
  );

  group('the in-memory fallback works for every cache writer', () {
    late AppDatabase db;

    setUp(() async {
      final result = await open(_Disk(failOpen: true), 'a');
      expect(result.inMemory, isTrue);
      db = result.database;
    });

    test('SessionEpoch guards writes as on disk', () async {
      final epoch = db.sessionEpoch.value;
      await db.upsertProfile(
        ProfileCacheEntriesCompanion.insert(
          userId: 'u1',
          handle: 'h1',
          displayName: 'N',
          cachedAt: DateTime.now(),
        ),
        epoch: epoch,
      );
      expect(await db.profileByUserId('u1'), isNotNull);

      db.sessionEpoch.end();
      await db.upsertProfile(
        ProfileCacheEntriesCompanion.insert(
          userId: 'u2',
          handle: 'h2',
          displayName: 'N',
          cachedAt: DateTime.now(),
        ),
        epoch: epoch,
      );
      expect(await db.profileByUserId('u2'), isNull, reason: 'stale epoch');

      // Sign-out on the fallback: claim for another uid wipes it.
      expect(await db.claimCacheFor('b'), isTrue);
      expect(await db.profileByUserId('u1'), isNull);
    });

    test('composer drafts: save, read back, list and claim a send', () async {
      final drafts = DraftsRepository(db);
      addTearDown(drafts.cancelPending);
      final now = DateTime.now().toUtc();
      final draft = ComposerDraft(
        id: 'd1',
        uid: 'a',
        text: 'hello',
        createdAt: now,
        updatedAt: now,
      );

      await drafts.upsert(draft);
      expect((await drafts.read('a', 'd1'))?.text, 'hello');
      expect([for (final d in await drafts.watch('a').first) d.id], ['d1']);

      final claim = await drafts.claimSend(
        draft: draft,
        kind: SendKind.post,
        newKey: () => 'k1',
      );
      expect(claim.key, 'k1');
      expect(claim.reused, isFalse);
    });
  });
}
