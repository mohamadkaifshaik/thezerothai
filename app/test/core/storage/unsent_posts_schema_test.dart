import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart'
    show kPostSendKeyWindow;
import 'package:dzeroth/features/posts/data/unsent_posts_store.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

ProcessedImage _image(int bytes, String tag) => ProcessedImage(
  fullBytes: Uint8List(bytes)..fillRange(0, bytes, tag.codeUnitAt(0)),
  thumbBytes: Uint8List.fromList([1, 2, 3]),
  width: 800,
  height: 600,
  fullMd5: 'full-$tag',
  thumbMd5: 'thumb-$tag',
  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
);

UnsentPostRecord _post(
  String uid,
  String id, {
  int photos = 1,
  int bytes = 40,
  DateTime? at,
  bool photosKept = true,
}) => UnsentPostRecord(
  uid: uid,
  postId: id,
  text: 'text $id',
  author: common.AuthorSnapshot(userId: uid, handle: 'h$uid'),
  createdAt: at ?? DateTime.now(),
  poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60),
  replyAudience: ReplyAudience.following,
  communityId: '1234567890123456789',
  key: 'key-$id',
  keyStartedAt: DateTime.now().subtract(const Duration(hours: 2)),
  keyUsed: true,
  ambiguous: true,
  photosKept: photosKept,
  photos: [
    for (var i = 0; i < photos; i++)
      StoredPhoto(image: _image(bytes, '$i'), altText: 'alt $i'),
  ],
);

void main() {
  test('migrates a v14 database to v15, keeping rows and adding the unsent '
      'post tables', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
          CREATE TABLE app_setting_entries (
            setting_key TEXT NOT NULL, setting_value TEXT NOT NULL,
            PRIMARY KEY (setting_key)
          )''');
        raw.execute("INSERT INTO app_setting_entries VALUES ('theme', 'dark')");
        raw.execute('PRAGMA user_version = 14');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    expect(await db.readSetting('theme'), 'dark');
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 15);

    final store = UnsentPostsStore(db, keepsPhotoBytes: true);
    await store.save(_post('u1', 'p1'), epoch: db.sessionEpoch.value);
    final back = await store.load('u1');
    expect(back.single.postId, 'p1');
    expect(back.single.photos, hasLength(1));
  });

  group('UnsentPostsStore', () {
    late AppDatabase db;
    late UnsentPostsStore store;
    var now = DateTime.now().toUtc();

    UnsentPostsStore make({
      bool keepsPhotoBytes = true,
      int maxPosts = 4,
      int maxBytes = 1000000,
    }) => UnsentPostsStore(
      db,
      now: () => now,
      keepsPhotoBytes: keepsPhotoBytes,
      maxPostsWithPhotos: maxPosts,
      maxBytes: maxBytes,
    );

    setUp(() {
      now = DateTime.now().toUtc();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = make();
    });
    tearDown(() async => db.close());

    int epoch() => db.sessionEpoch.value;

    test(
      'keeps everything a restore needs, and only processed bytes',
      () async {
        await store.save(_post('u1', 'a', photos: 2), epoch: epoch());
        final r = (await store.load('u1')).single;
        expect(r.text, 'text a');
        expect(r.poll!.choices, ['a', 'b']);
        expect(r.replyAudience, ReplyAudience.following);
        expect(r.communityId, '1234567890123456789');
        expect(r.key, 'key-a');
        expect(r.keyUsed, isTrue);
        expect(r.ambiguous, isTrue);
        expect(r.author.handle, 'hu1');
        expect(r.photos.map((p) => p.altText), ['alt 0', 'alt 1']);
        expect(r.photos.first.image.fullBytes, hasLength(40));
        expect(r.photos.first.image.thumbBytes, [1, 2, 3]);
        expect(r.photos.first.image.fullMd5, 'full-0');
      },
    );

    test('an account never reads another account\'s posts', () async {
      await store.save(_post('u1', 'a'), epoch: epoch());
      await store.save(_post('u2', 'b'), epoch: epoch());
      expect((await store.load('u1')).map((r) => r.postId), ['a']);
      expect((await store.load('u2')).map((r) => r.postId), ['b']);
      // The same post id under two accounts never collides.
      await store.save(_post('u2', 'a'), epoch: epoch());
      expect((await store.load('u1')).single.text, 'text a');
      expect((await store.load('u1')).single.author.handle, 'hu1');
    });

    test('the launch purge deletes what belongs to other accounts', () async {
      await store.save(_post('u1', 'a'), epoch: epoch());
      await store.save(_post('u2', 'b', photos: 2), epoch: epoch());
      await store.purgeOthers('u1');
      expect(await store.load('u2'), isEmpty);
      expect(await store.storedBytes('u2'), 0);
      expect((await store.load('u1')).single.postId, 'a');
    });

    test('rows older than the idempotency window are swept', () async {
      await store.save(
        _post('u1', 'old', at: now.subtract(kPostSendKeyWindow)),
        epoch: epoch(),
      );
      await store.save(
        _post('u1', 'new', at: now.subtract(const Duration(hours: 1))),
        epoch: epoch(),
      );
      expect((await store.load('u1')).map((r) => r.postId), ['new']);
      expect(await store.storedBytes('u1'), greaterThan(0));
      await store.delete('u1', 'new');
      expect(await store.storedBytes('u1'), 0);
    });

    test(
      'delete, deleteAll and deleteEverything remove rows and bytes',
      () async {
        await store.save(_post('u1', 'a'), epoch: epoch());
        await store.save(_post('u1', 'b'), epoch: epoch());
        await store.save(_post('u2', 'c'), epoch: epoch());
        await store.delete('u1', 'a');
        expect((await store.load('u1')).map((r) => r.postId), ['b']);
        await store.deleteAll('u1');
        expect(await store.load('u1'), isEmpty);
        expect(await store.storedBytes('u1'), 0);
        expect(await store.load('u2'), hasLength(1));
        await store.deleteEverything();
        expect(await store.load('u2'), isEmpty);
        expect(await store.storedBytes('u2'), 0);
      },
    );

    test('sign-out (clearAll) wipes the posts and the photo bytes', () async {
      await store.save(_post('u1', 'a'), epoch: epoch());
      await db.clearAll();
      expect(await store.load('u1'), isEmpty);
      expect(await store.storedBytes('u1'), 0);
    });

    test('a write from an ended session stores nothing', () async {
      final stale = epoch();
      db.sessionEpoch.end();
      final result = await store.save(_post('u1', 'a'), epoch: stale);
      expect(result, UnsentSave.textOnly);
      expect(await store.load('u1'), isEmpty);
    });

    test('past the post cap a post keeps its text only', () async {
      final small = make(maxPosts: 2);
      expect(
        await small.save(_post('u1', 'a'), epoch: epoch()),
        UnsentSave.full,
      );
      expect(
        await small.save(_post('u1', 'b'), epoch: epoch()),
        UnsentSave.full,
      );
      expect(
        await small.save(_post('u1', 'c'), epoch: epoch()),
        UnsentSave.textOnly,
      );
      final c = (await small.load('u1')).firstWhere((r) => r.postId == 'c');
      expect(c.text, 'text c');
      expect(c.photos, isEmpty);
      expect(c.photosKept, isFalse);
      // Saving a stored post again does not count it twice.
      expect(
        await small.save(_post('u1', 'a'), epoch: epoch()),
        UnsentSave.full,
      );
    });

    test('past the byte cap a post keeps its text only', () async {
      final small = make(maxBytes: 100);
      expect(
        await small.save(_post('u1', 'a', bytes: 30), epoch: epoch()),
        UnsentSave.full,
      );
      expect(
        await small.save(
          _post('u1', 'b', photos: 2, bytes: 40),
          epoch: epoch(),
        ),
        UnsentSave.textOnly,
      );
      // Another account has its own allowance.
      expect(
        await small.save(_post('u2', 'c', bytes: 90), epoch: epoch()),
        UnsentSave.full,
      );
    });

    test('the web keeps no photo bytes: text and key only', () async {
      final web = make(keepsPhotoBytes: false);
      expect(
        await web.save(_post('u1', 'a'), epoch: epoch()),
        UnsentSave.textOnly,
      );
      final r = (await web.load('u1')).single;
      expect(r.photos, isEmpty);
      expect(r.photosKept, isFalse);
      expect(r.key, 'key-a');
      expect(await web.storedBytes('u1'), 0);
    });

    test('a post without photos is whole without them', () async {
      expect(
        await store.save(_post('u1', 'a', photos: 0), epoch: epoch()),
        UnsentSave.full,
      );
      expect((await store.load('u1')).single.photosKept, isTrue);
    });

    test('updateKey changes the key and keeps the photos', () async {
      await store.save(_post('u1', 'a'), epoch: epoch());
      await store.updateKey(
        'u1',
        'a',
        epoch: epoch(),
        key: 'other',
        keyStartedAt: DateTime.now().subtract(const Duration(hours: 1)),
        keyUsed: false,
        ambiguous: false,
      );
      final r = (await store.load('u1')).single;
      expect(r.key, 'other');
      expect(r.keyUsed, isFalse);
      expect(r.photos, hasLength(1));
    });
  });
}
