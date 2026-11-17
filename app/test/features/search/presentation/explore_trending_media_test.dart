import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/explore_trending_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/failing_image_cache.dart';
import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';

pb.PostView _photo(String id, int seconds) => pb.PostView(
  post: pb.Post(
    postId: id,
    kind: PostKind.POST_KIND_POST,
    createdAt: Timestamp(seconds: Int64(seconds)),
    media: [
      common.MediaRef(
        url: 'https://m.test/$id.webp',
        thumbUrl: 'https://m.test/$id-t.webp',
      ),
    ],
  ),
);

/// The Trending page at phone width with the global media feed on or off.
Future<void> _open(
  WidgetTester tester, {
  required FakeSearchRepository repo,
  required bool mediaOn,
}) async {
  useFailingImageCache();
  final rig = ContextPaneRig(search: repo);
  await rig.pump(
    tester,
    location: '/explore/trending',
    width: 390,
    height: 844,
    flags: {...kContextPaneFlags, if (mediaOn) 'trending_media'},
    page: (path) => switch (path) {
      '/explore/trending' => const ExploreTrendingScreen(),
      _ => Text('$path body'),
    },
  );
}

FakeSearchRepository _repo() => FakeSearchRepository()
  ..trendsResult = TrendsResult(
    trends: [searchTrend('tag1', 1000, 1)],
    computedAt: DateTime.now().subtract(const Duration(hours: 2)),
  )
  ..exploreMediaResult = SearchPostsPage(
    posts: [_photo('a', 30), _photo('b', 20)],
  );

void main() {
  group('Trending page (See all) with the Posts and Media sections', () {
    testWidgets('has no media feed: it lives in the Explore tab', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo, mediaOn: true);
      await tester.pumpAndSettle();
      expect(find.text('Media'), findsNothing);
      expect(find.byKey(const ValueKey('trending-media-a')), findsNothing);
      expect(repo.exploreMediaTokens, isEmpty);
      expect(find.text('#tag1'), findsOneWidget);
    });

    testWidgets('a row opens the hashtag in the Explore tab', (tester) async {
      final repo = _repo();
      await _open(tester, repo: repo, mediaOn: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('#tag1'));
      await tester.pumpAndSettle();
      expect(find.text('/explore body'), findsOneWidget);
    });

    testWidgets('Posts alone does the same', (tester) async {
      final repo = _repo();
      useFailingImageCache();
      final rig = ContextPaneRig(search: repo);
      await rig.pump(
        tester,
        location: '/explore/trending',
        width: 390,
        height: 844,
        flags: {...kContextPaneFlags, 'trending_posts'},
        page: (path) => switch (path) {
          '/explore/trending' => const ExploreTrendingScreen(),
          _ => Text('$path body'),
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('#tag1'));
      await tester.pumpAndSettle();
      expect(find.text('/explore body'), findsOneWidget);
    });
  });

  group('Trending page (See all), both section flags off', () {
    testWidgets('asks nothing for media and a row opens the results', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo, mediaOn: false);
      await tester.pumpAndSettle();
      expect(find.text('Media'), findsNothing);
      expect(repo.exploreMediaTokens, isEmpty);
      expect(find.text('#tag1'), findsOneWidget);
      await tester.tap(find.text('#tag1'));
      await tester.pumpAndSettle();
      expect(find.text('/search body'), findsOneWidget);
    });
  });
}
