import 'dart:async';

import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_transport.dart';
import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

/// The home feed on the start-up fallback with no sqlite at all
/// (`AppDatabase.keepingNothing`, e.g. the web without `sqlite3.wasm`): the
/// rows the server returned stay in memory for the session and render, as on
/// a normal cache. Real repository and store, fake transport.
void main() {
  const home = FeedKey.home();
  late AppDatabase db;
  late List<tl.GetHomeTimelineRequest> requests;
  late List<tl.GetHomeTimelineResponse> answers;
  late TimelineRepository timeline;
  late MockPostsRepository posts;
  late StreamController<String> removed;
  final cubits = <TimelineCubit>[];

  List<String> ids(TimelineState s) => [
    for (final e in s.entries) e.isGap ? 'gap' : e.postView!.post.postId,
  ];
  List<String> idsOf(Iterable<int> n) => [for (final i in n) postId(i)];

  void give(List<int> postIds, {String since = '', String next = ''}) {
    answers.add(
      tl.GetHomeTimelineResponse(
        posts: [for (final id in postIds) postView(id)],
        sinceToken: since,
        nextPageToken: next,
      ),
    );
  }

  TimelineCubit cubit() {
    final c = TimelineCubit(feed: home, timeline: timeline, posts: posts);
    cubits.add(c);
    return c;
  }

  setUp(() {
    db = AppDatabase.keepingNothing();
    requests = [];
    answers = [];
    final transport = FakeTransport((procedure, input) async {
      requests.add(input as tl.GetHomeTimelineRequest);
      if (answers.isEmpty) throw StateError('unscripted $procedure');
      return answers.removeAt(0);
    });
    timeline = TimelineRepository(
      apiClient: ApiClient.withTransport(transport),
      store: TimelineStore(db),
      gate: PostsFeatureGate(isPostsEnabled: () => true),
    );
    posts = MockPostsRepository();
    removed = StreamController<String>.broadcast();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
  });

  tearDown(() async {
    for (final c in cubits) {
      await c.close();
    }
    cubits.clear();
    await removed.close();
    await db.close();
  });

  test('the first page the server returned renders', () async {
    await db.claimCacheFor('a');
    give([6, 5, 4], since: 's1', next: 'older');
    final feed = cubit();

    await feed.load();

    expect(requests, hasLength(1));
    expect(feed.state.status, TimelineStatus.ready);
    expect(ids(feed.state), idsOf([6, 5, 4]));
    expect(feed.state.hasMore, isTrue);
  });

  test('paging appends the older page below the first', () async {
    give([6, 5, 4], since: 's1', next: 'older');
    give([3, 2, 1]);
    final feed = cubit();
    await feed.load();

    await feed.loadMore();

    expect(requests.last.pageToken, 'older');
    expect(ids(feed.state), idsOf([6, 5, 4, 3, 2, 1]));
    expect(feed.state.hasMore, isFalse);
  });

  test('a refresh sends the kept since_token and merges newer posts on top '
      '(deduped by id)', () async {
    give([6, 5, 4], since: 's1');
    give([8, 7, 6], since: 's2');
    final feed = cubit();
    await feed.load();

    await feed.refresh();

    expect(requests.last.sinceToken, 's1');
    expect(ids(feed.state), idsOf([8, 7, 6, 5, 4]));
    // The same session: a re-opened screen renders the rows with no call.
    final cached = await timeline.cached(home);
    expect([
      for (final p in cached.posts) p.post.postId,
    ], idsOf([8, 7, 6, 5, 4]));
  });

  test('an account switch clears the rows: the next account never sees '
      'them', () async {
    await db.claimCacheFor('a');
    give([6, 5, 4], since: 's1');
    await cubit().load();
    expect((await timeline.cached(home)).posts, hasLength(3), reason: 'kept');

    // What `wireAuthSession` runs for a switch from a to b.
    await wipeSessionData(database: db, timelineRepository: timeline);
    await db.claimCacheFor('b');

    expect((await timeline.cached(home)).entries, isEmpty);
    give([9], since: 'b1');
    final feed = cubit();
    await feed.load();
    expect(requests.last.sinceToken, isEmpty, reason: "a's token is gone");
    expect(ids(feed.state), idsOf([9]));
  });

  test(
    'memory is bounded like the normal cache (kTimelineRetention)',
    () async {
      final store = TimelineStore(db);
      await store.applyColdOpen(
        home,
        posts: [for (var i = kTimelineHardCap + 1; i >= 1; i--) postView(i)],
        sinceToken: 's1',
        nextPageToken: '',
        session: store.session,
      );

      final kept = await store.read(home);
      expect(kept.posts, hasLength(kTimelineRetention));
      expect(kept.posts.first.post.postId, postId(kTimelineHardCap + 1));
    },
  );
}
