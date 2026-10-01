import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _home = '/dzeroth.timeline.v1.TimelineService/GetHomeTimeline';
const _user = '/dzeroth.timeline.v1.TimelineService/GetUserTimeline';

void main() {
  late AppDatabase db;
  late TimelineStore store;
  late FakeTransport transport;
  late TimelineRepository repo;
  late PostsFeatureGate gate;
  var postsOn = true;

  // Requests seen, and the queue of scripted answers per procedure.
  late List<Object> requests;
  late Map<String, List<Object>> script;

  void giveHome(
    List<int> ids, {
    String next = '',
    String since = '',
    String gap = '',
  }) {
    script[_home]!.add(
      tl.GetHomeTimelineResponse(
        posts: [for (final id in ids) postView(id)],
        nextPageToken: next,
        sinceToken: since,
        gapPageToken: gap,
      ),
    );
  }

  setUp(() {
    postsOn = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TimelineStore(db);
    requests = [];
    script = {_home: [], _user: []};
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final queue = script[procedure]!;
      if (queue.isEmpty) throw StateError('unscripted call to $procedure');
      final next = queue.removeAt(0);
      if (next is Exception) throw next;
      return next;
    });
    gate = PostsFeatureGate(isPostsEnabled: () => postsOn);
    repo = TimelineRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: gate,
    );
  });

  tearDown(() => db.close());

  List<String> ids(TimelineSnapshot s) => [
    for (final e in s.entries) e.isGap ? 'gap' : e.postView!.post.postId,
  ];
  List<String> idsOf(List<int> n) => [for (final i in n) postId(i)];

  const home = FeedKey.home();

  group('cold start and first refresh', () {
    test('first refresh stores items, since and scroll token', () async {
      giveHome([5, 4], next: 'older1', since: 's1');

      final snap = await repo.refresh(home);

      expect(ids(snap), idsOf([5, 4]));
      expect(snap.sinceToken, 's1');
      expect(snap.olderPageToken, 'older1');
      final sent = requests.single as tl.GetHomeTimelineRequest;
      expect(sent.sinceToken, isEmpty);
      expect(sent.pageToken, isEmpty);
    });

    test('a cached feed renders offline with no network call', () async {
      giveHome([5, 4], since: 's1');
      await repo.refresh(home);
      requests.clear();

      // A new session: same database, transport that fails if touched.
      final offline = TimelineRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((_, _) async => throw StateError('network touched')),
        ),
        store: TimelineStore(db),
        gate: gate,
      );
      final snap = await offline.cached(home);

      expect(ids(snap), idsOf([5, 4]));
      expect(snap.sinceToken, 's1');
      expect(requests, isEmpty);
    });
  });

  group('refresh merge', () {
    setUp(() async {
      giveHome([5, 4, 3], next: 'older1', since: 's1');
      await repo.refresh(home);
      requests.clear();
    });

    test('sends the stored since_token and nothing else', () async {
      giveHome([6], since: 's2');
      await repo.refresh(home);
      final sent = requests.single as tl.GetHomeTimelineRequest;
      expect(sent.sinceToken, 's1');
      expect(sent.pageToken, isEmpty);
    });

    test('a post already cached is held once, at its sort position', () async {
      // Settle window repeats 5 and carries an updated copy of it.
      script[_home]!.add(
        tl.GetHomeTimelineResponse(
          posts: [postView(6), postView(5, text: 'edited copy')],
          sinceToken: 's2',
        ),
      );

      final snap = await repo.refresh(home);

      expect(ids(snap), idsOf([6, 5, 4, 3]));
      expect(snap.sinceToken, 's2');
      expect(snap.entries[1].postView!.post.text, 'edited copy');
      expect(snap.olderPageToken, 'older1');
    });

    test('an empty response keeps the stored since_token', () async {
      giveHome(const [], since: '');
      final snap = await repo.refresh(home);
      expect(snap.sinceToken, 's1');
      expect(ids(snap), idsOf([5, 4, 3]));
    });

    test('gap_page_token persists a gap row between new and old', () async {
      giveHome([20, 19], since: 's2', gap: 'gap1');

      final snap = await repo.refresh(home);

      expect(ids(snap), [...idsOf([20, 19]), 'gap', ...idsOf([5, 4, 3])]);
      final gap = snap.entries.firstWhere((e) => e.isGap);
      expect(gap.gapToken, 'gap1');

      // Survives a restart.
      final again = await TimelineStore(db).read(home);
      expect(ids(again), ids(snap));
    });

    test('filling a gap merges until a cached post is reached', () async {
      giveHome([20, 19], since: 's2', gap: 'gap1');
      final withGap = await repo.refresh(home);
      final gapKey = withGap.entries.firstWhere((e) => e.isGap).itemKey;
      requests.clear();

      // First gap page: all new, more below -> gap moves down.
      giveHome([15, 14], next: 'gap2');
      var snap = await repo.fillGap(home, gapKey);
      expect(
        ids(snap),
        [...idsOf([20, 19, 15, 14]), 'gap', ...idsOf([5, 4, 3])],
      );
      expect((requests.single as tl.GetHomeTimelineRequest).pageToken, 'gap1');
      expect(snap.entries.firstWhere((e) => e.isGap).gapToken, 'gap2');

      // Second page reaches cached post 5: stop merging, gap closed.
      giveHome([10, 5, 4], next: 'gap3');
      final key2 = snap.entries.firstWhere((e) => e.isGap).itemKey;
      snap = await repo.fillGap(home, key2);
      expect(ids(snap), idsOf([20, 19, 15, 14, 10, 5, 4, 3]));
    });

    test('a gap page with no next token closes the gap', () async {
      giveHome([20], since: 's2', gap: 'gap1');
      final withGap = await repo.refresh(home);
      final gapKey = withGap.entries.firstWhere((e) => e.isGap).itemKey;
      giveHome([10], next: '');
      final snap = await repo.fillGap(home, gapKey);
      expect(ids(snap), idsOf([20, 10, 5, 4, 3]));
    });
  });

  group('rejected tokens (ADR-0010 D14)', () {
    setUp(() async {
      giveHome([5, 4, 3], next: 'older1', since: 's1');
      await repo.refresh(home);
      requests.clear();
    });

    test('rejected since_token: cleared, exactly one cold open, cache stays '
        'visible, cold next token becomes the gap filler', () async {
      script[_home]!.add(rejectedToken('since_token'));
      giveHome([30, 29], next: 'fillgap', since: 's9');

      final snap = await repo.refresh(home);

      expect(requests, hasLength(2));
      final first = requests[0] as tl.GetHomeTimelineRequest;
      final cold = requests[1] as tl.GetHomeTimelineRequest;
      expect(first.sinceToken, 's1');
      expect(cold.sinceToken, isEmpty);
      expect(cold.pageToken, isEmpty);
      expect(snap.sinceToken, 's9');
      expect(ids(snap), [...idsOf([30, 29]), 'gap', ...idsOf([5, 4, 3])]);
      expect(snap.entries.firstWhere((e) => e.isGap).gapToken, 'fillgap');
    });

    test('cold open stops at the first cached post and merges only the new '
        'items before it', () async {
      script[_home]!.add(rejectedToken('since_token'));
      // 5 is cached; 2 is NOT cached but sits below the overlap: ignored.
      giveHome([7, 6, 5, 2], next: 'tok', since: 's9');

      final snap = await repo.refresh(home);

      expect(ids(snap), idsOf([7, 6, 5, 4, 3]));
      expect(snap.entries.any((e) => e.isGap), isFalse);
    });

    test('cold open that already reaches a cached post adds no gap', () async {
      script[_home]!.add(rejectedToken('since_token'));
      giveHome([6, 5], next: 'whatever', since: 's9');

      final snap = await repo.refresh(home);

      expect(ids(snap), idsOf([6, 5, 4, 3]));
    });

    test('cached items stay visible when the cold open itself fails', () async {
      script[_home]!
        ..add(rejectedToken('since_token'))
        ..add(
          connect.ConnectException(connect.Code.unavailable, 'down'),
        );

      await expectLater(repo.refresh(home), throwsA(isA<NetworkException>()));
      expect(requests, hasLength(2));

      final snap = await repo.cached(home);
      expect(ids(snap), idsOf([5, 4, 3]));
      expect(snap.sinceToken, isEmpty, reason: 'the bad token is dropped');
    });

    test('a refresh with no since_token goes straight to a cold open', () async {
      script[_home]!.add(rejectedToken('since_token'));
      giveHome([6, 5], since: 's9');
      await repo.refresh(home);
      requests.clear();
      // Make the stored token empty again, then refresh.
      await store.clearSince(home);
      giveHome([7, 6], since: 's10');
      await repo.refresh(home);
      expect(requests, hasLength(1));
    });

    test('other validation errors are not treated as a rejected token',
        () async {
      script[_home]!.add(rejectedToken('page_size'));
      await expectLater(
        repo.refresh(home),
        throwsA(isA<ValidationException>()),
      );
      expect(requests, hasLength(1));
      expect((await repo.cached(home)).sinceToken, 's1');
    });

    test('rejected page_token on scroll: dropped, one cold open rebuilds the '
        'feed', () async {
      script[_home]!.add(rejectedToken('page_token'));
      giveHome([40, 39], next: 'o2', since: 's5');

      final snap = await repo.loadOlder(home);

      expect(requests, hasLength(2));
      expect((requests[0] as tl.GetHomeTimelineRequest).pageToken, 'older1');
      final cold = requests[1] as tl.GetHomeTimelineRequest;
      expect(cold.pageToken, isEmpty);
      expect(cold.sinceToken, isEmpty);
      expect(ids(snap), idsOf([40, 39]));
      expect(snap.olderPageToken, 'o2');
    });
  });

  group('loadOlder', () {
    test('appends the next page, dedupes, and advances the token', () async {
      giveHome([5, 4], next: 'older1', since: 's1');
      await repo.refresh(home);
      requests.clear();

      giveHome([4, 3, 2], next: '');
      final snap = await repo.loadOlder(home);

      expect(ids(snap), idsOf([5, 4, 3, 2]));
      expect(snap.hasMore, isFalse);
      expect((requests.single as tl.GetHomeTimelineRequest).pageToken,
          'older1');

      requests.clear();
      await repo.loadOlder(home);
      expect(requests, isEmpty, reason: 'nothing older: no call');
    });

    test('concurrent identical calls share one request', () async {
      giveHome([5, 4], next: 'older1', since: 's1');
      await repo.refresh(home);
      requests.clear();
      giveHome([3], next: '');

      await Future.wait([repo.loadOlder(home), repo.loadOlder(home)]);

      expect(requests, hasLength(1));
    });
  });

  group('retention', () {
    List<int> range(int from, int to) => [for (var i = from; i > to; i--) i];

    test('scrolling never prunes: the page just fetched survives and the '
        'next loadOlder asks for its token', () async {
      giveHome(range(2000, 1600), next: 't1', since: 's1');
      await repo.refresh(home);
      giveHome(range(1600, 1200), next: 't2');
      await repo.loadOlder(home);
      giveHome(range(1200, 800), next: 't3');
      var snap = await repo.loadOlder(home);

      expect(snap.posts, hasLength(1200));
      expect(snap.olderPageToken, 't3');

      requests.clear();
      giveHome(range(800, 400), next: 't4');
      snap = await repo.loadOlder(home);
      expect((requests.single as tl.GetHomeTimelineRequest).pageToken, 't3');
      expect(snap.posts, hasLength(1600));
      expect(snap.olderPageToken, 't4');
    });

    test('a refresh trims at a page boundary and scrolling resumes from the '
        'cut', () async {
      giveHome(range(2000, 1600), next: 't1', since: 's1');
      await repo.refresh(home);
      giveHome(range(1600, 1200), next: 't2');
      await repo.loadOlder(home);
      giveHome(range(1200, 800), next: 't3');
      await repo.loadOlder(home); // 1200 posts, past the 1000 hard cap

      giveHome([2001], since: 's2');
      final snap = await repo.refresh(home);

      // Cut at the first token row >= 500th that is under the cap: the end
      // of page 2 (row 800 of 1201).
      expect(snap.posts, hasLength(801));
      expect(snap.olderPageToken, 't2');
      requests.clear();
      giveHome(range(1200, 800), next: 't3');
      await repo.loadOlder(home);
      expect((requests.single as tl.GetHomeTimelineRequest).pageToken, 't2');
    });

    test('exactly 500 posts are all kept with their scroll token', () async {
      giveHome(range(500, 0), next: 'older1', since: 's1');
      final snap = await repo.refresh(home);
      expect(snap.posts, hasLength(500));
      expect(snap.olderPageToken, 'older1');
    });

    test('a feed past the hard cap with no boundary is cut to 500 and the '
        'scroll token cleared', () async {
      giveHome(range(1100, 0), next: 'older1', since: 's1');
      final snap = await repo.refresh(home);
      expect(snap.posts, hasLength(kTimelineRetention));
      expect(snap.entries.last.postView!.post.postId, postId(601));
      expect(snap.olderPageToken, isEmpty);
    });

    test('between 500 and the hard cap with no boundary nothing is trimmed',
        () async {
      giveHome(range(600, 90), next: 'older1', since: 's1');
      final snap = await repo.refresh(home);
      expect(snap.posts, hasLength(510));
      expect(snap.olderPageToken, 'older1');
    });
  });

  group('sign-out race (privacy)', () {
    test('an in-flight refresh that completes after sign-out writes nothing',
        () async {
      final gateOpen = Completer<void>();
      final slowTransport = FakeTransport((procedure, input) async {
        await gateOpen.future;
        return tl.GetHomeTimelineResponse(
          posts: [postView(5, authorId: 'userA')],
          sinceToken: 'sA',
          nextPageToken: 'oA',
        );
      });
      final slowRepo = TimelineRepository(
        apiClient: ApiClient.withTransport(slowTransport),
        store: store,
        gate: gate,
      );

      final pending = slowRepo.refresh(home);
      await Future<void>.delayed(Duration.zero);
      slowRepo.clearSession();
      await db.clearAll();
      gateOpen.complete();
      await pending;

      final snap = await store.read(home);
      expect(snap.entries, isEmpty);
      expect(snap.sinceToken, isEmpty);
      expect(snap.olderPageToken, isEmpty);
    });

    test('wipeSessionData ends the session and wipes the cache', () async {
      giveHome([5], since: 's1');
      await repo.refresh(home);
      final session = store.session;

      await wipeSessionData(database: db);

      expect(store.session, isNot(session));
      expect((await store.read(home)).entries, isEmpty);
    });

    test('the next user can load normally after sign-out', () async {
      giveHome([5], since: 's1');
      await repo.refresh(home);
      repo.clearSession();
      await db.clearAll();

      giveHome([9], since: 'sB');
      final snap = await repo.refresh(home);
      expect(ids(snap), idsOf([9]));
    });
  });

  group('user feeds', () {
    final feed = FeedKey.user('u9');

    test('sends user_id and tab, and caches per feed', () async {
      script[_user]!.add(
        tl.GetUserTimelineResponse(posts: [postView(3, authorId: 'u9')],
            sinceToken: 'us1'),
      );

      final snap = await repo.refresh(feed);

      final sent = requests.single as tl.GetUserTimelineRequest;
      expect(sent.userId, 'u9');
      expect(sent.includeReplies, isFalse);
      expect(ids(snap), idsOf([3]));
      expect(ids(await repo.cached(home)), isEmpty);
    });

    test('NOT_FOUND forgets that user\'s cached feed', () async {
      script[_user]!.add(
        tl.GetUserTimelineResponse(posts: [postView(3)], sinceToken: 'us1'),
      );
      await repo.refresh(feed);
      script[_user]!.add(
        connect.ConnectException(connect.Code.notFound, 'profile not found'),
      );

      await expectLater(repo.refresh(feed), throwsA(isA<NotFoundException>()));

      final snap = await repo.cached(feed);
      expect(snap.entries, isEmpty);
      expect(snap.sinceToken, isEmpty);
    });
  });

  group('feature flag', () {
    test('flag off: no timeline RPC is ever sent', () async {
      postsOn = false;

      await expectLater(
        repo.refresh(home),
        throwsA(isA<FeatureDisabledException>()),
      );
      await expectLater(
        repo.refresh(FeedKey.user('u9')),
        throwsA(isA<FeatureDisabledException>()),
      );

      expect(transport.calledProcedures, isEmpty);
    });

    test('FEATURE_DISABLED without a feature hides all of posts', () async {
      script[_home]!.add(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        ),
      );

      await expectLater(
        repo.refresh(home),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.postsEnabled, isFalse);

      transport.calledProcedures.clear();
      await expectLater(
        repo.refresh(home),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);
    });
  });
}
