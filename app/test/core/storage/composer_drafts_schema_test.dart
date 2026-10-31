import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:flutter_test/flutter_test.dart';

// Relative to the real clock, whole seconds (the column stores seconds).
final kBase = DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
);

void main() {
  test(
    'migrates a v8 database to v9, keeping rows and adding drafts',
    () async {
      // The tables a v8 database has that this test reads, with rows to keep.
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
          CREATE TABLE app_setting_entries (
            setting_key TEXT NOT NULL, setting_value TEXT NOT NULL,
            PRIMARY KEY (setting_key)
          )''');
          raw.execute(
            "INSERT INTO app_setting_entries VALUES ('theme', 'dark')",
          );
          raw.execute('''
          CREATE TABLE messaging_state_entries (
            state_key TEXT NOT NULL,
            since_token TEXT NOT NULL DEFAULT '',
            older_page_token TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL,
            request_count INTEGER,
            PRIMARY KEY (state_key)
          )''');
          raw.execute(
            "INSERT INTO messaging_state_entries VALUES ('inbox','s','o',0,3)",
          );
          raw.execute('PRAGMA user_version = 8');
        },
      );
      final db = AppDatabase.forTesting(executor);
      addTearDown(db.close);

      expect(await db.readSetting('theme'), 'dark');
      final state = await db
          .customSelect('SELECT request_count FROM messaging_state_entries')
          .getSingle();
      expect(state.read<int>('request_count'), 3);

      final repo = DraftsRepository(db);
      await repo.upsert(
        ComposerDraft(
          id: 'a',
          uid: 'u1',
          text: 'kept',
          createdAt: kBase,
          updatedAt: kBase,
        ),
      );
      expect((await repo.read('u1', 'a'))!.text, 'kept');
    },
  );

  test('migrates a v9 database to v10, keeping drafts and adding the send '
      'columns (null)', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        // The v9 shape of the table, with two rows to keep.
        raw.execute('''
          CREATE TABLE composer_draft_entries (
            draft_id TEXT NOT NULL, uid TEXT NOT NULL,
            draft_text TEXT NOT NULL,
            poll_json TEXT NOT NULL DEFAULT '',
            reply_policy TEXT NOT NULL DEFAULT 'everyone',
            paid_partnership INTEGER NOT NULL DEFAULT 0,
            made_with_ai INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            PRIMARY KEY (draft_id)
          )''');
        final s = kBase.millisecondsSinceEpoch ~/ 1000;
        raw.execute(
          "INSERT INTO composer_draft_entries (draft_id, uid, draft_text, "
          "created_at, updated_at) VALUES ('a', 'u1', 'kept one', $s, $s), "
          "('b', 'u2', 'kept two', $s, $s)",
        );
        raw.execute('PRAGMA user_version = 9');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    final rows = await db.select(db.composerDraftEntries).get();
    expect(rows.map((r) => r.draftText).toSet(), {'kept one', 'kept two'});
    for (final r in rows) {
      expect(r.sendKey, isNull);
      expect(r.sendKind, isNull);
      expect(r.sendPublishAt, isNull);
      expect(r.sendStartedAt, isNull);
      expect(r.updatedAt.millisecondsSinceEpoch, kBase.millisecondsSinceEpoch);
    }

    // The new columns work on a migrated row, and the 30 day clock is kept.
    final repo = DraftsRepository(db);
    final claim = await repo.claimSend(
      draft: (await repo.read('u1', 'a'))!,
      kind: SendKind.post,
      newKey: () => 'k1',
    );
    expect(claim.key, 'k1');
    final after = await (db.select(
      db.composerDraftEntries,
    )..where((t) => t.draftId.equals('a'))).getSingle();
    expect(after.sendKey, 'k1');
    expect(
      after.updatedAt.millisecondsSinceEpoch,
      kBase.millisecondsSinceEpoch,
    );
  });

  test(
    'a v8 database reaches v10 with the columns once (no duplicate)',
    () async {
      final executor = NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA user_version = 8'),
      );
      final db = AppDatabase.forTesting(executor);
      addTearDown(db.close);
      // The v8 -> v9 step creates the table with the v10 columns; the v9 -> v10
      // step must not add them a second time.
      final repo = DraftsRepository(db);
      await repo.upsert(
        ComposerDraft(
          id: 'a',
          uid: 'u1',
          text: 'hi',
          createdAt: kBase,
          updatedAt: kBase,
        ),
      );
      final claim = await repo.claimSend(
        draft: (await repo.read('u1', 'a'))!,
        kind: SendKind.schedule,
        publishAt: kBase,
        newKey: () => 'k1',
      );
      expect(claim.key, 'k1');
    },
  );

  test('a fresh database is at schema version 10', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 10);
  });
}
