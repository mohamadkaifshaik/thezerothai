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

  test('a fresh database is at schema version 9', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 9);
  });
}
