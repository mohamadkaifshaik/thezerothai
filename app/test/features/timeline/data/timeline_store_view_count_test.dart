import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:fixnum/fixnum.dart';
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

  test('view_count survives the cache and an engagement patch; unset stays '
      'unset', () async {
    final counted = postView(1)..post.viewCount = Int64(1200);
    final hidden = postView(2);
    await store.applyRefresh(
      home,
      posts: [counted, hidden],
      sinceToken: 's',
      gapPageToken: '',
      session: store.session,
    );

    await store.patchEngagement(
      postId: postId(1),
      session: store.session,
      liked: true,
      likeCount: 5,
    );
    await store.patchEngagement(
      postId: postId(2),
      session: store.session,
      likeCount: 1,
    );

    final rows = {
      for (final e in (await store.read(home)).entries) e.itemKey: e.postView!,
    };
    expect(rows[postId(1)]!.post.hasViewCount(), isTrue);
    expect(rows[postId(1)]!.post.viewCount.toInt(), 1200);
    expect(rows[postId(1)]!.post.likeCount.toInt(), 5);
    expect(rows[postId(2)]!.post.hasViewCount(), isFalse);
  });

  test('a newer refresh replaces the count', () async {
    await store.applyRefresh(
      home,
      posts: [postView(1)..post.viewCount = Int64(1000)],
      sinceToken: 's',
      gapPageToken: '',
      session: store.session,
    );
    await store.applyRefresh(
      home,
      posts: [postView(1)..post.viewCount = Int64(1500)],
      sinceToken: 's2',
      gapPageToken: '',
      session: store.session,
    );
    final row = (await store.read(home)).entries.single.postView!;
    expect(row.post.viewCount.toInt(), 1500);
  });
}
