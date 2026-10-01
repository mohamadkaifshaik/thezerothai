import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';

void main() {
  late AppDatabase db;
  late TimelineStore store;
  const home = FeedKey.home();

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TimelineStore(db);
  });
  tearDown(() => db.close());

  Future<void> insertPost(int n) {
    return db
        .into(db.timelineItemEntries)
        .insert(
          TimelineItemEntriesCompanion.insert(
            feedKey: home.value,
            itemKey: postId(n),
            sortKey: postId(n),
            payload: Value(Uint8List.fromList(postView(n).writeToBuffer())),
          ),
        );
  }

  Future<void> insertGap(int n) {
    return db
        .into(db.timelineItemEntries)
        .insert(
          TimelineItemEntriesCompanion.insert(
            feedKey: home.value,
            itemKey: 'gap:${postId(n)}',
            sortKey: postId(n),
            gapToken: const Value('g'),
          ),
        );
  }

  Future<TimelineSnapshot> refreshEmpty() async {
    await store.applyRefresh(
      home,
      posts: const [],
      sinceToken: 's',
      gapPageToken: '',
      session: store.session,
    );
    return store.read(home);
  }

  test('a cut also removes gap rows below it', () async {
    for (var n = 1100; n > 0; n--) {
      await insertPost(n);
    }
    await insertGap(50);

    final snap = await refreshEmpty();

    expect(snap.posts, hasLength(kTimelineRetention));
    expect(snap.entries.any((e) => e.isGap), isFalse);
    expect(snap.olderPageToken, isEmpty);
  });

  test('a gap row above the cut survives', () async {
    for (var n = 1100; n > 0; n--) {
      await insertPost(n);
    }
    await insertGap(1050);

    final snap = await refreshEmpty();

    expect(snap.entries.where((e) => e.isGap), hasLength(1));
  });

  test('writes started before endSession are dropped', () async {
    final session = store.session;
    store.endSession();
    await store.applyRefresh(
      home,
      posts: [postView(1)],
      sinceToken: 's',
      gapPageToken: '',
      session: session,
    );
    await store.clearSince(home, session: session);
    expect((await store.read(home)).entries, isEmpty);
  });
}
