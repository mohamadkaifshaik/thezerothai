import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/messaging_fixtures.dart';

void main() {
  test('migrates a v6 database to v7, keeping data and adding the messaging '
      'tables', () async {
    // The v6 schema (device settings arrived in v6), with a row to keep.
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
          CREATE TABLE app_setting_entries (
            setting_key TEXT NOT NULL, setting_value TEXT NOT NULL,
            PRIMARY KEY (setting_key)
          )''');
        raw.execute("INSERT INTO app_setting_entries VALUES ('theme', 'dark')");
        raw.execute('PRAGMA user_version = 6');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    expect(await db.readSetting('theme'), 'dark');

    final store = MessagingStore(db);
    await store.applyThreadColdOpen(
      'c1',
      items: msgs(1, 2),
      conversation: conv('c1'),
      sinceToken: 's',
      nextPageToken: 'n',
      session: store.session,
    );
    final snap = await store.readThread('c1');
    expect(snap.messages, hasLength(2));
    expect(snap.sinceToken, 's');
    expect(snap.olderPageToken, 'n');
    expect(snap.conversation?.id, 'c1');

    for (final table in [
      'conversation_entries',
      'message_entries',
      'messaging_state_entries',
    ]) {
      final cols = await db.customSelect('PRAGMA table_info($table)').get();
      expect(cols, isNotEmpty, reason: table);
    }
  });

  test('a fresh database is at schema version 7', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 7);
  });

  test('clearAll wipes messaging rows but keeps device settings', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.writeSetting('theme', 'dark');
    final store = MessagingStore(db);
    await store.applyThreadColdOpen(
      'c1',
      items: msgs(1, 2),
      conversation: conv('c1'),
      sinceToken: 's',
      nextPageToken: '',
      session: store.session,
    );

    await db.clearAll();

    expect(await db.select(db.messageEntries).get(), isEmpty);
    expect(await db.select(db.conversationEntries).get(), isEmpty);
    expect(await db.select(db.messagingStateEntries).get(), isEmpty);
    expect(await db.readSetting('theme'), 'dark');
  });
}
